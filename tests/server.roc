app [Context, program] {
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.16.0/42jC1JT3auhHSmv2Ah8mW5F2MXiAakq1UQQ4NQceQjXw.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	ch: "../package/main.roc",
}

import pf.Env
import pf.Http
import pf.Server
import http.Response
import ch.Client
import ch.JsonEachRow

Context : Client.Config

Row : { id : U64, text : Str }

Input : { sql : Str, rows ?: List(Row), parameters ?: List({ name : Str, value : Str }), async_insert ?: Bool, decode ?: Bool, password ?: Str, timeout_ms ?: U64, max_response_bytes ?: U64, endpoint ?: Str }

program = { init!, respond!, shutdown! }

init! = || {
	port = U16.from_str(Env.var_str!("CLIENT_PORT")?)?
	endpoint = Env.var_str!("CLICKHOUSE_URL")?
	password = Env.var_str!("CLICKHOUSE_PASSWORD")?
	context = { ..Client.default_config, endpoint, password }
	Ok({ config: Server.default_config.with_listen({ host: "127.0.0.1", port }), context })
}

respond! = |request, context| {
	path = match request.target() {
		Resource({ raw_path, .. }) => raw_path
		_ => ""
	}
	if path == "/health" {
		return Ok(Server.respond(Response.from_status(200)))
	}
	bytes = request.body().read_all!()?
	input : Input
	input = Json.parse(Str.from_utf8(bytes)?)?
	config = {
		..context,
		password: input.?password ?? context.password,
		timeout_ms: input.?timeout_ms ?? context.timeout_ms,
		max_response_bytes: input.?max_response_bytes ?? context.max_response_bytes,
		endpoint: input.?endpoint ?? context.endpoint,
	}
	body = JsonEachRow.encode(input.?rows ?? [])?
	parameters = (input.?parameters ?? []).map(|parameter| Client.string_parameter(parameter.name, parameter.value))
	statement = { ..Client.query(input.sql), body, parameters, async_insert: input.?async_insert ?? False }
	result = Client.send!(|outgoing, limit| Http.send_with!(outgoing, Http.default_config.with_max_response_bytes(limit)), config, statement)
	response = match result {
		Ok(upstream) => {
			if input.?decode ?? False {
				decoded : Try(List(Row), _)
				decoded = JsonEachRow.decode(Response.body(upstream))
				match decoded {
					Ok(rows) => json(200, { rows: rows })
					Err(_) => json(502, { error: "decode" })
				}
			} else {
				Response.from_status(Response.status(upstream)).with_body(Response.body(upstream))
			}
		}
		Err(ClickHouseError(error)) => json(502, { error: "clickhouse", status: error.status, code: error.code })
		Err(TransportError(_)) => json(503, { error: "transport" })
		Err(ResponseTooLarge) => json(503, { error: "response_too_large" })
		Err(_) => json(400, { error: "configuration" })
	}
	Ok(Server.respond(response))
}

json = |status, value| Response.from_status(status).with_body(Json.to_str(value).to_utf8()).with_headers([{ name: "Content-Type", value: "application/json" }])

shutdown! = |_reason, _context| Ok({})
