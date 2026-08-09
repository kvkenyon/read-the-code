import { randomBytes } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { CommentDraft, PollResult } from '../protocol.js';
import { SCHEMA_VERSION } from '../protocol.js';
import { AppError, errorMessage } from './errors.js';
import { LIMITS } from './limits.js';
import { clearRegistry, SessionStore, writeRegistry, type ServerRegistry } from './store.js';

const SECURITY_HEADERS = {
  'Content-Security-Policy':
    "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
  'Cross-Origin-Resource-Policy': 'same-origin',
} as const;

function sendJson(response: ServerResponse, status: number, value: unknown): void {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    ...SECURITY_HEADERS,
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  response.end(body);
}

function bearer(request: IncomingMessage): string {
  const value = request.headers.authorization;
  return value?.startsWith('Bearer ') ? value.slice(7) : '';
}

async function bodyJson<T>(request: IncomingMessage): Promise<T> {
  const contentType = request.headers['content-type'] ?? '';
  if (!contentType.toLowerCase().startsWith('application/json')) {
    throw new AppError('Expected application/json', 'INVALID_CONTENT_TYPE', 2, 415);
  }
  const parts: Buffer[] = [];
  let size = 0;
  for await (const part of request) {
    const buffer = Buffer.isBuffer(part) ? part : Buffer.from(part);
    size += buffer.length;
    if (size > LIMITS.maxRequestBytes) {
      throw new AppError('Request body exceeds 128 KB', 'REQUEST_TOO_LARGE', 4, 413);
    }
    parts.push(buffer);
  }
  try {
    return JSON.parse(Buffer.concat(parts).toString('utf8')) as T;
  } catch {
    throw new AppError('Malformed JSON body', 'INVALID_JSON', 2, 400);
  }
}

function mime(path: string): string {
  return (
    {
      '.html': 'text/html; charset=utf-8',
      '.js': 'text/javascript; charset=utf-8',
      '.css': 'text/css; charset=utf-8',
      '.svg': 'image/svg+xml',
      '.png': 'image/png',
      '.woff2': 'font/woff2',
    }[extname(path)] ?? 'application/octet-stream'
  );
}

export interface ReviewServer {
  port: number;
  close: () => Promise<void>;
  registry: ServerRegistry;
}

export interface StartServerOptions {
  store?: SessionStore;
  host?: string;
  port?: number;
  staticDir?: string;
  exitWhenIdle?: boolean;
}

export async function startServer(options: StartServerOptions = {}): Promise<ReviewServer> {
  const host = options.host ?? '127.0.0.1';
  if (host !== '127.0.0.1') {
    throw new AppError('The review server may only bind to 127.0.0.1', 'NON_LOOPBACK_BIND', 9, 400);
  }
  const store = options.store ?? new SessionStore();
  await store.initialize();
  const staticDir =
    options.staticDir ?? join(fileURLToPath(new URL('.', import.meta.url)), 'public');
  const waiting = new Map<string, Set<() => void>>();
  let idleTimer: NodeJS.Timeout | undefined;

  const notify = (sessionId: string): void => {
    for (const resolve of waiting.get(sessionId) ?? []) resolve();
    waiting.delete(sessionId);
  };

  const waitForEvent = async (sessionId: string, timeout: number): Promise<void> =>
    new Promise((resolve) => {
      const listeners = waiting.get(sessionId) ?? new Set<() => void>();
      const done = (): void => {
        clearTimeout(timer);
        listeners.delete(done);
        resolve();
      };
      listeners.add(done);
      waiting.set(sessionId, listeners);
      const timer = setTimeout(done, timeout);
    });

  const server = createServer(async (request, response) => {
    try {
      const address = server.address();
      const activePort = typeof address === 'object' && address ? address.port : 0;
      const expectedHost = `127.0.0.1:${activePort}`;
      if (request.headers.host !== expectedHost) {
        throw new AppError('Invalid Host header', 'INVALID_HOST', 9, 400);
      }
      const origin = request.headers.origin;
      if (origin && origin !== `http://${expectedHost}`) {
        throw new AppError('Cross-origin request rejected', 'INVALID_ORIGIN', 9, 403);
      }
      const rawTarget = request.url ?? '/';
      if (/(?:^|\/|%2f|%5c)\.\.(?:\/|%2f|%5c|$)|%(?:2e|2f|5c)/iu.test(rawTarget)) {
        throw new AppError('Invalid request path', 'INVALID_PATH', 2, 400);
      }
      const url = new URL(rawTarget, `http://${expectedHost}`);

      if (url.pathname === '/api/v1/control/ping') {
        if (bearer(request) !== registry.controlToken) {
          throw new AppError('Unauthorized', 'UNAUTHORIZED', 9, 401);
        }
        sendJson(response, 200, { schemaVersion: SCHEMA_VERSION, ok: true, port: activePort });
        return;
      }

      const match =
        /^\/api\/v1\/sessions\/([a-f0-9]{24})(?:\/(feedback|approval|end|events))?$/u.exec(
          url.pathname,
        );
      if (match) {
        const [, sessionId, action] = match;
        if (!(await store.authenticate(sessionId, bearer(request)))) {
          throw new AppError('Unauthorized', 'UNAUTHORIZED', 9, 401);
        }
        if (request.method === 'GET' && !action) {
          sendJson(response, 200, await store.manifest(sessionId));
          return;
        }
        if (request.method === 'GET' && action === 'events') {
          const afterRaw = url.searchParams.get('after') ?? '0';
          const timeoutRaw = url.searchParams.get('timeout') ?? '30000';
          const after = Number(afterRaw);
          const timeout = Math.min(Math.max(Number(timeoutRaw), 0), 60_000);
          if (!Number.isSafeInteger(after) || after < 0 || !Number.isFinite(timeout)) {
            throw new AppError('Invalid poll cursor or timeout', 'INVALID_POLL', 2, 400);
          }
          let events = await store.eventsAfter(sessionId, after);
          if (events.length === 0 && timeout > 0) {
            await waitForEvent(sessionId, timeout);
            events = await store.eventsAfter(sessionId, after);
          }
          const result: PollResult = {
            schemaVersion: SCHEMA_VERSION,
            sessionId,
            after,
            nextCursor: events.at(-1)?.sequence ?? after,
            timedOut: events.length === 0,
            events,
          };
          sendJson(response, 200, result);
          return;
        }
        if (request.method === 'POST' && action === 'feedback') {
          const body = await bodyJson<{ comments?: CommentDraft[] }>(request);
          const event = await store.submitFeedback(sessionId, body.comments ?? []);
          notify(sessionId);
          sendJson(response, 201, event);
          return;
        }
        if (request.method === 'POST' && action === 'approval') {
          await bodyJson<Record<string, never>>(request);
          const manifest = await store.manifest(sessionId);
          if (manifest.stale) {
            throw new AppError(
              'The requested head ref moved; open a new revision before approving',
              'STALE_REVISION',
              8,
              409,
            );
          }
          const event = await store.approve(sessionId);
          notify(sessionId);
          sendJson(response, 201, event);
          return;
        }
        if (request.method === 'POST' && action === 'end') {
          await bodyJson<Record<string, never>>(request);
          const event = await store.end(sessionId);
          notify(sessionId);
          sendJson(response, 200, event);
          if (options.exitWhenIdle) {
            clearTimeout(idleTimer);
            idleTimer = setTimeout(async () => {
              if (!(await store.hasOpenSessions())) await close();
            }, 750);
          }
          return;
        }
        throw new AppError('Method not allowed', 'METHOD_NOT_ALLOWED', 2, 405);
      }

      if (request.method !== 'GET' && request.method !== 'HEAD') {
        throw new AppError('Method not allowed', 'METHOD_NOT_ALLOWED', 2, 405);
      }
      const requested = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
      const safe = normalize(requested).replace(/^(\.\.(\/|\\|$))+/u, '');
      if (safe !== requested || safe.includes('\0')) {
        throw new AppError('Invalid asset path', 'INVALID_PATH', 2, 400);
      }
      if (safe !== 'index.html' && !/^assets\/[A-Za-z0-9_.-]+$/u.test(safe)) {
        throw new AppError('Asset not found', 'NOT_FOUND', 2, 404);
      }
      const filePath = join(staticDir, safe);
      const info = await stat(filePath).catch(() => undefined);
      if (!info?.isFile()) {
        throw new AppError('Asset not found', 'NOT_FOUND', 2, 404);
      }
      response.writeHead(200, {
        ...SECURITY_HEADERS,
        'Content-Type': mime(filePath),
        'Content-Length': info.size,
        'Cache-Control': safe === 'index.html' ? 'no-store' : 'public, max-age=31536000, immutable',
      });
      if (request.method === 'HEAD') response.end();
      else createReadStream(filePath).pipe(response);
    } catch (error) {
      const appError =
        error instanceof AppError
          ? error
          : new AppError(errorMessage(error), 'INTERNAL_ERROR', 1, 500);
      if (!response.headersSent) {
        sendJson(response, appError.statusCode, {
          schemaVersion: SCHEMA_VERSION,
          error: {
            code: appError.code,
            message: appError.statusCode >= 500 ? 'Local server error' : appError.message,
          },
        });
      } else {
        response.destroy();
      }
    }
  });

  const controlToken = randomBytes(32).toString('base64url');
  const registry: ServerRegistry = {
    schemaVersion: SCHEMA_VERSION,
    pid: process.pid,
    port: 0,
    controlToken,
    startedAt: new Date().toISOString(),
  };

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(options.port ?? 0, host, () => {
      server.off('error', reject);
      resolve();
    });
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Server did not acquire a TCP port');
  registry.port = address.port;
  await writeRegistry(store, registry);

  let closing: Promise<void> | undefined;
  const close = (): Promise<void> => {
    if (closing) return closing;
    clearTimeout(idleTimer);
    for (const listeners of waiting.values()) for (const resolve of listeners) resolve();
    waiting.clear();
    closing = new Promise((resolve, reject) => {
      server.close((error) => {
        clearRegistry(store)
          .then(() => (error ? reject(error) : resolve()))
          .catch(reject);
      });
      server.closeIdleConnections();
    });
    return closing;
  };

  return { port: address.port, close, registry };
}
