app [Context, program] {
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.16.0/42jC1JT3auhHSmv2Ah8mW5F2MXiAakq1UQQ4NQceQjXw.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	ch: "../package/main.roc",
}

import pf.Server
import http.Request
import http.Response
import ch.Client
import ch.JsonEachRow

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
		Err(ClickHouseError(error)) => error.message.to_utf8().len() <= 4096
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
		Err(InvalidRow(error)) => error.line == 2
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
