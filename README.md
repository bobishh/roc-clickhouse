# roc-clickhouse

`roc-clickhouse` runs native ClickHouse SQL from Roc and decodes results into the
record type you declare. Bind values with ClickHouse parameters, stream rows as
you consume them, and insert records in bounded batches. Your Roc application
supplies the HTTP transport and credentials.

## Read rows into a Roc record

```roc
import ch.Client

statement = {
    ..Client.query("SELECT {message:String} AS message"),
    parameters: [Client.string_parameter("message", "Hello from Roc!")],
}
result : Try(List({ message : Str }), _)
result = Client.query!(send_http!, db, statement)
```

The annotation selects the row decoder. ClickHouse checks the SQL at execution,
and the client reports missing columns or incompatible values during decoding.
The [complete webserver example](examples/server.roc) supplies the HTTP effect
and database configuration.

[Install](#installation) · [Query](#typed-queries) · [Stream](#streaming) ·
[Insert](#inserts-and-batching) · [Verify a release](#release-integrity)

## Installation

Use the pinned Roc nightly from [`.roc-version`](.roc-version), `--opt=dev` and
the shared `roc-lang/http` 2.0.0 package. Add the content-addressed URL from
[Releases](https://github.com/bobishh/roc-clickhouse/releases) under `ch` in the
app header alongside your platform and `http`.

```roc
ch: "https://github.com/bobishh/roc-clickhouse/releases/download/0.1.0/B9U2fBwU1G3j4pAGW5Csphx4zfqsQgH6W3gKJvvF5wW8.tar.zst",
```

For a local checkout, use `ch: "../roc-clickhouse/package/main.roc"`.
The [webserver example](examples/server.roc) uses `basic-webserver` 0.20.0.
The [streaming CLI example](examples/stream.roc) uses `basic-cli` 0.26.0.
When upgrading from 0.0.1, update the platform to a compatible version and
keep the shared `http` dependency at 2.0.0.

To try the webserver example from this checkout, export `CLICKHOUSE_URL`,
`CLICKHOUSE_USER` and `CLICKHOUSE_PASSWORD` for a running ClickHouse server.
Run `roc run --opt=dev examples/server.roc` with the pinned compiler on `PATH`.
With local port 8000 free, `curl -fsS http://127.0.0.1:8000/` returns
`[{"message":"Hello from Roc!"}]`.

## Typed queries

```roc
import ch.Client

statement = {
    ..Client.query("SELECT country, count() AS events FROM events WHERE country={country:String} GROUP BY country ORDER BY events DESC LIMIT 10"),
    parameters: [Client.string_parameter("country", "DE")],
    query_id: "country-report",
}
rows : Try(List({ country : Str, events : U64 }), _)
rows = Client.query!(send_http!, db, statement)
```

`send_http!` receives `(Request, max_response_bytes)` and returns
`Try(Response, transport_error)`. It must enforce the byte budget during
reception, honor the request deadline, verify HTTPS certificates, and avoid
implicit retries. The package wraps its original errors in `TransportError`.
The CLI example implements this with `Http.send_streaming!` followed by bounded
`read_to_end!`; the webserver uses bounded `Http.send_with!`.

The expected result type selects the JSON parser. No decoder callback or field
extraction is needed. A missing required field, incompatible value, overflow or
malformed row fails the entire buffered query, including any previously decoded
rows. Empty results return `Ok([])`.

Typed entry points set `default_format=JSONEachRow`, unquoted 64-bit integers,
quoted decimals, simple date/time output and plain exception framing. Do not add `FORMAT` or conflicting
output `SETTINGS` in typed SQL: explicit SQL clauses override HTTP defaults.
Other per-query ClickHouse settings use `statement.settings`, a list of
`{ name, value }`. Duplicate names and transport-owned settings are rejected.

Parameters use native `{name:Type}` placeholders. String values need
`Client.string_parameter`, which applies ClickHouse escaped-text rules before
URL percent encoding. Other values use ClickHouse's text representation:
`parameters: [{ name: "id", value: "42" }]` with `{id:UInt64}`. DateTime64
parameters can use a validated timestamp's `.text`. SQL and identifier selection
remain application-owned; parameter values are never interpolated into SQL.

`Client.query` is a pure statement constructor. `Client.send!` remains the
low-level raw-response operation; use `query!` for typed result guarantees.

## Streaming

```roc
result : Try(Stream(Try({ id : U64, text : Str }, _)), _)
result = Client.stream!(open_http!, db, Client.query("SELECT id, text FROM events"), Client.default_stream_options)
for! row in result? {
    event = row?
    process_event!(event)?
}
```

`open_http!` receives a `Request` and returns:

```roc
Ok({ status: response.status(), headers: response.headers(), chunks: response.chunks() })
```

`chunks` is `Stream(Try(List(U8), transport_error))`. It must read lazily and
release the connection when its last reference is released. A transport chunk
must not exceed `max_chunk_bytes` (default 64 KiB). Default maximum encoded row
size is 1 MiB, excluding LF but including a CR when present. No total result-size
cap applies to streaming; the request deadline still applies to the entire
exchange, including time spent processing rows.

The decoder retains at most one chunk plus one incomplete row. It handles
arbitrary chunk boundaries, split UTF-8, CRLF, blank lines and a final row without
LF. It does not request the next chunk until needed. Releasing all references to
an unfinished stream releases the transport. Streams are consumed once; copying
a stream does not provide an independent network cursor.

Opening failures use the outer `Try`. Failures after opening are stream items:
`TransportError`, `InvalidUtf8`, `InvalidRow({ line, problem })`,
`ClickHouseException({ line, code, message })`, `RowTooLarge({ line, limit })` or
`ChunkTooLarge(limit)`. Line numbers include blank lines. An error is terminal and
emitted once; subsequent source items are not read. Failed HTTP responses read
at most one diagnostic chunk and retain at most 4096 diagnostic bytes.

Streaming requests disable server response buffering (`wait_end_of_query=0`).
Rows already delivered remain provisional until successful end of stream:
ClickHouse can fail after returning rows. Processing side effects cannot be
rolled back by this client. Stopping early also does not prove query success.
Dropping an HTTP connection does not guarantee server cancellation; use a query
ID and `cancel!` when server execution must stop.

`JsonEachRow.stream(chunks, options)` exposes the same incremental decoder for
applications that already own a transport. `JsonEachRow.decode` and `encode`
remain pure buffered codec operations.

## Scalar representations

```roc
import ch.Types

Row : {
    id : U64,
    amount : Types.Decimal,
    happened_at : Types.DateTime64,
    day : Types.Date,
    uuid : Types.Uuid,
    note : Types.Nullable(Str),
}
```

| ClickHouse value | Roc representation and contract |
| --- | --- |
| UInt64 / Int64 | Native `U64` / `I64` with typed query settings; exact bounds, no float intermediate. |
| Quoted or unquoted 64-bit integers | `Types.UInt64` / `Types.Int64`; read `.value`, construct with `.from_value`. Overflow rejects. Encoding emits a JSON number. |
| Decimal32/64/128/256 | `Types.Decimal`; exact fixed-point `.text`, up to 76 total significant integer digits plus fractional digits. No exponent, rounding or float conversion. Encoding emits a quoted decimal. |
| Date / Date32 | `Types.Date`; Gregorian `YYYY-MM-DD` text with calendar validation. |
| DateTime / DateTime64 | `Types.DateTime64`; `YYYY-MM-DD HH:MM:SS` with optional 1–9 fractional digits. Precision and timezone interpretation remain explicit in SQL/schema. |
| UUID | `Types.Uuid`; canonical 36-character hyphenated hexadecimal text; preserves casing. |
| Nullable(T) | `Types.Nullable(T)` aliases `Try(T, [Null])`: `Ok(value)` or `Err(Null)`. Field remains required; a missing column fails. |

Text-backed types validate through `.from_str` and JSON parsing/encoding. For
example, `Types.Decimal.from_str("123.4500")?` preserves trailing zeros. Validators
check wire syntax; ClickHouse validates the target column's range, scale and
timezone semantics. Date/time wrappers do not silently convert timezones.
Arrays and nested records follow their Roc JSON shapes; other ClickHouse types
need an explicit compatible Roc representation or custom scalar codec.

## Inserts and batching

```roc
progress = Client.insert!(send_http!, db, ["analytics", "events"], events, {
    ..Client.default_insert_options,
    max_rows: 1000,
    max_bytes: 1_048_576,
    async_insert: True,
    query_id: "import-2026-11-05",
})?
```

`insert!` accepts a list. `insert_stream!` takes the same arguments with a lazy
`Stream(Try(Event, source_error))` instead. Table names are a nonempty list of
identifier parts; every part is quoted and escaped. An identifier containing a
dot is one name, not implicit database qualification.

Both helpers serialize one bounded JSONEachRow batch at a time. Row and byte
limits must be positive; bytes include each row's LF. A single oversized encoded
row fails. Serialization holds one row in addition to the current batch; source
record size is application-owned. Row-count boundaries flush before pulling
another source item. Byte boundaries require at most one encoded row of
lookahead. Empty inputs make no HTTP request.

Each batch is acknowledged before the next request. `async_insert: True` always
sets both `async_insert=1` and `wait_for_async_insert=1`. Returned progress is
`{ rows, batches }`, counting acknowledged work. A nonempty operation query ID
becomes `query_id:0`, `query_id:1`, etc.; choose an ID unique to the logical run.
Query IDs provide correlation, not insert deduplication.

Failure is `InsertFailed({ confirmed: { rows, batches }, cause })`. Causes retain
source, encoding, size, transport or server errors. Already confirmed batches
remain inserted; pending rows are not retried. A timeout/disconnect can leave
the current batch's outcome unknown. Retry and deduplication decisions belong
to the application. Encoding failures, including non-finite floats, return errors
rather than silently dropping rows.

## Compression

```roc
import ch.Compression

send_gzip! = |request, limit|
    Compression.send!(gzip!, gunzip!, send_http!, request, limit)

progress = Client.insert!(send_gzip!, db, ["events"], events, Client.default_insert_options)?
```

`Compression.send!` applies standard HTTP gzip to the request body and negotiates
gzip responses. It composes with every buffered Client operation, including each
insert batch. It uses `Content-Encoding`, `Accept-Encoding` and
`enable_http_compression=1`, not ClickHouse's separate native compression format.

The application supplies `gzip!(bytes) -> Try(bytes, error)` and
`gunzip!(bytes, max_output_bytes) -> Try(bytes, error)`. Decompression must enforce
the output budget while producing bytes; checking only after allocation cannot
protect against compressed expansion. The underlying HTTP effect must bound the
compressed response too. Codec failures remain `CompressionError` within the
transport error; unknown response encodings reject explicitly.

The integration client demonstrates bounded platform callbacks using `gzip`
through `basic-cli`'s `Cmd`, with command deadlines and captured-output limits.
Platforms can instead supply an in-process compression library. Streaming reads
use identity encoding; a custom platform may decompress incrementally before
supplying bounded decoded chunks. Do not feed compressed bytes to JSONEachRow.

## Cancellation, deadlines and errors

```roc
statuses = Client.cancel!(send_http!, db, "country-report")?
```

`cancel!` sends `KILL QUERY WHERE query_id={id:String} SYNC` with a bound String
parameter, returning records `{ kill_status, query_id }`. An absent query returns
an empty list. Cancellation requires server permissions and targets the server
at the configured endpoint; routing to the executing node remains the
application's responsibility. It is an explicit effect, independent of stopping
a consumer or encountering a local deadline.

`Client.default_config` uses `http://127.0.0.1:8123`, database/user `default`, an
empty password, an 8-second deadline and a 1 MiB buffered response budget. Set
production credentials explicitly. Credentials use HTTP headers. Endpoints may
include a reverse-proxy path; userinfo, query strings and fragments reject.

Errors distinguish:

- `InvalidConfig` / `InvalidParameter`: request validation before transport.
- `TransportError(error)`: the transport's original failure, including limits,
  deadlines and optional compression errors.
- `HttpError({ status, code, message })`: non-success HTTP status without a
  recognizable ClickHouse exception; `code` is empty.
- `ClickHouseError({ status, code, message })`: server exception header/body or
  a late exception detected by buffered typed decoding.
- Row-decoding and stream-item errors described above.
- `ResponseTooLarge`: defensive check if a transport violates its budget.

Buffered requests ask for `wait_end_of_query=1`, disable progress headers and
always decode typed results. An HTTP 200 alone is insufficient proof of success.
Server/transport diagnostics can contain query data; choose what to log or expose
at the application boundary. Diagnostics retained by this package are at most
4096 bytes. See [ClickHouse HTTP behavior](https://clickhouse.com/docs/interfaces/http)
and [cancellation](https://clickhouse.com/docs/sql-reference/statements/kill).

## Development

Install Node.js 22, Docker and the compiler in `.roc-version`. Linux x86-64 and
macOS ARM64 can use the SHA-256-verified installer:

```sh
sh scripts/install-roc.sh /path/to/roc
ROC=/path/to/roc/roc node scripts/check.mjs
```

The check command verifies formatting, types, unit expectations and examples,
then bundles the package and builds native integration apps against that exact
bundle. Tests use disposable authenticated ClickHouse, unused loopback ports and
isolated fault servers; cleanup targets only their own processes/container.
Integration compression tests also require `gzip` on PATH.

Set `ROC_CLICKHOUSE_WORK_DIR` to choose a build/log location. The GitHub workflow
runs the same checks on Linux x86-64. Local verification also runs on macOS ARM64
with ClickHouse 26.8.11.7 in Docker.

## Release integrity

The archive filename is Roc's content hash. For `0.1.0`, the archive's SHA-256
is `9c7ed9926ba7ba68a793c3b308fccbe5d2538112cc308ec3f2e05a7e70537cd5`.
For new immutable GitHub releases, verify a downloaded archive against its
release tag with `gh release verify-asset <version> <archive>`.

### Publish a verified archive

The [package workflow](.github/workflows/ci.yml) tests the exact bundle and
attests it after the tests and workflow security scan pass on `main`. A
maintainer downloads the archive, verifies its provenance and creates a GitHub
release draft. Use a successful `main` run and an unused `X.Y.Z` version.

```sh
set -eu
repo=bobishh/roc-clickhouse
run_id=REPLACE_WITH_RUN_ID
version=REPLACE_WITH_VERSION
revision=$(gh run view "$run_id" -R "$repo" --json headBranch,conclusion,headSha \
  --jq 'select(.headBranch == "main" and .conclusion == "success") | .headSha')
test -n "$revision"
existing_tag=$(git ls-remote --refs "https://github.com/$repo.git" "refs/tags/$version")
test -z "$existing_tag"
release_dir=$(mktemp -d)
gh run download "$run_id" -R "$repo" -n package -D "$release_dir"
set -- "$release_dir"/*.tar.zst
test "$#" -eq 1
test -f "$1"
gh attestation verify "$1" -R "$repo" \
  --signer-workflow "$repo/.github/workflows/ci.yml" \
  --source-ref refs/heads/main --source-digest "$revision" --deny-self-hosted-runners
gh release create "$version" "$1" -R "$repo" --draft --target "$revision" \
  --title "$version" --generate-notes
```

Review the draft's source revision and archive on GitHub, then publish it from
the Releases page. GitHub locks the tag and archive at publication.
