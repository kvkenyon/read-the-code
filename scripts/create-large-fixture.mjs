import { execFile } from 'node:child_process';
import { access, mkdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { promisify } from 'node:util';

const exec = promisify(execFile);
const target = resolve(process.argv[2] ?? '.test-state/large-repository');
const fileCount = Number(process.argv[3] ?? 100);
const lineCount = Number(process.argv[4] ?? 5000);
if (!Number.isSafeInteger(fileCount) || fileCount < 1 || fileCount > 2000)
  throw new Error('file count must be 1..2000');
if (!Number.isSafeInteger(lineCount) || lineCount < 1 || lineCount > 100000)
  throw new Error('line count must be 1..100000');
try {
  await access(target);
  throw new Error(`Refusing to overwrite existing path: ${target}`);
} catch (error) {
  if (error instanceof Error && error.message.startsWith('Refusing')) throw error;
}
const git = async (...args) =>
  (await exec('git', ['-C', target, ...args], { encoding: 'utf8' })).stdout.trim();

await mkdir(dirname(target), { recursive: true });
await mkdir(target);
await git('init', '-q', '--initial-branch=main');
await git('config', 'user.name', 'Read the Code Performance Fixture');
await git('config', 'user.email', 'fixture@example.invalid');
const deep = join(
  target,
  ...Array.from({ length: 20 }, (_, index) => `level-${String(index).padStart(2, '0')}`),
);
await mkdir(deep, { recursive: true });
for (let index = 0; index < fileCount; index += 1) {
  const path = join(deep, `component-with-a-stable-long-name-${String(index).padStart(4, '0')}.ts`);
  await writeFile(path, `export const value${index} = ${index};\n`);
}
await writeFile(
  join(target, 'large-diff.ts'),
  `${Array.from({ length: lineCount }, (_, index) => `export const line${index} = ${index};`).join('\n')}\n`,
);
await git('add', '--all');
await git('commit', '-qm', 'Large fixture base');
const base = await git('rev-parse', 'HEAD');
for (let index = 0; index < fileCount; index += 1) {
  const path = join(deep, `component-with-a-stable-long-name-${String(index).padStart(4, '0')}.ts`);
  await writeFile(path, `export const value${index} = ${index + 1};\n`);
}
await writeFile(
  join(target, 'large-diff.ts'),
  `${Array.from({ length: lineCount }, (_, index) => `export const line${index} = ${index + 1};`).join('\n')}\n`,
);
await git('add', '--all');
await git('commit', '-qm', 'Large fixture head');
const head = await git('rev-parse', 'HEAD');
process.stdout.write(
  `${JSON.stringify({ repository: target, base, head, fileCount: fileCount + 1, lineCount })}\n`,
);
