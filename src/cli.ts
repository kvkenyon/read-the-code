#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { resolve } from 'node:path';
import { Command } from 'commander';
import { ensureServer, sessionFetch } from './core/client.js';
import { AppError, errorMessage } from './core/errors.js';
import { buildReview, resolveCommit, resolveRepository } from './core/git.js';
import { startServer } from './core/server.js';
import { SessionStore } from './core/store.js';
import type { EndSubmission, OpenResult, PollResult } from './protocol.js';
import { SCHEMA_VERSION } from './protocol.js';

const program = new Command();

function output(value: unknown, json: boolean, text: string): void {
  process.stdout.write(json ? `${JSON.stringify(value)}\n` : `${text}\n`);
}

function shortSha(sha: string): string {
  return sha.slice(0, 10);
}

function parseDuration(input: string): number {
  const match = /^(\d+)(ms|s|m)?$/u.exec(input.trim());
  if (!match)
    throw new AppError('Timeout must look like 500ms, 30s, or 2m', 'INVALID_TIMEOUT', 2, 400);
  const amount = Number(match[1]);
  const multiplier = match[2] === 'm' ? 60_000 : match[2] === 'ms' ? 1 : 1_000;
  const value = amount * multiplier;
  if (!Number.isSafeInteger(value) || value > 3_600_000) {
    throw new AppError('Timeout must be at most 60 minutes', 'INVALID_TIMEOUT', 2, 400);
  }
  return value;
}

function launchBrowser(url: string): void {
  const platform = process.platform;
  const command = platform === 'darwin' ? 'open' : platform === 'win32' ? 'cmd' : 'xdg-open';
  const args = platform === 'win32' ? ['/d', '/s', '/c', 'start', '', url] : [url];
  const child = spawn(command, args, { detached: true, stdio: 'ignore', windowsHide: true });
  child.unref();
}

program
  .name('read-the-code-axi')
  .description('Open an exact local Git change set for browser review')
  .version('0.1.0');

program
  .command('open')
  .description('Create or resume an exact base-to-head review')
  .requiredOption('--repo <path>', 'local Git repository')
  .requiredOption('--base <ref>', 'base commit-ish')
  .requiredOption('--head <ref>', 'head commit-ish')
  .option('--no-browser', 'do not launch the default browser')
  .option('--json', 'emit versioned JSON')
  .action(
    async (options: {
      repo: string;
      base: string;
      head: string;
      browser: boolean;
      json?: boolean;
    }) => {
      const repository = await resolveRepository(resolve(options.repo));
      const [baseSha, headSha] = await Promise.all([
        resolveCommit(repository.path, options.base),
        resolveCommit(repository.path, options.head),
      ]);
      const store = new SessionStore();
      const id = store.sessionId(repository.path, baseSha, headSha);
      let review: Awaited<ReturnType<typeof buildReview>>;
      if (await store.exists(id)) {
        const existing = await store.read(id);
        review = { files: existing.files, summary: existing.summary };
      } else {
        review = await buildReview(repository.path, baseSha, headSha);
      }
      const { token, resumed } = await store.createOrResume({
        schemaVersion: SCHEMA_VERSION,
        id,
        repositoryName: repository.name,
        repositoryPath: repository.path,
        baseRef: options.base,
        headRef: options.head,
        baseSha,
        headSha,
        ...review,
      });
      const registry = await ensureServer(store, process.argv[1]);
      const browserUrl = `http://127.0.0.1:${registry.port}/#/review/${id}/${token}`;
      if (options.browser) launchBrowser(browserUrl);
      const result: OpenResult = {
        schemaVersion: SCHEMA_VERSION,
        sessionId: id,
        baseSha,
        headSha,
        browserUrl,
        resumed,
        status: 'open',
      };
      output(
        result,
        Boolean(options.json),
        `${resumed ? 'Resumed' : 'Opened'} ${id} · ${shortSha(baseSha)} → ${shortSha(headSha)}\n${browserUrl}`,
      );
    },
  );

program
  .command('status')
  .description('Show local review session status')
  .argument('<session>', 'session id')
  .option('--json', 'emit versioned JSON')
  .action(async (session: string, options: { json?: boolean }) => {
    const store = new SessionStore();
    const manifest = await store.manifest(session);
    const record = await store.read(session);
    const lastSequence = record.events.at(-1)?.sequence ?? 0;
    const result = {
      schemaVersion: SCHEMA_VERSION,
      sessionId: session,
      status: manifest.status,
      stale: manifest.stale,
      approvalStale: manifest.approvalStale,
      baseSha: manifest.baseSha,
      headSha: manifest.headSha,
      summary: manifest.summary,
      eventCount: record.events.length,
      lastSequence,
      updatedAt: manifest.updatedAt,
    };
    output(
      result,
      Boolean(options.json),
      `${session} · ${result.status}${result.stale ? ' · stale revision' : ''} · ${result.eventCount} events`,
    );
  });

program
  .command('poll')
  .description('Wait for durable review feedback after a submission cursor')
  .argument('<session>', 'session id')
  .option('--timeout <duration>', 'maximum wait (for example 30s or 2m)', '30s')
  .option('--after <cursor>', 'return events after this durable sequence', '0')
  .option('--json', 'emit versioned JSON')
  .action(async (session: string, options: { timeout: string; after: string; json?: boolean }) => {
    const timeout = parseDuration(options.timeout);
    const after = Number(options.after);
    if (!Number.isSafeInteger(after) || after < 0) {
      throw new AppError('Cursor must be a non-negative integer', 'INVALID_CURSOR', 2, 400);
    }
    const store = new SessionStore();
    const token = await store.token(session);
    const registry = await ensureServer(store, process.argv[1]);
    const started = Date.now();
    let result: PollResult;
    do {
      const remaining = Math.max(0, timeout - (Date.now() - started));
      result = await sessionFetch<PollResult>(
        registry,
        session,
        token,
        `/events?after=${after}&timeout=${Math.min(remaining, 60_000)}`,
      );
    } while (result.timedOut && Date.now() - started < timeout);
    output(
      result,
      Boolean(options.json),
      result.timedOut
        ? `No feedback after cursor ${after}`
        : `${result.events.length} event(s); next cursor ${result.nextCursor}`,
    );
  });

program
  .command('export')
  .description('Export the complete typed review record without secrets')
  .argument('<session>', 'session id')
  .option('--diagnostic', 'include the local repository path')
  .option('--json', 'emit versioned JSON')
  .action(async (session: string, options: { diagnostic?: boolean; json?: boolean }) => {
    const result = await new SessionStore().export(session, Boolean(options.diagnostic));
    output(result, Boolean(options.json), JSON.stringify(result, null, 2));
  });

program
  .command('end')
  .description('End only this review session')
  .argument('<session>', 'session id')
  .option('--json', 'emit versioned JSON')
  .action(async (session: string, options: { json?: boolean }) => {
    const store = new SessionStore();
    const token = await store.token(session);
    const registry = await ensureServer(store, process.argv[1]);
    const event = await sessionFetch<EndSubmission>(registry, session, token, '/end', {
      method: 'POST',
      body: '{}',
    });
    output(
      { schemaVersion: SCHEMA_VERSION, sessionId: session, status: 'ended', event },
      Boolean(options.json),
      `Ended ${session}`,
    );
  });

program
  .command('_serve', { hidden: true })
  .description('Run the loopback review server')
  .action(async () => {
    const server = await startServer({ exitWhenIdle: true });
    const shutdown = (): void => {
      void server.close().finally(() => process.exit(0));
    };
    process.once('SIGINT', shutdown);
    process.once('SIGTERM', shutdown);
    await new Promise(() => undefined);
  });

program.exitOverride();

try {
  await program.parseAsync(process.argv);
} catch (error) {
  if ((error as { code?: string; exitCode?: number }).exitCode === 0) process.exit(0);
  const appError =
    error instanceof AppError ? error : new AppError(errorMessage(error), 'CLI_ERROR', 1, 500);
  if (process.argv.includes('--json')) {
    process.stderr.write(
      `${JSON.stringify({ schemaVersion: SCHEMA_VERSION, error: { code: appError.code, message: appError.message } })}\n`,
    );
  } else {
    process.stderr.write(`read-the-code-axi: ${appError.message}\n`);
  }
  process.exit(appError.exitCode);
}
