import { execFile } from 'node:child_process';
import { access, cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';

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
  state = join(root, 'state');

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

  const feedbackResponse = await api('feedback', {
    method: 'POST',
    body: JSON.stringify({
      comments: [{ scope: 'general', body: 'Please verify the exact diff.' }],
    }),
  });
  if (feedbackResponse.status !== 201) throw new Error('Packed review rejected feedback');
  const feedbackPoll = JSON.parse(
    await runCli('poll', sessionId, '--after', '0', '--timeout', '1s', '--json'),
  );
  if (
    feedbackPoll.nextCursor !== 1 ||
    feedbackPoll.events.length !== 1 ||
    feedbackPoll.events[0].type !== 'feedback'
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
  const staleApproval = await api('approval', { method: 'POST', body: '{}' });
  const staleError = await staleApproval.json();
  if (staleApproval.status !== 409 || staleError.error?.code !== 'STALE_REVISION') {
    throw new Error('Packed review did not reject approval of a stale head');
  }

  const ended = JSON.parse(await runCli('end', sessionId, '--json'));
  if (ended.status !== 'ended' || ended.event?.type !== 'end' || ended.event?.sequence !== 3) {
    throw new Error('Packed end did not append the expected durable event');
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

  process.stdout.write(`packed skill and lifecycle smoke passed (${packed[0].filename})\n`);
} finally {
  if (binary && state && sessionId) await runCli('end', sessionId, '--json').catch(() => undefined);
  await new Promise((resolveDelay) => setTimeout(resolveDelay, 1_000));
  await access(root)
    .then(() => rm(root, { recursive: true, force: true }))
    .catch(() => undefined);
}
