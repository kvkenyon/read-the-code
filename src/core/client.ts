import { spawn } from 'node:child_process';
import { open, stat, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { AppError } from './errors.js';
import { readRegistry, SessionStore, type ServerRegistry } from './store.js';

async function ping(registry: ServerRegistry): Promise<boolean> {
  try {
    const response = await fetch(`http://127.0.0.1:${registry.port}/api/v1/control/ping`, {
      headers: { Authorization: `Bearer ${registry.controlToken}` },
      signal: AbortSignal.timeout(1_000),
    });
    return response.ok;
  } catch {
    return false;
  }
}

export async function ensureServer(store: SessionStore, cliPath: string): Promise<ServerRegistry> {
  const current = await readRegistry(store);
  if (current && (await ping(current))) return current;
  await store.initialize();
  const lockPath = join(store.root, 'server-start.lock');
  const deadline = Date.now() + 8_000;
  while (Date.now() < deadline) {
    let handle;
    try {
      handle = await open(lockPath, 'wx', 0o600);
      const raced = await readRegistry(store);
      if (raced && (await ping(raced))) return raced;
      const child = spawn(process.execPath, [cliPath, '_serve'], {
        detached: true,
        stdio: 'ignore',
        env: { ...process.env, READ_THE_CODE_STATE_DIR: store.root },
        windowsHide: true,
      });
      child.unref();
      while (Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 75));
        const registry = await readRegistry(store);
        if (registry && (await ping(registry))) return registry;
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
      const info = await stat(lockPath).catch(() => undefined);
      if (info && Date.now() - info.mtimeMs > 15_000) await unlink(lockPath).catch(() => undefined);
      await new Promise((resolve) => setTimeout(resolve, 75));
      const registry = await readRegistry(store);
      if (registry && (await ping(registry))) return registry;
    } finally {
      if (handle) {
        await handle.close();
        await unlink(lockPath).catch(() => undefined);
      }
    }
  }
  throw new AppError('Local review server did not start', 'SERVER_START_FAILED', 10, 500);
}

export async function sessionFetch<T>(
  registry: ServerRegistry,
  sessionId: string,
  token: string,
  suffix = '',
  init?: RequestInit,
): Promise<T> {
  const response = await fetch(
    `http://127.0.0.1:${registry.port}/api/v1/sessions/${sessionId}${suffix}`,
    {
      ...init,
      headers: {
        Authorization: `Bearer ${token}`,
        ...(init?.body ? { 'Content-Type': 'application/json' } : {}),
        ...init?.headers,
      },
    },
  );
  const data = (await response.json()) as T & { error?: { code: string; message: string } };
  if (!response.ok) {
    throw new AppError(
      data.error?.message ?? `Server returned ${response.status}`,
      data.error?.code ?? 'SERVER_ERROR',
      1,
      response.status,
    );
  }
  return data;
}
