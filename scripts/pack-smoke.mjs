import { execFile } from 'node:child_process';
import { access, cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { decode } from '@toon-format/toon';

const exec = promisify(execFile);
const packageJson = JSON.parse(await readFile('package.json', 'utf8'));
const root = await mkdtemp(join(process.cwd(), '.pack-smoke-'));
let binary;
let state;
let sessionId;

async function runCli(...args) {
  return (
    await exec(binary, args, {
      cwd: root,
      env: { ...process.env, READ_THE_CODE_STATE_DIR: state },
      encoding: 'utf8',
    })
  ).stdout.trim();
}

function parseToon(text, label) {
  try {
    return decode(text);
  } catch (error) {
    throw new Error(
      `${label} was not valid TOON: ${error instanceof Error ? error.message : error}`,
    );
  }
}

async function runCliFailure(...args) {
  try {
    await runCli(...args);
  } catch (error) {
    return error;
  }
  throw new Error(`Expected read-the-code-axi ${args.join(' ')} to fail`);
}

try {
  const packOutput = (
    await exec('npm', ['pack', '--json', '--pack-destination', root], { encoding: 'utf8' })
  ).stdout;
  const jsonStart = packOutput.lastIndexOf('\n[\n');
  const packed = JSON.parse(jsonStart >= 0 ? packOutput.slice(jsonStart + 1) : packOutput);
  const tarball = join(root, packed[0].filename);
  const packedPaths = new Set(packed[0].files.map((file) => file.path));
  if (!packedPaths.has('skills/read-the-code/SKILL.md')) {
    throw new Error('Packed product is missing the canonical agent skill');
  }
  if (!packedPaths.has('skills/read-the-code/agents/openai.yaml')) {
    throw new Error('Packed product is missing agent skill metadata');
  }

  const install = join(root, 'install');
  await mkdir(install);
  await writeFile(join(install, 'package.json'), '{"private":true}\n');
  await exec('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund', tarball], {
    cwd: install,
    encoding: 'utf8',
  });
  binary = join(install, 'node_modules', '.bin', 'read-the-code-axi');
  const { stdout } = await exec(binary, ['--version'], { cwd: install, encoding: 'utf8' });
  if (stdout.trim() !== packageJson.version) {
    throw new Error(`Unexpected packed CLI version: ${stdout.trim()}`);
  }
  state = join(root, 'state');
  const home = parseToon(await runCli(), 'no-argument home view');
  if (
    home.description === undefined ||
    !Array.isArray(home.sessions) ||
    !Array.isArray(home.help)
  ) {
    throw new Error('Packed no-argument home view is missing AXI content, empty state, or help');
  }

  const packagedSkill = join(install, 'node_modules', packageJson.name, 'skills', 'read-the-code');
  const discoveredSkill = join(install, '.agents', 'skills', 'read-the-code');
  await mkdir(join(install, '.agents', 'skills'), { recursive: true });
  await cp(packagedSkill, discoveredSkill, { recursive: true });
  const discovered = await readFile(join(discoveredSkill, 'SKILL.md'), 'utf8');
  if (!/^---\nname: read-the-code\n/mu.test(discovered)) {
    throw new Error('Packed skill was not discoverable after standard-path installation');
  }

  const fixtureOutput = (
    await exec(
      process.execPath,
      [join(process.cwd(), 'scripts', 'create-fixture.mjs'), join(root, 'fixture')],
      {
        encoding: 'utf8',
      },
    )
  ).stdout;
  const fixture = JSON.parse(fixtureOutput);
  await exec('git', ['-C', fixture.repository, 'branch', 'review-head', fixture.head]);
  const toonOpen = parseToon(
    await runCli(
      'open',
      '--repo',
      fixture.repository,
      '--base',
      fixture.base,
      '--head',
      'review-head',
      '--no-browser',
    ),
    'default open',
  );
  if (toonOpen.state !== 'open' || toonOpen.browser !== 'not launched (--no-browser)') {
    throw new Error('Packed default open did not return the compact AXI view');
  }

  const opened = JSON.parse(
    await runCli(
      'open',
      '--repo',
      fixture.repository,
      '--base',
      fixture.base,
      '--head',
      'review-head',
      '--no-browser',
      '--json',
    ),
  );
  sessionId = opened.sessionId;
  if (
    opened.schemaVersion !== 1 ||
    opened.baseSha !== fixture.base ||
    opened.headSha !== fixture.head
  ) {
    throw new Error('Packed open did not preserve the exact requested revision');
  }
  const capabilityUrl = new URL(opened.browserUrl);
  const [, route, urlSession, capability] = capabilityUrl.hash.slice(1).split('/');
  if (route !== 'review' || urlSession !== sessionId || !capability) {
    throw new Error('Packed open returned an invalid local review capability');
  }
  const api = async (action, init = {}) =>
    fetch(`${capabilityUrl.origin}/api/v1/sessions/${sessionId}/${action}`, {
      ...init,
      headers: {
        Authorization: `Bearer ${capability}`,
        Origin: capabilityUrl.origin,
        ...(init.body ? { 'Content-Type': 'application/json' } : {}),
      },
    });

  const initialStatus = JSON.parse(await runCli('status', sessionId, '--json'));
  if (initialStatus.stale || initialStatus.lastSequence !== 0) {
    throw new Error('New packed review did not start at an exact empty cursor');
  }
  const toonStatus = parseToon(await runCli('status', sessionId), 'default status');
  if (toonStatus.state !== 'open' || toonStatus.cursor !== 0 || !Array.isArray(toonStatus.help)) {
    throw new Error('Packed default status did not return summary aggregates and contextual help');
  }
  const waiting = parseToon(
    await runCli('poll', sessionId, '--after', '0', '--timeout', '0ms'),
    'default timeout poll',
  );
  if (waiting.state !== 'waiting' || waiting.nextCursor !== 0 || waiting.events.length !== 0) {
    throw new Error('Packed default poll did not distinguish a successful timeout');
  }

  const feedbackResponse = await api('feedback', {
    method: 'POST',
    body: JSON.stringify({
      comments: Array.from({ length: 21 }, (_, index) => ({
        scope: 'general',
        body:
          index === 0
            ? `${'Long, hostile 世界 comment\\n'.repeat(10)}tail`
            : `Please verify comment ${index}, 世界.`,
      })),
    }),
  });
  if (feedbackResponse.status !== 201) throw new Error('Packed review rejected feedback');
  const toonFeedback = parseToon(
    await runCli('poll', sessionId, '--after', '0', '--timeout', '1s'),
    'default feedback poll',
  );
  if (
    toonFeedback.state !== 'feedback' ||
    toonFeedback.comments.length !== 20 ||
    !toonFeedback.truncation?.includes('20 of 21') ||
    !toonFeedback.comments[0].body.includes('truncated,')
  ) {
    throw new Error('Packed default poll did not bound and identify hostile feedback content');
  }
  const feedbackPoll = JSON.parse(
    await runCli('poll', sessionId, '--after', '0', '--timeout', '1s', '--json'),
  );
  if (
    feedbackPoll.nextCursor !== 1 ||
    feedbackPoll.events.length !== 1 ||
    feedbackPoll.events[0].type !== 'feedback' ||
    feedbackPoll.events[0].comments.length !== 21
  ) {
    throw new Error('Packed feedback poll did not preserve cursor sequence 1');
  }

  const approvalResponse = await api('approval', { method: 'POST', body: '{}' });
  if (approvalResponse.status !== 201)
    throw new Error('Packed review rejected exact-head approval');
  const approvalPoll = JSON.parse(
    await runCli('poll', sessionId, '--after', '1', '--timeout', '1s', '--json'),
  );
  const approval = approvalPoll.events[0];
  if (
    approvalPoll.nextCursor !== 2 ||
    approval?.type !== 'approval' ||
    approval.approvedHeadSha !== fixture.head ||
    approval.headSha !== fixture.head
  ) {
    throw new Error('Packed approval was not bound to the exact head at cursor 2');
  }

  await exec('git', ['-C', fixture.repository, 'branch', '-f', 'review-head', fixture.base]);
  const staleStatus = JSON.parse(await runCli('status', sessionId, '--json'));
  if (!staleStatus.stale || !staleStatus.approvalStale) {
    throw new Error('Packed status did not invalidate approval after the head moved');
  }
  const staleApprovalView = parseToon(
    await runCli('poll', sessionId, '--after', '1', '--timeout', '0ms'),
    'default stale approval poll',
  );
  if (staleApprovalView.state !== 'approval-stale') {
    throw new Error('Packed default poll did not distinguish stale approval');
  }
  const staleApproval = await api('approval', { method: 'POST', body: '{}' });
  const staleError = await staleApproval.json();
  if (staleApproval.status !== 409 || staleError.error?.code !== 'STALE_REVISION') {
    throw new Error('Packed review did not reject approval of a stale head');
  }

  const toonEnd = parseToon(await runCli('end', sessionId), 'default end');
  if (toonEnd.state !== 'ended' || toonEnd.sequence !== 3 || !Array.isArray(toonEnd.help)) {
    throw new Error('Packed default end did not return its durable outcome and next step');
  }
  const ended = JSON.parse(await runCli('end', sessionId, '--json'));
  if (ended.status !== 'ended' || ended.event?.type !== 'end' || ended.event?.sequence !== 3) {
    throw new Error('Packed end did not append the expected durable event');
  }
  const toonEndPoll = parseToon(
    await runCli('poll', sessionId, '--after', '2', '--timeout', '0ms'),
    'default ended poll',
  );
  if (toonEndPoll.state !== 'ended' || toonEndPoll.events[0]?.type !== 'end') {
    throw new Error('Packed default poll did not distinguish ended review');
  }
  const endPoll = JSON.parse(
    await runCli('poll', sessionId, '--after', '2', '--timeout', '1s', '--json'),
  );
  if (endPoll.nextCursor !== 3 || endPoll.events[0]?.type !== 'end') {
    throw new Error('Packed poll did not return the durable end event');
  }

  const exportedText = await runCli('export', sessionId, '--json');
  const exported = JSON.parse(exportedText);
  if (exported.events.map((event) => event.sequence).join(',') !== '1,2,3') {
    throw new Error('Packed export did not preserve the complete event sequence');
  }
  if (
    exportedText.includes(capability) ||
    exportedText.includes(opened.browserUrl) ||
    exportedText.includes(fixture.repository)
  ) {
    throw new Error('Packed export exposed a capability or absolute repository path');
  }

  const toonExportText = await runCli('export', sessionId);
  const toonExport = parseToon(toonExportText, 'default export');
  if (
    toonExport.events.length !== 3 ||
    toonExport.comments.length !== 20 ||
    !toonExport.commentTruncation
  ) {
    throw new Error('Packed default export did not provide bounded review aggregates');
  }
  const fullExport = parseToon(await runCli('export', sessionId, '--full'), 'full TOON export');
  if (fullExport.events.length !== 3 || fullExport.events[0].comments.length !== 21) {
    throw new Error('Packed full TOON export did not preserve the complete typed record');
  }
  const defaultBytes = Buffer.byteLength(toonExportText);
  const jsonBytes = Buffer.byteLength(exportedText);
  if (defaultBytes >= jsonBytes * 0.9) {
    throw new Error(
      `Packed TOON export did not meaningfully reduce output (${defaultBytes} vs ${jsonBytes} bytes)`,
    );
  }

  const invalidSession = await runCliFailure('status', 'not-a-session');
  const defaultError = parseToon(invalidSession.stdout.trim(), 'default structured error');
  if (invalidSession.code !== 2 || defaultError.error?.code !== 'INVALID_SESSION') {
    throw new Error('Packed default errors were not structured with the documented exit category');
  }
  const invalidFlag = await runCliFailure('status', sessionId, '--invented');
  const flagError = parseToon(invalidFlag.stdout.trim(), 'unknown-flag error');
  if (invalidFlag.code !== 2 || flagError.error?.code !== 'UNKNOWN_ARGUMENT') {
    throw new Error('Packed unknown flags did not fail loudly with exit code 2');
  }
  const jsonError = await runCliFailure('status', 'not-a-session', '--json');
  const parsedJsonError = JSON.parse(jsonError.stderr.trim());
  if (jsonError.code !== 2 || parsedJsonError.schemaVersion !== 1 || !parsedJsonError.error?.code) {
    throw new Error('Packed JSON errors were not kept schema-compatible');
  }

  process.stdout.write(
    `packed AXI lifecycle smoke passed (${packed[0].filename}; TOON ${defaultBytes} B vs JSON ${jsonBytes} B, ${Math.round((1 - defaultBytes / jsonBytes) * 100)}% smaller)\n`,
  );
} finally {
  if (binary && state && sessionId) await runCli('end', sessionId, '--json').catch(() => undefined);
  await new Promise((resolveDelay) => setTimeout(resolveDelay, 1_000));
  await access(root)
    .then(() => rm(root, { recursive: true, force: true }))
    .catch(() => undefined);
}
