import { mkdir, rm, writeFile } from 'node:fs/promises';
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

async function setup(symbolicHead = false) {
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
