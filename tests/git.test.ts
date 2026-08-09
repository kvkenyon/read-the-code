import { execFile } from 'node:child_process';
import { rm } from 'node:fs/promises';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { afterEach, describe, expect, it } from 'vitest';
import { buildReview, resolveCommit, resolveRepository } from '../src/core/git';
import { createFixtureRepo, createTestRoot } from './helpers';

const cleanup: string[] = [];
const exec = promisify(execFile);
afterEach(async () =>
  Promise.all(cleanup.splice(0).map((path) => rm(path, { recursive: true, force: true }))),
);

describe('Git review construction', () => {
  it('pins revisions and represents text, rename, deletion, binary, and hostile filenames safely', async () => {
    const root = await createTestRoot('git-');
    cleanup.push(root);
    const fixture = await createFixtureRepo(join(root, 'fixture'));
    const repository = await resolveRepository(fixture.path);
    const base = await resolveCommit(repository.path, fixture.baseSha);
    const head = await resolveCommit(repository.path, fixture.headSha);
    const review = await buildReview(repository.path, base, head);

    expect(review.files.map((file) => file.status)).toEqual(
      expect.arrayContaining(['modified', 'added', 'deleted', 'renamed', 'binary']),
    );
    expect(review.files.some((file) => file.path.includes('<script>'))).toBe(true);
    expect(review.files.find((file) => file.path === 'src/math.ts')?.hunks[0].lines).toEqual(
      expect.arrayContaining([expect.objectContaining({ kind: 'addition', newLine: 2 })]),
    );
    expect(
      review.files
        .flatMap((file) => file.hunks.flatMap((hunk) => hunk.lines))
        .every((line) => line.contextHash.length === 24),
    ).toBe(true);
    expect(review.summary.files).toBe(6);
  });

  it('rejects option-like and missing refs', async () => {
    const root = await createTestRoot('ref-');
    cleanup.push(root);
    const fixture = await createFixtureRepo(join(root, 'fixture'));
    await expect(resolveCommit(fixture.path, '--upload-pack=oops')).rejects.toMatchObject({
      code: 'INVALID_REF',
    });
    await expect(resolveCommit(fixture.path, 'does-not-exist')).rejects.toMatchObject({
      code: 'GIT_ERROR',
    });
  });

  it('contains oversized text blobs without buffering their patch', async () => {
    const root = await createTestRoot('large-');
    cleanup.push(root);
    const fixture = await createFixtureRepo(join(root, 'fixture'));
    await writeFile(join(fixture.path, 'large.txt'), 'x'.repeat(1_000_001));
    await exec('git', ['-C', fixture.path, 'add', 'large.txt']);
    await exec('git', ['-C', fixture.path, 'commit', '-qm', 'large fixture file']);
    const { stdout } = await exec('git', ['-C', fixture.path, 'rev-parse', 'HEAD'], {
      encoding: 'utf8',
    });
    const review = await buildReview(fixture.path, fixture.headSha, stdout.trim());
    expect(review.files).toEqual([
      expect.objectContaining({
        path: 'large.txt',
        status: 'added',
        truncated: true,
        binary: false,
        hunks: [],
      }),
    ]);
  });
});
