#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { constants } from 'node:fs';
import { chmod, open, realpath } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { encode } from '@toon-format/toon';
import { Command } from 'commander';
import packageJson from '../package.json' with { type: 'json' };
import { ensureServer, sessionFetch } from './core/client.js';
import { AppError, errorMessage } from './core/errors.js';
import { buildReview, resolveCommit, resolveRepository } from './core/git.js';
import { startServer } from './core/server.js';
import { SessionStore } from './core/store.js';
import type { EndSubmission, OpenResult, PollResult } from './protocol.js';
import { SCHEMA_VERSION } from './protocol.js';

const program = new Command();
const DEFAULT_LIMIT = 20;

function output(value: unknown, json: boolean): void {
  process.stdout.write(json ? `${JSON.stringify(value)}\n` : `${encode(value)}\n`);
}

function shortSha(sha: string): string {
  return sha.slice(0, 10);
}

function compactPath(path: string): string {
  const home = homedir();
  return path === home || path.startsWith(`${home}/`) ? `~${path.slice(home.length)}` : path;
}

function truncate(value: string, limit = 160): string {
  const characters = [...value];
  if (characters.length <= limit) return value;
  return `${characters.slice(0, limit).join('')}… (truncated, ${characters.length} chars total — use --full)`;
}

function eventSummary(event: PollResult['events'][number]): string {
  if (event.type === 'feedback') {
    return `${event.comments.length} comment${event.comments.length === 1 ? '' : 's'}`;
  }
  if (event.type === 'approval') return `approved ${shortSha(event.approvedHeadSha)}`;
  return 'review ended';
}

function activitySummary(events: PollResult['events']): string {
  const feedback = events.filter((event) => event.type === 'feedback');
  const comments = feedback.reduce(
    (count, event) => count + (event.type === 'feedback' ? event.comments.length : 0),
    0,
  );
  const approval = events.some((event) => event.type === 'approval');
  const ended = events.some((event) => event.type === 'end');
  const parts = [
    `${feedback.length} feedback ${feedback.length === 1 ? 'batch' : 'batches'}`,
    `${comments} comment${comments === 1 ? '' : 's'}`,
    approval ? 'approval recorded' : 'no approval',
    ended ? 'ended' : 'active',
  ];
  return parts.join('; ');
}

function eventRows(events: PollResult['events']) {
  return events.map((event) => ({
    sequence: event.sequence,
    type: event.type,
    summary: eventSummary(event),
  }));
}

function commentRows(events: PollResult['events'], limit = DEFAULT_LIMIT) {
  const comments = events.flatMap((event) =>
    event.type === 'feedback'
      ? event.comments.map((comment) => ({
          event: event.sequence,
          scope: comment.scope,
          path: comment.path ? truncate(comment.path, 120) : null,
          body: truncate(comment.body),
        }))
      : [],
  );
  return { comments: comments.slice(0, limit), total: comments.length };
}

function statusView(
  sessionId: string,
  manifest: Awaited<ReturnType<SessionStore['manifest']>>,
  events: PollResult['events'],
) {
  return {
    session: sessionId,
    state: manifest.status === 'ended' ? 'ended' : manifest.stale ? 'stale' : 'open',
    revision: `${shortSha(manifest.baseSha)} → ${shortSha(manifest.headSha)}`,
    changes: `${manifest.summary.files} files; +${manifest.summary.additions}/-${manifest.summary.deletions}`,
    activity: activitySummary(events),
    ...(manifest.approvalStale ? { approval: 'stale; open a new exact revision' } : {}),
  };
}

function help(commands: string[]): { help: string[] } {
  return { help: commands };
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

function inside(root: string, target: string): boolean {
  const path = relative(root, target);
  return path === '' || (!path.startsWith('..') && !isAbsolute(path));
}

async function armWakeFile(path: string, repository: string): Promise<string> {
  const absolute = resolve(path);
  if (inside(repository, absolute)) {
    throw new AppError(
      'Wake file must stay outside the reviewed repository',
      'INVALID_WAKE_FILE',
      2,
      400,
    );
  }
  let canonicalParent: string;
  try {
    canonicalParent = await realpath(dirname(absolute));
  } catch {
    throw new AppError(
      'Wake file parent directory must already exist',
      'INVALID_WAKE_FILE',
      2,
      400,
    );
  }
  const canonical = join(canonicalParent, basename(absolute));
  if (inside(repository, canonical)) {
    throw new AppError(
      'Wake file must stay outside the reviewed repository',
      'INVALID_WAKE_FILE',
      2,
      400,
    );
  }
  const handle = await open(
    canonical,
    constants.O_WRONLY | constants.O_APPEND | constants.O_CREAT | (constants.O_NOFOLLOW ?? 0),
    0o600,
  );
  await handle.close();
  await chmod(canonical, 0o600);
  return canonical;
}

program
  .name('read-the-code-axi')
  .description('Open an exact local Git change set for browser review')
  .option('--json', 'emit versioned JSON for the home view')
  .version(packageJson.version);

program.configureOutput({ writeErr: () => undefined });

program.action(async (options: { json?: boolean }) => {
  const recent = await new SessionStore().recent(5);
  const value = {
    bin: compactPath(process.argv[1]),
    description: 'Review exact local Git revisions in a loopback-only browser workspace',
    aggregates: {
      sessions: recent.total,
      open: recent.open,
      ended: recent.ended,
    },
    sessions: recent.sessions.map((session) => ({
      session: session.id,
      state: session.status === 'ended' ? 'ended' : session.stale ? 'stale' : 'open',
      revision: `${shortSha(session.baseSha)} → ${shortSha(session.headSha)}`,
      changes: `${session.summary.files} files; +${session.summary.additions}/-${session.summary.deletions}`,
    })),
    ...help([
      'Run `read-the-code-axi open --repo <path> --base <ref> --head <ref>` to review a change',
      'Run `read-the-code-axi --help` to see commands and flags',
    ]),
  };
  output(options.json ? { schemaVersion: SCHEMA_VERSION, ...value } : value, Boolean(options.json));
});

program
  .command('open')
  .description('Create or resume an exact base-to-head review')
  .requiredOption('--repo <path>', 'local Git repository')
  .requiredOption('--base <ref>', 'base commit-ish')
  .requiredOption('--head <ref>', 'head commit-ish')
  .option('--no-browser', 'do not launch the default browser')
  .option('--wake-file <path>', 'append secret-free JSONL when a review event is submitted')
  .option('--json', 'emit versioned JSON')
  .action(
    async (options: {
      repo: string;
      base: string;
      head: string;
      browser: boolean;
      wakeFile?: string;
      json?: boolean;
    }) => {
      const json = process.argv.includes('--json');
      const repository = await resolveRepository(resolve(options.repo));
      const [baseSha, headSha] = await Promise.all([
        resolveCommit(repository.path, options.base),
        resolveCommit(repository.path, options.head),
      ]);
      const store = new SessionStore();
      const id = store.sessionId(repository.path, baseSha, headSha);
      const wakeFile = options.wakeFile
        ? await armWakeFile(options.wakeFile, repository.path)
        : undefined;
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
        wakeFile,
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
        wakeFileArmed: Boolean(wakeFile),
        status: 'open',
      };
      if (json) {
        output(result, true);
        return;
      }
      output(
        {
          session: id,
          state: resumed ? 'resumed' : 'open',
          revision: `${shortSha(baseSha)} → ${shortSha(headSha)}`,
          changes: `${review.summary.files} files; +${review.summary.additions}/-${review.summary.deletions}`,
          browser: options.browser ? 'launched locally' : 'not launched (--no-browser)',
          wakeDelivery: wakeFile ? 'armed with secret-free JSONL events' : 'not armed',
          ...help([
            `Run \`read-the-code-axi status ${id}\` to inspect this review`,
            wakeFile
              ? `Watch the armed wake file, then run \`read-the-code-axi poll ${id} --after 0 --json\` for durable events`
              : `Run \`read-the-code-axi poll ${id} --after 0 --timeout 2m\` to wait for feedback`,
          ]),
        },
        false,
      );
    },
  );

program
  .command('status')
  .description('Show local review session status')
  .argument('<session>', 'session id')
  .option('--json', 'emit versioned JSON')
  .action(async (session: string) => {
    const json = process.argv.includes('--json');
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
    if (json) {
      output(result, true);
      return;
    }
    output(
      {
        ...statusView(session, manifest, record.events),
        events: result.eventCount,
        cursor: result.lastSequence,
        ...help(
          manifest.status === 'ended'
            ? [
                `Run \`read-the-code-axi export ${session}\` to summarize the durable record`,
                'Run `read-the-code-axi open --repo <path> --base <ref> --head <ref>` to start another exact review',
              ]
            : [
                `Run \`read-the-code-axi poll ${session} --after ${lastSequence} --timeout 2m\` to wait for feedback`,
                `Run \`read-the-code-axi end ${session}\` when this review is complete`,
              ],
        ),
      },
      false,
    );
  });

program
  .command('poll')
  .description('Wait for durable review feedback after a submission cursor')
  .argument('<session>', 'session id')
  .option('--timeout <duration>', 'maximum wait (for example 30s or 2m)', '30s')
  .option('--after <cursor>', 'return events after this durable sequence', '0')
  .option('--full', 'include complete event and comment records')
  .option('--json', 'emit versioned JSON')
  .action(
    async (
      session: string,
      options: { timeout: string; after: string; full?: boolean; json?: boolean },
    ) => {
      const json = process.argv.includes('--json');
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
      if (json) {
        output(result, true);
        return;
      }
      if (options.full) {
        output(
          {
            ...result,
            ...help([`Run \`read-the-code-axi status ${session}\` to inspect review state`]),
          },
          false,
        );
        return;
      }
      const manifest = await store.manifest(session);
      const comments = commentRows(result.events);
      const state = result.timedOut
        ? 'waiting'
        : result.events.some((event) => event.type === 'end')
          ? 'ended'
          : manifest.approvalStale && result.events.some((event) => event.type === 'approval')
            ? 'approval-stale'
            : result.events.some((event) => event.type === 'approval')
              ? 'approval'
              : 'feedback';
      output(
        {
          session,
          state,
          after,
          nextCursor: result.nextCursor,
          events: eventRows(result.events),
          comments: comments.comments,
          ...(comments.total > comments.comments.length
            ? {
                truncation: `${comments.comments.length} of ${comments.total} comments shown; use --full`,
              }
            : {}),
          ...help(
            state === 'ended'
              ? [`Run \`read-the-code-axi export ${session}\` to summarize the durable record`]
              : [
                  `Run \`read-the-code-axi poll ${session} --after ${result.nextCursor} --timeout 2m\` to continue waiting`,
                  `Run \`read-the-code-axi status ${session}\` to inspect review state`,
                ],
          ),
        },
        false,
      );
    },
  );

program
  .command('export')
  .description('Export the complete typed review record without secrets')
  .argument('<session>', 'session id')
  .option('--diagnostic', 'include the local repository path')
  .option('--full', 'include the complete typed review record')
  .option('--json', 'emit versioned JSON')
  .action(
    async (session: string, options: { diagnostic?: boolean; full?: boolean; json?: boolean }) => {
      const json = process.argv.includes('--json');
      const result = await new SessionStore().export(session, Boolean(options.diagnostic));
      if (json) {
        output(result, true);
        return;
      }
      if (options.full) {
        output(
          {
            ...result,
            ...help([`Run \`read-the-code-axi status ${session}\` to inspect current state`]),
          },
          false,
        );
        return;
      }
      const files = result.session.files.slice(0, DEFAULT_LIMIT).map((file) => ({
        path: truncate(file.path, 120),
        state: file.status,
        additions: file.additions,
        deletions: file.deletions,
      }));
      const comments = commentRows(result.events);
      output(
        {
          ...statusView(session, result.session, result.events),
          events: eventRows(result.events),
          comments: comments.comments,
          files,
          ...(result.session.files.length > files.length
            ? {
                truncation: `${files.length} of ${result.session.files.length} files shown; use --full`,
              }
            : {}),
          ...(comments.total > comments.comments.length
            ? {
                commentTruncation: `${comments.comments.length} of ${comments.total} comments shown; use --full`,
              }
            : {}),
          ...help([
            `Run \`read-the-code-axi export ${session} --full\` for the complete typed record`,
          ]),
        },
        false,
      );
    },
  );

program
  .command('end')
  .description('End only this review session')
  .argument('<session>', 'session id')
  .option('--json', 'emit versioned JSON')
  .action(async (session: string) => {
    const json = process.argv.includes('--json');
    const store = new SessionStore();
    const token = await store.token(session);
    const registry = await ensureServer(store, process.argv[1]);
    const event = await sessionFetch<EndSubmission>(registry, session, token, '/end', {
      method: 'POST',
      body: '{}',
    });
    const result = { schemaVersion: SCHEMA_VERSION, sessionId: session, status: 'ended', event };
    if (json) {
      output(result, true);
      return;
    }
    output(
      {
        session,
        state: 'ended',
        sequence: event.sequence,
        revision: `${shortSha(event.baseSha)} → ${shortSha(event.headSha)}`,
        ...help([`Run \`read-the-code-axi export ${session}\` to summarize the durable record`]),
      },
      false,
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

for (const command of program.commands) {
  command.configureOutput({ writeErr: () => undefined });
  command.exitOverride();
}
program.exitOverride();

try {
  await program.parseAsync(process.argv);
} catch (error) {
  if ((error as { code?: string; exitCode?: number }).exitCode === 0) process.exit(0);
  const commanderError = error as { code?: string; exitCode?: number };
  const invalidUsage = commanderError.code?.startsWith('commander.') ?? false;
  const appError =
    error instanceof AppError
      ? error
      : new AppError(
          errorMessage(error),
          invalidUsage ? 'UNKNOWN_ARGUMENT' : 'CLI_ERROR',
          invalidUsage ? 2 : 1,
          500,
        );
  if (process.argv.includes('--json')) {
    process.stderr.write(
      `${JSON.stringify({ schemaVersion: SCHEMA_VERSION, error: { code: appError.code, message: appError.message } })}\n`,
    );
  } else {
    output(
      {
        error: { code: appError.code, message: appError.message },
        ...help(['Run `read-the-code-axi --help` to see valid commands and flags']),
      },
      false,
    );
  }
  process.exit(appError.exitCode);
}
