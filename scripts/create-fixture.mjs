import { execFile } from 'node:child_process';
import { access, mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { promisify } from 'node:util';

const exec = promisify(execFile);
const target = resolve(process.argv[2] ?? '.test-state/example-repository');

try {
  await access(target);
  throw new Error(`Refusing to overwrite existing path: ${target}`);
} catch (error) {
  if (error instanceof Error && error.message.startsWith('Refusing')) throw error;
}

async function git(...args) {
  return (await exec('git', ['-C', target, ...args], { encoding: 'utf8' })).stdout.trim();
}

await mkdir(dirname(target), { recursive: true });
await mkdir(target);
await git('init', '-q', '--initial-branch=main');
await git('config', 'user.name', 'Read the Code Fixture');
await git('config', 'user.email', 'fixture@example.invalid');
await mkdir(`${target}/src`);
await writeFile(
  `${target}/src/checkout.ts`,
  `export function total(items: number[]): number {
  return items.reduce((sum, item) => sum + item, 0);
}
`,
);
await writeFile(`${target}/obsolete.txt`, 'Remove this before release.\n');
await writeFile(`${target}/guide.md`, '# Checkout\n\nA small local checkout module.\n');
await writeFile(`${target}/logo.bin`, Buffer.from([0, 1, 2, 0, 255]));
await git('add', '--all');
await git('commit', '-qm', 'Fixture base');
const base = await git('rev-parse', 'HEAD');

await writeFile(
  `${target}/src/checkout.ts`,
  `export interface LineItem {
  price: number;
  quantity: number;
}

export function total(items: LineItem[]): number {
  const subtotal = items.reduce((sum, item) => sum + item.price * item.quantity, 0);
  return Math.round(subtotal * 100) / 100;
}
`,
);
await writeFile(
  `${target}/src/currency.ts`,
  `export function formatCurrency(value: number): string {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(value);
}
`,
);
await git('rm', '-q', 'obsolete.txt');
await git('mv', 'guide.md', 'checkout-guide.md');
await writeFile(`${target}/logo.bin`, Buffer.from([0, 1, 9, 8, 0, 255]));
await writeFile(
  `${target}/unsafe<script>.tsx`,
  'export const literal = "</script><img onerror=alert(1)>";\n',
);
await git('add', '--all');
await git('commit', '-qm', 'Fixture head');
const head = await git('rev-parse', 'HEAD');

process.stdout.write(`${JSON.stringify({ repository: target, base, head })}\n`);
