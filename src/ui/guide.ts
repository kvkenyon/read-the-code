import type { ReviewFile, ReviewManifest } from '../protocol';

export interface GuideStop {
  path: string;
  hunk: number;
  label: string;
}

export interface GuideChapter {
  id: string;
  title: string;
  why: string;
  stops: GuideStop[];
}

type ChapterKind = 'foundation' | 'behavior' | 'experience' | 'proof';

function chapterKind(file: ReviewFile): ChapterKind {
  const path = file.path.toLowerCase();
  if (/(^|\/)(protocol|schema|types?|models?|domain)([./_-]|$)/u.test(path)) return 'foundation';
  if (/(^|\/)(test|tests|spec|specs|__tests__)(\/|$)|\.(test|spec)\./u.test(path)) return 'proof';
  if (/\.(md|mdx|rst|txt)$/u.test(path) || /(^|\/)(docs?|examples?|fixtures?)(\/|$)/u.test(path))
    return 'proof';
  if (/(^|\/)(ui|views?|components?|pages?|styles?|assets?)(\/|$)|\.(css|scss|html)$/u.test(path))
    return 'experience';
  return 'behavior';
}

const chapterCopy: Record<ChapterKind, { title: string; why: string }> = {
  foundation: {
    title: 'Contracts & foundations',
    why: 'Start with the shapes and invariants the rest of the change relies on. These hunks define what downstream behavior is allowed to assume.',
  },
  behavior: {
    title: 'Core behavior',
    why: 'Follow the main execution path next. Read these hunks as the implementation of the contracts, before looking at presentation or proof.',
  },
  experience: {
    title: 'Reviewer experience',
    why: 'See how the behavior reaches the person using the product. These hunks cover interaction, navigation, and visual consequences.',
  },
  proof: {
    title: 'Proof & explanation',
    why: 'Finish with tests, fixtures, and documentation. They show the intended guarantees, boundary cases, and the public story of the change.',
  },
};

export function buildGuide(manifest: ReviewManifest): GuideChapter[] {
  const groups = new Map<ChapterKind, ReviewFile[]>();
  for (const file of manifest.files.filter((candidate) => candidate.hunks.length > 0)) {
    const kind = chapterKind(file);
    groups.set(kind, [...(groups.get(kind) ?? []), file]);
  }
  return (['foundation', 'behavior', 'experience', 'proof'] as const).flatMap((kind) => {
    const files = groups.get(kind) ?? [];
    if (!files.length) return [];
    const stops = files.flatMap((file) =>
      file.hunks.map((_, hunk) => ({
        path: file.path,
        hunk,
        label: `${file.path} · hunk ${hunk + 1}`,
      })),
    );
    const additions = files.reduce((sum, file) => sum + file.additions, 0);
    const deletions = files.reduce((sum, file) => sum + file.deletions, 0);
    return [
      {
        id: kind,
        title: chapterCopy[kind].title,
        why: `${chapterCopy[kind].why} ${files.length} ${files.length === 1 ? 'file' : 'files'}, ${stops.length} ${stops.length === 1 ? 'stop' : 'stops'}, +${additions}/−${deletions}.`,
        stops,
      },
    ];
  });
}
