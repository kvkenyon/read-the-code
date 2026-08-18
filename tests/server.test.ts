import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { afterEach, describe, expect, it } from 'vitest';
import { buildReview } from '../src/core/git';
import { startServer, type ReviewServer } from '../src/core/server';
import { SessionStore } from '../src/core/store';
import { SCHEMA_VERSION } from '../src/protocol';
import { createFixtureRepo, createTestRoot } from './helpers';

const exec = promisify(execFile);

const cleanup: string[] = [];
const servers: ReviewServer[] = [];
afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => server.close()));
  await Promise.all(cleanup.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

async function setup(symbolicHead = false, wakeFile?: string) {
  const root = await createTestRoot('server-');
  cleanup.push(root);
  const fixture = await createFixtureRepo(join(root, 'repo'));
  if (symbolicHead)
    await exec('git', ['-C', fixture.path, 'branch', 'review-head', fixture.headSha]);
  const staticDir = join(root, 'public');
  await mkdir(staticDir);
  await writeFile(staticDir + '/index.html', '<!doctype html><title>Review</title>');
  const store = new SessionStore(join(root, 'state'));
  const review = await buildReview(fixture.path, fixture.baseSha, fixture.headSha);
  const id = store.sessionId(fixture.path, fixture.baseSha, fixture.headSha);
  const created = await store.createOrResume({
    schemaVersion: SCHEMA_VERSION,
    id,
    repositoryName: 'fixture',
    repositoryPath: fixture.path,
    baseRef: fixture.headSha,
    headRef: symbolicHead ? 'review-head' : fixture.headSha,
    baseSha: fixture.baseSha,
    headSha: fixture.headSha,
    wakeFile,
    ...review,
  });
  const server = await startServer({ store, staticDir });
  servers.push(server);
  return { root, fixture, staticDir, store, id, token: created.token, server, review };
}

describe('loopback review server', () => {
  it('requires capabilities and rejects bad origins and traversal', async () => {
    const { server, id, token } = await setup();
    const base = `http://127.0.0.1:${server.port}`;
    expect((await fetch(`${base}/api/v1/sessions/${id}`)).status).toBe(401);
    expect(
      (
        await fetch(`${base}/api/v1/sessions/${id}`, {
          headers: { Authorization: `Bearer ${token}`, Origin: 'https://attacker.invalid' },
        })
      ).status,
    ).toBe(403);
    expect((await fetch(`${base}/%2e%2e/secret`)).status).toBeGreaterThanOrEqual(400);
    expect((await fetch(`${base}/`)).headers.get('content-security-policy')).toContain(
      "default-src 'self'",
    );
  });

  it('wakes long polls and keeps events after a server restart', async () => {
    const { server, store, staticDir, id, token } = await setup();
    const base = `http://127.0.0.1:${server.port}`;
    const poll = fetch(`${base}/api/v1/sessions/${id}/events?after=0&timeout=5000`, {
      headers: { Authorization: `Bearer ${token}` },
    }).then((response) => response.json() as Promise<{ events: Array<{ sequence: number }> }>);
    await new Promise((resolve) => setTimeout(resolve, 75));
    const submit = await fetch(`${base}/api/v1/sessions/${id}/feedback`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ comments: [{ scope: 'general', body: 'Durable feedback.' }] }),
    });
    expect(submit.status).toBe(201);
    expect((await poll).events[0].sequence).toBe(1);

    await server.close();
    servers.splice(servers.indexOf(server), 1);
    const restarted = await startServer({ store, staticDir });
    servers.push(restarted);
    const replay = await fetch(
      `http://127.0.0.1:${restarted.port}/api/v1/sessions/${id}/events?after=0&timeout=0`,
      { headers: { Authorization: `Bearer ${token}` } },
    );
    const result = (await replay.json()) as { events: Array<{ sequence: number }> };
    expect(result.events.map((event) => event.sequence)).toEqual([1]);
  });

  it('delivers a secret-free wake event to an instantiator without another prompt', async () => {
    const root = await createTestRoot('wake-');
    cleanup.push(root);
    const wakeFile = join(root, 'instantiator', 'review-events.jsonl');
    await mkdir(join(root, 'instantiator'), { mode: 0o700 });
    await writeFile(wakeFile, '', { mode: 0o600 });
    const { server, id, token } = await setup(false, wakeFile);
    const response = await fetch(`http://127.0.0.1:${server.port}/api/v1/sessions/${id}/approval`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: '{}',
    });
    expect(response.status).toBe(201);
    const [wake] = (await readFile(wakeFile, 'utf8'))
      .trim()
      .split('\n')
      .map((line) => JSON.parse(line));
    expect(wake).toMatchObject({
      schemaVersion: 1,
      sessionId: id,
      sequence: 1,
      type: 'approval',
      event: { type: 'approval', sequence: 1 },
    });
    expect(JSON.stringify(wake)).not.toContain('Bearer');
    expect(JSON.stringify(wake)).not.toContain('/#/review/');
    expect(JSON.stringify(wake)).not.toContain(token);

    for (let index = 0; index < 2; index += 1) {
      const ended = await fetch(`http://127.0.0.1:${server.port}/api/v1/sessions/${id}/end`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: '{}',
      });
      expect(ended.status).toBe(200);
    }
    const wakes = (await readFile(wakeFile, 'utf8'))
      .trim()
      .split('\n')
      .map((line) => JSON.parse(line));
    expect(wakes.map((event) => [event.sequence, event.type])).toEqual([
      [1, 'approval'],
      [2, 'end'],
    ]);
  });

  it('expands context from the exact committed trees, not the working tree', async () => {
    const { server, fixture, id, token, review } = await setup();
    const file = review.files.find((candidate) => candidate.path === 'src/math.ts')!;
    await writeFile(join(fixture.path, 'src', 'math.ts'), 'WORKING TREE ONLY\n');
    const response = await fetch(
      `http://127.0.0.1:${server.port}/api/v1/sessions/${id}/context?path=${encodeURIComponent(file.path)}&hunk=0&position=after&lines=20`,
      { headers: { Authorization: `Bearer ${token}` } },
    );
    expect(response.status).toBe(200);
    const context = (await response.json()) as { total: number; lines: Array<{ text: string }> };
    expect(context.total).toBeGreaterThan(0);
    expect(context.lines.some((line) => line.text.includes('export const eight'))).toBe(true);
    expect(context.lines.some((line) => line.text.includes('WORKING TREE ONLY'))).toBe(false);
  });

  it('refuses a non-loopback bind', async () => {
    await expect(startServer({ host: '0.0.0.0' })).rejects.toMatchObject({
      code: 'NON_LOOPBACK_BIND',
    });
  });

  it('rejects oversized transport bodies before parsing them', async () => {
    const { server, id, token } = await setup();
    const response = await fetch(`http://127.0.0.1:${server.port}/api/v1/sessions/${id}/feedback`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ comments: [{ scope: 'general', body: 'x'.repeat(130_000) }] }),
    });
    expect(response.status).toBe(413);
    expect(await response.json()).toMatchObject({ error: { code: 'REQUEST_TOO_LARGE' } });
  });

  it('rejects feedback at the HTTP boundary after the requested head moves', async () => {
    const { server, fixture, store, id, token } = await setup(true);
    await exec('git', ['-C', fixture.path, 'branch', '-f', 'review-head', fixture.baseSha]);
    const response = await fetch(`http://127.0.0.1:${server.port}/api/v1/sessions/${id}/feedback`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ comments: [{ scope: 'general', body: 'Stale feedback.' }] }),
    });
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: { code: 'STALE_REVISION' } });
    expect((await store.read(id)).events).toHaveLength(0);
  });
});
