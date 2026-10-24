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

# Run with CLICKHOUSE_URL, CLICKHOUSE_USER and CLICKHOUSE_PASSWORD set.
# GET http://127.0.0.1:8000/ performs a read-only query.
Context : Client.Config

program = { init!, respond!, shutdown! }

init! = || {
	endpoint = Env.var_str!("CLICKHOUSE_URL")?
	username = Env.var_str!("CLICKHOUSE_USER")?
	password = Env.var_str!("CLICKHOUSE_PASSWORD")?
	Ok({ config: Server.default_config, context: { ..Client.default_config, endpoint, username, password } })
}

respond! = |_request, context| {
	statement = {
		..Client.query("SELECT {message:String} AS message FORMAT JSONEachRow"),
		parameters: [Client.string_parameter("message", "Hello from Roc!")],
	}
	result = Client.send!(|request, limit| Http.send_with!(request, Http.default_config.with_max_response_bytes(limit)), context, statement)
	response = match result {
		Ok(upstream) => {
			rows : Try(List({ message : Str }), _)
			rows = JsonEachRow.decode(Response.body(upstream))
			match rows {
				Ok(values) => Response.from_status(200).with_body(Json.to_str(values).to_utf8())
				Err(_) => Response.from_status(502).with_body("Invalid database result".to_utf8())
			}
		}
		Err(_) => Response.from_status(503).with_body("Database unavailable".to_utf8())
	}
	Ok(Server.respond(response.add_header("Content-Type", "application/json")))
}

shutdown! = |_reason, _context| Ok({})
