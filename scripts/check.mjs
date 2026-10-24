import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const roc = process.env.ROC ?? 'roc';
const workRoot = process.env.ROC_CLICKHOUSE_WORK_DIR ?? process.env.RUNNER_TEMP ?? os.tmpdir();
await mkdir(workRoot, { recursive: true });
const work = await mkdtemp(path.join(workRoot, 'roc-clickhouse-check-'));

async function run(command, args, label, options = {}) {
  let output = '';
  const child = spawn(command, args, { cwd: root, ...options, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.setEncoding('utf8').on('data', chunk => { output += chunk; });
  child.stderr.setEncoding('utf8').on('data', chunk => { output += chunk; });
  const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); });
  await writeFile(path.join(work, label + '.log'), output);
  assert.ok(code === 0 || (command === roc && code === 2), label + ' failed; see ' + path.join(work, label + '.log'));
  console.log('PASS: ' + label);
  return output;
}

const pin = (await readFile(path.join(root, '.roc-version'), 'utf8')).trim();
assert.ok((await run(roc, ['version'], 'compiler')).includes(pin), 'install compiler from .roc-version');
await run(roc, ['fmt', '--check', 'package', 'tests', 'examples'], 'format');
await run(roc, ['check', 'package/main.roc'], 'types');
await run(roc, ['check', 'examples/server.roc'], 'example');
const tests = await run(roc, ['test', 'tests/client.roc'], 'unit');
assert.match(tests, /All \([1-9][0-9]*\) tests passed/, 'expectations execute and pass');

await run(roc, ['bundle', 'package/main.roc', '--output-dir', work], 'bundle');
const archives = (await readdir(work)).filter(file => file.endsWith('.tar.zst'));
assert.equal(archives.length, 1);
const archive = await readFile(path.join(work, archives[0]));
const server = createServer((request, response) => {
  if (request.url !== '/' + archives[0]) { response.writeHead(404).end(); return; }
  response.writeHead(200, { 'Content-Type': 'application/zstd', 'Content-Length': archive.length });
  response.end(archive);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
try {
  const output = await run(process.execPath, ['tests/integration.mjs'], 'integration', { env: {
    ...process.env, ROC: roc, ROC_CLICKHOUSE_WORK_DIR: workRoot,
    ROC_CLICKHOUSE_PACKAGE: `http://127.0.0.1:${server.address().port}/${archives[0]}`,
  } });
  assert.match(output, /PASS: real ClickHouse/);
} finally {
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
const bundle = path.join(work, archives[0]);
if (process.env.GITHUB_OUTPUT) {
  const { appendFile } = await import('node:fs/promises');
  await appendFile(process.env.GITHUB_OUTPUT, `bundle=${bundle}\n`);
}
console.log('Verified release bundle: ' + bundle);
