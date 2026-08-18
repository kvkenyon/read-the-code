import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
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
  ContextPosition,
  ContextResult,
  DiffLine,
  ReviewEvent,
  ReviewFile,
  ReviewManifest,
} from '../protocol';
import { buildGuide } from './guide';
import {
  ariaKeyShortcuts,
  COMMANDS,
  commandById,
  commandFor,
  isTypingTarget,
  keyStroke,
  type FocusRegion,
  type ReviewCommand,
} from './commands';

for (const [name, language] of Object.entries({
  javascript,
  typescript,
  python,
  json,
  bash,
  css,
  xml,
  markdown,
}))
  hljs.registerLanguage(name, language);

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
interface Composer {
  scope: 'line' | 'file' | 'general';
  body: string;
  editId?: string;
}
interface FlatLine {
  line: DiffLine;
  side: CommentSide;
  hunk: number;
  index: number;
}
interface GuideJump {
  path: string;
  hunk: number;
}
type Theme = 'light' | 'dark' | 'system';

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
  return (
    {
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
    } as Record<string, string>
  )[path.split('.').pop()?.toLowerCase() ?? ''];
}

function HighlightedLine({ text, path }: { text: string; path: string }) {
  const language = languageFor(path);
  const html = language
    ? hljs.highlight(text, { language, ignoreIllegals: true }).value
    : hljs.highlightAuto(text).value;
  return <code aria-hidden="true" dangerouslySetInnerHTML={{ __html: html || ' ' }} />;
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
  return ({ modified: 'M', added: 'A', deleted: 'D', renamed: 'R', binary: 'B' } as const)[
    file.status
  ];
}

function spokenLine(line: DiffLine): string {
  const kind =
    line.kind === 'addition' ? 'Added' : line.kind === 'deletion' ? 'Deleted' : 'Context';
  const oldNumber = line.oldLine === null ? 'no old line' : `old line ${line.oldLine}`;
  const newNumber = line.newLine === null ? 'no new line' : `new line ${line.newLine}`;
  return `${kind}, ${oldNumber}, ${newNumber}: ${line.text || 'blank line'}`;
}

function hiddenContextCount(
  file: ReviewFile,
  hunkIndex: number,
  position: ContextPosition,
): number {
  const hunk = file.hunks[hunkIndex];
  if (!hunk) return 0;
  const adjacent = position === 'before' ? file.hunks[hunkIndex - 1] : file.hunks[hunkIndex + 1];
  const oldStart =
    position === 'before'
      ? adjacent
        ? adjacent.oldStart + adjacent.oldLines
        : 1
      : hunk.oldStart + hunk.oldLines;
  const newStart =
    position === 'before'
      ? adjacent
        ? adjacent.newStart + adjacent.newLines
        : 1
      : hunk.newStart + hunk.newLines;
  const oldEnd =
    position === 'before'
      ? hunk.oldStart - 1
      : adjacent
        ? adjacent.oldStart - 1
        : (file.oldLineCount ?? 0);
  const newEnd =
    position === 'before'
      ? hunk.newStart - 1
      : adjacent
        ? adjacent.newStart - 1
        : (file.newLineCount ?? 0);
  return Math.max(0, oldEnd - oldStart + 1, newEnd - newStart + 1);
}

function ContextGap({
  file,
  hunk,
  position,
  result,
  busy,
  onExpand,
}: {
  file: ReviewFile;
  hunk: number;
  position: ContextPosition;
  result?: ContextResult;
  busy: boolean;
  onExpand: () => void;
}) {
  const total = hiddenContextCount(file, hunk, position);
  if (!total) return null;
  const remaining = total - (result?.lines.length ?? 0);
  const control = remaining > 0 && (
    <button className="context-expand" disabled={busy} onClick={onExpand}>
      {busy
        ? 'Reading exact tree…'
        : `Expand ${Math.min(20, remaining)} of ${remaining} hidden ${remaining === 1 ? 'line' : 'lines'} ${position}`}
    </button>
  );
  const lines = result?.lines.map((line) => (
    <div className="context-line" key={`${line.oldLine ?? 'x'}:${line.newLine ?? 'x'}`}>
      <span className="line-no old">{line.oldLine ?? ''}</span>
      <span className="line-no new">{line.newLine ?? ''}</span>
      <span className="line-marker"> </span>
      <span className="line-code">
        <HighlightedLine text={line.text} path={file.path} />
      </span>
      <span />
    </div>
  ));
  return (
    <div className={`context-gap ${position}`}>
      {position === 'before' && control}
      {lines}
      {position === 'after' && control}
    </div>
  );
}

function Overlay({
  title,
  onClose,
  children,
  initialFocus,
}: {
  title: string;
  onClose: () => void;
  children: ReactNode;
  initialFocus?: 'input';
}) {
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const selector = initialFocus === 'input' ? 'input' : 'button, input, [tabindex="0"]';
    window.requestAnimationFrame(() =>
      panel.current?.querySelector<HTMLElement>(selector)?.focus(),
    );
  }, [initialFocus]);
  return (
    <div className="overlay" role="presentation">
      <div
        ref={panel}
        className="overlay-panel"
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onKeyDown={(event) => {
          if (event.key === 'Escape' && !event.nativeEvent.isComposing) {
            event.preventDefault();
            onClose();
            return;
          }
          if (event.key !== 'Tab') return;
          const items = [
            ...(panel.current?.querySelectorAll<HTMLElement>(
              'button:not(:disabled), input, [tabindex="0"]',
            ) ?? []),
          ];
          if (!items.length) return;
          const first = items[0];
          const last = items.at(-1)!;
          if (event.shiftKey && document.activeElement === first) {
            event.preventDefault();
            last.focus();
          } else if (!event.shiftKey && document.activeElement === last) {
            event.preventDefault();
            first.focus();
          }
        }}
      >
        {children}
      </div>
    </div>
  );
}

function InlineComposer({
  composer,
  selection,
  path,
  onChange,
  onKeep,
  onClose,
}: {
  composer: Composer;
  selection?: Selection;
  path?: string;
  onChange: (body: string) => void;
  onKeep: () => void;
  onClose: () => void;
}) {
  const title =
    composer.scope === 'general'
      ? 'General review comment'
      : composer.scope === 'file'
        ? `File comment · ${visiblePath(path ?? '')}`
        : `Line comment · ${selection?.side} ${selection?.startLine}${selection && selection.endLine !== selection.startLine ? `–${selection.endLine}` : ''}`;
  return (
    <section className="inline-composer" aria-labelledby="composer-title" data-region="composer">
      <div className="composer-title">
        <div>
          <span className="eyebrow">Recoverable draft</span>
          <h2 id="composer-title">{title}</h2>
        </div>
        <button onClick={onClose} aria-label="Close comment composer">
          ×
        </button>
      </div>
      <label>
        <span className="sr-only">Comment</span>
        <textarea
          name="review-comment"
          autoFocus
          maxLength={20000}
          value={composer.body}
          onChange={(event) => onChange(event.target.value)}
          onKeyDown={(event) => {
            if (event.nativeEvent.isComposing) return;
            if (event.key === 'Escape') {
              event.preventDefault();
              onKeep();
            }
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
              event.preventDefault();
              onKeep();
            }
          }}
          placeholder="What should the author understand or change?"
        />
      </label>
      <div className="composer-footer">
        <span>
          {new TextEncoder().encode(composer.body).length.toLocaleString()} / 20,000 bytes
        </span>
        <div>
          <button className="secondary-button" onClick={onKeep}>
            Keep draft & close
          </button>
          <button className="primary-button" disabled={!composer.body.trim()} onClick={onKeep}>
            Save draft
          </button>
        </div>
      </div>
    </section>
  );
}

export function App() {
  const creds = useMemo(() => credentials(), []);
  const [manifest, setManifest] = useState<ReviewManifest>();
  const [events, setEvents] = useState<ReviewEvent[]>([]);
  const [activePath, setActivePath] = useState('');
  const [query, setQuery] = useState('');
  const [layout, setLayout] = useState<'unified' | 'split'>('unified');
  const [wrap, setWrap] = useState(false);
  const [reviewed, setReviewed] = useState<Set<string>>(new Set());
  const [drafts, setDrafts] = useState<LocalDraft[]>([]);
  const [selection, setSelection] = useState<Selection>();
  const [composer, setComposer] = useState<Composer>();
  const [trayOpen, setTrayOpen] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(() => window.innerWidth >= 720);
  const [sidebarMode, setSidebarMode] = useState<'files' | 'guide'>('files');
  const [guideIndex, setGuideIndex] = useState(0);
  const [guideJump, setGuideJump] = useState<GuideJump>();
  const [expandedContext, setExpandedContext] = useState(new Map<string, ContextResult>());
  const [contextBusy, setContextBusy] = useState('');
  const [overlay, setOverlay] = useState<'help' | 'palette'>();
  const [paletteQuery, setPaletteQuery] = useState('');
  const [theme, setTheme] = useState<Theme>(
    () => (localStorage.getItem('read-the-code:theme') as Theme | null) ?? 'system',
  );
  const [characterShortcuts, setCharacterShortcuts] = useState(
    () => localStorage.getItem('read-the-code:character-shortcuts') !== 'false',
  );
  const [wideLayout, setWideLayout] = useState(() => window.innerWidth >= 900);
  const [focusRegion, setFocusRegion] = useState<FocusRegion>('files');
  const [fileCursor, setFileCursor] = useState(0);
  const [lineCursor, setLineCursor] = useState(0);
  const [pendingChord, setPendingChord] = useState('');
  const [busy, setBusy] = useState('');
  const [notice, setNotice] = useState('');
  const [error, setError] = useState('');
  const searchRef = useRef<HTMLInputElement>(null);
  const fileRefs = useRef(new Map<number, HTMLButtonElement>());
  const lineRefs = useRef(new Map<number, HTMLButtonElement>());
  const trayRef = useRef<HTMLButtonElement>(null);
  const diffRef = useRef<HTMLElement>(null);
  const guideRefs = useRef(new Map<number, HTMLButtonElement>());
  const overlayTrigger = useRef<HTMLElement | null>(null);

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
    const prefix = `read-the-code:${manifest.sessionId}`;
    const savedReviewed = JSON.parse(
      localStorage.getItem(`${prefix}:reviewed`) ?? '[]',
    ) as string[];
    const savedDrafts = JSON.parse(
      localStorage.getItem(`${prefix}:drafts`) ?? '[]',
    ) as LocalDraft[];
    setReviewed(
      new Set(savedReviewed.filter((path) => manifest.files.some((file) => file.path === path))),
    );
    setDrafts(
      savedDrafts.filter(
        (draft) => !draft.path || manifest.files.some((file) => file.path === draft.path),
      ),
    );
  }, [manifest]);

  useEffect(() => {
    if (manifest)
      localStorage.setItem(`read-the-code:${manifest.sessionId}:drafts`, JSON.stringify(drafts));
  }, [drafts, manifest]);
  useEffect(() => {
    localStorage.setItem('read-the-code:theme', theme);
    document.documentElement.dataset.themePreference = theme;
    window.dispatchEvent(new CustomEvent('read-the-code-theme'));
  }, [theme]);
  useEffect(() => {
    localStorage.setItem('read-the-code:character-shortcuts', String(characterShortcuts));
  }, [characterShortcuts]);
  useEffect(() => {
    const update = () => setWideLayout(window.innerWidth >= 900);
    window.addEventListener('resize', update);
    return () => window.removeEventListener('resize', update);
  }, []);

  const activeFile = manifest?.files.find((file) => file.path === activePath);
  const filteredFiles =
    manifest?.files.filter((file) =>
      visiblePath(file.path).toLowerCase().includes(query.toLowerCase()),
    ) ?? [];
  const guide = useMemo(() => (manifest ? buildGuide(manifest) : []), [manifest]);
  const guideStops = useMemo(
    () =>
      guide.flatMap((chapter, chapterIndex) =>
        chapter.stops.map((stop) => ({ ...stop, chapterIndex, chapterTitle: chapter.title })),
      ),
    [guide],
  );
  const flatLines = useMemo<FlatLine[]>(
    () =>
      activeFile?.hunks.flatMap((hunk, hunkIndex) =>
        hunk.lines.map((line, index) => ({
          line,
          side: line.kind === 'deletion' ? 'old' : 'new',
          hunk: hunkIndex,
          index,
        })),
      ) ?? [],
    [activeFile],
  );
  const commentCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const event of events)
      if (event.type === 'feedback')
        for (const comment of event.comments)
          if (comment.path) counts.set(comment.path, (counts.get(comment.path) ?? 0) + 1);
    for (const draft of drafts)
      if (draft.path) counts.set(draft.path, (counts.get(draft.path) ?? 0) + 1);
    return counts;
  }, [events, drafts]);
  const readOnly = manifest?.status === 'ended';
  const writable = Boolean(manifest && !manifest.stale && !readOnly);

  const announce = (message: string) => {
    setNotice(message);
    window.setTimeout(() => setNotice((value) => (value === message ? '' : value)), 4000);
  };
  const focusFile = (index: number) => {
    const next = Math.max(0, Math.min(filteredFiles.length - 1, index));
    setFileCursor(next);
    window.requestAnimationFrame(() => fileRefs.current.get(next)?.focus());
  };
  const focusLine = (index: number, extend = false) => {
    if (!flatLines.length) {
      diffRef.current?.focus();
      setFocusRegion('diff');
      return;
    }
    const next = Math.max(0, Math.min(flatLines.length - 1, index));
    setLineCursor(next);
    const item = flatLines[next];
    if (extend && selection && item) selectLine(item.line, item.side, true);
    window.requestAnimationFrame(() => {
      lineRefs.current.get(next)?.focus();
      lineRefs.current.get(next)?.scrollIntoView({ block: 'nearest' });
    });
    if (item) announce(spokenLine(item.line));
  };

  const chooseFile = useCallback((path: string, focusDiff = false) => {
    setActivePath(path);
    setSelection(undefined);
    setComposer(undefined);
    setLineCursor(0);
    if (window.innerWidth < 720) setSidebarOpen(false);
    document.querySelector('.review-main')?.scrollTo({ top: 0 });
    if (focusDiff) window.requestAnimationFrame(() => lineRefs.current.get(0)?.focus());
  }, []);

  useEffect(() => {
    if (!guideJump || activeFile?.path !== guideJump.path) return;
    const index = flatLines.findIndex((line) => line.hunk === guideJump.hunk);
    if (index >= 0) {
      setLineCursor(index);
      window.requestAnimationFrame(() => {
        lineRefs.current.get(index)?.focus();
        lineRefs.current.get(index)?.scrollIntoView({ block: 'nearest' });
      });
    } else diffRef.current?.focus();
    setGuideJump(undefined);
  }, [activeFile, flatLines, guideJump]);

  function selectLine(line: DiffLine, side: CommentSide, extend: boolean): void {
    const lineNumber = side === 'old' ? line.oldLine : line.newLine;
    if (!activeFile || lineNumber === null) return;
    if (extend && selection?.path === activeFile.path && selection.side === side) {
      const start = Math.min(selection.startLine, lineNumber);
      const end = Math.max(selection.endLine, lineNumber);
      const all = activeFile.hunks.flatMap((hunk) => hunk.lines);
      const numberOf = (candidate: DiffLine) =>
        side === 'old' ? candidate.oldLine : candidate.newLine;
      const startLine = all.find((candidate) => numberOf(candidate) === start);
      const endLine = all.find((candidate) => numberOf(candidate) === end);
      if (startLine && endLine)
        setSelection({
          path: activeFile.path,
          side,
          startLine: start,
          endLine: end,
          contextHash: startLine.contextHash,
          endContextHash: endLine.contextHash,
        });
    } else
      setSelection({
        path: activeFile.path,
        side,
        startLine: lineNumber,
        endLine: lineNumber,
        contextHash: line.contextHash,
        endContextHash: line.contextHash,
      });
    announce(`Selected ${side} line ${lineNumber}. Press C to comment or V then J or K to extend.`);
  }

  const openComposer = (scope: Composer['scope'], edit?: LocalDraft) => {
    if (!writable) return;
    if (scope === 'line' && !selection && !edit?.anchor) {
      const item = flatLines[lineCursor];
      if (item) selectLine(item.line, item.side, false);
      else return;
    }
    if (edit?.anchor)
      setSelection({
        path: edit.anchor.path,
        side: edit.anchor.side,
        startLine: edit.anchor.startLine,
        endLine: edit.anchor.endLine,
        contextHash: edit.anchor.contextHash,
        endContextHash: edit.anchor.endContextHash,
      });
    setComposer({ scope, body: edit?.body ?? '', editId: edit?.clientId });
    window.requestAnimationFrame(() =>
      document.querySelector<HTMLTextAreaElement>('.inline-composer textarea')?.focus(),
    );
  };

  const keepDraft = (): void => {
    if (!composer || !manifest) return;
    const existing = drafts.find((draft) => draft.clientId === composer.editId);
    if (composer.body.trim()) {
      const draft: LocalDraft = {
        clientId: existing?.clientId ?? crypto.randomUUID(),
        scope: composer.scope,
        body: composer.body.trim(),
        ...(composer.scope !== 'general' && activeFile
          ? { path: existing?.path ?? activeFile.path }
          : {}),
        ...(composer.scope === 'line' && (existing?.anchor || selection)
          ? {
              anchor: existing?.anchor ?? {
                revision: { baseSha: manifest.baseSha, headSha: manifest.headSha },
                ...selection!,
              },
            }
          : {}),
      };
      setDrafts((current) =>
        existing
          ? current.map((item) => (item.clientId === existing.clientId ? draft : item))
          : [...current, draft],
      );
      announce('Draft saved privately in this browser.');
    }
    setComposer(undefined);
    setSelection(undefined);
    setTrayOpen(true);
    window.requestAnimationFrame(() => {
      const anchor = lineRefs.current.get(lineCursor);
      if (anchor) anchor.focus();
      else trayRef.current?.focus();
    });
  };

  const toggleReviewed = (path = activeFile?.path) => {
    if (!path || !manifest) return;
    const next = new Set(reviewed);
    if (next.has(path)) next.delete(path);
    else next.add(path);
    setReviewed(next);
    localStorage.setItem(`read-the-code:${manifest.sessionId}:reviewed`, JSON.stringify([...next]));
    announce(`${next.size} of ${manifest.files.length} files reviewed.`);
  };

  const nextUnreviewed = () => {
    if (!manifest?.files.length) return;
    const activeIndex = manifest.files.findIndex((file) => file.path === activePath);
    const ordered = [
      ...manifest.files.slice(activeIndex + 1),
      ...manifest.files.slice(0, activeIndex + 1),
    ];
    const next = ordered.find((file) => !reviewed.has(file.path));
    if (next) chooseFile(next.path, true);
    else announce('Every changed file is marked reviewed.');
  };

  const goGuideStop = (index: number) => {
    const next = Math.max(0, Math.min(guideStops.length - 1, index));
    const stop = guideStops[next];
    if (!stop) return;
    setGuideIndex(next);
    setGuideJump({ path: stop.path, hunk: stop.hunk });
    chooseFile(stop.path);
  };

  const returnToGuide = () => {
    setSidebarMode('guide');
    setSidebarOpen(true);
    window.requestAnimationFrame(() => guideRefs.current.get(guideIndex)?.focus());
  };

  const expandContext = async (file: ReviewFile, hunk: number, position: ContextPosition) => {
    if (!creds) return;
    const key = `${file.path}:${hunk}:${position}`;
    const current = expandedContext.get(key)?.lines.length ?? 0;
    const lines = Math.min(200, Math.max(20, current + 20));
    setContextBusy(key);
    try {
      const result = await api<ContextResult>(
        creds,
        `/context?path=${encodeURIComponent(file.path)}&hunk=${hunk}&position=${position}&lines=${lines}`,
      );
      setExpandedContext((values) => new Map(values).set(key, result));
    } catch (reason) {
      setError((reason as Error).message);
    } finally {
      setContextBusy('');
    }
  };

  const submit = async () => {
    if (!creds || !drafts.length) return;
    setBusy('submit');
    setError('');
    try {
      const comments = drafts.map((item) => {
        const draft: CommentDraft = {
          scope: item.scope,
          body: item.body,
          ...(item.path ? { path: item.path } : {}),
          ...(item.anchor ? { anchor: item.anchor } : {}),
        };
        return draft;
      });
      await api(creds, '/feedback', { method: 'POST', body: JSON.stringify({ comments }) });
      setDrafts([]);
      setSelection(undefined);
      announce('Feedback submitted as one durable batch.');
      await refresh();
    } catch (reason) {
      setError((reason as Error).message);
    } finally {
      setBusy('');
    }
  };
  const approve = async () => {
    if (!creds || !manifest || manifest.stale) return;
    if (
      !window.confirm(
        `Approve exactly ${manifest.headSha}?${reviewed.size < manifest.files.length ? ` ${manifest.files.length - reviewed.size} files are not marked reviewed.` : ''}`,
      )
    )
      return;
    setBusy('approve');
    try {
      await api(creds, '/approval', { method: 'POST', body: '{}' });
      announce(`Approved exact head ${shortSha(manifest.headSha)}.`);
      await refresh();
    } catch (reason) {
      setError((reason as Error).message);
    } finally {
      setBusy('');
    }
  };
  const endReview = async () => {
    if (
      !creds ||
      !window.confirm('End this exact review? Recoverable browser drafts will not be submitted.')
    )
      return;
    setBusy('end');
    try {
      await api(creds, '/end', { method: 'POST', body: '{}' });
      announce('Review ended. This exact record is now read-only.');
      await refresh();
    } catch (reason) {
      setError((reason as Error).message);
    } finally {
      setBusy('');
    }
  };

  const closeOverlay = () => {
    setOverlay(undefined);
    window.requestAnimationFrame(() => overlayTrigger.current?.focus());
  };
  const openOverlay = (next: 'help' | 'palette') => {
    overlayTrigger.current = document.activeElement as HTMLElement;
    setPaletteQuery('');
    setOverlay(next);
  };

  // The keyboard listener intentionally rebinds to this render's exact review state.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const runCommand = (command: ReviewCommand) => {
    const activeIndex = manifest?.files.findIndex((file) => file.path === activePath) ?? -1;
    switch (command.id) {
      case 'help':
        openOverlay('help');
        break;
      case 'palette':
        openOverlay('palette');
        break;
      case 'toggle-sidebar':
        setSidebarOpen((open) => {
          const next = !open;
          window.requestAnimationFrame(() => {
            if (next) focusFile(fileCursor);
            else focusLine(lineCursor);
          });
          return next;
        });
        break;
      case 'quick-find':
        setSidebarOpen(true);
        window.requestAnimationFrame(() => searchRef.current?.focus());
        break;
      case 'focus-files':
        setSidebarOpen(true);
        window.requestAnimationFrame(() => focusFile(fileCursor));
        break;
      case 'focus-diff':
        focusLine(lineCursor);
        break;
      case 'focus-review':
        setTrayOpen(true);
        window.requestAnimationFrame(() => trayRef.current?.focus());
        break;
      case 'next-file':
        if (manifest && activeIndex < manifest.files.length - 1)
          chooseFile(manifest.files[activeIndex + 1].path, true);
        break;
      case 'previous-file':
        if (manifest && activeIndex > 0) chooseFile(manifest.files[activeIndex - 1].path, true);
        break;
      case 'toggle-reviewed':
        toggleReviewed();
        break;
      case 'next-unreviewed':
        nextUnreviewed();
        break;
      case 'file-comment':
        openComposer('file');
        break;
      case 'general-comment':
        openComposer('general');
        break;
      case 'row-next':
        if (focusRegion === 'files') focusFile(fileCursor + 1);
        else focusLine(lineCursor + 1, Boolean(selection));
        break;
      case 'row-previous':
        if (focusRegion === 'files') focusFile(fileCursor - 1);
        else focusLine(lineCursor - 1, Boolean(selection));
        break;
      case 'first-item':
        if (focusRegion === 'files') focusFile(0);
        else focusLine(0);
        break;
      case 'last-item':
        if (focusRegion === 'files') focusFile(filteredFiles.length - 1);
        else focusLine(flatLines.length - 1);
        break;
      case 'open-item':
        if (filteredFiles[fileCursor]) chooseFile(filteredFiles[fileCursor].path, true);
        break;
      case 'next-hunk': {
        const current = flatLines[lineCursor]?.hunk ?? 0;
        const next = flatLines.findIndex((item) => item.hunk > current);
        if (next >= 0) focusLine(next);
        break;
      }
      case 'previous-hunk': {
        const current = flatLines[lineCursor]?.hunk ?? 0;
        const previous = flatLines.findIndex((item) => item.hunk === current - 1);
        if (previous >= 0) focusLine(previous);
        break;
      }
      case 'select-line': {
        const item = flatLines[lineCursor];
        if (item) selectLine(item.line, item.side, Boolean(selection));
        break;
      }
      case 'compose-line':
        openComposer('line');
        break;
      case 'view-unified':
        setLayout('unified');
        break;
      case 'view-split':
        if (wideLayout) setLayout('split');
        else announce('Split view is unavailable below 900 pixels.');
        break;
      case 'toggle-wrap':
        setWrap((value) => !value);
        break;
    }
  };

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (
        event.isComposing ||
        event.key === 'Dead' ||
        overlay ||
        composer ||
        isTypingTarget(event.target) ||
        !manifest
      )
        return;
      if (event.key === 'Escape') {
        if (selection) {
          event.preventDefault();
          setSelection(undefined);
          announce('Line selection cleared.');
        } else if (trayOpen) {
          event.preventDefault();
          setTrayOpen(false);
        } else if (sidebarOpen) {
          event.preventDefault();
          setSidebarOpen(false);
        }
        return;
      }
      const stroke = keyStroke(event);
      const sequence = pendingChord ? `${pendingChord} ${stroke.toLowerCase()}` : stroke;
      const scope = focusRegion === 'files' ? 'files' : 'diff';
      const command = commandFor(sequence, scope, {
        characterShortcuts,
        writable,
        activeFile: Boolean(activeFile),
      });
      if (command) {
        event.preventDefault();
        setPendingChord('');
        runCommand(command);
        return;
      }
      if (!pendingChord && ['g', 'a', 'd'].includes(stroke.toLowerCase()) && characterShortcuts) {
        event.preventDefault();
        setPendingChord(stroke.toLowerCase());
        window.setTimeout(() => setPendingChord(''), 1200);
      } else setPendingChord('');
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [
    activeFile,
    characterShortcuts,
    composer,
    focusRegion,
    manifest,
    overlay,
    pendingChord,
    runCommand,
    selection,
    sidebarOpen,
    trayOpen,
    writable,
  ]);

  if (!creds)
    return (
      <main className="gate-state">
        <div className="brand-mark">RC</div>
        <h1>Review capability required</h1>
        <p>Open this review with the authenticated local URL returned by read-the-code-axi.</p>
      </main>
    );
  if (error && !manifest)
    return (
      <main className="gate-state">
        <div className="brand-mark danger">!</div>
        <h1>Couldn’t open this review</h1>
        <p>{error}</p>
      </main>
    );
  if (!manifest)
    return (
      <main className="gate-state" aria-live="polite">
        <div className="loading-ring" />
        <h1>Reading the change set…</h1>
        <p>Loading the exact pinned revision from local session storage.</p>
      </main>
    );
  const approval = events.findLast((event) => event.type === 'approval');

  return (
    <div
      className="app-shell"
      onFocusCapture={(event) => {
        const region = (event.target as HTMLElement).closest<HTMLElement>('[data-region]')?.dataset
          .region as FocusRegion | undefined;
        if (region) setFocusRegion(region);
      }}
    >
      <a className="skip-link" href="#review-diff">
        Skip to diff
      </a>
      <header className="topbar" data-region="revision">
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
        <div
          className="revision-route"
          aria-label={`Review revision ${manifest.baseSha} to ${manifest.headSha}`}
        >
          <span>{manifest.baseRef}</span>
          <code>{shortSha(manifest.baseSha)}</code>
          <i>→</i>
          <span>{manifest.headRef}</span>
          <code>{shortSha(manifest.headSha)}</code>
        </div>
        <div className="top-actions">
          <span className="summary-pills">
            <span>{manifest.summary.files} files</span>
            <span className="plus">+{manifest.summary.additions}</span>
            <span className="minus">−{manifest.summary.deletions}</span>
          </span>
          <select
            name="theme"
            aria-label="Theme"
            value={theme}
            onChange={(event) => setTheme(event.target.value as Theme)}
          >
            <option value="system">System</option>
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
          <button
            onClick={(event) => {
              overlayTrigger.current = event.currentTarget;
              openOverlay('palette');
            }}
            aria-label="Open command palette"
            aria-keyshortcuts={ariaKeyShortcuts('palette')}
          >
            ⌘
          </button>
          <button
            onClick={(event) => {
              overlayTrigger.current = event.currentTarget;
              openOverlay('help');
            }}
            aria-label="Open keyboard help"
            aria-keyshortcuts={ariaKeyShortcuts('help')}
          >
            ?
          </button>
        </div>
      </header>
      {(manifest.stale || readOnly) && (
        <div className={`state-banner ${manifest.stale ? 'warning' : ''}`} role="alert">
          <strong>{manifest.stale ? 'Head ref moved' : 'Review ended'}</strong>
          <span>
            {manifest.stale
              ? `Pinned to ${manifest.headSha}. Open a new exact revision to comment or approve.`
              : 'The exact review record is preserved; new comments and approvals are disabled.'}
          </span>
        </div>
      )}
      <div className={`workspace ${sidebarOpen ? '' : 'sidebar-hidden'}`}>
        <aside
          className={`file-sidebar ${sidebarOpen ? 'open' : 'closed'}`}
          aria-label="Changed files"
          data-region="files"
        >
          <div className="sidebar-heading">
            <div>
              <span className="eyebrow">Change set</span>
              <h2>{sidebarMode === 'files' ? 'Files' : 'Guide'}</h2>
            </div>
            <button
              className="close-sidebar"
              onClick={() => setSidebarOpen(false)}
              aria-label="Close changed files"
            >
              ×
            </button>
          </div>
          <div className="sidebar-tabs" role="tablist" aria-label="Review navigation">
            <button
              role="tab"
              aria-selected={sidebarMode === 'files'}
              onClick={() => setSidebarMode('files')}
            >
              Files
            </button>
            <button
              role="tab"
              aria-selected={sidebarMode === 'guide'}
              onClick={() => setSidebarMode('guide')}
            >
              Guide <span>{guide.length}</span>
            </button>
          </div>
          {sidebarMode === 'files' ? (
            <>
              <label className="search-box">
                <span aria-hidden="true">⌕</span>
                <span className="sr-only">Find changed files</span>
                <input
                  name="file-search"
                  ref={searchRef}
                  value={query}
                  onChange={(event) => {
                    setQuery(event.target.value);
                    setFileCursor(0);
                  }}
                  onKeyDown={(event) => {
                    if (event.nativeEvent.isComposing) return;
                    if (event.key === 'Escape') {
                      event.preventDefault();
                      if (query) setQuery('');
                      else {
                        setSidebarOpen(false);
                        fileRefs.current.get(fileCursor)?.focus();
                      }
                    }
                    if (event.key === 'ArrowDown') {
                      event.preventDefault();
                      focusFile(0);
                    }
                  }}
                  placeholder="Find files  /"
                  aria-keyshortcuts={ariaKeyShortcuts('quick-find')}
                />
                {query && (
                  <button onClick={() => setQuery('')} aria-label="Clear file search">
                    ×
                  </button>
                )}
              </label>
              <div
                className="review-progress"
                aria-label={`${reviewed.size} of ${manifest.files.length} files reviewed`}
              >
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
              <nav className="file-list" aria-label="Changed file list">
                {filteredFiles.map((file, index) => (
                  <div
                    key={file.path}
                    className={`file-row ${file.path === activePath ? 'active' : ''} ${reviewed.has(file.path) ? 'reviewed' : ''}`}
                  >
                    <button
                      ref={(node) => {
                        if (node) fileRefs.current.set(index, node);
                        else fileRefs.current.delete(index);
                      }}
                      tabIndex={index === fileCursor ? 0 : -1}
                      onFocus={() => {
                        setFileCursor(index);
                        setActivePath(file.path);
                      }}
                      onClick={() => chooseFile(file.path, true)}
                      aria-current={file.path === activePath ? 'page' : undefined}
                      aria-label={`${file.status} ${visiblePath(file.path)}${reviewed.has(file.path) ? ', reviewed' : ', not reviewed'}${commentCounts.has(file.path) ? `, ${commentCounts.get(file.path)} comments` : ''}`}
                    >
                      <span className={`status-dot ${file.status}`} aria-hidden="true">
                        {statusLabel(file)}
                      </span>
                      <span className="file-name">{visiblePath(file.path)}</span>
                      {commentCounts.has(file.path) && (
                        <span className="count-badge">{commentCounts.get(file.path)}</span>
                      )}
                    </button>
                    <button
                      className={`review-check ${reviewed.has(file.path) ? 'done' : ''}`}
                      role="checkbox"
                      aria-checked={reviewed.has(file.path)}
                      aria-label={`${reviewed.has(file.path) ? 'Mark unreviewed' : 'Mark reviewed'} ${visiblePath(file.path)}`}
                      onFocus={() => {
                        setFileCursor(index);
                        setActivePath(file.path);
                      }}
                      onClick={() => toggleReviewed(file.path)}
                    >
                      {reviewed.has(file.path) ? '✓' : '○'}
                    </button>
                  </div>
                ))}
                {!filteredFiles.length && <p className="no-files">No files match “{query}”.</p>}
              </nav>
              <div className="keyboard-card">
                <span>
                  <kbd>{commandById('row-next').bindings[0]}</kbd>
                  <kbd>{commandById('row-previous').bindings[0]}</kbd> move
                </span>
                <span>
                  <kbd>{commandById('quick-find').bindings[0]}</kbd> find
                </span>
                <span>
                  <kbd>{commandById('focus-diff').bindings[0]}</kbd> diff
                </span>
              </div>
            </>
          ) : (
            <div className="guide-panel">
              <p className="guide-intro">
                A local reading path generated from this exact revision. It never replaces the raw
                file list.
              </p>
              {guide.map((chapter, chapterIndex) => (
                <section className="guide-chapter" key={chapter.id}>
                  <span className="guide-number">{chapterIndex + 1}</span>
                  <h3>{chapter.title}</h3>
                  <p>{chapter.why}</p>
                  <ol>
                    {chapter.stops.map((stop) => {
                      const index = guideStops.findIndex(
                        (candidate) => candidate.path === stop.path && candidate.hunk === stop.hunk,
                      );
                      return (
                        <li key={`${stop.path}:${stop.hunk}`}>
                          <button
                            ref={(node) => {
                              if (node) guideRefs.current.set(index, node);
                              else guideRefs.current.delete(index);
                            }}
                            className={index === guideIndex ? 'active' : ''}
                            onClick={() => goGuideStop(index)}
                          >
                            {visiblePath(stop.label)}
                          </button>
                        </li>
                      );
                    })}
                  </ol>
                </section>
              ))}
            </div>
          )}
        </aside>
        {sidebarOpen && (
          <button
            className="sidebar-scrim"
            onClick={() => setSidebarOpen(false)}
            aria-label="Close changed files"
          />
        )}
        <main
          ref={diffRef}
          className="review-main"
          id="review-diff"
          tabIndex={-1}
          data-region="diff"
        >
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
                      onClick={() =>
                        wideLayout
                          ? setLayout('split')
                          : announce('Split view is unavailable below 900 pixels.')
                      }
                      aria-pressed={layout === 'split'}
                      aria-disabled={!wideLayout}
                    >
                      Split
                    </button>
                  </div>
                  <button
                    className="secondary-button"
                    onClick={() => openComposer('file')}
                    disabled={!writable}
                    aria-keyshortcuts={ariaKeyShortcuts('file-comment')}
                  >
                    Comment on file
                  </button>
                  <button
                    className={`reviewed-button ${reviewed.has(activeFile.path) ? 'done' : ''}`}
                    onClick={() => toggleReviewed()}
                    aria-keyshortcuts={ariaKeyShortcuts('toggle-reviewed')}
                  >
                    {reviewed.has(activeFile.path) ? '✓ Reviewed' : 'Mark reviewed'}
                  </button>
                  <button
                    className="secondary-button next-unreviewed"
                    onClick={nextUnreviewed}
                    aria-keyshortcuts={ariaKeyShortcuts('next-unreviewed')}
                  >
                    Next unreviewed
                  </button>
                </div>
              </div>
              <div className="diff-meta">
                <span className="plus">+{activeFile.additions}</span>
                <span className="minus">−{activeFile.deletions}</span>
                <span>
                  {activeFile.hunks.length} {activeFile.hunks.length === 1 ? 'hunk' : 'hunks'}
                </span>
                <span className="hint">
                  Click a line to select · Shift-click for a range · C to comment
                </span>
              </div>
              {guideStops.length > 0 && (
                <nav className="guide-nav" aria-label="Guided review controls">
                  <button disabled={guideIndex === 0} onClick={() => goGuideStop(guideIndex - 1)}>
                    ← Previous
                  </button>
                  <button className="guide-location" onClick={returnToGuide}>
                    Guide · {guideStops[guideIndex]?.chapterTitle} · {guideIndex + 1}/
                    {guideStops.length}
                  </button>
                  <button
                    disabled={guideIndex === guideStops.length - 1}
                    onClick={() => goGuideStop(guideIndex + 1)}
                  >
                    Next →
                  </button>
                </nav>
              )}
              {composer && composer.scope !== 'line' && (
                <InlineComposer
                  composer={composer}
                  path={activeFile.path}
                  onChange={(body) => setComposer({ ...composer, body })}
                  onKeep={keepDraft}
                  onClose={keepDraft}
                />
              )}
              <div
                className={`diff-view ${layout} ${wrap ? 'wrap' : ''}`}
                data-testid="diff-view"
                data-region="diff"
                role="listbox"
                aria-label={`Accessible unified diff for ${visiblePath(activeFile.path)}`}
              >
                {!activeFile.hunks.length ? (
                  <div className="file-empty">
                    <span className="empty-icon">
                      {activeFile.binary ? '◈' : activeFile.truncated ? '↯' : '◇'}
                    </span>
                    <h2>
                      {activeFile.binary
                        ? 'Binary file changed'
                        : activeFile.truncated
                          ? 'Diff contained for safety'
                          : 'No textual hunks'}
                    </h2>
                    <p>
                      {activeFile.binary
                        ? 'Binary content is never rendered or executed.'
                        : activeFile.truncated
                          ? 'This file exceeded the per-file patch limit.'
                          : 'Git recorded metadata-only or empty content changes.'}
                    </p>
                  </div>
                ) : (
                  activeFile.hunks.map((hunk, hunkIndex) => (
                    <section
                      className="hunk"
                      key={hunkIndex}
                      aria-label={`Hunk ${hunkIndex + 1} of ${activeFile.hunks.length}`}
                    >
                      <ContextGap
                        file={activeFile}
                        hunk={hunkIndex}
                        position="before"
                        result={expandedContext.get(`${activeFile.path}:${hunkIndex}:before`)}
                        busy={contextBusy === `${activeFile.path}:${hunkIndex}:before`}
                        onExpand={() => expandContext(activeFile, hunkIndex, 'before')}
                      />
                      <div className="hunk-header">{hunk.header}</div>
                      {hunk.lines.map((line, index) => {
                        const side: CommentSide = line.kind === 'deletion' ? 'old' : 'new';
                        const number = side === 'old' ? line.oldLine : line.newLine;
                        const globalIndex = flatLines.findIndex(
                          (item) => item.hunk === hunkIndex && item.index === index,
                        );
                        const selected =
                          selection?.side === side &&
                          selection.path === activeFile.path &&
                          number !== null &&
                          number >= selection.startLine &&
                          number <= selection.endLine;
                        return (
                          <button
                            ref={(node) => {
                              if (node) lineRefs.current.set(globalIndex, node);
                              else lineRefs.current.delete(globalIndex);
                            }}
                            key={`${line.oldLine}-${line.newLine}-${index}`}
                            className={`diff-line ${line.kind}${selected ? ' selected' : ''}`}
                            tabIndex={globalIndex === lineCursor ? 0 : -1}
                            role="option"
                            aria-posinset={globalIndex + 1}
                            aria-setsize={flatLines.length}
                            aria-selected={selected}
                            aria-label={spokenLine(line)}
                            aria-keyshortcuts={ariaKeyShortcuts(
                              'row-next',
                              'row-previous',
                              'next-hunk',
                              'previous-hunk',
                              'select-line',
                              'compose-line',
                            )}
                            data-testid={`line-${side}-${number ?? 'none'}`}
                            onFocus={() => {
                              setLineCursor(globalIndex);
                              setFocusRegion('diff');
                            }}
                            onClick={(event) => selectLine(line, side, event.shiftKey)}
                          >
                            <span className="line-no old" aria-hidden="true">
                              {line.oldLine ?? ''}
                            </span>
                            <span className="line-no new" aria-hidden="true">
                              {line.newLine ?? ''}
                            </span>
                            <span className="line-marker" aria-hidden="true">
                              {line.kind === 'addition'
                                ? '+'
                                : line.kind === 'deletion'
                                  ? '−'
                                  : ' '}
                            </span>
                            <span className="line-code">
                              <span className="sr-only">{line.text}</span>
                              <HighlightedLine text={line.text} path={activeFile.path} />
                            </span>
                            <span className="comment-glyph" aria-hidden="true">
                              +
                            </span>
                          </button>
                        );
                      })}
                      {hunkIndex === activeFile.hunks.length - 1 && (
                        <ContextGap
                          file={activeFile}
                          hunk={hunkIndex}
                          position="after"
                          result={expandedContext.get(`${activeFile.path}:${hunkIndex}:after`)}
                          busy={contextBusy === `${activeFile.path}:${hunkIndex}:after`}
                          onExpand={() => expandContext(activeFile, hunkIndex, 'after')}
                        />
                      )}
                    </section>
                  ))
                )}
              </div>
              {composer?.scope === 'line' && (
                <InlineComposer
                  composer={composer}
                  selection={selection}
                  path={activeFile.path}
                  onChange={(body) => setComposer({ ...composer, body })}
                  onKeep={keepDraft}
                  onClose={keepDraft}
                />
              )}
            </article>
          ) : (
            <div className="file-empty">
              <span className="empty-icon">✓</span>
              <h1>No changed files</h1>
              <p>The two revisions have identical trees.</p>
            </div>
          )}
        </main>
        <aside
          className={`draft-tray ${trayOpen ? 'open' : ''}`}
          aria-label="Review drafts"
          data-region="inspector"
        >
          <button
            ref={trayRef}
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
                        if (draft.path) chooseFile(draft.path);
                        openComposer(draft.scope, draft);
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
              {!drafts.length && (
                <div className="empty-drafts">
                  <span>✦</span>
                  <p>Select a diff line, then press C to comment.</p>
                </div>
              )}
            </div>
            <button
              className="general-button"
              onClick={() => openComposer('general')}
              disabled={!writable}
              aria-keyshortcuts={ariaKeyShortcuts('general-comment')}
            >
              + General comment
            </button>
            <div className="submit-stack">
              <button
                className="primary-button"
                disabled={!drafts.length || Boolean(busy) || !writable}
                onClick={submit}
              >
                {busy === 'submit'
                  ? 'Submitting…'
                  : `Submit feedback${drafts.length ? ` (${drafts.length})` : ''}`}
              </button>
              <button
                className="approve-button"
                disabled={Boolean(busy) || !writable}
                onClick={approve}
              >
                ✓ Approve exact revision
              </button>
              <button
                className="end-button"
                disabled={Boolean(busy) || Boolean(readOnly)}
                onClick={endReview}
              >
                End review
              </button>
            </div>
            <p className="consequence">
              Approval is bound only to <code>{manifest.headSha}</code>. Feedback sends all drafts
              as one durable event.
            </p>
          </div>
        </aside>
      </div>
      {pendingChord && (
        <div className="chord-strip" role="status">
          <kbd>{pendingChord}</kbd> waiting for next key…
        </div>
      )}
      {overlay === 'help' && (
        <Overlay title="Keyboard help" onClose={closeOverlay}>
          <div className="overlay-heading">
            <div>
              <span className="eyebrow">Current region · {focusRegion}</span>
              <h2 tabIndex={0}>Keyboard help</h2>
            </div>
            <button onClick={closeOverlay} aria-label="Close keyboard help">
              ×
            </button>
          </div>
          <label className="preference">
            <input
              name="character-shortcuts"
              type="checkbox"
              checked={characterShortcuts}
              onChange={(event) => setCharacterShortcuts(event.target.checked)}
            />{' '}
            Enable character shortcuts
          </label>
          <div className="command-list">
            {COMMANDS.filter(
              (command) =>
                command.scopes.includes('global') ||
                command.scopes.includes(focusRegion === 'files' ? 'files' : 'diff'),
            ).map((command) => (
              <div key={command.id}>
                <span>{command.label}</span>
                <span>
                  {command.bindings.map((binding) => (
                    <kbd key={binding}>{binding}</kbd>
                  ))}
                </span>
              </div>
            ))}
          </div>
        </Overlay>
      )}
      {overlay === 'palette' && (
        <Overlay title="Command palette" onClose={closeOverlay} initialFocus="input">
          <div className="overlay-heading">
            <div>
              <span className="eyebrow">Every review action</span>
              <h2>Command palette</h2>
            </div>
            <button onClick={closeOverlay} aria-label="Close command palette">
              ×
            </button>
          </div>
          <label className="palette-search">
            <span className="sr-only">Search commands</span>
            <input
              name="command-search"
              value={paletteQuery}
              onChange={(event) => setPaletteQuery(event.target.value)}
              placeholder="Type a command"
            />
          </label>
          <div className="palette-results">
            {COMMANDS.filter((command) =>
              command.label.toLowerCase().includes(paletteQuery.toLowerCase()),
            ).map((command) => (
              <button
                key={command.id}
                onClick={() => {
                  closeOverlay();
                  runCommand(command);
                }}
              >
                <span>
                  <b>{command.label}</b>
                  <small>
                    {command.category}
                    {command.availability === 'writable' && !writable
                      ? ' · unavailable for pinned/read-only review'
                      : ''}
                  </small>
                </span>
                <span>
                  {command.bindings.map((binding) => (
                    <kbd key={binding}>{binding}</kbd>
                  ))}
                </span>
              </button>
            ))}
          </div>
          <div className="palette-review-actions">
            <button
              disabled={!drafts.length || !writable}
              onClick={() => {
                closeOverlay();
                void submit();
              }}
            >
              Submit feedback ({drafts.length})
            </button>
            <button
              disabled={!writable}
              onClick={() => {
                closeOverlay();
                void approve();
              }}
            >
              Approve exact {shortSha(manifest.headSha)}
            </button>
            <button
              disabled={Boolean(readOnly)}
              onClick={() => {
                closeOverlay();
                void endReview();
              }}
            >
              End review
            </button>
          </div>
        </Overlay>
      )}
      {(notice || (error && manifest)) && (
        <div className={`toast ${error ? 'error' : ''}`} role={error ? 'alert' : 'status'}>
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
