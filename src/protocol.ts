export const SCHEMA_VERSION = 1 as const;

export type ChangeStatus = 'modified' | 'added' | 'deleted' | 'renamed' | 'binary';
export type DiffLineKind = 'context' | 'addition' | 'deletion';
export type CommentSide = 'old' | 'new';
export type CommentScope = 'line' | 'file' | 'general';

export interface DiffLine {
  kind: DiffLineKind;
  oldLine: number | null;
  newLine: number | null;
  text: string;
  contextHash: string;
}

export interface DiffHunk {
  header: string;
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  lines: DiffLine[];
}

export interface ReviewFile {
  path: string;
  oldPath?: string;
  status: ChangeStatus;
  additions: number;
  deletions: number;
  binary: boolean;
  truncated: boolean;
  oldLineCount?: number;
  newLineCount?: number;
  hunks: DiffHunk[];
}

export interface ReviewSummary {
  files: number;
  additions: number;
  deletions: number;
}

export interface ReviewManifest {
  schemaVersion: typeof SCHEMA_VERSION;
  sessionId: string;
  repository: string;
  baseRef: string;
  headRef: string;
  baseSha: string;
  headSha: string;
  createdAt: string;
  updatedAt: string;
  status: 'open' | 'ended';
  stale: boolean;
  approvalStale: boolean;
  summary: ReviewSummary;
  files: ReviewFile[];
}

export interface LineAnchor {
  revision: { baseSha: string; headSha: string };
  path: string;
  side: CommentSide;
  startLine: number;
  endLine: number;
  contextHash: string;
  endContextHash: string;
}

export interface ReviewComment {
  id: string;
  scope: CommentScope;
  body: string;
  path?: string;
  anchor?: LineAnchor;
  createdAt: string;
}

export interface CommentDraft {
  scope: CommentScope;
  body: string;
  path?: string;
  anchor?: LineAnchor;
}

interface EventBase {
  schemaVersion: typeof SCHEMA_VERSION;
  sessionId: string;
  sequence: number;
  id: string;
  createdAt: string;
  baseSha: string;
  headSha: string;
}

export interface FeedbackSubmission extends EventBase {
  type: 'feedback';
  comments: ReviewComment[];
}

export interface ApprovalSubmission extends EventBase {
  type: 'approval';
  approvedHeadSha: string;
}

export interface EndSubmission extends EventBase {
  type: 'end';
}

export type ReviewEvent = FeedbackSubmission | ApprovalSubmission | EndSubmission;

export interface SessionExport {
  schemaVersion: typeof SCHEMA_VERSION;
  session: Omit<ReviewManifest, 'files'> & { files: ReviewFile[] };
  events: ReviewEvent[];
}

export interface SessionRecord {
  schemaVersion: typeof SCHEMA_VERSION;
  id: string;
  repositoryName: string;
  repositoryPath: string;
  baseRef: string;
  headRef: string;
  baseSha: string;
  headSha: string;
  createdAt: string;
  updatedAt: string;
  status: 'open' | 'ended';
  nextSequence: number;
  summary: ReviewSummary;
  files: ReviewFile[];
  events: ReviewEvent[];
  wakeFile?: string;
}

export interface OpenResult {
  schemaVersion: typeof SCHEMA_VERSION;
  sessionId: string;
  baseSha: string;
  headSha: string;
  browserUrl: string;
  resumed: boolean;
  wakeFileArmed: boolean;
  status: 'open';
}

export interface PollResult {
  schemaVersion: typeof SCHEMA_VERSION;
  sessionId: string;
  after: number;
  nextCursor: number;
  timedOut: boolean;
  events: ReviewEvent[];
}

export type ContextPosition = 'before' | 'after';

export interface ContextLine {
  oldLine: number | null;
  newLine: number | null;
  text: string;
}

export interface ContextResult {
  schemaVersion: typeof SCHEMA_VERSION;
  sessionId: string;
  path: string;
  hunk: number;
  position: ContextPosition;
  total: number;
  lines: ContextLine[];
}

export interface ReviewWakeEvent {
  schemaVersion: typeof SCHEMA_VERSION;
  sessionId: string;
  sequence: number;
  type: ReviewEvent['type'];
  event: ReviewEvent;
}
