import { describe, expect, it } from 'vitest';
import { buildGuide } from '../src/ui/guide';
import type { ReviewManifest } from '../src/protocol';

describe('deterministic review guide', () => {
  it('orders contracts, behavior, experience, and proof while retaining real hunk targets', () => {
    const file = (path: string) => ({
      path,
      status: 'modified' as const,
      additions: 2,
      deletions: 1,
      binary: false,
      truncated: false,
      hunks: [{ header: '@@', oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: [] }],
    });
    const manifest = {
      files: [
        file('tests/app.test.ts'),
        file('src/ui/App.tsx'),
        file('src/core/server.ts'),
        file('src/protocol.ts'),
      ],
    } as unknown as ReviewManifest;
    const guide = buildGuide(manifest);
    expect(guide.map((chapter) => chapter.id)).toEqual([
      'foundation',
      'behavior',
      'experience',
      'proof',
    ]);
    expect(guide.flatMap((chapter) => chapter.stops).map((stop) => stop.path)).toEqual([
      'src/protocol.ts',
      'src/core/server.ts',
      'src/ui/App.tsx',
      'tests/app.test.ts',
    ]);
  });
});
