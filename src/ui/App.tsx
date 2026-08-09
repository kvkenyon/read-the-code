import { useCallback, useEffect, useMemo, useState } from 'react';
import hljs from 'highlight.js/lib/core';
import bash from 'highlight.js/lib/languages/bash';
import css from 'highlight.js/lib/languages/css';
import javascript from 'highlight.js/lib/languages/javascript';
import json from 'highlight.js/lib/languages/json';
import markdown from 'highlight.js/lib/languages/markdown';
import python from 'highlight.js/lib/languages/python';
import typescript from 'highlight.js/lib/languages/typescript';
import xml from 'highlight.js/lib/languages/xml';
import type {
  CommentDraft,
  CommentSide,
  DiffHunk,
  DiffLine,
  ReviewEvent,
  ReviewFile,
  ReviewManifest,
} from '../protocol';

hljs.registerLanguage('javascript', javascript);
hljs.registerLanguage('typescript', typescript);
hljs.registerLanguage('python', python);
hljs.registerLanguage('json', json);
hljs.registerLanguage('bash', bash);
hljs.registerLanguage('css', css);
hljs.registerLanguage('xml', xml);
hljs.registerLanguage('markdown', markdown);

interface Credentials {
  sessionId: string;
  token: string;
}

interface LocalDraft extends CommentDraft {
  clientId: string;
}

interface Selection {
  path: string;
  side: CommentSide;
  startLine: number;
  endLine: number;
  contextHash: string;
  endContextHash: string;
}

function credentials(): Credentials | undefined {
  const match = /^#\/review\/([a-f0-9]{24})\/([A-Za-z0-9_-]{40,})$/u.exec(window.location.hash);
  return match ? { sessionId: match[1], token: match[2] } : undefined;
}

function visiblePath(path: string): string {
  return [...path]
    .map((value) => {
      const code = value.codePointAt(0) ?? 0;
      if (code > 31 && code !== 127) return value;
      if (value === '\n') return '⏎';
      if (value === '\t') return '⇥';
      return `\\x${code.toString(16).padStart(2, '0')}`;
    })
    .join('');
}

function shortSha(value: string): string {
  return value.slice(0, 9);
}

function languageFor(path: string): string | undefined {
  const extension = path.split('.').pop()?.toLowerCase();
  return {
    js: 'javascript',
    jsx: 'javascript',
    mjs: 'javascript',
    ts: 'typescript',
    tsx: 'typescript',
    py: 'python',
    json: 'json',
    sh: 'bash',
    bash: 'bash',
    css: 'css',
    html: 'xml',
    xml: 'xml',
    md: 'markdown',
  }[extension ?? ''];
}

function HighlightedLine({ text, path }: { text: string; path: string }) {
  const language = languageFor(path);
  const html = language
    ? hljs.highlight(text, { language, ignoreIllegals: true }).value
    : hljs.highlightAuto(text).value;
  return <code dangerouslySetInnerHTML={{ __html: html || ' ' }} />;
}

async function api<T>(creds: Credentials, suffix = '', init?: RequestInit): Promise<T> {
  const response = await fetch(`/api/v1/sessions/${creds.sessionId}${suffix}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${creds.token}`,
      ...(init?.body ? { 'Content-Type': 'application/json' } : {}),
      ...init?.headers,
    },
  });
  const data = (await response.json()) as T & { error?: { message: string } };
  if (!response.ok) throw new Error(data.error?.message ?? `Request failed (${response.status})`);
  return data;
}

function statusLabel(file: ReviewFile): string {
  return { modified: 'M', added: 'A', deleted: 'D', renamed: 'R', binary: 'B' }[file.status];
}

function DiffLineButton({
  line,
  path,
  side,
  selected,
  onSelect,
  layout,
}: {
  line: DiffLine;
  path: string;
  side: CommentSide;
  selected: boolean;
  onSelect: (line: DiffLine, side: CommentSide, extend: boolean) => void;
  layout: 'unified' | 'split';
}) {
  const lineNumber = side === 'old' ? line.oldLine : line.newLine;
  if (lineNumber === null && layout === 'split')
    return <div className={`split-empty ${line.kind}`} aria-hidden="true" />;
  return (
    <button
      className={`diff-line ${line.kind}${selected ? ' selected' : ''}`}
      onClick={(event) => onSelect(line, side, event.shiftKey)}
      aria-label={`Comment on ${side} line ${lineNumber ?? 'unchanged'}`}
      data-testid={`line-${side}-${lineNumber ?? 'none'}`}
    >
      {layout === 'unified' ? (
        <>
          <span className="line-no old">{line.oldLine ?? ''}</span>
          <span className="line-no new">{line.newLine ?? ''}</span>
        </>
      ) : (
        <span className="line-no">{lineNumber ?? ''}</span>
      )}
      <span className="line-marker">
        {line.kind === 'addition' ? '+' : line.kind === 'deletion' ? '−' : ' '}
      </span>
      <span className="line-code">
        <HighlightedLine text={line.text} path={path} />
      </span>
      <span className="comment-glyph" aria-hidden="true">
        +
      </span>
    </button>
  );
}

function UnifiedHunk({
  hunk,
  file,
  selection,
  onSelect,
}: {
  hunk: DiffHunk;
  file: ReviewFile;
  selection?: Selection;
  onSelect: (line: DiffLine, side: CommentSide, extend: boolean) => void;
}) {
  return (
    <section className="hunk">
      <div className="hunk-header">{hunk.header}</div>
      {hunk.lines.map((line, index) => {
        const side: CommentSide = line.kind === 'deletion' ? 'old' : 'new';
        const number = side === 'old' ? line.oldLine : line.newLine;
        const selected =
          selection?.side === side &&
          number !== null &&
          number >= selection.startLine &&
          number <= selection.endLine;
        return (
          <DiffLineButton
            key={`${line.oldLine}-${line.newLine}-${index}`}
            line={line}
            path={file.path}
            side={side}
            selected={selected}
            onSelect={onSelect}
            layout="unified"
          />
        );
      })}
    </section>
  );
}

function SplitHunk({
  hunk,
  file,
  selection,
  onSelect,
}: {
  hunk: DiffHunk;
  file: ReviewFile;
  selection?: Selection;
  onSelect: (line: DiffLine, side: CommentSide, extend: boolean) => void;
}) {
  const rows: Array<{ old?: DiffLine; next?: DiffLine }> = [];
  let index = 0;
  while (index < hunk.lines.length) {
    const line = hunk.lines[index];
    if (line.kind === 'context') {
      rows.push({ old: line, next: line });
      index += 1;
      continue;
    }
    const removed: DiffLine[] = [];
    const added: DiffLine[] = [];
    while (hunk.lines[index]?.kind === 'deletion') removed.push(hunk.lines[index++]);
    while (hunk.lines[index]?.kind === 'addition') added.push(hunk.lines[index++]);
    for (let row = 0; row < Math.max(removed.length, added.length); row += 1) {
      rows.push({ old: removed[row], next: added[row] });
    }
  }
  return (
    <section className="hunk split-hunk">
      <div className="hunk-header">{hunk.header}</div>
      {rows.map((row, rowIndex) => (
        <div className="split-row" key={rowIndex}>
          {row.old ? (
            <DiffLineButton
              line={row.old}
              path={file.path}
              side="old"
              selected={Boolean(
                selection?.side === 'old' &&
                row.old.oldLine &&
                row.old.oldLine >= selection.startLine &&
                row.old.oldLine <= selection.endLine,
              )}
              onSelect={onSelect}
              layout="split"
            />
          ) : (
            <div className="split-empty deletion" />
          )}
          {row.next ? (
            <DiffLineButton
              line={row.next}
              path={file.path}
              side="new"
              selected={Boolean(
                selection?.side === 'new' &&
                row.next.newLine &&
                row.next.newLine >= selection.startLine &&
                row.next.newLine <= selection.endLine,
              )}
              onSelect={onSelect}
              layout="split"
            />
          ) : (
            <div className="split-empty addition" />
          )}
        </div>
      ))}
    </section>
  );
}

function EmptyFile({ file }: { file: ReviewFile }) {
  return (
    <div className="file-empty">
      <span className="empty-icon">{file.binary ? '◈' : file.truncated ? '↯' : '◇'}</span>
      <h3>
        {file.binary
          ? 'Binary file changed'
          : file.truncated
            ? 'Diff contained for safety'
            : 'No textual hunks'}
      </h3>
      <p>
        {file.binary
          ? 'Binary content is never rendered or executed.'
          : file.truncated
            ? 'This file exceeded the 1 MB per-file patch limit.'
            : 'Git recorded metadata-only or empty content changes.'}
      </p>
    </div>
  );
}

export function App() {
  const creds = useMemo(() => credentials(), []);
  const [manifest, setManifest] = useState<ReviewManifest>();
  const [events, setEvents] = useState<ReviewEvent[]>([]);
  const [activePath, setActivePath] = useState('');
  const [query, setQuery] = useState('');
  const [layout, setLayout] = useState<'unified' | 'split'>('unified');
  const [reviewed, setReviewed] = useState<Set<string>>(new Set());
  const [drafts, setDrafts] = useState<LocalDraft[]>([]);
  const [selection, setSelection] = useState<Selection>();
  const [composer, setComposer] = useState<{
    scope: 'line' | 'file' | 'general';
    body: string;
    editId?: string;
  }>();
  const [trayOpen, setTrayOpen] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [busy, setBusy] = useState('');
  const [notice, setNotice] = useState('');
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    if (!creds) return;
    const [nextManifest, eventResult] = await Promise.all([
      api<ReviewManifest>(creds),
      api<{ events: ReviewEvent[] }>(creds, '/events?after=0&timeout=0'),
    ]);
    setManifest(nextManifest);
    setEvents(eventResult.events);
    setActivePath((current) => current || nextManifest.files[0]?.path || '');
  }, [creds]);

  useEffect(() => {
    refresh().catch((reason: Error) => setError(reason.message));
    const interval = window.setInterval(() => refresh().catch(() => undefined), 10_000);
    return () => window.clearInterval(interval);
  }, [refresh]);

  useEffect(() => {
    if (!manifest) return;
    const key = `read-the-code:${manifest.sessionId}:reviewed`;
    const stored = JSON.parse(localStorage.getItem(key) ?? '[]') as string[];
    setReviewed(
      new Set(stored.filter((path) => manifest.files.some((file) => file.path === path))),
    );
  }, [manifest]);

  const activeFile = manifest?.files.find((file) => file.path === activePath);
  const filteredFiles =
    manifest?.files.filter((file) => file.path.toLowerCase().includes(query.toLowerCase())) ?? [];
  const commentCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const event of events) {
      if (event.type !== 'feedback') continue;
      for (const comment of event.comments)
        if (comment.path) counts.set(comment.path, (counts.get(comment.path) ?? 0) + 1);
    }
    for (const draft of drafts)
      if (draft.path) counts.set(draft.path, (counts.get(draft.path) ?? 0) + 1);
    return counts;
  }, [events, drafts]);

  const selectLine = (line: DiffLine, side: CommentSide, extend: boolean): void => {
    const lineNumber = side === 'old' ? line.oldLine : line.newLine;
    if (!activeFile || lineNumber === null) return;
    if (extend && selection?.path === activeFile.path && selection.side === side) {
      const start = Math.min(selection.startLine, lineNumber);
      const end = Math.max(selection.endLine, lineNumber);
      const all = activeFile.hunks.flatMap((hunk) => hunk.lines);
      const numberOf = (candidate: DiffLine): number | null =>
        side === 'old' ? candidate.oldLine : candidate.newLine;
      const startLine = all.find((candidate) => numberOf(candidate) === start);
      const endLine = all.find((candidate) => numberOf(candidate) === end);
      if (startLine && endLine) {
        setSelection({
          path: activeFile.path,
          side,
          startLine: start,
          endLine: end,
          contextHash: startLine.contextHash,
          endContextHash: endLine.contextHash,
        });
      }
    } else {
      setSelection({
        path: activeFile.path,
        side,
        startLine: lineNumber,
        endLine: lineNumber,
        contextHash: line.contextHash,
        endContextHash: line.contextHash,
      });
    }
    setComposer({ scope: 'line', body: '' });
  };

  const saveDraft = (): void => {
    if (!composer || !composer.body.trim() || !manifest) return;
    const existing = drafts.find((draft) => draft.clientId === composer.editId);
    const scope = composer.scope;
    const draft: LocalDraft = {
      clientId: existing?.clientId ?? crypto.randomUUID(),
      scope,
      body: composer.body.trim(),
      ...(scope !== 'general' && activeFile ? { path: existing?.path ?? activeFile.path } : {}),
      ...(scope === 'line' && (existing?.anchor || selection)
        ? {
            anchor:
              existing?.anchor ??
              ({
                revision: { baseSha: manifest.baseSha, headSha: manifest.headSha },
                ...selection!,
              } as LocalDraft['anchor']),
          }
        : {}),
    };
    setDrafts((current) =>
      existing
        ? current.map((item) => (item.clientId === existing.clientId ? draft : item))
        : [...current, draft],
    );
    setComposer(undefined);
    setSelection(undefined);
    setTrayOpen(true);
  };

  const submit = async (): Promise<void> => {
    if (!creds || drafts.length === 0) return;
    setBusy('submit');
    setError('');
    try {
      const comments: CommentDraft[] = drafts.map((localDraft) => {
        const draft = { ...localDraft };
        delete (draft as Partial<LocalDraft>).clientId;
        return draft;
      });
      await api(creds, '/feedback', { method: 'POST', body: JSON.stringify({ comments }) });
      setDrafts([]);
      setSelection(undefined);
      setNotice('Feedback submitted as one durable batch.');
      await refresh();
    } catch (reason) {
      setError((reason as Error).message);
    } finally {
      setBusy('');
    }
  };

  const approve = async (): Promise<void> => {
    if (!creds || manifest?.stale) return;
    if (
      !window.confirm(`Approve exactly ${manifest ? shortSha(manifest.headSha) : 'this revision'}?`)
    )
      return;
    setBusy('approve');
    try {
      await api(creds, '/approval', { method: 'POST', body: '{}' });
      setNotice(`Approved exact head ${shortSha(manifest!.headSha)}.`);
      await refresh();
    } catch (reason) {
      setError((reason as Error).message);
    } finally {
      setBusy('');
    }
  };

  const endReview = async (): Promise<void> => {
    if (
      !creds ||
      !window.confirm('End this review session? Unsubmitted drafts will remain only in this tab.')
    )
      return;
    setBusy('end');
    try {
      await api(creds, '/end', { method: 'POST', body: '{}' });
      setNotice('Review ended. This local tab is now read-only.');
      await refresh();
    } catch (reason) {
      setError((reason as Error).message);
    } finally {
      setBusy('');
    }
  };

  const toggleReviewed = (): void => {
    if (!activeFile || !manifest) return;
    const next = new Set(reviewed);
    if (next.has(activeFile.path)) next.delete(activeFile.path);
    else next.add(activeFile.path);
    setReviewed(next);
    localStorage.setItem(`read-the-code:${manifest.sessionId}:reviewed`, JSON.stringify([...next]));
  };

  const chooseFile = useCallback((path: string) => {
    setActivePath(path);
    setSelection(undefined);
    setComposer(undefined);
    setSidebarOpen(false);
    document.querySelector('.review-main')?.scrollTo({ top: 0 });
  }, []);

  useEffect(() => {
    const handler = (event: KeyboardEvent): void => {
      if (event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement)
        return;
      if (!manifest) return;
      const index = manifest.files.findIndex((file) => file.path === activePath);
      if (event.key === 'j' && index < manifest.files.length - 1)
        chooseFile(manifest.files[index + 1].path);
      if (event.key === 'k' && index > 0) chooseFile(manifest.files[index - 1].path);
      if (event.key === 'u') setLayout('unified');
      if (event.key === 's') setLayout('split');
      if (event.key === 'g') setComposer({ scope: 'general', body: '' });
      if (event.key === 'Escape') {
        setComposer(undefined);
        setSelection(undefined);
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [activePath, chooseFile, manifest]);

  if (!creds) {
    return (
      <main className="gate-state">
        <div className="brand-mark">RC</div>
        <h1>Review capability required</h1>
        <p>Open this review with the authenticated local URL returned by read-the-code-axi.</p>
      </main>
    );
  }
  if (error && !manifest) {
    return (
      <main className="gate-state">
        <div className="brand-mark danger">!</div>
        <h1>Couldn’t open this review</h1>
        <p>{error}</p>
      </main>
    );
  }
  if (!manifest) {
    return (
      <main className="gate-state" aria-live="polite">
        <div className="loading-ring" />
        <h1>Reading the change set…</h1>
        <p>Loading the exact pinned revision from local session storage.</p>
      </main>
    );
  }

  const approval = events.findLast((event) => event.type === 'approval');
  const readOnly = manifest.status === 'ended';

  return (
    <div className="app-shell">
      <header className="topbar">
        <button
          className="mobile-menu"
          onClick={() => setSidebarOpen(true)}
          aria-label="Open changed files"
        >
          ☰
        </button>
        <div className="brand-lockup">
          <div className="brand-mark">RC</div>
          <div>
            <span className="eyebrow">Read the Code</span>
            <strong>{visiblePath(manifest.repository)}</strong>
          </div>
        </div>
        <div className="revision-route" aria-label="Review revision">
          <span>{manifest.baseRef}</span>
          <code>{shortSha(manifest.baseSha)}</code>
          <i>→</i>
          <span>{manifest.headRef}</span>
          <code>{shortSha(manifest.headSha)}</code>
        </div>
        <div className="summary-pills">
          <span>{manifest.summary.files} files</span>
          <span className="plus">+{manifest.summary.additions}</span>
          <span className="minus">−{manifest.summary.deletions}</span>
        </div>
      </header>

      {(manifest.stale || readOnly) && (
        <div className={`state-banner ${manifest.stale ? 'warning' : ''}`} role="alert">
          <strong>{manifest.stale ? 'Head ref moved' : 'Review ended'}</strong>
          <span>
            {manifest.stale
              ? `This tab remains pinned to ${shortSha(manifest.headSha)}. Open a new revision to comment or approve the moved head.`
              : 'The exact review record is preserved; new comments and approvals are disabled.'}
          </span>
        </div>
      )}

      <div className="workspace">
        <aside className={`file-sidebar ${sidebarOpen ? 'open' : ''}`} aria-label="Changed files">
          <div className="sidebar-heading">
            <div>
              <span className="eyebrow">Change set</span>
              <h2>Files</h2>
            </div>
            <button
              className="close-sidebar"
              onClick={() => setSidebarOpen(false)}
              aria-label="Close changed files"
            >
              ×
            </button>
          </div>
          <label className="search-box">
            <span aria-hidden="true">⌕</span>
            <span className="sr-only">Filter changed files</span>
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Filter files"
            />
            {query && (
              <button onClick={() => setQuery('')} aria-label="Clear file filter">
                ×
              </button>
            )}
          </label>
          <div className="review-progress">
            <div>
              <span>Reviewed</span>
              <b>
                {reviewed.size}/{manifest.files.length}
              </b>
            </div>
            <div className="progress-track">
              <span
                style={{
                  width: `${manifest.files.length ? (reviewed.size / manifest.files.length) * 100 : 0}%`,
                }}
              />
            </div>
          </div>
          <nav className="file-list">
            {filteredFiles.map((file) => (
              <button
                key={file.path}
                className={file.path === activePath ? 'active' : ''}
                onClick={() => chooseFile(file.path)}
                aria-current={file.path === activePath ? 'page' : undefined}
              >
                <span className={`status-dot ${file.status}`}>{statusLabel(file)}</span>
                <span className="file-name" title={visiblePath(file.path)}>
                  {visiblePath(file.path)}
                </span>
                {commentCounts.has(file.path) && (
                  <span className="count-badge">{commentCounts.get(file.path)}</span>
                )}
                <span className={`review-check ${reviewed.has(file.path) ? 'done' : ''}`}>
                  {reviewed.has(file.path) ? '✓' : '○'}
                </span>
              </button>
            ))}
            {filteredFiles.length === 0 && <p className="no-files">No files match “{query}”.</p>}
          </nav>
          <div className="keyboard-card">
            <span>
              <kbd>J</kbd>
              <kbd>K</kbd> files
            </span>
            <span>
              <kbd>U</kbd>
              <kbd>S</kbd> layout
            </span>
            <span>
              <kbd>G</kbd> general note
            </span>
          </div>
        </aside>
        {sidebarOpen && (
          <button
            className="sidebar-scrim"
            onClick={() => setSidebarOpen(false)}
            aria-label="Close sidebar"
          />
        )}

        <main className="review-main">
          {activeFile ? (
            <article className="file-review">
              <div className="file-toolbar">
                <div className="file-title">
                  <span className={`status-label ${activeFile.status}`}>{activeFile.status}</span>
                  <div>
                    {activeFile.oldPath && <small>{visiblePath(activeFile.oldPath)} →</small>}
                    <h1>{visiblePath(activeFile.path)}</h1>
                  </div>
                </div>
                <div className="file-actions">
                  <div className="layout-toggle" aria-label="Diff layout">
                    <button
                      className={layout === 'unified' ? 'active' : ''}
                      onClick={() => setLayout('unified')}
                      aria-pressed={layout === 'unified'}
                    >
                      Unified
                    </button>
                    <button
                      className={layout === 'split' ? 'active' : ''}
                      onClick={() => setLayout('split')}
                      aria-pressed={layout === 'split'}
                    >
                      Split
                    </button>
                  </div>
                  <button
                    className="secondary-button"
                    onClick={() => setComposer({ scope: 'file', body: '' })}
                    disabled={readOnly || manifest.stale}
                  >
                    Comment on file
                  </button>
                  <button
                    className={`reviewed-button ${reviewed.has(activeFile.path) ? 'done' : ''}`}
                    onClick={toggleReviewed}
                  >
                    {reviewed.has(activeFile.path) ? '✓ Reviewed' : 'Mark reviewed'}
                  </button>
                </div>
              </div>
              <div className="diff-meta">
                <span className="plus">+{activeFile.additions}</span>
                <span className="minus">−{activeFile.deletions}</span>
                <span>
                  {activeFile.hunks.length} {activeFile.hunks.length === 1 ? 'hunk' : 'hunks'}
                </span>
                <span className="hint">Select a line · Shift-click for a range</span>
              </div>
              <div className={`diff-view ${layout}`} data-testid="diff-view">
                {activeFile.hunks.length === 0 ? (
                  <EmptyFile file={activeFile} />
                ) : (
                  activeFile.hunks.map((hunk, index) =>
                    layout === 'unified' ? (
                      <UnifiedHunk
                        key={index}
                        hunk={hunk}
                        file={activeFile}
                        selection={selection}
                        onSelect={selectLine}
                      />
                    ) : (
                      <SplitHunk
                        key={index}
                        hunk={hunk}
                        file={activeFile}
                        selection={selection}
                        onSelect={selectLine}
                      />
                    ),
                  )
                )}
              </div>
            </article>
          ) : (
            <div className="file-empty">
              <span className="empty-icon">✓</span>
              <h3>No changed files</h3>
              <p>The two revisions have identical trees.</p>
            </div>
          )}
        </main>

        <aside className={`draft-tray ${trayOpen ? 'open' : ''}`} aria-label="Review drafts">
          <button
            className="tray-tab"
            onClick={() => setTrayOpen((value) => !value)}
            aria-expanded={trayOpen}
          >
            <span>Review</span>
            <b>{drafts.length}</b>
          </button>
          <div className="tray-content">
            <div className="tray-title">
              <div>
                <span className="eyebrow">Before you send</span>
                <h2>Review drafts</h2>
              </div>
              <button onClick={() => setTrayOpen(false)} aria-label="Close draft tray">
                ×
              </button>
            </div>
            {approval && (
              <div className={`approval-note ${manifest.approvalStale ? 'stale' : ''}`}>
                ✓{' '}
                {manifest.approvalStale
                  ? 'Prior approval is stale'
                  : `Approved ${shortSha(approval.headSha)}`}
              </div>
            )}
            <div className="draft-list">
              {drafts.map((draft) => (
                <article className="draft-card" key={draft.clientId}>
                  <span>
                    {draft.scope}
                    {draft.path ? ` · ${visiblePath(draft.path)}` : ''}
                  </span>
                  {draft.anchor && (
                    <small>
                      {draft.anchor.side} lines {draft.anchor.startLine}
                      {draft.anchor.endLine !== draft.anchor.startLine
                        ? `–${draft.anchor.endLine}`
                        : ''}
                    </small>
                  )}
                  <p>{draft.body}</p>
                  <div>
                    <button
                      onClick={() => {
                        setComposer({
                          scope: draft.scope as 'line' | 'file' | 'general',
                          body: draft.body,
                          editId: draft.clientId,
                        });
                        setActivePath(draft.path ?? activePath);
                      }}
                    >
                      Edit
                    </button>
                    <button
                      onClick={() =>
                        setDrafts((current) =>
                          current.filter((item) => item.clientId !== draft.clientId),
                        )
                      }
                    >
                      Discard
                    </button>
                  </div>
                </article>
              ))}
              {drafts.length === 0 && (
                <div className="empty-drafts">
                  <span>✦</span>
                  <p>Select any diff line to start a comment, or add a general note.</p>
                </div>
              )}
            </div>
            <button
              className="general-button"
              onClick={() => setComposer({ scope: 'general', body: '' })}
              disabled={readOnly || manifest.stale}
            >
              + General comment
            </button>
            <div className="submit-stack">
              <button
                className="primary-button"
                disabled={drafts.length === 0 || Boolean(busy) || readOnly || manifest.stale}
                onClick={submit}
              >
                {busy === 'submit'
                  ? 'Submitting…'
                  : `Submit feedback${drafts.length ? ` (${drafts.length})` : ''}`}
              </button>
              <button
                className="approve-button"
                disabled={Boolean(busy) || readOnly || manifest.stale}
                onClick={approve}
              >
                ✓ Approve revision
              </button>
              <button
                className="end-button"
                disabled={Boolean(busy) || readOnly}
                onClick={endReview}
              >
                End review
              </button>
            </div>
            <p className="consequence">
              Approval is bound only to <code>{shortSha(manifest.headSha)}</code>. Feedback
              submission sends all drafts as one durable event.
            </p>
          </div>
        </aside>
      </div>

      {composer && (
        <div
          className="composer-layer"
          role="presentation"
          onMouseDown={(event) => {
            if (event.currentTarget === event.target) setComposer(undefined);
          }}
        >
          <section
            className="composer"
            role="dialog"
            aria-modal="true"
            aria-labelledby="composer-title"
          >
            <div className="composer-title">
              <div>
                <span className="eyebrow">Draft comment</span>
                <h2 id="composer-title">
                  {composer.scope === 'general'
                    ? 'Across this review'
                    : composer.scope === 'file'
                      ? visiblePath(activeFile?.path ?? '')
                      : `${selection?.side ?? drafts.find((d) => d.clientId === composer.editId)?.anchor?.side} line ${selection?.startLine ?? drafts.find((d) => d.clientId === composer.editId)?.anchor?.startLine}`}
                </h2>
              </div>
              <button
                onClick={() => {
                  setComposer(undefined);
                  setSelection(undefined);
                }}
                aria-label="Close comment composer"
              >
                ×
              </button>
            </div>
            <label>
              <span className="sr-only">Comment</span>
              <textarea
                autoFocus
                maxLength={20000}
                value={composer.body}
                onChange={(event) => setComposer({ ...composer, body: event.target.value })}
                placeholder="What should the author understand or change?"
              />
            </label>
            <div className="composer-footer">
              <span>
                {new TextEncoder().encode(composer.body).length.toLocaleString()} / 20,000 bytes
              </span>
              <div>
                <button
                  className="secondary-button"
                  onClick={() => {
                    setComposer(undefined);
                    setSelection(undefined);
                  }}
                >
                  Cancel
                </button>
                <button
                  className="primary-button"
                  disabled={!composer.body.trim()}
                  onClick={saveDraft}
                >
                  Save draft
                </button>
              </div>
            </div>
          </section>
        </div>
      )}

      {(notice || (error && manifest)) && (
        <div className={`toast ${error ? 'error' : ''}`} role="status">
          <span>{error || notice}</span>
          <button
            onClick={() => {
              setError('');
              setNotice('');
            }}
            aria-label="Dismiss message"
          >
            ×
          </button>
        </div>
      )}
    </div>
  );
}
