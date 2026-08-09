import { execFile } from 'node:child_process';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';

const exec = promisify(execFile);
const root = await mkdtemp(join(process.cwd(), '.pack-smoke-'));
try {
  const packOutput = (
    await exec('npm', ['pack', '--json', '--pack-destination', root], { encoding: 'utf8' })
  ).stdout;
  const jsonStart = packOutput.lastIndexOf('\n[\n');
  const packed = JSON.parse(jsonStart >= 0 ? packOutput.slice(jsonStart + 1) : packOutput);
  const tarball = join(root, packed[0].filename);
  const install = join(root, 'install');
  await mkdir(install);
  await writeFile(join(install, 'package.json'), '{"private":true}\n');
  await exec('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund', tarball], {
    cwd: install,
    encoding: 'utf8',
  });
  const binary = join(install, 'node_modules', '.bin', 'read-the-code-axi');
  const { stdout } = await exec(binary, ['--version'], { cwd: install, encoding: 'utf8' });
  if (stdout.trim() !== '0.1.0') throw new Error(`Unexpected packed CLI version: ${stdout.trim()}`);
  process.stdout.write(`packed install smoke passed (${packed[0].filename})\n`);
} finally {
  await rm(root, { recursive: true, force: true });
}
