import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';

const exec = promisify(execFile);

async function git(repo: string, ...args: string[]): Promise<string> {
  const { stdout } = await exec('git', ['-C', repo, ...args], { encoding: 'utf8' });
  return stdout.trim();
}

export interface FixtureRepo {
  path: string;
  baseSha: string;
  headSha: string;
}

export async function createTestRoot(prefix: string): Promise<string> {
  const parent = join(process.cwd(), '.test-state');
  await mkdir(parent, { recursive: true });
  return mkdtemp(join(parent, prefix));
}

export async function createFixtureRepo(root: string): Promise<FixtureRepo> {
  await mkdir(root, { recursive: true });
  await git(root, 'init', '-q');
  await git(root, 'config', 'user.name', 'Read the Code Tests');
  await git(root, 'config', 'user.email', 'test@example.invalid');
  await mkdir(join(root, 'src'), { recursive: true });
  await writeFile(
    join(root, 'src', 'math.ts'),
    'export function add(a: number, b: number) {\n  return a + b;\n}\n',
  );
  await writeFile(join(root, 'delete-me.txt'), 'this file will be removed\n');
  await writeFile(join(root, 'rename-me.md'), '# Before\n\nRename this document.\n');
  await writeFile(join(root, 'binary.dat'), Buffer.from([0, 1, 2, 3, 255, 0, 10]));
  await git(root, 'add', '--all');
  await git(root, 'commit', '-qm', 'base fixture');
  const baseSha = await git(root, 'rev-parse', 'HEAD');

  await writeFile(
    join(root, 'src', 'math.ts'),
    'export function add(a: number, b: number) {\n  const total = a + b;\n  return total;\n}\n\nexport const answer = 42;\n',
  );
  await writeFile(join(root, 'added.py'), 'def greet(name):\n    return f"Hello, {name}!"\n');
  await git(root, 'rm', '-q', 'delete-me.txt');
  await git(root, 'mv', 'rename-me.md', 'renamed-guide.md');
  await writeFile(join(root, 'binary.dat'), Buffer.from([0, 1, 9, 8, 7, 0, 255]));
  await writeFile(
    join(root, 'evil\nname<script>.tsx'),
    'export const payload = "</script><img src=x onerror=alert(1)>";\n',
  );
  await git(root, 'add', '--all');
  await git(root, 'commit', '-qm', 'head fixture');
  const headSha = await git(root, 'rev-parse', 'HEAD');
  return { path: root, baseSha, headSha };
}
