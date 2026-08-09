import { execFile } from 'node:child_process';
import { access, readFile, readdir } from 'node:fs/promises';
import { dirname, extname, join, relative, resolve } from 'node:path';
import { promisify } from 'node:util';

const exec = promisify(execFile);
const repository = process.cwd();
const skillDirectory = join(repository, 'skills', 'read-the-code');
const skillPath = join(skillDirectory, 'SKILL.md');
const cli = join(repository, 'dist', 'cli.js');
const publicCommands = ['open', 'status', 'poll', 'export', 'end'];

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function markdownFiles(directory) {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) result.push(...(await markdownFiles(path)));
    else if (extname(entry.name) === '.md') result.push(path);
  }
  return result;
}

function parseFrontmatter(markdown) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n/u.exec(markdown);
  assert(match, 'SKILL.md must begin with YAML frontmatter');
  const fields = {};
  for (const line of match[1].split(/\r?\n/u)) {
    if (!line.trim() || line.trimStart().startsWith('#')) continue;
    const field = /^([a-z][a-z0-9_-]*):\s*(.+)$/u.exec(line);
    assert(field, `Unsupported SKILL.md frontmatter line: ${line}`);
    assert(!(field[1] in fields), `Duplicate SKILL.md frontmatter field: ${field[1]}`);
    let value = field[2].trim();
    if (value.startsWith('"')) value = JSON.parse(value);
    else if (value.startsWith("'") && value.endsWith("'")) value = value.slice(1, -1);
    fields[field[1]] = value;
  }
  return fields;
}

function flags(help) {
  return new Set(help.match(/--[a-z][a-z0-9-]*/gu) ?? []);
}

function codeSamples(markdown) {
  const samples = [];
  for (const match of markdown.matchAll(/```[^\n]*\n([\s\S]*?)```/gu)) samples.push(match[1]);
  for (const match of markdown.matchAll(/`([^`\n]*read-the-code-axi[^`\n]*)`/gu)) {
    samples.push(match[1]);
  }
  return samples;
}

async function verifyLinks(path, markdown) {
  for (const match of markdown.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/gu)) {
    let target = match[1].trim().replace(/^<|>$/gu, '');
    target = target.split(/\s+["']/u, 1)[0];
    if (/^https:\/\//u.test(target)) {
      new URL(target);
      continue;
    }
    assert(
      !/^[a-z]+:/iu.test(target),
      `Unsupported link protocol in ${relative(repository, path)}`,
    );
    const local = decodeURIComponent(target.split('#', 1)[0]);
    if (local) await access(resolve(dirname(path), local));
  }
}

const skill = await readFile(skillPath, 'utf8');
const frontmatter = parseFrontmatter(skill);
assert(
  Object.keys(frontmatter).sort().join(',') === 'description,name',
  'Portable skill frontmatter must contain exactly name and description',
);
assert(frontmatter.name === 'read-the-code', 'Skill name must match its directory');
assert(
  typeof frontmatter.description === 'string' && frontmatter.description.length >= 80,
  'Skill description must explain both capability and trigger',
);

const rootHelp = (await exec(process.execPath, [cli, '--help'], { encoding: 'utf8' })).stdout;
const rootFlags = flags(rootHelp);
const helpByCommand = new Map();
for (const command of publicCommands) {
  assert(new RegExp(`^  ${command}(?: |$)`, 'mu').test(rootHelp), `CLI help is missing ${command}`);
  const help = (await exec(process.execPath, [cli, command, '--help'], { encoding: 'utf8' }))
    .stdout;
  helpByCommand.set(command, flags(help));
}
const allCliFlags = new Set([
  ...rootFlags,
  ...[...helpByCommand.values()].flatMap((commandFlags) => [...commandFlags]),
]);

const markdownPaths = await markdownFiles(repository);
const seenSkillCommands = new Set();
for (const path of markdownPaths) {
  const markdown = await readFile(path, 'utf8');
  await verifyLinks(path, markdown);
  assert(
    !/#\/review\/[a-f0-9]{24}\/[A-Za-z0-9_-]{16,}/u.test(markdown),
    `Secret-bearing review URL example in ${relative(repository, path)}`,
  );
  assert(
    !/Bearer\s+[A-Za-z0-9_-]{16,}/u.test(markdown),
    `Secret-bearing token example in ${relative(repository, path)}`,
  );
  for (const inline of markdown.matchAll(/`(--[^`\n]+)`/gu)) {
    for (const flag of inline[1].match(/--[a-z][a-z0-9-]*/gu) ?? []) {
      assert(allCliFlags.has(flag), `Unknown CLI flag documented: ${flag}`);
    }
  }

  for (const sample of codeSamples(markdown)) {
    const logical = sample.replace(/\\\r?\n\s*/gu, ' ');
    for (const line of logical.split(/\r?\n/u)) {
      const invocation = /read-the-code-axi\s+([a-z][a-z0-9-]*|--[a-z][a-z0-9-]*)/u.exec(line);
      if (!invocation) continue;
      const command = invocation[1].startsWith('--') ? undefined : invocation[1];
      if (command) {
        assert(publicCommands.includes(command), `Stale CLI command documented: ${command}`);
        if (path === skillPath) seenSkillCommands.add(command);
      }
      const available = command ? helpByCommand.get(command) : rootFlags;
      for (const flag of line.match(/--[a-z][a-z0-9-]*/gu) ?? []) {
        assert(available.has(flag), `Unknown ${command ?? 'root'} flag documented: ${flag}`);
      }
    }
  }
}

assert(
  publicCommands.every((command) => seenSkillCommands.has(command)),
  'SKILL.md must document the complete open/status/poll/export/end lifecycle',
);

const metadata = await readFile(join(skillDirectory, 'agents', 'openai.yaml'), 'utf8');
assert(
  /display_name:\s*['"]Read the Code['"]/u.test(metadata),
  'Agent metadata display name is stale',
);
assert(
  /default_prompt:\s*['"][^'"\n]*\$read-the-code[^'"\n]*['"]/u.test(metadata),
  'Agent metadata prompt must invoke $read-the-code',
);

process.stdout.write('agent skill validation passed\n');
