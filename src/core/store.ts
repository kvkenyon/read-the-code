import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { constants } from 'node:fs';
import {
  access,
  chmod,
  mkdir,
  open,
  readFile,
  rename,
  stat,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import type {
  CommentDraft,
  EndSubmission,
  FeedbackSubmission,
  ApprovalSubmission,
  ReviewEvent,
  ReviewManifest,
  ReviewSummary,
  ReviewWakeEvent,
  SessionExport,
  SessionRecord,
} from '../protocol.js';
import { SCHEMA_VERSION } from '../protocol.js';
import { AppError } from './errors.js';
import { isRevisionStale } from './git.js';
import { LIMITS } from './limits.js';

const LOCK_TIMEOUT_MS = 3_000;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function stateDirectory(env = process.env): string {
  if (env.READ_THE_CODE_STATE_DIR) return env.READ_THE_CODE_STATE_DIR;
  const base = env.XDG_STATE_HOME || join(homedir(), '.local', 'state');
  return join(base, 'read-the-code');
}

async function ensurePrivateDirectory(path: string): Promise<void> {
  await mkdir(path, { recursive: true, mode: 0o700 });
  await chmod(path, 0o700);
}

async function atomicWrite(path: string, value: unknown, mode = 0o600): Promise<void> {
  await ensurePrivateDirectory(dirname(path));
  const temp = `${path}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
  await writeFile(temp, `${JSON.stringify(value, null, 2)}\n`, { mode, flag: 'wx' });
  await rename(temp, path);
  await chmod(path, mode);
}

async function withLock<T>(lockPath: string, operation: () => Promise<T>): Promise<T> {
  const started = Date.now();
  await ensurePrivateDirectory(dirname(lockPath));
  while (true) {
    try {
      const handle = await open(lockPath, 'wx', 0o600);
      try {
        return await operation();
      } finally {
        await handle.close();
        await unlink(lockPath).catch(() => undefined);
      }
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code !== 'EEXIST') throw error;
      const info = await stat(lockPath).catch(() => undefined);
      if (info && Date.now() - info.mtimeMs > 30_000) {
        await unlink(lockPath).catch(() => undefined);
        continue;
      }
      if (Date.now() - started > LOCK_TIMEOUT_MS) {
        throw new AppError('Session is busy; retry shortly', 'SESSION_BUSY', 5, 409);
      }
      await sleep(25 + Math.floor(Math.random() * 25));
    }
  }
}

function validSessionId(id: string): boolean {
  return /^[a-f0-9]{24}$/u.test(id);
}

function validateBody(body: string): void {
  if (!body.trim()) throw new AppError('Comment body cannot be empty', 'INVALID_COMMENT', 2, 400);
  if (Buffer.byteLength(body) > LIMITS.maxCommentBytes) {
    throw new AppError('Comment exceeds the 20 KB limit', 'COMMENT_TOO_LARGE', 4, 413);
  }
  const hasControl = [...body].some((character) => {
    const code = character.codePointAt(0) ?? 0;
    return (code < 32 && code !== 9 && code !== 10 && code !== 13) || code === 127;
  });
  if (hasControl) {
    throw new AppError(
      'Comment contains unsupported control characters',
      'INVALID_COMMENT',
      2,
      400,
    );
  }
}

export class SessionStore {
  readonly root: string;
  readonly sessionsDir: string;

  constructor(root = stateDirectory()) {
    this.root = root;
    this.sessionsDir = join(root, 'sessions');
  }

  async initialize(): Promise<void> {
    await ensurePrivateDirectory(this.sessionsDir);
  }

  sessionId(repositoryPath: string, baseSha: string, headSha: string): string {
    return createHash('sha256')
      .update(`${repositoryPath}\0${baseSha}\0${headSha}`)
      .digest('hex')
      .slice(0, 24);
  }

  private recordPath(id: string): string {
    if (!validSessionId(id)) throw new AppError('Invalid session id', 'INVALID_SESSION', 2, 400);
    return join(this.sessionsDir, `${id}.json`);
  }

  private tokenPath(id: string): string {
    if (!validSessionId(id)) throw new AppError('Invalid session id', 'INVALID_SESSION', 2, 400);
    return join(this.sessionsDir, `${id}.token`);
  }

  private lockPath(id: string): string {
    if (!validSessionId(id)) throw new AppError('Invalid session id', 'INVALID_SESSION', 2, 400);
    return join(this.sessionsDir, `${id}.lock`);
  }

  async exists(id: string): Promise<boolean> {
    try {
      await access(this.recordPath(id), constants.R_OK);
      return true;
    } catch {
      return false;
    }
  }

  async read(id: string): Promise<SessionRecord> {
    let raw: string;
    try {
      raw = await readFile(this.recordPath(id), 'utf8');
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        throw new AppError('Review session not found', 'SESSION_NOT_FOUND', 6, 404);
      }
      throw error;
    }
    const parsed = JSON.parse(raw) as SessionRecord;
    if (parsed.schemaVersion !== SCHEMA_VERSION || parsed.id !== id) {
      throw new AppError('Unsupported or corrupt session record', 'CORRUPT_SESSION', 7, 500);
    }
    return parsed;
  }

  async token(id: string): Promise<string> {
    try {
      return (await readFile(this.tokenPath(id), 'utf8')).trim();
    } catch {
      throw new AppError('Session capability is unavailable', 'SESSION_SECRET_MISSING', 7, 500);
    }
  }

  async authenticate(id: string, candidate: string): Promise<boolean> {
    const expected = await this.token(id);
    const a = Buffer.from(expected);
    const b = Buffer.from(candidate);
    if (a.length !== b.length) return false;
    return (await import('node:crypto')).timingSafeEqual(a, b);
  }

  async createOrResume(
    input: Omit<SessionRecord, 'createdAt' | 'updatedAt' | 'status' | 'nextSequence' | 'events'>,
  ): Promise<{
    record: SessionRecord;
    token: string;
    resumed: boolean;
  }> {
    await this.initialize();
    return withLock(this.lockPath(input.id), async () => {
      const resumed = await this.exists(input.id);
      const now = new Date().toISOString();
      let record: SessionRecord;
      if (resumed) {
        record = await this.read(input.id);
        record.status = 'open';
        record.updatedAt = now;
        record.wakeFile = input.wakeFile;
      } else {
        record = {
          ...input,
          createdAt: now,
          updatedAt: now,
          status: 'open',
          nextSequence: 1,
          events: [],
        };
      }
      await atomicWrite(this.recordPath(input.id), record);
      let token: string;
      if (resumed) {
        token = await this.token(input.id);
      } else {
        token = randomBytes(32).toString('base64url');
        await writeFile(this.tokenPath(input.id), `${token}\n`, { mode: 0o600, flag: 'wx' });
      }
      return { record, token, resumed };
    });
  }

  async manifest(id: string): Promise<ReviewManifest> {
    const record = await this.read(id);
    const stale = await isRevisionStale(record.repositoryPath, record.headRef, record.headSha);
    const hasApproval = record.events.some((event) => event.type === 'approval');
    return {
      schemaVersion: SCHEMA_VERSION,
      sessionId: record.id,
      repository: record.repositoryName,
      baseRef: record.baseRef,
      headRef: record.headRef,
      baseSha: record.baseSha,
      headSha: record.headSha,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      status: record.status,
      stale,
      approvalStale: stale && hasApproval,
      summary: record.summary,
      files: record.files,
    };
  }

  private validateDraft(record: SessionRecord, draft: CommentDraft): void {
    validateBody(draft.body);
    if (!['line', 'file', 'general'].includes(draft.scope)) {
      throw new AppError('Invalid comment scope', 'INVALID_COMMENT', 2, 400);
    }
    if (draft.scope === 'general') {
      if (draft.path || draft.anchor)
        throw new AppError('General comments cannot have anchors', 'INVALID_COMMENT', 2, 400);
      return;
    }
    const file = record.files.find((item) => item.path === draft.path);
    if (!file) throw new AppError('Comment file is not in this review', 'INVALID_ANCHOR', 2, 400);
    if (draft.scope === 'file') {
      if (draft.anchor)
        throw new AppError('File comments cannot have line anchors', 'INVALID_ANCHOR', 2, 400);
      return;
    }
    const anchor = draft.anchor;
    if (!anchor || anchor.path !== draft.path)
      throw new AppError('Line comment needs an anchor', 'INVALID_ANCHOR', 2, 400);
    if (anchor.revision.baseSha !== record.baseSha || anchor.revision.headSha !== record.headSha) {
      throw new AppError('Comment anchor belongs to another revision', 'STALE_ANCHOR', 2, 409);
    }
    if (anchor.startLine > anchor.endLine || anchor.startLine < 1) {
      throw new AppError('Invalid comment line range', 'INVALID_ANCHOR', 2, 400);
    }
    const candidates = file.hunks.flatMap((hunk) => hunk.lines);
    const numberForSide = (line: (typeof candidates)[number]): number | null =>
      anchor.side === 'old' ? line.oldLine : line.newLine;
    const start = candidates.find((line) => numberForSide(line) === anchor.startLine);
    const end = candidates.find((line) => numberForSide(line) === anchor.endLine);
    if (
      !start ||
      !end ||
      start.contextHash !== anchor.contextHash ||
      end.contextHash !== anchor.endContextHash
    ) {
      throw new AppError('Comment anchor is stale or outside this patch', 'STALE_ANCHOR', 2, 409);
    }
  }

  async submitFeedback(id: string, drafts: CommentDraft[]): Promise<FeedbackSubmission> {
    if (
      !Array.isArray(drafts) ||
      drafts.length === 0 ||
      drafts.length > LIMITS.maxCommentsPerSubmission
    ) {
      throw new AppError('Submit between 1 and 100 comments', 'INVALID_SUBMISSION', 2, 400);
    }
    if (Buffer.byteLength(JSON.stringify(drafts)) > LIMITS.maxSubmissionBytes) {
      throw new AppError('Feedback submission exceeds 100 KB', 'SUBMISSION_TOO_LARGE', 4, 413);
    }
    const snapshot = await this.read(id);
    if (await isRevisionStale(snapshot.repositoryPath, snapshot.headRef, snapshot.headSha)) {
      throw new AppError(
        'The requested head ref moved; open a new revision before submitting feedback',
        'STALE_REVISION',
        8,
        409,
      );
    }
    return this.updateWithWake(id, (record) => {
      if (record.status !== 'open') throw new AppError('Review has ended', 'SESSION_ENDED', 8, 409);
      drafts.forEach((draft) => this.validateDraft(record, draft));
      const createdAt = new Date().toISOString();
      const event: FeedbackSubmission = {
        schemaVersion: SCHEMA_VERSION,
        sessionId: id,
        sequence: record.nextSequence++,
        id: randomUUID(),
        type: 'feedback',
        createdAt,
        baseSha: record.baseSha,
        headSha: record.headSha,
        comments: drafts.map((draft) => ({ ...draft, id: randomUUID(), createdAt })),
      };
      record.events.push(event);
      return event;
    });
  }

  async approve(id: string): Promise<ApprovalSubmission> {
    return this.updateWithWake(id, (record) => {
      if (record.status !== 'open') throw new AppError('Review has ended', 'SESSION_ENDED', 8, 409);
      const event: ApprovalSubmission = {
        schemaVersion: SCHEMA_VERSION,
        sessionId: id,
        sequence: record.nextSequence++,
        id: randomUUID(),
        type: 'approval',
        createdAt: new Date().toISOString(),
        baseSha: record.baseSha,
        headSha: record.headSha,
        approvedHeadSha: record.headSha,
      };
      record.events.push(event);
      return event;
    });
  }

  async end(id: string): Promise<EndSubmission> {
    return this.updateWithWake(id, (record) => {
      const existing = record.events.findLast(
        (event): event is EndSubmission => event.type === 'end',
      );
      if (existing) return existing;
      const event: EndSubmission = {
        schemaVersion: SCHEMA_VERSION,
        sessionId: id,
        sequence: record.nextSequence++,
        id: randomUUID(),
        type: 'end',
        createdAt: new Date().toISOString(),
        baseSha: record.baseSha,
        headSha: record.headSha,
      };
      record.status = 'ended';
      record.events.push(event);
      return event;
    });
  }

  async eventsAfter(id: string, after: number): Promise<ReviewEvent[]> {
    const record = await this.read(id);
    return record.events.filter((event) => event.sequence > after);
  }

  async export(
    id: string,
    diagnostic = false,
  ): Promise<SessionExport & { diagnostics?: { repositoryPath: string } }> {
    const record = await this.read(id);
    const session = await this.manifest(id);
    return {
      schemaVersion: SCHEMA_VERSION,
      session,
      events: record.events,
      ...(diagnostic ? { diagnostics: { repositoryPath: record.repositoryPath } } : {}),
    };
  }

  async recent(limit = 5): Promise<{
    sessions: Array<{
      id: string;
      status: 'open' | 'ended';
      stale: boolean;
      baseSha: string;
      headSha: string;
      summary: ReviewSummary;
      updatedAt: string;
    }>;
    total: number;
    open: number;
    ended: number;
  }> {
    const { readdir } = await import('node:fs/promises');
    const entries = await readdir(this.sessionsDir).catch(() => []);
    const records = await Promise.all(
      entries
        .filter((entry) => entry.endsWith('.json'))
        .map(async (entry) => {
          const id = entry.slice(0, -5);
          try {
            const manifest = await this.manifest(id);
            return {
              id,
              status: manifest.status,
              stale: manifest.stale,
              baseSha: manifest.baseSha,
              headSha: manifest.headSha,
              summary: manifest.summary,
              updatedAt: manifest.updatedAt,
            };
          } catch {
            return undefined;
          }
        }),
    );
    const valid = records
      .filter((record): record is NonNullable<typeof record> => Boolean(record))
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
    return {
      sessions: valid.slice(0, limit),
      total: valid.length,
      open: valid.filter((record) => record.status === 'open').length,
      ended: valid.filter((record) => record.status === 'ended').length,
    };
  }

  async hasOpenSessions(): Promise<boolean> {
    const { readdir } = await import('node:fs/promises');
    const entries = await readdir(this.sessionsDir).catch(() => []);
    for (const entry of entries) {
      if (!entry.endsWith('.json')) continue;
      const id = entry.slice(0, -5);
      try {
        if ((await this.read(id)).status === 'open') return true;
      } catch {
        // Ignore unrelated or partially-created files in the state directory.
      }
    }
    return false;
  }

  private async update<T>(id: string, mutate: (record: SessionRecord) => T): Promise<T> {
    return withLock(this.lockPath(id), async () => {
      const record = await this.read(id);
      const result = mutate(record);
      record.updatedAt = new Date().toISOString();
      await atomicWrite(this.recordPath(id), record);
      return result;
    });
  }

  private async updateWithWake<T extends ReviewEvent>(
    id: string,
    mutate: (record: SessionRecord) => T,
  ): Promise<T> {
    const { result, wakeFile, shouldWake } = await withLock(this.lockPath(id), async () => {
      const record = await this.read(id);
      const eventCount = record.events.length;
      const result = mutate(record);
      record.updatedAt = new Date().toISOString();
      await atomicWrite(this.recordPath(id), record);
      return {
        result,
        wakeFile: record.wakeFile,
        shouldWake: record.events.length > eventCount,
      };
    });
    if (wakeFile && shouldWake) {
      const capability = await this.token(id);
      const wake: ReviewWakeEvent = {
        schemaVersion: SCHEMA_VERSION,
        sessionId: id,
        sequence: result.sequence,
        type: result.type,
        event: result,
      };
      const handle = await open(
        wakeFile,
        constants.O_WRONLY | constants.O_APPEND | constants.O_CREAT | (constants.O_NOFOLLOW ?? 0),
        0o600,
      );
      try {
        await handle.appendFile(
          `${JSON.stringify(wake).replaceAll(capability, '[REDACTED_CAPABILITY]')}\n`,
        );
      } finally {
        await handle.close();
      }
      await chmod(wakeFile, 0o600);
    }
    return result;
  }
}

export interface ServerRegistry {
  schemaVersion: typeof SCHEMA_VERSION;
  pid: number;
  port: number;
  controlToken: string;
  startedAt: string;
}

export function registryPath(store: SessionStore): string {
  return join(store.root, 'server.json');
}

export async function writeRegistry(store: SessionStore, registry: ServerRegistry): Promise<void> {
  await atomicWrite(registryPath(store), registry);
}

export async function readRegistry(store: SessionStore): Promise<ServerRegistry | undefined> {
  try {
    const value = JSON.parse(await readFile(registryPath(store), 'utf8')) as ServerRegistry;
    if (
      value.schemaVersion !== SCHEMA_VERSION ||
      !Number.isInteger(value.port) ||
      !value.controlToken
    )
      return undefined;
    return value;
  } catch {
    return undefined;
  }
}

export async function clearRegistry(store: SessionStore, pid = process.pid): Promise<void> {
  const registry = await readRegistry(store);
  if (registry?.pid === pid) await unlink(registryPath(store)).catch(() => undefined);
}
