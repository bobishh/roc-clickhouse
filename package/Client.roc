import http.Request
import http.Response

Client :: [].{

	## Connection credentials stay in HTTP headers. The transport owns TLS,
	## connection pooling, cancellation and enforcing limits before allocation.
	Config : { endpoint : Str, database : Str, username : Str, password : Str, timeout_ms : U64, max_response_bytes : U64 }
	Query : { sql : Str, body : List(U8), parameters : List({ name : Str, value : Str }), async_insert : Bool, query_id : Str }
	Error : { status : U16, code : Str, message : Str }

	default_config : Config
	default_config = { endpoint: "http://127.0.0.1:8123", database: "default", username: "default", password: "", timeout_ms: 8_000, max_response_bytes: 1_048_576 }

	query : Str -> Query
	query = |sql| { sql, body: [], parameters: [], async_insert: False, query_id: "" }

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
		uri = "${config.endpoint}${separator}?database=${percent_encode(config.database)}&query=${percent_encode(statement.sql)}&wait_end_of_query=1&send_progress_in_http_headers=0${async_options}${query_id}${Str.join_with(parameters, "")}"
		Ok(
			Request.from_method(POST)
				.with_uri(uri)
				.with_headers([
					{ name: "Content-Type", value: "application/x-ndjson; charset=utf-8" },
					{ name: "X-ClickHouse-User", value: config.username },
					{ name: "X-ClickHouse-Key", value: config.password },
					{ name: "Content-Length", value: statement.body.len().to_str() },
				])
				.with_body(statement.body)
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
	check_response : Response -> Try(Response, [ClickHouseError(Error)])
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
		if status < 200 or status >= 300 or (code.is_empty() == False and code != "0") {
			message = Str.from_utf8(Response.body(response).take_first(4096)) ?? "ClickHouse returned a non-UTF-8 or truncated diagnostic"
			Err(ClickHouseError({ status, code, message }))
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
