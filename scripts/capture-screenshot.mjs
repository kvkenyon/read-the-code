import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { chromium } from '@playwright/test';

const exec = promisify(execFile);
const workspace = process.cwd();
const testState = join(workspace, '.test-state');
await mkdir(testState, { recursive: true });
const root = await mkdtemp(join(testState, 'screenshot-'));
const repository = join(root, 'fixture-repository');
const state = join(root, 'state');
const cli = join(workspace, 'dist', 'cli.js');
const output = join(workspace, 'docs', 'screenshot.png');
const macChrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
let sessionId;

async function runCli(...args) {
  return (
    await exec(process.execPath, [cli, ...args], {
      cwd: workspace,
      env: { ...process.env, READ_THE_CODE_STATE_DIR: state },
      encoding: 'utf8',
    })
  ).stdout.trim();
}

try {
  await exec(process.execPath, [join(workspace, 'scripts', 'create-fixture.mjs'), repository], {
    cwd: workspace,
  });
  const opened = JSON.parse(
    await runCli(
      'open',
      '--repo',
      repository,
      '--base',
      'main~1',
      '--head',
      'main',
      '--no-browser',
      '--json',
    ),
  );
  sessionId = opened.sessionId;
  const browser = await chromium.launch({
    headless: true,
    ...(existsSync(macChrome) ? { executablePath: macChrome } : {}),
  });
  try {
    const page = await browser.newPage({
      viewport: { width: 1440, height: 900 },
      colorScheme: 'dark',
    });
    await page.goto(opened.browserUrl, { waitUntil: 'networkidle' });
    await page.getByRole('button', { name: /src\/checkout\.ts/ }).click();
    await page.getByRole('heading', { name: 'src/checkout.ts' }).waitFor();
    await page.getByTestId('line-new-7').click();
    await page
      .getByPlaceholder('What should the author understand or change?')
      .fill('Should rounding happen only at the currency formatting boundary?');
    await page.getByRole('button', { name: 'Save draft' }).click();
    await page.screenshot({ path: output, animations: 'disabled' });
  } finally {
    await browser.close();
  }
  process.stdout.write(`${output}\n`);
} finally {
  if (sessionId) await runCli('end', sessionId, '--json').catch(() => undefined);
  await rm(root, { recursive: true, force: true });
}
