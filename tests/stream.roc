app [main!] {
	ch: "../package/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import ch.Client
import ch.JsonEachRow
import ch.Types
import ch.Compression
import http.Response
import pf.Http
import pf.Env
import pf.Stdout
import pf.Cmd
import pf.Duration

Row : { id : U64, text : Str }

Input : { action : Str, sql ?: Str, endpoint ?: Str, rows ?: List(Row), table ?: List(Str), take ?: U64, max_rows ?: U64, max_bytes ?: U64, max_row_bytes ?: U64, timeout_ms ?: U64, query_id ?: Str, gzip ?: Bool, source_error ?: Bool }

main! = |_args| {
	input : Input
	input = Json.parse(Env.var_str!("INPUT")?)?
	if input.action == "selftest" {
		return selftest!()
	}
	endpoint = input.?endpoint ?? Env.var_str!("CLICKHOUSE_URL")?
	password = Env.var_str!("CLICKHOUSE_PASSWORD")?
	config = { ..Client.default_config, endpoint, password, timeout_ms: input.?timeout_ms ?? 8000, max_response_bytes: input.?max_bytes ?? 1_048_576 }
	statement = { ..Client.query(input.?sql ?? "SELECT id, text FROM events ORDER BY id"), query_id: input.?query_id ?? "" }
	send! = |request, limit| if input.?gzip ?? False {
		Compression.send!(gzip!, gunzip!, send_http!, request, limit)
	} else {
		send_http!(request, limit)
	}
	if input.action == "stream" {
		result : Try(Stream(Try(Row, _)), _)
		result = Client.stream!(open_http!, config, statement, { ..Client.default_stream_options, max_row_bytes: input.?max_row_bytes ?? 1_048_576 })
		match result {
			Err(error) => Stdout.line!(Json.to_str({ error: Str.inspect(error) }))?
			Ok(rows) => {
				for! row in rows.take_first(input.?take ?? U64.highest) {
					match row {
						Ok(value) => Stdout.line!(Json.to_str({ row: value }))?
						Err(error) => Stdout.line!(Json.to_str({ error: Str.inspect(error) }))?
					}
				}
				Stdout.line!("{\"end\":true}")?
			}
		}
	} else {
		match run!(send!, config, statement, input) {
			Ok(json) => Stdout.line!(json)?
			Err(error) => Stdout.line!(Json.to_str({ error: Str.inspect(error) }))?
		}
	}
	Ok({})
}

run! = |send!, config, statement, input| {
	value : Input
	value = input
	data : List(Row)
	data = value.?rows ?? []
	match input.action {
		"insert" | "insert_stream" => {
			options = { ..Client.default_insert_options, max_rows: input.?max_rows ?? 2, max_bytes: input.?max_bytes ?? 1_048_576, async_insert: True, query_id: input.?query_id ?? "" }
			source = data.iter().stream().map(
				|row| {
					Stdout.line!(Json.to_str({ pulled: row.id })) ? SourceLogError
					if (input.?source_error ?? False) and row.id == 3 {
						Err(Injected)
					} else {
						Ok(row)
					}
				},
			)
			progress = if input.action == "insert" {
				Client.insert!(send!, config, input.?table ?? ["events"], data, options)?
			} else {
				Client.insert_stream!(send!, config, input.?table ?? ["events"], source, options)?
			}
			Ok(Json.to_str({ progress: progress }))
		}
		"cancel" => {
			cancelled = Client.cancel!(send!, config, input.?query_id ?? "")?
			Ok(Json.to_str({ cancelled: cancelled }))
		}
		"scalars" => {
			rows : List({ u : U64, i : I64, d : Types.Decimal, at : Types.DateTime64, day : Types.Date, uuid : Types.Uuid, nullable : Types.Nullable(Str) })
			rows = Client.query!(send!, config, statement)?
			Json.to_str_try({ rows: rows }).map_err(|error| EncodeOutput(error))
		}
		_ => {
			rows : List(Row)
			rows = Client.query!(send!, config, statement)?
			Json.to_str_try({ rows: rows }).map_err(|error| EncodeOutput(error))
		}
	}
}

open_http! = |request| {
	response = Http.send_streaming!(request, {})?
	Ok({ status: response.status(), headers: response.headers(), chunks: response.chunks() })
}

send_http! = |request, limit| {
	response = Http.send_streaming!(request, {})?
	body = response.read_to_end!(MaxBytes(limit))?
	Ok(Response.from_status(response.status()).with_headers(response.headers()).with_body(body))
}

gzip! = |bytes| Ok(Cmd.new("gzip").arg("-n").arg("-c").stdin(Bytes(bytes)).timeout(Duration.seconds(5)).output_limit(MaxBytes(bytes.len() + 1024)).run!()?.require_success()?.stdout_bytes)

gunzip! = |bytes, limit| Ok(Cmd.new("gzip").arg("-d").arg("-c").stdin(Bytes(bytes)).timeout(Duration.seconds(5)).output_limit(MaxBytes(limit)).run!()?.require_success()?.stdout_bytes)

require = |condition| if condition {
	Ok({})
} else {
	Err(AssertionFailed)
}

collect! = |chunks, options| {
	result : Try(Stream(Try(Row, _)), _)
	result = JsonEachRow.stream(chunks.iter().stream(), options)
	Ok(result?.collect!())
}

selftest! = || {
	options = { max_row_bytes: 100.U64, max_chunk_bytes: 1000.U64 }
	chunks : List(Try(List(U8), [Injected]))
	chunks = [Ok("\r\n{\"id\":1,\"text\":\"".to_utf8().concat([195])), Ok([169].concat("\"}\r\n\n{\"id\":2,\"text\":\"last\"}".to_utf8()))]
	values = collect!(chunks, options)?
	require(values == [Ok({ id: 1, text: "é" }), Ok({ id: 2, text: "last" })])?
	late : List(Try(List(U8), [Injected]))
	late = [Ok("{\"id\":1,\"text\":\"ok\"}\nCode: 395. DB::Exception\n".to_utf8())]
	results = collect!(late, options)?
	require(results.len() == 2)?
	require(
		match results.last()? {
			Err(ClickHouseException(_)) => True
			_ => False
		},
	)?
	oversized : List(Try(List(U8), [Injected]))
	oversized = [Ok("{\"id\":1,\"text\":\"ok\"}\n".to_utf8().concat(List.repeat(120, 101)))]
	large = collect!(oversized, options)?
	require(large.len() == 2)?
	require(
		match large.last()? {
			Err(RowTooLarge(_)) => True
			_ => False
		},
	)?
	broken : List(Try(List(U8), [Injected]))
	broken = [Ok("{\"id\":1".to_utf8()), Err(Injected), Ok("}".to_utf8())]
	failures = collect!(broken, options)?
	require(failures.len() == 1)?
	require(
		match failures.first()? {
			Err(TransportError(Injected)) => True
			_ => False
		},
	)?
	truncated : List(Try(List(U8), [Injected]))
	truncated = [Ok("{\"id\":1".to_utf8())]
	invalid = collect!(truncated, options)?
	require(
		match invalid.first()? {
			Err(InvalidRow(_)) => True
			_ => False
		},
	)?
	chunk_limit = collect!(chunks, { ..options, max_chunk_bytes: 1 })?
	require(
		match chunk_limit.first()? {
			Err(ChunkTooLarge(1)) => True
			_ => False
		},
	)?
	Stdout.line!("{\"selftest\":true}")?
	Ok({})
}
