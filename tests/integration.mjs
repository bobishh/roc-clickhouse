// Given a disposable authenticated ClickHouse, When compiled Roc inserts and
// queries, Then values survive and failures/limits remain explicit without retry.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const workRoot = process.env.ROC_CLICKHOUSE_WORK_DIR ?? process.env.RUNNER_TEMP ?? os.tmpdir();
await mkdir(workRoot, { recursive: true });
const work = await mkdtemp(path.join(workRoot, 'roc-clickhouse-'));
const binary = path.join(work, 'client-server');
const roc = process.env.ROC ?? 'roc';
const container = 'roc-clickhouse-' + randomUUID();
const password = randomUUID();
let app;
let faults;
let stderr = '';
let requests = 0;

function docker(...args) {
  const result = spawnSync('docker', args, { encoding: 'utf8', timeout: 120_000 });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result.stdout.trim();
}

async function unusedPort() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

async function ready(url, child) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (child?.exitCode != null) throw new Error('Roc application exited: ' + stderr);
    try { if ((await fetch(url, { signal: AbortSignal.timeout(500) })).ok) return; } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error('Service did not start: ' + url + '\n' + stderr);
}

try {
  const replacement = process.env.ROC_CLICKHOUSE_PACKAGE ? ['--replace-dep', path.join(root, 'package/main.roc'), process.env.ROC_CLICKHOUSE_PACKAGE] : [];
  const build = spawnSync(roc, ['build', '--opt=dev', 'tests/server.roc', `--output=${binary}`, ...replacement], { cwd: root, encoding: 'utf8', timeout: 120_000 });
  await writeFile(path.join(work, 'build.log'), build.stdout + build.stderr);
  assert.ok([0, 2].includes(build.status), 'Roc build failed; see ' + path.join(work, 'build.log'));
  assert.ok((await readFile(binary)).length > 0, 'fresh compiled binary exists');

  docker('run', '-d', '--name', container, '-e', `CLICKHOUSE_PASSWORD=${password}`,
    '-e', 'CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1', '-p', '127.0.0.1::8123', 'clickhouse/clickhouse-server:26.8.11.7');
  const published = docker('port', container, '8123/tcp');
  const clickhouse = 'http://127.0.0.1:' + published.match(/:(\d+)$/)[1];
  await ready(clickhouse + '/ping');

  const port = await unusedPort();
  const origin = `http://127.0.0.1:${port}`;
  app = spawn(binary, [], { cwd: root, stdio: ['ignore', 'ignore', 'pipe'], env: {
    ...process.env, CLIENT_PORT: String(port), CLICKHOUSE_URL: clickhouse, CLICKHOUSE_PASSWORD: password,
  } });
  app.stderr.setEncoding('utf8').on('data', chunk => { stderr = (stderr + chunk).slice(-16_384); });
  await ready(origin + '/health', app);

  async function query(input, expected = 200) {
    const response = await fetch(origin, { method: 'POST', body: JSON.stringify(input), signal: AbortSignal.timeout(15_000) });
    const text = await response.text();
    assert.equal(response.status, expected, text + '\n' + stderr);
    return text ? JSON.parse(text) : null;
  }

  await query({ sql: 'CREATE TABLE events (id UInt64, text String) ENGINE=MergeTree ORDER BY id' });
  const text = "Привет + '& backslash\\ newline\n tab\t null\0 return\r";
  const rows = [{ id: 1, text }, { id: 2, text: "x' OR 1=1 --" }];
  await query({ sql: 'INSERT INTO events FORMAT JSONEachRow', rows, async_insert: true });
  const selected = await query({ sql: 'SELECT id, text FROM events ORDER BY id SETTINGS output_format_json_quote_64bit_integers=0 FORMAT JSONEachRow', decode: true });
  assert.deepEqual(selected.rows, rows, 'async acknowledgement means rows are stored and typed values survive: ' + JSON.stringify(selected));
  const filtered = await query({ sql: 'SELECT id, text FROM events WHERE text={value:String} SETTINGS output_format_json_quote_64bit_integers=0 FORMAT JSONEachRow',
    parameters: [{ name: 'value', value: rows[1].text }], decode: true });
  assert.deepEqual(filtered.rows, [rows[1]], 'parameter is data rather than SQL');
  const escaped = await query({ sql: 'SELECT id, text FROM events WHERE text={value:String} SETTINGS output_format_json_quote_64bit_integers=0 FORMAT JSONEachRow',
    parameters: [{ name: 'value', value: text }], decode: true });
  assert.deepEqual(escaped.rows, [rows[0]], 'parameter preserves Unicode, controls and backslashes');
  const empty = await query({ sql: 'SELECT id, text FROM events WHERE id=999 FORMAT JSONEachRow', decode: true });
  assert.deepEqual(empty.rows, []);

  assert.equal((await query({ sql: 'SELECT 1', password: 'wrong-password' }, 502)).error, 'clickhouse');
  assert.equal((await query({ sql: 'INVALID SQL' }, 502)).error, 'clickhouse');
  assert.equal((await query({ sql: 'SELECT * FROM absent_table' }, 502)).code, '60');
  assert.equal((await query({ sql: 'INSERT INTO events FORMAT JSONEachRow', rows: [{ id: 1, text: 'bad' }], password: 'wrong-password', async_insert: true }, 502)).error, 'clickhouse');
  assert.equal((await query({ sql: 'SELECT number AS id, toString(throwIf(number=2)) AS text FROM numbers(5) SETTINGS max_block_size=1 FORMAT JSONEachRow', decode: true }, 502)).error, 'clickhouse');

  let mode = 'disconnect';
  faults = http.createServer((request, response) => {
    requests += 1;
    request.resume();
    if (mode === 'disconnect') { request.socket.destroy(); return; }
    if (mode === 'large') { response.end('x'.repeat(4096)); return; }
    if (mode === 'late-error') { response.end('{"id":1,"text":"partial"}\nCode: 395. DB::Exception'); return; }
    if (mode === 'slow') { const timer = setTimeout(() => response.end('late'), 2000); response.on('close', () => clearTimeout(timer)); }
  });
  await new Promise(resolve => faults.listen(0, '127.0.0.1', resolve));
  const endpoint = `http://127.0.0.1:${faults.address().port}`;
  assert.equal((await query({ sql: 'SELECT 1', endpoint }, 503)).error, 'transport');
  assert.equal(requests, 1, 'disconnected request is not retried');
  mode = 'large';
  assert.equal((await query({ sql: 'SELECT 1', endpoint, max_response_bytes: 64 }, 503)).error, 'transport');
  mode = 'late-error';
  assert.equal((await query({ sql: 'SELECT 1', endpoint, decode: true }, 502)).error, 'decode');
  mode = 'slow';
  assert.equal((await query({ sql: 'SELECT 1', endpoint, timeout_ms: 100 }, 503)).error, 'transport');
  assert.equal(requests, 4, 'every operation sends exactly once');
  console.log('PASS: real ClickHouse authenticated insert/select, parameters, empty results, failures, limits and no retries.');
} finally {
  if (app) {
    const ended = new Promise(resolve => app.once('exit', resolve));
    if (app.exitCode == null) { app.kill('SIGTERM'); await ended; }
  }
  if (faults) { faults.closeAllConnections(); await new Promise(resolve => faults.close(resolve)); }
  spawnSync('docker', ['rm', '-f', container], { stdio: 'ignore' });
  await writeFile(path.join(work, 'server.log'), stderr);
  console.log('Integration artifacts: ' + work);
}
