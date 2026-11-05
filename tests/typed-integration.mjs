import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { gzipSync, gunzipSync } from 'node:zlib';

export async function verifyTypedClient({ root, work, roc, replacement, clickhouse, password }) {
  const binary = path.join(work, 'typed-client');
  const build = spawnSync(roc, ['build', '--opt=dev', 'tests/stream.roc', `--output=${binary}`, ...replacement], { cwd: root, encoding: 'utf8', timeout: 120_000 });
  await writeFile(path.join(work, 'typed-build.log'), build.stdout + build.stderr);
  assert.ok([0, 2].includes(build.status), 'typed client build failed: ' + path.join(work, 'typed-build.log'));
  assert.ok((await readFile(binary)).length > 0);
  const active = new Set();
  function start(input, onLine = () => {}) {
    const child = spawn(binary, [], { cwd: root, env: { ...process.env, INPUT: JSON.stringify(input), CLICKHOUSE_URL: clickhouse, CLICKHOUSE_PASSWORD: password }, stdio: ['ignore', 'pipe', 'pipe'] });
    active.add(child);
    let output = '', stderr = '', pending = '';
    const lines = [];
    const timeout = setTimeout(() => child.kill('SIGTERM'), 20_000);
    const done = new Promise((resolve, reject) => {
      child.stdout.setEncoding('utf8').on('data', chunk => {
        output += chunk;
        pending += chunk;
        while (pending.includes('\n')) {
          const index = pending.indexOf('\n');
          const line = pending.slice(0, index);
          pending = pending.slice(index + 1);
          try { const value = JSON.parse(line); lines.push(value); onLine(value); } catch (error) { reject(error); }
        }
      });
      child.stderr.setEncoding('utf8').on('data', chunk => { stderr += chunk; });
      child.once('error', reject);
      child.once('exit', (code, signal) => {
        clearTimeout(timeout);
        active.delete(child);
        if (code !== 0) reject(new Error(`typed client exited ${code}/${signal}: ${stderr}\n${output}`));
        else resolve({ lines, output });
      });
    });
    return { child, done };
  }
  const run = (input, onLine) => start(input, onLine).done;
  let handler;
  const fake = http.createServer((request, response) => { Promise.resolve(handler(request, response)).catch(error => { response.destroy(error); }); });
  await new Promise(resolve => fake.listen(0, '127.0.0.1', resolve));
  const endpoint = `http://127.0.0.1:${fake.address().port}`;
  const body = async request => { const chunks = []; for await (const chunk of request) chunks.push(chunk); return Buffer.concat(chunks); };
  const row = { id: 7, text: 'é\nquoted "' };
  try {
    assert.deepEqual((await run({ action: 'selftest' })).lines, [{ selftest: true }]);
    const typed = await run({ action: 'query', sql: 'SELECT toUInt64(7) AS id, \'typed\' AS text' });
    assert.deepEqual(typed.lines, [{ rows: [{ id: 7, text: 'typed' }] }]);
    for (const sql of ['SELECT 1 AS id', "SELECT 'bad' AS id, '' AS text", "SELECT toUInt128('18446744073709551616') AS id, '' AS text"]) {
      assert.match((await run({ action: 'query', sql })).lines[0].error, /InvalidRow/);
    }
    const scalarSql = "SELECT toUInt64('18446744073709551615') AS u, toInt64('-9223372036854775808') AS i, toDecimal128('12345678901234567890.123456789012345678',18) AS d, toDateTime64('2024-02-29 23:59:59.123456789',9,'UTC') AS at, toDate('2024-02-29') AS day, toUUID('00112233-4455-6677-8899-aabbccddeeff') AS uuid, CAST(NULL AS Nullable(String)) AS nullable";
    const scalars = await run({ action: 'scalars', sql: scalarSql });
    assert.ok(scalars.output.includes('18446744073709551615'), scalars.output);
    assert.ok(scalars.output.includes('-9223372036854775808'), scalars.output);
    assert.equal(scalars.lines[0].rows[0].d, '12345678901234567890.123456789012345678');
    assert.equal(scalars.lines[0].rows[0].at, '2024-02-29 23:59:59.123456789');
    assert.equal(scalars.lines[0].rows[0].nullable, null);

    // Real gzip request bodies and responses pass through the platform adapter.
    const inserted = [{ id: 41, text: 'gzip é' }, { id: 42, text: 'batch 2' }, { id: 43, text: 'last' }];
    const insert = await run({ action: 'insert', rows: inserted, gzip: true, query_id: 'compressed-batches' });
    assert.deepEqual(insert.lines.at(-1), { progress: { rows: 3, batches: 2 } });
    assert.deepEqual((await run({ action: 'query', gzip: true, sql: 'SELECT id, text FROM events WHERE id>=41 ORDER BY id' })).lines[0].rows, inserted);
    const streamed = await run({ action: 'stream', sql: 'SELECT id, text FROM events WHERE id>=41 ORDER BY id' });
    assert.deepEqual(streamed.lines, [...inserted.map(row => ({ row })), { end: true }]);

    // One row arrives while server deliberately waits for consumer progress.
    let earlyClosed;
    const closed = new Promise(resolve => { earlyClosed = resolve; });
    handler = async (request, response) => {
      await body(request);
      const url = new URL(request.url, endpoint);
      assert.equal(url.searchParams.get('wait_end_of_query'), '0');
      response.writeHead(200, { 'Content-Type': 'application/x-ndjson' });
      const bytes = Buffer.from(JSON.stringify(row) + '\n');
      const split = bytes.indexOf(Buffer.from('é')) + 1;
      response.write(bytes.subarray(0, split));
      const timer = setTimeout(() => response.write(bytes.subarray(split)), 30);
      const guard = setTimeout(() => response.destroy(new Error('consumer did not release body')), 5000);
      response.once('close', () => { clearTimeout(timer); clearTimeout(guard); earlyClosed(); });
    };
    const early = await run({ action: 'stream', endpoint, take: 1 });
    assert.deepEqual(early.lines, [{ row }, { end: true }]);
    await closed;

    for (const [suffix, error] of [['Code: 395. DB::Exception\n', 'ClickHouseException'], ['{"id":', 'InvalidRow'], ['x'.repeat(101), 'RowTooLarge']]) {
      handler = async (request, response) => { await body(request); response.end(JSON.stringify(row) + '\n' + suffix); };
      const failed = await run({ action: 'stream', endpoint, max_row_bytes: 100 });
      assert.deepEqual(failed.lines[0], { row });
      assert.match(failed.lines[1].error, new RegExp(error));
      assert.equal(failed.lines.length, 3, 'one terminal error then end');
    }
    handler = async (request, response) => { await body(request); response.writeHead(502).end('upstream unavailable'); };
    assert.match((await run({ action: 'query', endpoint })).lines[0].error, /HttpError/);
    handler = async (request, response) => { await body(request); response.writeHead(200, { 'Content-Encoding': 'gzip' }).end(gzipSync(Buffer.from('x'.repeat(10_000)))); };
    assert.match((await run({ action: 'query', endpoint, gzip: true, max_bytes: 200 })).lines[0].error, /CompressionError/);
    handler = async (request, response) => { await body(request); response.writeHead(200, { 'Content-Encoding': 'gzip' }).end('broken gzip'); };
    assert.match((await run({ action: 'query', endpoint, gzip: true })).lines[0].error, /CompressionError/);

    let batches = 0;
    const accepted = [];
    handler = async (request, response) => {
      const url = new URL(request.url, endpoint);
      assert.match(url.searchParams.get('query'), /^INSERT INTO `events` FORMAT JSONEachRow$/);
      const bytes = await body(request);
      const decoded = request.headers['content-encoding'] === 'gzip' ? gunzipSync(bytes) : bytes;
      assert.ok(decoded.length <= 100);
      const records = decoded.toString().trim().split('\n').map(JSON.parse);
      assert.ok(records.length <= 2);
      batches += 1;
      if (batches === 2) response.writeHead(500, { 'X-ClickHouse-Exception-Code': '243' }).end('Code: 243. batch failed');
      else { accepted.push(...records); response.end(); }
    };
    const data = Array.from({ length: 5 }, (_, index) => ({ id: index + 1, text: 'batch' }));
    const batchFailure = await run({ action: 'insert_stream', endpoint, rows: data, max_bytes: 100 }, value => {
      if (value.pulled >= 3) assert.ok(batches >= 1, 'previous batch acknowledged before pulling more rows');
    });
    assert.equal(batches, 2);
    assert.deepEqual(accepted, data.slice(0, 2));
    assert.deepEqual(batchFailure.lines.filter(value => value.pulled).map(value => value.pulled), [1, 2, 3, 4]);
    assert.match(batchFailure.lines.at(-1).error, /InsertFailed/);
    assert.match(batchFailure.lines.at(-1).error, /rows: 2/);
    handler = async (request, response) => { await body(request); batches += 1; response.end(); };
    const sourceFailure = await run({ action: 'insert_stream', endpoint, rows: data, source_error: true });
    assert.match(sourceFailure.lines.at(-1).error, /SourceError/);
    assert.match(sourceFailure.lines.at(-1).error, /rows: 2/);
    assert.deepEqual(sourceFailure.lines.filter(value => value.pulled).map(value => value.pulled), [1, 2, 3]);
    let byteBatches = 0;
    handler = async (request, response) => {
      const bytes = await body(request);
      assert.ok(bytes.length <= 55, 'serialized byte budget includes LF');
      byteBatches += 1;
      response.end();
    };
    const byteLimited = await run({ action: 'insert_stream', endpoint, rows: data, max_rows: 100, max_bytes: 55 });
    assert.deepEqual(byteLimited.lines.at(-1), { progress: { rows: 5, batches: 3 } });
    assert.equal(byteBatches, 3, 'byte boundary flushes before row-count boundary');
    assert.match((await run({ action: 'insert', endpoint, rows: [row], max_bytes: 5 })).lines[0].error, /RowTooLarge/);
    assert.match((await run({ action: 'insert', endpoint, table: [], rows: [] })).lines[0].error, /InvalidConfig/);
    const beforeEmpty = byteBatches;
    assert.deepEqual((await run({ action: 'insert', endpoint, rows: [] })).lines[0], { progress: { rows: 0, batches: 0 } });
    assert.equal(byteBatches, beforeEmpty, 'empty inputs and oversized rows never send');

    // Server process metadata proves the target is running before cancellation.
    const queryId = 'cancel-' + Date.now();
    const headers = { 'X-ClickHouse-User': 'default', 'X-ClickHouse-Key': password };
    const queryUrl = new URL(clickhouse);
    queryUrl.searchParams.set('query_id', queryId);
    queryUrl.searchParams.set('query', "SELECT number, sleepEachRow(0.05) FROM numbers(1000) SETTINGS max_block_size=1 FORMAT JSONEachRow");
    queryUrl.searchParams.set('buffer_size', '1');
    queryUrl.searchParams.set('wait_end_of_query', '0');
    const running = fetch(queryUrl, { method: 'POST', headers, signal: AbortSignal.timeout(15_000) }).then(response => response.text());
    // Allow query admission once, then inspect authoritative server state.
    await new Promise(resolve => setTimeout(resolve, 200));
    const observed = await run({ action: 'query', sql: `SELECT toUInt64(1) AS id, query_id AS text FROM system.processes WHERE query_id='${queryId}'` });
    assert.equal(observed.lines[0].rows.length, 1, 'target query is running');
    const cancelled = await run({ action: 'cancel', query_id: queryId });
    assert.ok(cancelled.lines[0].cancelled.some(result => result.query_id === queryId && result.kill_status === 'finished'), JSON.stringify(cancelled));
    assert.match(await running, /QUERY_WAS_CANCELLED|Query was cancelled|Code: 394/);
    assert.deepEqual((await run({ action: 'cancel', query_id: "absent' OR 1=1 --" })).lines[0].cancelled, []);
    console.log('PASS: typed records/scalars, lazy row streaming, early release, terminal errors, bounded acknowledged batches, gzip and server cancellation.');
  } finally {
    for (const child of active) child.kill('SIGTERM');
    fake.closeAllConnections();
    await new Promise(resolve => fake.close(resolve));
  }
}
