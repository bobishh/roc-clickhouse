# roc-clickhouse

A platform-independent ClickHouse HTTP client for Roc. Typed JSONEachRow
encoding/decoding, query parameters, confirmed asynchronous inserts and explicit
transport/server errors. The application supplies bounded HTTP effects.

## Compatibility

- Roc: `nightly-2026-09-23-c7852fd` (new Zig compiler).
- Shared HTTP types: `roc-lang/http` 1.0.0.
- Tested transport: `basic-webserver` 0.16.0.
- Integration tests: ClickHouse 26.8.11.7 on Linux; Roc apps on Linux and macOS ARM64.

Other compiler, platform and HTTP package versions require verification. Roc's
nominal HTTP types must come from the same package URL in the client and transport.

## Usage

Add the immutable package URL from [Releases](https://github.com/bobishh/roc-clickhouse/releases)
to your app header under the name `ch`. For a local checkout, use
`ch: "../roc-clickhouse/package/main.roc"` (relative to your app).
The [complete example](examples/server.roc) serves a read-only query on loopback.

```roc
import pf.Http
import http.Response
import ch.Client
import ch.JsonEachRow

config = {
    ..Client.default_config,
    endpoint: "https://clickhouse.example.test:8443",
    database: "analytics",
    username: "reader",
    password: "load-from-private-configuration",
}

send_http! = |request, max_response_bytes|
    Http.send_with!(request, Http.default_config.with_max_response_bytes(max_response_bytes))

# Inside your handler or CLI entry point:
statement = {
    ..Client.query("SELECT id, text FROM events WHERE text={text:String} SETTINGS output_format_json_quote_64bit_integers=0 FORMAT JSONEachRow"),
    parameters: [Client.string_parameter("text", "a value with 'quotes' and\nnewlines")],
}
response = Client.send!(send_http!, config, statement)?
rows : List({ id : U64, text : Str })
rows = JsonEachRow.decode(Response.body(response))?
```

For numeric parameters, pass their text representation directly:
`parameters: [{ name: "id", value: "42" }]` with `{id:UInt64}` in SQL.
`Client.string_parameter` handles ClickHouse's escaped-text String representation;
URL percent encoding is applied separately by the client. Parameters bind values;
the application owns SQL and identifier selection.

For insertion:

```roc
body = JsonEachRow.encode([{ id: 42, text: "hello" }])?
statement = {
    ..Client.query("INSERT INTO events FORMAT JSONEachRow"),
    body,
    async_insert: True,
}
_ = Client.send!(send_http!, config, statement)?
```

`async_insert: True` always sends both `async_insert=1` and
`wait_for_async_insert=1`. A successful acknowledgement waits for the insertion.
Timeouts and disconnects leave the write outcome unknown. No operation is retried
automatically; deduplication and retry decisions belong to the application.

## API and errors

`Client` owns connection configuration, query construction and response checking.
`JsonEachRow` owns typed row encoding/decoding. Pure `Client.request` and
`Client.check_response` can be used separately when an application owns transport.

`Client.default_config` uses `http://127.0.0.1:8123`, database/user `default`, an
empty password, an 8-second deadline and a 1 MiB response budget. Set production
credentials explicitly. Endpoints can include a reverse-proxy path, with an
optional trailing slash; userinfo, query strings and fragments are rejected.
Set `query_id` on a statement when correlation is needed.

`Client.send!` returns a shared HTTP `Response` or:

- `InvalidConfig(field)` / `InvalidParameter(name)`: local request validation.
- `TransportError(error)`: preserves the supplied transport's error value.
- `ResponseTooLarge`: defensive check if a transport ignored the response budget.
- `ClickHouseError({ status, code, message })`: failed HTTP status or a nonzero
  `X-ClickHouse-Exception-Code` header. Diagnostic messages are at most 4096 bytes.

The supplied HTTP function receives `(request, max_response_bytes)` and must
enforce that limit while receiving, honor the request deadline, and provide TLS
verification when HTTPS is used. A check after allocation cannot enforce a memory
bound. `basic-webserver`'s `Http.send_with!` supplies these facilities. The client
calls this function exactly once per operation.

Requests use POST, credentials in headers and `wait_end_of_query=1`, with progress
headers disabled. ClickHouse can still expose late execution errors through its
HTTP response body under some server configurations. Always decode structured
results: `JsonEachRow.decode` rejects the entire result on the first invalid row,
including trailing exception text. An HTTP 200 alone is insufficient proof for
arbitrary raw query results. See the [HTTP interface contract](https://clickhouse.com/docs/interfaces/http).

`JsonEachRow.encode` returns `EncodeError(error)` on unsupported values, including
non-finite floats. `decode` returns `InvalidUtf8` or
`InvalidRow({ line, problem })`, where line is one-based and includes blank lines.
Empty results and CRLF are accepted. Integer quoting, DateTime precision,
Decimal, UUID and nullable representations follow the selected Roc record type
and ClickHouse output settings; the library does not guess coercions.

Server diagnostics and preserved transport errors may contain query data. Choose
what to expose or log at the application boundary. Credentials are never added
to query parameters by this library.

## Development and releases

Install the compiler in `.roc-version`, Node.js 22 and Docker. Linux x86-64 and
macOS ARM64 can use `sh scripts/install-roc.sh /path/to/roc` (archive SHA-256 is
checked). Then run:

```sh
ROC=/path/to/roc/roc node scripts/check.mjs
```

This checks formatting, types and expectations, bundles the package, and runs a
compiled application against disposable authenticated ClickHouse using the
downloaded bundle. Tests use unused loopback ports and remove only their own
container. Set `ROC_CLICKHOUSE_WORK_DIR` to choose the build/log location;
otherwise the runner's temporary directory is used.

The GitHub workflow runs the same checks on Linux. Dispatch it with a `version`
such as `0.1.0` to publish that exact verified bundle. Package URLs contain the
Roc content hash and are immutable.
