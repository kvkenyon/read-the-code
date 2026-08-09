import { execFile } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { promisify } from 'node:util';

const exec = promisify(execFile);
const repository = resolve(process.argv[2] ?? '.test-state/large-repository');
const state = await mkdtemp(join(tmpdir(), 'read-the-code-baseline-'));
try {
  const started = performance.now();
  const { stdout } = await exec(
    process.execPath,
    [
      'dist/cli.js',
      'open',
      '--repo',
      repository,
      '--base',
      'HEAD~1',
      '--head',
      'HEAD',
      '--no-browser',
      '--json',
    ],
    {
      env: { ...process.env, READ_THE_CODE_STATE_DIR: state },
      maxBuffer: 32 * 1024 * 1024,
      encoding: 'utf8',
    },
  );
  const openMs = performance.now() - started;
  const opened = JSON.parse(stdout);
  const statusStarted = performance.now();
  await exec(process.execPath, ['dist/cli.js', 'status', opened.sessionId, '--json'], {
    env: { ...process.env, READ_THE_CODE_STATE_DIR: state },
    encoding: 'utf8',
  });
  process.stdout.write(
    `${JSON.stringify({ schemaVersion: 1, openMs: Math.round(openMs), statusMs: Math.round(performance.now() - statusStarted), platform: process.platform, arch: process.arch, node: process.version })}\n`,
  );
} finally {
  await rm(state, { recursive: true, force: true });
}
