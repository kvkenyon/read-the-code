export type FocusRegion = 'revision' | 'files' | 'diff' | 'inspector' | 'composer';
export type CommandScope = 'global' | 'files' | 'diff' | 'composer';

export interface ReviewCommand {
  id: string;
  label: string;
  category: 'Navigate' | 'Comment' | 'View' | 'Review';
  bindings: string[];
  scopes: CommandScope[];
  focusResult?: FocusRegion;
  characterShortcut?: boolean;
  availability?: 'always' | 'active-file' | 'writable';
}

export const COMMANDS: readonly ReviewCommand[] = [
  { id: 'help', label: 'Keyboard help', category: 'View', bindings: ['?'], scopes: ['global'] },
  {
    id: 'palette',
    label: 'Command palette',
    category: 'View',
    bindings: ['Mod+K'],
    scopes: ['global'],
  },
  {
    id: 'toggle-sidebar',
    label: 'Toggle changed files sidebar',
    category: 'View',
    bindings: ['Mod+B'],
    scopes: ['global'],
  },
  {
    id: 'quick-find',
    label: 'Find changed files',
    category: 'Navigate',
    bindings: ['/'],
    scopes: ['global'],
    focusResult: 'files',
  },
  {
    id: 'focus-files',
    label: 'Focus changed files',
    category: 'Navigate',
    bindings: ['g f'],
    scopes: ['global'],
    focusResult: 'files',
  },
  {
    id: 'focus-diff',
    label: 'Focus diff',
    category: 'Navigate',
    bindings: ['g d'],
    scopes: ['global'],
    focusResult: 'diff',
    availability: 'active-file',
  },
  {
    id: 'focus-review',
    label: 'Open review drafts',
    category: 'Navigate',
    bindings: ['g r'],
    scopes: ['global'],
    focusResult: 'inspector',
  },
  {
    id: 'next-file',
    label: 'Next changed file',
    category: 'Navigate',
    bindings: ['Shift+J'],
    scopes: ['global'],
    focusResult: 'diff',
    availability: 'active-file',
  },
  {
    id: 'previous-file',
    label: 'Previous changed file',
    category: 'Navigate',
    bindings: ['Shift+K'],
    scopes: ['global'],
    focusResult: 'diff',
    availability: 'active-file',
  },
  {
    id: 'toggle-reviewed',
    label: 'Toggle reviewed',
    category: 'Review',
    bindings: ['m'],
    scopes: ['global'],
    availability: 'active-file',
    characterShortcut: true,
  },
  {
    id: 'next-unreviewed',
    label: 'Next unreviewed file',
    category: 'Review',
    bindings: [']'],
    scopes: ['global'],
    focusResult: 'diff',
    availability: 'active-file',
    characterShortcut: true,
  },
  {
    id: 'file-comment',
    label: 'Add file comment',
    category: 'Comment',
    bindings: ['a f'],
    scopes: ['global'],
    focusResult: 'composer',
    availability: 'writable',
  },
  {
    id: 'general-comment',
    label: 'Add general comment',
    category: 'Comment',
    bindings: ['a g'],
    scopes: ['global'],
    focusResult: 'composer',
    availability: 'writable',
  },
  {
    id: 'row-next',
    label: 'Next item',
    category: 'Navigate',
    bindings: ['j', 'ArrowDown'],
    scopes: ['files', 'diff'],
    characterShortcut: true,
  },
  {
    id: 'row-previous',
    label: 'Previous item',
    category: 'Navigate',
    bindings: ['k', 'ArrowUp'],
    scopes: ['files', 'diff'],
    characterShortcut: true,
  },
  {
    id: 'first-item',
    label: 'First item',
    category: 'Navigate',
    bindings: ['Home', 'g g'],
    scopes: ['files', 'diff'],
  },
  {
    id: 'last-item',
    label: 'Last item',
    category: 'Navigate',
    bindings: ['End', 'Shift+G'],
    scopes: ['files', 'diff'],
  },
  {
    id: 'open-item',
    label: 'Open focused item',
    category: 'Navigate',
    bindings: ['Enter'],
    scopes: ['files'],
    focusResult: 'diff',
  },
  {
    id: 'next-hunk',
    label: 'Next hunk',
    category: 'Navigate',
    bindings: ['n'],
    scopes: ['diff'],
    characterShortcut: true,
  },
  {
    id: 'previous-hunk',
    label: 'Previous hunk',
    category: 'Navigate',
    bindings: ['p'],
    scopes: ['diff'],
    characterShortcut: true,
  },
  {
    id: 'select-line',
    label: 'Start or extend line selection',
    category: 'Comment',
    bindings: ['v'],
    scopes: ['diff'],
    characterShortcut: true,
    availability: 'writable',
  },
  {
    id: 'compose-line',
    label: 'Comment on selected line or range',
    category: 'Comment',
    bindings: ['c', 'Enter'],
    scopes: ['diff'],
    focusResult: 'composer',
    characterShortcut: true,
    availability: 'writable',
  },
  {
    id: 'view-unified',
    label: 'Use unified diff',
    category: 'View',
    bindings: ['d u'],
    scopes: ['global'],
  },
  {
    id: 'view-split',
    label: 'Use split diff',
    category: 'View',
    bindings: ['d s'],
    scopes: ['global'],
  },
  {
    id: 'toggle-wrap',
    label: 'Wrap long lines',
    category: 'View',
    bindings: ['d w'],
    scopes: ['global'],
  },
];

export function keyStroke(event: Pick<KeyboardEvent, 'key' | 'metaKey' | 'ctrlKey' | 'shiftKey'>) {
  if ((event.metaKey || event.ctrlKey) && event.key.length === 1)
    return `Mod+${event.key.toUpperCase()}`;
  if (event.shiftKey && event.key.length === 1) return `Shift+${event.key.toUpperCase()}`;
  return event.key;
}

export function commandById(id: string): ReviewCommand {
  const command = COMMANDS.find((candidate) => candidate.id === id);
  if (!command) throw new Error(`Unknown review command: ${id}`);
  return command;
}

export function ariaKeyShortcuts(...ids: string[]): string {
  return ids
    .flatMap((id) => commandById(id).bindings)
    .flatMap((binding) =>
      binding.startsWith('Mod+')
        ? [`Meta+${binding.slice(4)}`, `Control+${binding.slice(4)}`]
        : [binding],
    )
    .join(' ');
}

export function commandFor(
  sequence: string,
  scope: Exclude<CommandScope, 'composer'>,
  options: { characterShortcuts: boolean; writable: boolean; activeFile: boolean },
): ReviewCommand | undefined {
  return COMMANDS.find((command) => {
    if (!command.bindings.includes(sequence)) return false;
    if (!command.scopes.includes('global') && !command.scopes.includes(scope)) return false;
    if (
      !options.characterShortcuts &&
      (sequence.length === 1 || sequence.startsWith('Shift+') || sequence.includes(' '))
    )
      return false;
    if (command.availability === 'writable' && !options.writable) return false;
    if (command.availability === 'active-file' && !options.activeFile) return false;
    return true;
  });
}

export function isTypingTarget(target: EventTarget | null): boolean {
  return (
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    target instanceof HTMLSelectElement ||
    (target instanceof HTMLElement && target.isContentEditable)
  );
}
