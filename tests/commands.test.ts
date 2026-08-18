import { describe, expect, it } from 'vitest';
import { ariaKeyShortcuts, COMMANDS, commandFor } from '../src/ui/commands';

const enabled = { characterShortcuts: true, writable: true, activeFile: true };

describe('review command registry', () => {
  it('defines scope, availability, focus result, and unique ids for every command', () => {
    expect(new Set(COMMANDS.map((command) => command.id)).size).toBe(COMMANDS.length);
    for (const command of COMMANDS) {
      expect(command.scopes.length).toBeGreaterThan(0);
      expect(command.bindings.length).toBeGreaterThan(0);
      expect(command.availability ?? 'always').toMatch(/always|active-file|writable/u);
      if (command.id.startsWith('focus-') || command.id.includes('comment'))
        expect(command.focusResult).toBeTruthy();
    }
  });

  it('resolves bindings only in their declared focus scope', () => {
    expect(commandFor('j', 'files', enabled)?.id).toBe('row-next');
    expect(commandFor('j', 'diff', enabled)?.id).toBe('row-next');
    expect(commandFor('n', 'files', enabled)).toBeUndefined();
    expect(commandFor('n', 'diff', enabled)?.id).toBe('next-hunk');
  });

  it('removes character commands when the preference disables them', () => {
    expect(commandFor('j', 'diff', { ...enabled, characterShortcuts: false })).toBeUndefined();
    expect(commandFor('ArrowDown', 'diff', { ...enabled, characterShortcuts: false })?.id).toBe(
      'row-next',
    );
    expect(commandFor(':', 'diff', enabled)).toBeUndefined();
    expect(commandFor('Mod+K', 'diff', { ...enabled, characterShortcuts: false })?.id).toBe(
      'palette',
    );
  });

  it('omits unavailable commands for stale/read-only or empty reviews', () => {
    expect(commandFor('a g', 'diff', { ...enabled, writable: false })).toBeUndefined();
    expect(commandFor('g d', 'files', { ...enabled, activeFile: false })).toBeUndefined();
  });

  it('derives accessibility shortcut metadata from the same bindings', () => {
    expect(ariaKeyShortcuts('palette')).toBe('Meta+K Control+K');
    expect(ariaKeyShortcuts('toggle-sidebar')).toBe('Meta+B Control+B');
    expect(ariaKeyShortcuts('row-next', 'row-previous')).toContain('ArrowDown');
  });
});
