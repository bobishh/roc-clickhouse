app [Context, program] {
	ch: "../package/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.20.0/7dR2ewuEbpPQXTAZL3aH62weBwpNNjbCJtyyiRsufTNZ.tar.zst",
}

import pf.Server
import http.Request
import http.Response
import ch.Client
import ch.JsonEachRow
import ch.Types

Context : {}

program = { init!, respond!, shutdown! }

init! = || Ok({ config: Server.default_config, context: {} })

respond! = |_request, _context| Ok(Server.respond(Response.from_status(200)))

shutdown! = |_reason, _context| Ok({})

config = { ..Client.default_config, endpoint: "https://example.test/clickhouse/", database: "events & logs", username: "writer", password: "secret&never-in-url" }

# Given untrusted SQL values, When building a parameterized query, Then values
# remain parameters, credentials remain headers, and inserts wait for storage.
expect {
	query = { ..Client.query("SELECT {text:String}"), parameters: [{ name: "text", value: "Привет + '&\n" }], async_insert: True }
	request = Client.request(config, query)?
	uri = Request.uri(request)
	uri.starts_with("https://example.test/clickhouse/?") and
		uri.contains("database=events%20%26%20logs") and
			uri.contains("param_text=%D0%9F%D1%80%D0%B8%D0%B2%D0%B5%D1%82%20%2B%20%27%26%0A") and
				uri.contains("async_insert=1&wait_for_async_insert=1") and
					uri.contains("wait_end_of_query=1") and
						uri.contains("secret") == False and
							Request.headers(request).any(|header| header.name == "X-ClickHouse-Key" and header.value == config.password)
}

# Given query-bearing endpoints or invalid parameter names, Then reject locally.
expect match Client.request({ ..config, endpoint: "https://example.test/?user=root" }, Client.query("SELECT 1")) {
	Err(InvalidConfig("endpoint")) => True
	_ => False
}
expect match Client.request(config, { ..Client.query("SELECT 1"), parameters: [{ name: "x&user", value: "root" }] }) {
	Err(InvalidParameter("x&user")) => True
	_ => False
}
expect match Client.request(config, { ..Client.query("SELECT 1"), parameters: [{ name: "x", value: "1" }, { name: "x", value: "2" }] }) {
	Err(InvalidParameter("x")) => True
	_ => False
}

# ClickHouse parses String parameters with escaped-text rules after URL decoding.
expect Client.string_parameter("value", "backslash\\\n\t\r").value == "backslash\\\\\\n\\t\\r"

# Given ClickHouse rejection, Then preserve status/code and bound diagnostics.
expect {
	response = Response.from_status(500).with_headers([{ name: "x-clickhouse-exception-code", value: "60" }]).with_body("table absent".to_utf8())
	match Client.check_response(response) {
		Err(ClickHouseError(error)) => error.status == 500 and error.code == "60" and error.message == "table absent"
		_ => False
	}
}
expect {
	response = Response.from_status(200).with_headers([{ name: "X-ClickHouse-Exception-Code", value: "395" }])
	match Client.check_response(response) {
		Err(ClickHouseError(_)) => True
		_ => False
	}
}
expect {
	response = Response.from_status(500).with_body(Str.repeat("x", 10_000).to_utf8())
	match Client.check_response(response) {
		Err(HttpError(error)) => error.message.to_utf8().len() <= 4096
		_ => False
	}
}

# Given JSONEachRow, Then preserve escaping/types and reject a partial result.
expect {
	rows = [{ id: 1, text: "Привет\nworld" }, { id: 2, text: "quote: \"" }]
	encoded = JsonEachRow.encode(rows)?
	decoded : Try(List({ id : U64, text : Str }), _)
	decoded = JsonEachRow.decode(encoded)
	decoded == Ok(rows)
}
expect {
	decoded : Try(List({ id : U64 }), _)
	decoded = JsonEachRow.decode("{\"id\":1}\nCode: 395. DB::Exception".to_utf8())
	match decoded {
		Err(ClickHouseException(error)) => error.line == 2 and error.code == "395"
		_ => False
	}
}
expect {
	decoded : Try(List({ id : U64 }), _)
	decoded = JsonEachRow.decode("\r\n{\"id\":1}\r\n\n".to_utf8())
	decoded == Ok([{ id: 1 }])
}
expect {
	decoded : Try(List({ id : U64 }), _)
	decoded = JsonEachRow.decode([])
	decoded == Ok([])
}
expect {
	decoded : Try(List({ id : U64 }), _)
	decoded = JsonEachRow.decode([255])
	decoded == Err(InvalidUtf8)
}

# Given typed SQL, When preparing a query, Then wire settings are centralized.
expect {
	prepared = Client.typed_query(Client.query("SELECT 1 AS id"))?
	request = Client.request(config, prepared)?
	Request.uri(request).contains("default_format=JSONEachRow") and
		Request.uri(request).contains("output_format_json_quote_64bit_integers=0")
}

# Given chunk boundaries inside UTF-8, When framing rows, Then bytes stay intact.
expect {
	state = JsonEachRow.framer(100)?
	first = JsonEachRow.frame_chunk(state, [123, 34, 120, 34, 58, 34, 195])?
	second = JsonEachRow.frame_chunk(first.state, [169, 34, 125, 10])?
	second.row == Ready({ line: 1, bytes: "{\"x\":\"é\"}".to_utf8() })
}

# Given exact ClickHouse scalar text, Then preserve precision and reject bad data.
expect {
	value : Try({ n : Types.UInt64, d : Types.Decimal, at : Types.DateTime64, day : Types.Date, uuid : Types.Uuid, optional : Types.Nullable(Str) }, _)
	value = Json.parse("{\"n\":\"18446744073709551615\",\"d\":\"12345678901234567890.12345678901234567890\",\"at\":\"2024-02-29 23:59:59.123456789\",\"day\":\"2024-02-29\",\"uuid\":\"00112233-4455-6677-8899-aabbccddeeff\",\"optional\":null}")
	row = value?
	row.n.value == U64.highest and row.d.text == "12345678901234567890.12345678901234567890" and row.optional == Err(Null)
}
expect Types.Decimal.from_str("NaN").is_err()
expect Types.Decimal.from_str("1e30").is_err()
expect Types.DateTime64.from_str("2023-02-29 00:00:00").is_err()
expect Types.DateTime64.from_str("2024-01-01 24:00:00").is_err()
expect Types.Uuid.from_str("00112233-4455-6677-8899-zzbbccddeeff").is_err()
expect {
	value : Try(Types.UInt64, _)
	value = Json.parse("\"18446744073709551616\"")
	value.is_err()
}

# Required fields and exact numeric bounds are runtime decoding guarantees.
expect {
	result : Try(List({ id : U64 }), _)
	result = JsonEachRow.decode("{}".to_utf8())
	match result {
		Err(InvalidRow({ problem: MissingRequiredField("id"), .. })) => True
		_ => False
	}
}
expect {
	result : Try(List({ id : U64 }), _)
	result = JsonEachRow.decode("{\"id\":false}".to_utf8())
	match result {
		Err(InvalidRow(_)) => True
		_ => False
	}
}
expect {
	result : Try(List({ id : U64 }), _)
	result = JsonEachRow.decode("{\"id\":18446744073709551615}".to_utf8())
	result == Ok([{ id: U64.highest }])
}
expect {
	result : Try(List({ id : U64 }), _)
	result = JsonEachRow.decode("{\"id\":18446744073709551616}".to_utf8())
	match result {
		Err(InvalidRow(_)) => True
		_ => False
	}
}
expect {
	result : Try(Types.Int64, _)
	result = Json.parse("\"-9223372036854775808\"")
	result?.value == I64.lowest
}
expect {
	result : Try(Types.Int64, _)
	result = Json.parse("\"9223372036854775808\"")
	result.is_err()
}
expect {
	result : Try(Types.UInt64, _)
	result = Json.parse("18446744073709551615")
	result?.value == U64.highest
}
expect {
	original = Types.Decimal.from_str("0.${Str.repeat("1", 76)}")?
	encoded = Json.to_str_try(original)?
	decoded : Try(Types.Decimal, _)
	decoded = Json.parse(encoded)
	decoded?.text == original.text
}
expect Types.Decimal.from_str(Str.repeat("1", 77)).is_err()
expect Types.Date.from_str("1900-02-29").is_err()
expect Types.Date.from_str("2000-02-29").is_ok()
expect Types.DateTime64.from_str("2024-01-01 00:00:00.1234567890").is_err()
expect {
	row : { value : Types.Nullable(U64) }
	row = { value: Err(Null) }
	Json.to_str(row) == "{\"value\":null}"
}
expect {
	parsed : Try({ value : Types.Nullable(U64) }, _)
	parsed = Json.parse("{\"value\":42}")
	parsed == Ok({ value: Ok(42) })
}
expect {
	parsed : Try({ value : Types.Nullable(U64) }, _)
	parsed = Json.parse("{}")
	match parsed {
		Err(MissingRequiredField("value")) => True
		_ => False
	}
}
expect Client.insert_sql(["analytics", "strange`table\\name"]) == Ok("INSERT INTO `analytics`.`strange\\`table\\\\name` FORMAT JSONEachRow")
expect Client.insert_sql([]) == Err(InvalidConfig("table"))
expect Client.insert_sql(["bad\ntable"]) == Err(InvalidConfig("table"))
expect {
	statement = { ..Client.query("SELECT 1"), settings: [{ name: "query", value: "DROP TABLE events" }] }
	match Client.request(config, statement) {
		Err(InvalidConfig("settings")) => True
		_ => False
	}
}
expect {
	statement = { ..Client.query("SELECT 1"), settings: [{ name: "max_threads", value: "2" }, { name: "max_threads", value: "3" }] }
	match Client.request(config, statement) {
		Err(InvalidConfig("settings")) => True
		_ => False
	}
}
expect {
	prepared = Client.typed_query({ ..Client.query("SELECT 1"), settings: [{ name: "output_format_json_quote_64bit_integers", value: "1" }] })?
	prepared.settings.keep_if(|setting| setting.name == "output_format_json_quote_64bit_integers") == [{ name: "output_format_json_quote_64bit_integers", value: "0" }]
}
expect match Client.check_response(Response.from_status(502).with_body("proxy failure".to_utf8())) {
	Err(HttpError(error)) => error.status == 502 and error.message == "proxy failure"
	_ => False
}
expect match Client.check_response(Response.from_status(200).with_body("Code: 395. DB::Exception".to_utf8())) {
	Err(ClickHouseError(error)) => error.code == "395"
	_ => False
}
expect JsonEachRow.framer(0) == Err(InvalidConfig("max_row_bytes"))
expect {
	frame = JsonEachRow.framer(3)?
	JsonEachRow.frame_chunk(frame, [1, 2, 3, 4]) == Err(RowTooLarge({ line: 1, limit: 3 }))
}
