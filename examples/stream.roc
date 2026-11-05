## Lazy typed reads and bounded acknowledged inserts using basic-cli.
app [main!] {
	ch: "../package/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import ch.Client
import pf.Env
import pf.Http
import pf.Stdout
import http.Response

Event : { id : U64, text : Str }

main! = |_args| {
	endpoint = Env.var_str!("CLICKHOUSE_URL")?
	username = Env.var_str!("CLICKHOUSE_USER")?
	password = Env.var_str!("CLICKHOUSE_PASSWORD")?
	db = { ..Client.default_config, endpoint, username, password }
	statement = Client.query("SELECT id, text FROM events ORDER BY id")
	result : Try(Stream(Try(Event, _)), _)
	result = Client.stream!(open_http!, db, statement, Client.default_stream_options)
	for! row in result? {
		event = row?
		Stdout.line!("${event.id.to_str()}: ${event.text}")?
	}
	Ok({})
}

open_http! = |request| {
	response = Http.send_streaming!(request, {})?
	Ok({ status: response.status(), headers: response.headers(), chunks: response.chunks() })
}

## Pass this callback to Client.query!, insert!, insert_stream! and cancel!.
## read_to_end! enforces the budget during reception, before full allocation.
send_http! = |request, limit| {
	response = Http.send_streaming!(request, {})?
	body = response.read_to_end!(MaxBytes(limit))?
	Ok(Response.from_status(response.status()).with_headers(response.headers()).with_body(body))
}
