import http.Request
import http.Response
import JsonEachRow

Client :: [].{

	## Connection credentials stay in HTTP headers. The transport owns TLS,
	## connection pooling, cancellation and enforcing limits before allocation.
	Config : { endpoint : Str, database : Str, username : Str, password : Str, timeout_ms : U64, max_response_bytes : U64 }
	Query : { sql : Str, body : List(U8), parameters : List({ name : Str, value : Str }), async_insert : Bool, query_id : Str, settings : List({ name : Str, value : Str }), streaming : Bool }
	Error : { status : U16, code : Str, message : Str }

	default_config : Config
	default_config = { endpoint: "http://127.0.0.1:8123", database: "default", username: "default", password: "", timeout_ms: 8_000, max_response_bytes: 1_048_576 }

	query : Str -> Query
	query = |sql| { sql, body: [], parameters: [], async_insert: False, query_id: "", settings: [], streaming: False }

	## Typed entry points own the output format and numeric representation.
	typed_query : Query -> Try(Query, [InvalidConfig(Str)])
	typed_query = |statement| {
		if statement.body.is_empty() == False {
			return Err(InvalidConfig("query body"))
		}
		Ok({
			..statement,
			settings: statement.settings.keep_if(|setting| setting.name != "default_format" and setting.name != "output_format_json_quote_64bit_integers" and setting.name != "output_format_json_quote_decimals" and setting.name != "date_time_output_format" and setting.name != "http_write_exception_in_output_format").concat([
				{ name: "default_format", value: "JSONEachRow" },
				{ name: "output_format_json_quote_64bit_integers", value: "0" },
				{ name: "output_format_json_quote_decimals", value: "1" },
				{ name: "date_time_output_format", value: "simple" },
				{ name: "http_write_exception_in_output_format", value: "0" },
			]),
		})
	}

	query! = |send_http!, config, statement| {
		prepared = typed_query(statement)?
		response = send!(send_http!, config, prepared)?
		match JsonEachRow.decode(Response.body(response)) {
			Err(ClickHouseException(error)) => Err(ClickHouseError({ status: Response.status(response), code: error.code, message: error.message }))
			other => other
		}
	}

	## The transport returns {status, headers, chunks}; chunks is a lazy Stream
	## of Try(List(U8), transport_error). It must close on early release.
	stream! = |open_http!, config, statement, options| {
		if options.max_row_bytes == 0 or options.max_chunk_bytes == 0 {
			return Err(InvalidConfig("stream limits"))
		}
		prepared = typed_query(statement)?
		outgoing = request(config, { ..prepared, streaming: True })?
		response = open_http!(outgoing) ? TransportError
		metadata = Response.from_status(response.status).with_headers(response.headers)
		match check_response(metadata) {
			Ok(_) => {}
			Err(_) => {
				var $diagnostic = []
				for! chunk in response.chunks.take_first(1) {
					bytes = chunk ? TransportError
					$diagnostic = bytes.take_first(4096)
				}
				_ = check_response(metadata.with_body($diagnostic))?
			}
		}
		JsonEachRow.stream(response.chunks, options)
	}

	default_stream_options = { max_row_bytes: 1_048_576.U64, max_chunk_bytes: 65_536.U64 }
	default_insert_options : { max_rows : U64, max_bytes : U64, async_insert : Bool, query_id : Str }
	default_insert_options = { max_rows: 1000.U64, max_bytes: 1_048_576.U64, async_insert: False, query_id: "" }

	## Table parts are identifiers, never SQL fragments. Database qualification
	## is explicit through a list such as ["analytics", "events"].
	insert_sql : List(Str) -> Try(Str, [InvalidConfig(Str)])
	insert_sql = |table| {
		if table.is_empty() {
			return Err(InvalidConfig("table"))
		}
		names = table.map_try(
			|part| {
				if part.is_empty() or part.to_utf8().any(|byte| byte < 32 or byte == 127) {
					return Err(InvalidConfig("table"))
				}
				Ok("`${part.replace_each("\\", "\\\\").replace_each("`", "\\`")}`")
			},
		)?
		Ok("INSERT INTO ${Str.join_with(names, ".")} FORMAT JSONEachRow")
	}

	insert! = |send_http!, config, table, rows, options| insert_stream!(send_http!, config, table, rows.iter().stream().map(|row| Ok(row)), options)

	## Pull only one bounded batch at a time; successful batches are durable
	## progress. Failure never retries and carries confirmed row/batch counts.
	insert_stream! = |send_http!, config, table, rows, options| {
		sql = insert_sql(table)?
		if options.max_rows == 0 or options.max_bytes == 0 {
			return Err(InvalidConfig("batch limits"))
		}
		_ = request(config, query(sql))?
		var $body = []
		var $count = 0.U64
		var $confirmed = { rows: 0.U64, batches: 0.U64 }
		for! item in rows {
			row = item ? |error| InsertFailed({ confirmed: $confirmed, cause: SourceError(error) })
			encoded = JsonEachRow.encode([row]) ? |error| InsertFailed({ confirmed: $confirmed, cause: error })
			bytes = encoded.concat([10])
			if bytes.len() > options.max_bytes {
				return Err(InsertFailed({ confirmed: $confirmed, cause: RowTooLarge({ line: $confirmed.rows + $count + 1, limit: options.max_bytes }) }))
			}
			if $count > 0 and ($body.len() + bytes.len() > options.max_bytes) {
				_ = send_batch!(send_http!, config, sql, $body, options, $confirmed.batches) ? |cause| InsertFailed({ confirmed: $confirmed, cause })
				$confirmed = { rows: $confirmed.rows + $count, batches: $confirmed.batches + 1 }
				$body = []
				$count = 0
			}
			$body = $body.concat(bytes)
			$count = $count + 1
			if $count >= options.max_rows {
				_ = send_batch!(send_http!, config, sql, $body, options, $confirmed.batches) ? |cause| InsertFailed({ confirmed: $confirmed, cause })
				$confirmed = { rows: $confirmed.rows + $count, batches: $confirmed.batches + 1 }
				$body = []
				$count = 0
			}
		}
		if $count > 0 {
			_ = send_batch!(send_http!, config, sql, $body, options, $confirmed.batches) ? |cause| InsertFailed({ confirmed: $confirmed, cause })
			$confirmed = { rows: $confirmed.rows + $count, batches: $confirmed.batches + 1 }
		}
		Ok($confirmed)
	}

	cancel! = |send_http!, config, query_id| {
		if query_id.is_empty() {
			return Err(InvalidConfig("query_id"))
		}
		statement = { ..query("KILL QUERY WHERE query_id={id:String} SYNC"), parameters: [string_parameter("id", query_id)] }
		result : Try(List({ kill_status : Str, query_id : Str }), _)
		result = query!(send_http!, config, statement)
		result
	}

	## Serialize a String value for a {name:String} placeholder. Other scalar
	## parameters use their ClickHouse text representation directly in value.
	string_parameter : Str, Str -> { name : Str, value : Str }
	string_parameter = |name, value| {
		escaped = value.to_utf8().map(
			|byte| match byte {
				0 => [92, 48]
				8 => [92, 98]
				9 => [92, 116]
				10 => [92, 110]
				12 => [92, 102]
				13 => [92, 114]
				92 => [92, 92]
				_ => [byte]
			},
		).join()
		{ name, value: Str.from_utf8(escaped) ?? "" }
	}

	request : Config, Query -> Try(Request, [InvalidConfig(Str), InvalidParameter(Str)])
	request = |config, statement| {
		authority = Str.split_on(config.endpoint, "://").last() ?? ""
		if (config.endpoint.starts_with("http://") or config.endpoint.starts_with("https://")) == False or
			authority.is_empty() or authority.starts_with("/") or
				config.endpoint.contains("?") or config.endpoint.contains("#") or config.endpoint.contains("@") or
					config.endpoint.to_utf8().any(|byte| byte <= 32 or byte == 127 or byte == 92) {
			return Err(InvalidConfig("endpoint"))
		}
		if config.timeout_ms == 0 {
			return Err(InvalidConfig("timeout_ms"))
		}
		if config.max_response_bytes == 0 {
			return Err(InvalidConfig("max_response_bytes"))
		}
		if statement.sql.trim().is_empty() {
			return Err(InvalidConfig("sql"))
		}
		if config.username.to_utf8().any(|byte| byte < 32 or byte == 127) {
			return Err(InvalidConfig("username"))
		}
		if config.password.to_utf8().any(|byte| byte < 32 or byte == 127) {
			return Err(InvalidConfig("password"))
		}

		_ = statement.parameters.fold(
			Ok(Dict.empty()),
			|acc, parameter| {
				seen = acc?
				bytes = parameter.name.to_utf8()
				first = bytes.first() ?? 0
				valid_first = (first >= 65 and first <= 90) or (first >= 97 and first <= 122) or first == 95
				valid_rest = bytes.all(|byte| (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or (byte >= 48 and byte <= 57) or byte == 95)
				if valid_first == False or valid_rest == False or seen.contains(parameter.name) {
					Err(InvalidParameter(parameter.name))
				} else {
					Ok(seen.insert(parameter.name, {}))
				}
			},
		)?

		_ = statement.settings.fold(
			Ok(Dict.empty()),
			|acc, setting| {
				seen = acc?
				valid = setting.name.is_empty() == False and setting.name.to_utf8().all(|byte| (byte >= 97 and byte <= 122) or (byte >= 48 and byte <= 57) or byte == 95)
				reserved = ["query", "database", "user", "password", "query_id", "async_insert", "wait_for_async_insert", "wait_end_of_query", "send_progress_in_http_headers", "enable_http_compression"].contains(setting.name) or setting.name.starts_with("param_")
				if valid == False or reserved or seen.contains(setting.name) {
					Err(InvalidConfig("settings"))
				} else {
					Ok(seen.insert(setting.name, {}))
				}
			},
		)?

		separator = if config.endpoint.ends_with("/") {
			""
		} else {
			"/"
		}
		parameters = statement.parameters.map(|parameter| "&param_${parameter.name}=${percent_encode(parameter.value)}")
		async_options = if statement.async_insert {
			"&async_insert=1&wait_for_async_insert=1"
		} else {
			""
		}
		query_id = if statement.query_id.is_empty() {
			""
		} else {
			"&query_id=${percent_encode(statement.query_id)}"
		}
		settings = statement.settings.map(|setting| "&${percent_encode(setting.name)}=${percent_encode(setting.value)}")
		wait = if statement.streaming {
			"0"
		} else {
			"1"
		}
		uri = "${config.endpoint}${separator}?database=${percent_encode(config.database)}&query=${percent_encode(statement.sql)}&wait_end_of_query=${wait}&send_progress_in_http_headers=0${async_options}${query_id}${Str.join_with(parameters, "")}${Str.join_with(settings, "")}"
		# Some transports discard Content-Length: 0. A separator newline
		# keeps POST framing explicit without changing the SQL in the URL.
		body = if statement.body.is_empty() {
			[10]
		} else {
			statement.body
		}
		Ok(
			Request.from_method(POST)
				.with_uri(uri)
				.with_headers([
					{ name: "Content-Type", value: "application/x-ndjson; charset=utf-8" },
					{ name: "X-ClickHouse-User", value: config.username },
					{ name: "X-ClickHouse-Key", value: config.password },
					{ name: "Content-Length", value: body.len().to_str() },
				])
				.with_body(body)
				.with_timeout(TimeoutMilliseconds(config.timeout_ms)),
		)
	}

	## The supplied effect must enforce max_response_bytes while receiving the
	## response, and honor the deadline attached to Request. Called exactly once.
	send! = |send_http!, config, statement| {
		outgoing = request(config, statement)?
		response = send_http!(outgoing, config.max_response_bytes) ? TransportError
		if Response.body(response).len() > config.max_response_bytes {
			return Err(ResponseTooLarge)
		}
		check_response(response)
	}

	## Check transport status and a ClickHouse exception header. Buffering is
	## requested by request; decode structured results to detect late errors too.
	check_response : Response -> Try(Response, [ClickHouseError(Error), HttpError(Error)])
	check_response = |response| {
		code = Response.headers(response).fold(
			"",
			|found, header| {
				if lowercase_ascii(header.name) == "x-clickhouse-exception-code" {
					header.value.trim()
				} else {
					found
				}
			},
		)
		status = Response.status(response)
		body = Str.from_utf8(Response.body(response)) ?? ""
		body_exception = JsonEachRow.is_exception(body)
		if status < 200 or status >= 300 or (code.is_empty() == False and code != "0") or body_exception {
			message = Str.from_utf8(Response.body(response).take_first(4096)) ?? "ClickHouse returned a non-UTF-8 or truncated diagnostic"
			if (code.is_empty() == False and code != "0") or body_exception {
				actual_code = if code.is_empty() or code == "0" {
					match JsonEachRow.exception({ line: 1, bytes: Response.body(response) }) {
						ClickHouseException(error) => error.code
					}
				} else {
					code
				}
				Err(ClickHouseError({ status, code: actual_code, message }))
			} else {
				Err(HttpError({ status, code: "", message }))
			}
		} else {
			Ok(response)
		}
	}
}

percent_encode : Str -> Str
percent_encode = |value| Str.join_with(
	value.to_utf8().map(
		|byte| {
			if (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or (byte >= 48 and byte <= 57) or byte == 45 or byte == 46 or byte == 95 or byte == 126 {
				Str.from_utf8([byte]) ?? ""
			} else {
				"%${hex_digit(U8.to_u64(byte) / 16)}${hex_digit(U8.to_u64(byte) % 16)}"
			}
		},
	),
	"",
)

hex_digit : U64 -> Str
hex_digit = |value| ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"].get(value) ?? "0"

lowercase_ascii : Str -> Str
lowercase_ascii = |value| Str.from_utf8(
	value.to_utf8().map(
		|byte| if byte >= 65 and byte <= 90 {
			byte + 32
		} else {
			byte
		},
	),
) ?? ""

send_batch! = |send_http!, config, sql, body, options, batch| {
	query_id = if options.query_id.is_empty() {
		""
	} else {
		"${options.query_id}:${batch.to_str()}"
	}
	response = Client.send!(send_http!, config, { ..Client.query(sql), body, async_insert: options.async_insert, query_id })?
	if Response.body(response).is_empty() == False {
		return Err(UnexpectedInsertResponse)
	}
	Ok({})
}
