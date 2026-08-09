import { execFile } from 'node:child_process';
import { rm } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { expect, test } from '@playwright/test';
import { createFixtureRepo, createTestRoot, type FixtureRepo } from '../helpers';

const exec = promisify(execFile);
let root: string;
let fixture: FixtureRepo;
let state: string;
let sessionId: string;
let browserUrl: string;

async function cli(...args: string[]): Promise<string> {
  return (
    await exec(process.execPath, [join(process.cwd(), 'dist', 'cli.js'), ...args], {
      cwd: process.cwd(),
      env: { ...process.env, READ_THE_CODE_STATE_DIR: state },
      encoding: 'utf8',
    })
  ).stdout.trim();
}

test.beforeAll(async () => {
  root = await createTestRoot('e2e-');
  fixture = await createFixtureRepo(join(root, 'fixture-repository'));
  state = join(root, 'state');
  const opened = JSON.parse(
    await cli(
      'open',
      '--repo',
      fixture.path,
      '--base',
      fixture.baseSha,
      '--head',
      fixture.headSha,
      '--no-browser',
      '--json',
    ),
  ) as { sessionId: string; browserUrl: string };
  sessionId = opened.sessionId;
  browserUrl = opened.browserUrl;
});

test.afterAll(async () => {
  if (sessionId) await cli('end', sessionId, '--json').catch(() => undefined);
  if (root) await rm(root, { recursive: true, force: true });
});

test('keyboard-first exact review is safe, accessible, themed, and responsive', async ({
  page,
}) => {
  const requests: string[] = [];
  let injectionExecuted = false;
  page.on('request', (request) => requests.push(request.url()));
  page.on('dialog', async (dialog) => {
    if (dialog.type() === 'alert') injectionExecuted = true;
    await dialog.accept();
  });
  await page.goto(browserUrl);
  await expect(page).toHaveTitle('Read the Code');
  await expect(page.getByText('fixture-repository')).toBeVisible();
  await expect(page.getByText('6 files')).toBeVisible();
  expect(requests.every((url) => new URL(url).hostname === '127.0.0.1')).toBe(true);

  const mathFile = page.getByRole('button', { name: /modified src\/math\.ts/ });
  await mathFile.click();
  await expect(page.getByRole('heading', { name: 'src/math.ts' })).toBeVisible();
  await expect(page.getByTestId('diff-view')).toHaveClass(/unified/);
  await page.getByRole('button', { name: 'Split' }).click();
  await expect(page.getByTestId('diff-view')).toHaveClass(/split/);
  await page.getByRole('button', { name: 'Unified' }).click();

  const line = page.getByTestId('line-new-2');
  await expect(line).toHaveAttribute(
    'aria-label',
    /Added, no old line, new line 2: {3}const total/,
  );
  await line.focus();
  await page.keyboard.press('c');
  const composer = page.getByPlaceholder('What should the author understand or change?');
  await expect(composer).toBeFocused();
  await composer.fill('Keyboard safety j k s u g : / ?');
  await page.keyboard.press('Escape');
  await expect(composer).toHaveCount(0);
  await expect(page.getByText('Keyboard safety j k s u g : / ?')).toBeVisible();
  await expect(line).toBeFocused();

  await line.focus();
  await page.keyboard.press('/');
  const find = page.getByPlaceholder('Find files  /');
  await expect(find).toBeFocused();
  await find.fill('math');
  await expect(page.getByRole('heading', { name: 'src/math.ts' })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(find).toHaveValue('');
  await page.keyboard.press('Escape');

  await mathFile.focus();
  await page.keyboard.press('?');
  const help = page.getByRole('dialog', { name: 'Keyboard help' });
  await expect(help).toBeVisible();
  await expect(help.getByRole('heading', { name: 'Keyboard help' })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(mathFile).toBeFocused();

  await page.keyboard.press(':');
  const palette = page.getByRole('dialog', { name: 'Command palette' });
  await expect(palette.getByPlaceholder('Type a command')).toBeFocused();
  await page.keyboard.type('unified');
  await expect(palette.getByRole('button', { name: /Use unified diff/ })).toBeVisible();
  await page.keyboard.press('Escape');

  await page.getByLabel('Theme').selectOption('light');
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  await expect(page.getByText('Keyboard safety j k s u g : / ?')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'src/math.ts' })).toBeVisible();
  await page.getByLabel('Theme').selectOption('system');
  await page.emulateMedia({ colorScheme: 'dark' });
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await page.emulateMedia({ colorScheme: 'light' });
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');

  await mathFile.focus();
  await page.keyboard.press('g');
  await page.keyboard.press('r');
  await page.getByRole('button', { name: '+ General comment' }).click();
  await composer.fill('The change set is focused and readable.');
  await page.keyboard.press(process.platform === 'darwin' ? 'Meta+Enter' : 'Control+Enter');
  await expect(page.getByText('The change set is focused and readable.')).toBeVisible();
  await page.getByRole('button', { name: 'Submit feedback (2)' }).click();
  await expect(page.getByText('Feedback submitted as one durable batch.')).toBeVisible();
  const polled = JSON.parse(
    await cli('poll', sessionId, '--after', '0', '--timeout', '1s', '--json'),
  ) as {
    events: Array<{ sequence: number; type: string; comments: unknown[] }>;
    nextCursor: number;
  };
  expect(polled.events[0]).toMatchObject({ sequence: 1, type: 'feedback' });
  expect(polled.events[0].comments).toHaveLength(2);
  expect(polled.nextCursor).toBe(1);

  await page.keyboard.press('m');
  await expect(page.locator('.reviewed-button')).toHaveText(/Reviewed/);
  await page.getByRole('button', { name: 'Approve exact revision' }).click();
  await expect(page.getByText(/Approved exact head [0-9a-f]{9}/)).toBeVisible();

  await page.getByRole('button', { name: /evil/ }).click();
  await expect(page.locator('.diff-view img')).toHaveCount(0);
  expect(injectionExecuted).toBe(false);

  for (const width of [1440, 720, 390, 320]) {
    await page.setViewportSize({ width, height: 844 });
    expect(
      await page.evaluate(() => ({
        width: document.documentElement.scrollWidth,
        client: document.documentElement.clientWidth,
      })),
    ).toEqual({ width, client: width });
    await expect(page.getByRole('button', { name: 'Comment on file' })).toBeVisible();
    await expect(page.locator('.reviewed-button')).toBeVisible();
    await expect(page.getByRole('button', { name: /Submit feedback/ })).toBeAttached();
    await expect(page.getByRole('button', { name: 'Approve exact revision' })).toBeAttached();
    await expect(page.getByRole('button', { name: 'End review' })).toBeAttached();
  }
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.evaluate(() => {
    document.body.style.zoom = '4';
  });
  await expect(page.locator('.reviewed-button')).toBeAttached();
  await expect(page.getByRole('button', { name: 'Comment on file' })).toBeAttached();
  await expect(page.getByRole('button', { name: 'Approve exact revision' })).toBeAttached();
});
