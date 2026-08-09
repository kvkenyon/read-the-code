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

test('reviews an exact revision from lines through durable approval', async ({ page }) => {
  let injectionExecuted = false;
  page.on('dialog', async (dialog) => {
    if (dialog.type() === 'alert') injectionExecuted = true;
    await dialog.accept();
  });
  await page.goto(browserUrl);
  await expect(page).toHaveTitle('Read the Code');
  await expect(page.getByText('fixture-repository')).toBeVisible();
  await expect(page.getByText('6 files')).toBeVisible();

  await page.getByRole('button', { name: /src\/math\.ts/ }).click();
  await expect(page.getByRole('heading', { name: 'src/math.ts' })).toBeVisible();
  await expect(page.getByTestId('diff-view')).toHaveClass(/unified/);
  await page.getByRole('button', { name: 'Split' }).click();
  await expect(page.getByTestId('diff-view')).toHaveClass(/split/);
  await page.getByRole('button', { name: 'Unified' }).click();

  await page.getByTestId('line-new-2').click();
  await page
    .getByPlaceholder('What should the author understand or change?')
    .fill('Could this intermediate name explain the unit?');
  await page.getByRole('button', { name: 'Save draft' }).click();
  await expect(page.getByText('Could this intermediate name explain the unit?')).toBeVisible();

  await page.getByRole('button', { name: '+ General comment' }).click();
  await page
    .getByPlaceholder('What should the author understand or change?')
    .fill('The change set is focused and readable.');
  await page.getByRole('button', { name: 'Save draft' }).click();
  await page.locator('.draft-card').first().getByRole('button', { name: 'Edit' }).click();
  await page
    .getByPlaceholder('What should the author understand or change?')
    .fill('Could this intermediate name explain its unit?');
  await page.getByRole('button', { name: 'Save draft' }).click();

  await page.getByRole('button', { name: '+ General comment' }).click();
  await page.getByPlaceholder('What should the author understand or change?').fill('Discard me.');
  await page.getByRole('button', { name: 'Save draft' }).click();
  await page
    .locator('.draft-card')
    .filter({ hasText: 'Discard me.' })
    .getByRole('button', { name: 'Discard' })
    .click();
  await expect(page.getByText('Discard me.')).toHaveCount(0);

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

  await page.getByRole('button', { name: 'Approve revision' }).click();
  await expect(page.getByText(/Approved [0-9a-f]{9}/)).toBeVisible();

  await page.getByRole('button', { name: /evil/ }).click();
  await expect(page.locator('.diff-view img')).toHaveCount(0);
  expect(injectionExecuted).toBe(false);

  await page.keyboard.press('j');
  await page.keyboard.press('k');
  await page.keyboard.press('Tab');
  expect(await page.evaluate(() => document.activeElement?.tagName)).not.toBe('BODY');

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.getByRole('button', { name: 'Open changed files' })).toBeVisible();
  expect(
    await page.evaluate(() => ({
      width: document.documentElement.scrollWidth,
      client: document.documentElement.clientWidth,
    })),
  ).toEqual({ width: 390, client: 390 });
});
