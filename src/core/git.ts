import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { basename } from 'node:path';
import { promisify } from 'node:util';
import { realpath } from 'node:fs/promises';
import parseDiff from 'parse-diff';
import type { ChangeStatus, DiffHunk, DiffLine, ReviewFile, ReviewSummary } from '../protocol.js';
import { AppError } from './errors.js';
import { LIMITS } from './limits.js';

const execFileAsync = promisify(execFile);

interface GitResult {
  stdout: string;
  stderr: string;
}

async function git(repo: string, args: string[], maxBuffer = 10_000_000): Promise<GitResult> {
  try {
    return await execFileAsync('git', ['-C', repo, ...args], {
      encoding: 'utf8',
      maxBuffer,
      timeout: 30_000,
      windowsHide: true,
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message.replaceAll(repo, '<repository>') : 'Git failed';
    throw new AppError(message, 'GIT_ERROR', 3, 400);
  }
}

function validatePlainInput(value: string, label: string, maxBytes: number): void {
  const hasControl = [...value].some((character) => {
    const code = character.codePointAt(0) ?? 0;
    return code < 32 || code === 127;
  });
  if (!value || Buffer.byteLength(value) > maxBytes || hasControl) {
    throw new AppError(`Invalid ${label}`, `INVALID_${label.toUpperCase()}`, 2, 400);
  }
}

export async function resolveRepository(input: string): Promise<{ path: string; name: string }> {
  validatePlainInput(input, 'repository', LIMITS.maxPathBytes);
  let canonical: string;
  try {
    canonical = await realpath(input);
  } catch {
    throw new AppError('Repository path does not exist', 'INVALID_REPOSITORY', 2, 400);
  }
  const { stdout } = await git(canonical, ['rev-parse', '--show-toplevel']);
  const root = await realpath(stdout.trim());
  if (root !== canonical) {
    canonical = root;
  }
  return { path: canonical, name: basename(canonical) || 'repository' };
}

export async function resolveCommit(repo: string, ref: string): Promise<string> {
  validatePlainInput(ref, 'ref', LIMITS.maxRefBytes);
  if (ref.startsWith('-'))
    throw new AppError('Refs may not begin with a dash', 'INVALID_REF', 2, 400);
  const { stdout } = await git(repo, [
    'rev-parse',
    '--verify',
    '--end-of-options',
    `${ref}^{commit}`,
  ]);
  const sha = stdout.trim();
  if (!/^[0-9a-f]{40,64}$/u.test(sha)) {
    throw new AppError('Ref did not resolve to a commit', 'INVALID_REF', 2, 400);
  }
  return sha;
}

function parseNameStatus(raw: string): Array<{
  status: ChangeStatus;
  path: string;
  oldPath?: string;
}> {
  const fields = raw.split('\0');
  const results: Array<{ status: ChangeStatus; path: string; oldPath?: string }> = [];
  let index = 0;
  while (index < fields.length && fields[index]) {
    const code = fields[index++];
    if ((code.startsWith('R') || code.startsWith('C')) && index + 1 < fields.length) {
      const oldPath = fields[index++];
      const path = fields[index++];
      results.push({ status: 'renamed', path, oldPath });
      continue;
    }
    const path = fields[index++];
    const status: ChangeStatus = code.startsWith('A')
      ? 'added'
      : code.startsWith('D')
        ? 'deleted'
        : 'modified';
    results.push({ status, path });
  }
  return results;
}

function hashContext(path: string, line: DiffLine, nearby: string[]): string {
  return createHash('sha256')
    .update(JSON.stringify([path, line.kind, line.oldLine, line.newLine, line.text, nearby]))
    .digest('hex')
    .slice(0, 24);
}

function normalizePatch(path: string, patch: string): { hunks: DiffHunk[]; binary: boolean } {
  const [parsed] = parseDiff(patch);
  if (!parsed) return { hunks: [], binary: /Binary files|GIT binary patch/u.test(patch) };
  const hunks: DiffHunk[] = parsed.chunks.map((chunk) => {
    const pending: DiffLine[] = chunk.changes.map((change) => {
      const kind =
        change.type === 'add' ? 'addition' : change.type === 'del' ? 'deletion' : 'context';
      return {
        kind,
        oldLine: change.type === 'add' ? null : change.type === 'del' ? change.ln : change.ln1,
        newLine: change.type === 'del' ? null : change.type === 'add' ? change.ln : change.ln2,
        text: change.content.slice(1),
        contextHash: '',
      };
    });
    for (let index = 0; index < pending.length; index += 1) {
      const nearby = pending.slice(Math.max(0, index - 2), index + 3).map((line) => line.text);
      pending[index].contextHash = hashContext(path, pending[index], nearby);
    }
    return {
      header: chunk.content,
      oldStart: chunk.oldStart,
      oldLines: chunk.oldLines,
      newStart: chunk.newStart,
      newLines: chunk.newLines,
      lines: pending,
    };
  });
  return { hunks, binary: /Binary files|GIT binary patch/u.test(patch) };
}

async function blobSize(repo: string, sha: string, path: string | undefined): Promise<number> {
  if (!path) return 0;
  try {
    const { stdout } = await git(repo, ['cat-file', '-s', `${sha}:${path}`], 1_024);
    const size = Number(stdout.trim());
    return Number.isSafeInteger(size) && size >= 0 ? size : 0;
  } catch {
    return 0;
  }
}

async function fileStats(
  repo: string,
  baseSha: string,
  headSha: string,
  paths: string[],
): Promise<{ additions: number; deletions: number; binary: boolean }> {
  const { stdout } = await git(repo, [
    'diff',
    '--numstat',
    '-z',
    '--find-renames',
    '--no-ext-diff',
    '--no-textconv',
    baseSha,
    headSha,
    '--',
    ...paths,
  ]);
  const [addRaw = '0', deleteRaw = '0'] = stdout.split('\t');
  const binary = addRaw === '-' || deleteRaw === '-';
  return {
    additions: binary ? 0 : Number(addRaw) || 0,
    deletions: binary ? 0 : Number(deleteRaw) || 0,
    binary,
  };
}

export async function buildReview(
  repo: string,
  baseSha: string,
  headSha: string,
): Promise<{ files: ReviewFile[]; summary: ReviewSummary }> {
  const { stdout: statusRaw } = await git(repo, [
    'diff',
    '--name-status',
    '-z',
    '--find-renames',
    '--no-ext-diff',
    '--no-textconv',
    baseSha,
    headSha,
    '--',
  ]);
  const changes = parseNameStatus(statusRaw);
  if (changes.length > LIMITS.maxFiles) {
    throw new AppError(
      `Review exceeds ${LIMITS.maxFiles} changed files`,
      'REVIEW_TOO_LARGE',
      4,
      413,
    );
  }
  const files: ReviewFile[] = [];
  let totalBytes = 0;
  for (const change of changes) {
    const paths = change.oldPath ? [change.oldPath, change.path] : [change.path];
    const stats = await fileStats(repo, baseSha, headSha, paths);
    const [oldSize, newSize] = await Promise.all([
      blobSize(repo, baseSha, change.oldPath ?? change.path),
      blobSize(repo, headSha, change.path),
    ]);
    const truncated = !stats.binary && Math.max(oldSize, newSize) > LIMITS.maxPatchBytesPerFile;
    if (stats.binary || truncated) {
      files.push({
        ...change,
        status: stats.binary ? 'binary' : change.status,
        additions: stats.additions,
        deletions: stats.deletions,
        binary: stats.binary,
        truncated,
        hunks: [],
      });
      continue;
    }
    const { stdout: patch } = await git(
      repo,
      [
        '-c',
        'core.quotePath=true',
        'diff',
        '--find-renames',
        '--no-ext-diff',
        '--no-textconv',
        '--no-color',
        '--unified=4',
        baseSha,
        headSha,
        '--',
        ...paths,
      ],
      LIMITS.maxPatchBytesPerFile + 100_000,
    );
    const bytes = Buffer.byteLength(patch);
    totalBytes += Math.min(bytes, LIMITS.maxPatchBytesPerFile);
    if (totalBytes > LIMITS.maxPatchBytesTotal) {
      throw new AppError('Review patch exceeds the 8 MB safety limit', 'REVIEW_TOO_LARGE', 4, 413);
    }
    const normalized = normalizePatch(change.path, patch);
    files.push({
      ...change,
      status: change.status,
      additions: stats.additions,
      deletions: stats.deletions,
      binary: false,
      truncated,
      hunks: normalized.hunks,
    });
  }
  return {
    files,
    summary: {
      files: files.length,
      additions: files.reduce((sum, file) => sum + file.additions, 0),
      deletions: files.reduce((sum, file) => sum + file.deletions, 0),
    },
  };
}

export async function isRevisionStale(
  repo: string,
  headRef: string,
  headSha: string,
): Promise<boolean> {
  try {
    return (await resolveCommit(repo, headRef)) !== headSha;
  } catch {
    return true;
  }
}
