import { execFile } from 'node:child_process';
import { rm } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { afterEach, describe, expect, it } from 'vitest';
import { buildReview } from '../src/core/git';
import { SessionStore } from '../src/core/store';
import { SCHEMA_VERSION } from '../src/protocol';
import { createFixtureRepo, createTestRoot } from './helpers';

const cleanup: string[] = [];
const exec = promisify(execFile);
afterEach(async () =>
  Promise.all(cleanup.splice(0).map((path) => rm(path, { recursive: true, force: true }))),
);

describe('durable sessions', () => {
  it('resumes exact revisions and preserves ordered batched events without secrets', async () => {
    const root = await createTestRoot('store-');
    cleanup.push(root);
    const fixture = await createFixtureRepo(join(root, 'repo'));
    const store = new SessionStore(join(root, 'state'));
    const review = await buildReview(fixture.path, fixture.baseSha, fixture.headSha);
    const id = store.sessionId(fixture.path, fixture.baseSha, fixture.headSha);
    const input = {
      schemaVersion: SCHEMA_VERSION,
      id,
      repositoryName: 'fixture',
      repositoryPath: fixture.path,
      baseRef: fixture.baseSha,
      headRef: fixture.headSha,
      baseSha: fixture.baseSha,
      headSha: fixture.headSha,
      ...review,
    };
    const first = await store.createOrResume(input);
    const second = await store.createOrResume(input);
    expect(first.resumed).toBe(false);
    expect(second.resumed).toBe(true);
    expect(second.token).toBe(first.token);

    const file = review.files.find((item) => item.path === 'src/math.ts')!;
    const line = file.hunks.flatMap((hunk) => hunk.lines).find((item) => item.newLine === 2)!;
    const feedback = await store.submitFeedback(id, [
      {
        scope: 'line',
        path: file.path,
        body: 'Please name this intermediate value more specifically.',
        anchor: {
          revision: { baseSha: fixture.baseSha, headSha: fixture.headSha },
          path: file.path,
          side: 'new',
          startLine: 2,
          endLine: 2,
          contextHash: line.contextHash,
          endContextHash: line.contextHash,
        },
      },
      { scope: 'general', body: 'The overall direction is clear.' },
    ]);
    const approval = await store.approve(id);
    expect(feedback.sequence).toBe(1);
    expect(approval.sequence).toBe(2);
    expect((await store.eventsAfter(id, 1)).map((event) => event.sequence)).toEqual([2]);
    const exported = await store.export(id);
    expect(JSON.stringify(exported)).not.toContain(first.token);
    expect(JSON.stringify(exported)).not.toContain(fixture.path);
  });

  it('rejects an anchor whose context hash changed', async () => {
    const root = await createTestRoot('anchor-');
    cleanup.push(root);
    const fixture = await createFixtureRepo(join(root, 'repo'));
    const store = new SessionStore(join(root, 'state'));
    const review = await buildReview(fixture.path, fixture.baseSha, fixture.headSha);
    const id = store.sessionId(fixture.path, fixture.baseSha, fixture.headSha);
    await store.createOrResume({
      schemaVersion: SCHEMA_VERSION,
      id,
      repositoryName: 'fixture',
      repositoryPath: fixture.path,
      baseRef: fixture.baseSha,
      headRef: fixture.headSha,
      baseSha: fixture.baseSha,
      headSha: fixture.headSha,
      ...review,
    });
    await expect(
      store.submitFeedback(id, [
        {
          scope: 'line',
          path: 'src/math.ts',
          body: 'This anchor is stale.',
          anchor: {
            revision: { baseSha: fixture.baseSha, headSha: fixture.headSha },
            path: 'src/math.ts',
            side: 'new',
            startLine: 2,
            endLine: 2,
            contextHash: 'not-the-real-context',
            endContextHash: 'not-the-real-context',
          },
        },
      ]),
    ).rejects.toMatchObject({ code: 'STALE_ANCHOR' });
  });

  it('marks approval stale when a symbolic head moves and gives the new revision a new id', async () => {
    const root = await createTestRoot('stale-');
    cleanup.push(root);
    const fixture = await createFixtureRepo(join(root, 'repo'));
    await exec('git', ['-C', fixture.path, 'branch', 'review-head', fixture.headSha]);
    const store = new SessionStore(join(root, 'state'));
    const review = await buildReview(fixture.path, fixture.baseSha, fixture.headSha);
    const id = store.sessionId(fixture.path, fixture.baseSha, fixture.headSha);
    await store.createOrResume({
      schemaVersion: SCHEMA_VERSION,
      id,
      repositoryName: 'fixture',
      repositoryPath: fixture.path,
      baseRef: fixture.baseSha,
      headRef: 'review-head',
      baseSha: fixture.baseSha,
      headSha: fixture.headSha,
      ...review,
    });
    await store.approve(id);
    expect(await store.manifest(id)).toMatchObject({ stale: false, approvalStale: false });

    await exec('git', ['-C', fixture.path, 'branch', '-f', 'review-head', fixture.baseSha]);
    expect(await store.manifest(id)).toMatchObject({ stale: true, approvalStale: true });
    expect(store.sessionId(fixture.path, fixture.baseSha, fixture.baseSha)).not.toBe(id);
    expect((await store.read(id)).events).toEqual([
      expect.objectContaining({ type: 'approval', approvedHeadSha: fixture.headSha }),
    ]);
  });

  it('serializes concurrent opens, feedback, and idempotent end calls', async () => {
    const root = await createTestRoot('races-');
    cleanup.push(root);
    const fixture = await createFixtureRepo(join(root, 'repo'));
    const store = new SessionStore(join(root, 'state'));
    const review = await buildReview(fixture.path, fixture.baseSha, fixture.headSha);
    const id = store.sessionId(fixture.path, fixture.baseSha, fixture.headSha);
    const input = {
      schemaVersion: SCHEMA_VERSION,
      id,
      repositoryName: 'fixture',
      repositoryPath: fixture.path,
      baseRef: fixture.baseSha,
      headRef: fixture.headSha,
      baseSha: fixture.baseSha,
      headSha: fixture.headSha,
      ...review,
    };
    const opened = await Promise.all(Array.from({ length: 4 }, () => store.createOrResume(input)));
    expect(new Set(opened.map((result) => result.token)).size).toBe(1);

    const submitted = await Promise.all(
      Array.from({ length: 8 }, (_, index) =>
        store.submitFeedback(id, [{ scope: 'general', body: `Concurrent feedback ${index}` }]),
      ),
    );
    expect(submitted.map((event) => event.sequence).sort((a, b) => a - b)).toEqual([
      1, 2, 3, 4, 5, 6, 7, 8,
    ]);
    const ended = await Promise.all([store.end(id), store.end(id), store.end(id)]);
    expect(new Set(ended.map((event) => event.id)).size).toBe(1);
    expect((await store.read(id)).events.filter((event) => event.type === 'end')).toHaveLength(1);
  });

  it('enforces comment and batch size limits', async () => {
    const root = await createTestRoot('limits-');
    cleanup.push(root);
    const fixture = await createFixtureRepo(join(root, 'repo'));
    const store = new SessionStore(join(root, 'state'));
    const review = await buildReview(fixture.path, fixture.baseSha, fixture.headSha);
    const id = store.sessionId(fixture.path, fixture.baseSha, fixture.headSha);
    await store.createOrResume({
      schemaVersion: SCHEMA_VERSION,
      id,
      repositoryName: 'fixture',
      repositoryPath: fixture.path,
      baseRef: fixture.baseSha,
      headRef: fixture.headSha,
      baseSha: fixture.baseSha,
      headSha: fixture.headSha,
      ...review,
    });
    await expect(
      store.submitFeedback(id, [{ scope: 'general', body: 'x'.repeat(20_001) }]),
    ).rejects.toMatchObject({ code: 'COMMENT_TOO_LARGE' });
    await expect(
      store.submitFeedback(
        id,
        Array.from({ length: 101 }, () => ({ scope: 'general' as const, body: 'too many' })),
      ),
    ).rejects.toMatchObject({ code: 'INVALID_SUBMISSION' });
  });
});
