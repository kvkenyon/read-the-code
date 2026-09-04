import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const expectedDependencies = {
  ReadTheCode: [
    'RTCAgentChat',
    'RTCContracts',
    'RTCDesign',
    'RTCDiffCanvas',
    'RTCExport',
    'RTCGit',
    'RTCInboxFeature',
    'RTCIngest',
    'RTCDomain',
    'RTCIPC',
    'RTCLifecycle',
    'RTCReview',
    'RTCReviewWorkspace',
    'RTCSettings',
    'RTCStore',
    'RTCTourIntegration',
    'RTCWorkspaceShell',
    'TourWorkspace',
  ],
  rtc: ['RTCCLI'],
  GitWorker: ['RTCContracts', 'RTCGit'],
  ModelWorker: ['RTCContracts', 'RTCModelAdapters'],
  RTCContracts: [],
  RTCDomain: ['RTCContracts'],
  RTCStore: ['GRDB', 'RTCContracts'],
  RTCIPC: ['RTCContracts'],
  RTCGit: ['RTCContracts'],
  RTCSyntax: ['RTCContracts'],
  RTCDiffCanvas: ['RTCContracts'],
  RTCDiagram: ['RTCContracts'],
  RTCTour: ['RTCContracts', 'RTCDiagram'],
  RTCTourIntegration: [
    'GRDB',
    'RTCContracts',
    'RTCDiagram',
    'RTCGit',
    'RTCModelAdapters',
    'RTCStore',
    'RTCSyntax',
    'RTCTour',
  ],
  TourWorkspace: ['RTCContracts', 'RTCDesign', 'RTCDiagram', 'RTCTourIntegration'],
  RTCModelAdapters: ['RTCContracts'],
  RTCAgentChat: ['RTCContracts', 'RTCIPC'],
  RTCReview: ['RTCContracts', 'RTCDomain'],
  RTCDesign: [],
  RTCLifecycle: ['RTCContracts'],
  RTCSettings: ['RTCContracts', 'RTCModelAdapters', 'RTCLifecycle'],
  RTCIngest: ['GRDB', 'RTCContracts', 'RTCGit', 'RTCIPC', 'RTCLifecycle', 'RTCStore'],
  RTCInboxFeature: ['RTCContracts', 'RTCDesign', 'RTCIngest'],
  RTCWorkspaceShell: ['RTCAgentChat', 'RTCContracts', 'RTCDesign'],
  RTCExport: ['RTCContracts', 'RTCDiagram', 'RTCIPC', 'RTCReview', 'RTCTour'],
  RTCReviewWorkspace: [
    'RTCContracts',
    'RTCDiffCanvas',
    'RTCDesign',
    'RTCDomain',
    'RTCReview',
    'RTCSyntax',
    'RTCWorkspaceShell',
  ],
  RTCCLI: ['RTCContracts', 'RTCGit', 'RTCIngest', 'RTCIPC'],
  RTCTestSupport: ['RTCContracts'],
  RTCAgentChatTests: ['RTCAgentChat', 'RTCContracts'],
  RTCDesignTests: ['RTCDesign'],
  RTCGitTests: ['RTCContracts', 'RTCGit'],
  RTCModelAdapterTests: ['RTCContracts', 'RTCModelAdapters'],
  RTCStoreTests: ['RTCStore'],
  RTCWorkspaceShellTests: ['RTCWorkspaceShell'],
  RTCSettingsTests: ['RTCSettings'],
  RTCCLITests: ['RTCCLI'],
  RTCContractTests: ['RTCContracts', 'RTCTestSupport'],
  RTCDiagramTests: ['RTCContracts', 'RTCDiagram'],
  RTCDiffCanvasTests: ['RTCContracts', 'RTCDiffCanvas'],
  RTCDomainTests: ['RTCContracts', 'RTCDomain'],
  RTCExportTests: ['RTCContracts', 'RTCExport', 'RTCIPC', 'RTCReview'],
  RTCIPCTests: ['RTCContracts', 'RTCIPC'],
  RTCAgentChatSmokeTests: ['RTCAgentChat', 'RTCContracts', 'RTCIPC', 'RTCStore'],
  RTCLifecycleTests: ['RTCContracts', 'RTCLifecycle'],
  RTCReviewTests: ['RTCContracts', 'RTCDomain', 'RTCReview'],
  RTCReviewPersistenceTests: ['RTCContracts', 'RTCDomain', 'RTCReview', 'RTCStore'],
  RTCSyntaxTests: ['RTCContracts', 'RTCSyntax'],
  RTCTourTests: ['RTCContracts', 'RTCTour'],
  RTCIngestTests: [
    'RTCCLI',
    'RTCContracts',
    'RTCGit',
    'RTCIngest',
    'RTCIPC',
    'RTCLifecycle',
    'RTCStore',
  ],
  RTCInboxFeatureTests: ['RTCContracts', 'RTCInboxFeature', 'RTCIngest'],
  TourWorkspaceFeatureTests: [
    'RTCContracts',
    'RTCDiagram',
    'RTCModelAdapters',
    'RTCStore',
    'RTCSyntax',
    'RTCTour',
    'RTCTourIntegration',
    'TourWorkspace',
  ],
  RTCReviewWorkspaceFeatureTests: [
    'RTCContracts',
    'RTCDiffCanvas',
    'RTCDomain',
    'RTCReview',
    'RTCReviewWorkspace',
  ],
};

function fail(message) {
  throw new Error(message);
}

function sorted(values) {
  return [...values].sort();
}

function targetBlock(name, project) {
  const lines = project.split('\n');
  const start = lines.indexOf(`  ${name}:`);
  if (start < 0) return undefined;
  let end = start + 1;
  while (
    end < lines.length &&
    (!lines[end].startsWith('  ') || lines[end].startsWith('    ') || !lines[end].endsWith(':'))
  ) {
    end += 1;
  }
  return lines.slice(start, end).join('\n');
}

function projectDependencies(block) {
  return block
    .split('\n')
    .map((line) => line.trim())
    .flatMap((line) => {
      for (const prefix of ['- target: ', '- package: ']) {
        if (line.startsWith(prefix)) return [line.slice(prefix.length)];
      }
      return [];
    });
}

function projectType(block) {
  return block
    .split('\n')
    .map((line) => line.trim())
    .find((line) => line.startsWith('type: '))
    ?.slice('type: '.length);
}

const packageDescription = JSON.parse(
  execFileSync('/usr/bin/swift', ['package', '--package-path', 'native', 'dump-package'], {
    cwd: repositoryRoot,
    encoding: 'utf8',
  }),
);
const packageTargets = new Map(packageDescription.targets.map((target) => [target.name, target]));
const project = fs.readFileSync(path.join(repositoryRoot, 'native/project.yml'), 'utf8');

for (const [name, expected] of Object.entries(expectedDependencies)) {
  const packageTarget = packageTargets.get(name);
  if (!packageTarget) fail(`SwiftPM is missing target ${name}`);
  const packageDependencies = packageTarget.dependencies.flatMap((dependency) => {
    if (dependency.byName) return [dependency.byName[0]];
    if (dependency.product) return [dependency.product[0]];
    return [];
  });
  if (JSON.stringify(sorted(packageDependencies)) !== JSON.stringify(sorted(expected))) {
    fail(`SwiftPM dependencies for ${name} are ${packageDependencies}; expected ${expected}`);
  }

  const block = targetBlock(name, project);
  if (!block) fail(`XcodeGen is missing target ${name}`);
  const xcodeDependencies = projectDependencies(block);
  if (JSON.stringify(sorted(xcodeDependencies)) !== JSON.stringify(sorted(expected))) {
    fail(`XcodeGen dependencies for ${name} are ${xcodeDependencies}; expected ${expected}`);
  }
}

for (const worker of ['GitWorker', 'ModelWorker']) {
  if (packageTargets.get(worker).type !== 'regular') {
    fail(`SwiftPM target ${worker} must remain a source-only library target`);
  }
  if (projectType(targetBlock(worker, project)) !== 'framework') {
    fail(`XcodeGen target ${worker} must remain a source-only framework target`);
  }
}

for (const root of ['Sources', 'Tests']) {
  const directory = path.join(repositoryRoot, 'native', root);
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    if (!packageTargets.has(entry.name)) fail(`SwiftPM is missing native/${root}/${entry.name}`);
    if (!targetBlock(entry.name, project)) {
      fail(`XcodeGen is missing native/${root}/${entry.name}`);
    }
  }
}

for (const [directory, packageType, xcodeType] of [
  ['RTCAgentChatTests', 'test', 'bundle.unit-test'],
  ['RTCDesignTests', 'test', 'bundle.unit-test'],
  ['RTCGitTests', 'test', 'bundle.unit-test'],
  ['RTCModelAdapterTests', 'test', 'bundle.unit-test'],
  ['RTCStoreTests', 'test', 'bundle.unit-test'],
  ['RTCWorkspaceShellTests', 'test', 'bundle.unit-test'],
  ['RTCSettingsTests', 'test', 'bundle.unit-test'],
  ['RTCCLITests', 'executable', 'tool'],
  ['RTCContractTests', 'executable', 'tool'],
  ['RTCDiagramTests', 'executable', 'tool'],
  ['RTCDiffCanvasTests', 'executable', 'tool'],
  ['RTCDomainTests', 'executable', 'tool'],
  ['RTCExportTests', 'executable', 'tool'],
  ['RTCIPCTests', 'executable', 'tool'],
  ['RTCAgentChatSmokeTests', 'executable', 'tool'],
  ['RTCLifecycleTests', 'executable', 'tool'],
  ['RTCReviewTests', 'executable', 'tool'],
  ['RTCReviewPersistenceTests', 'executable', 'tool'],
  ['RTCSyntaxTests', 'executable', 'tool'],
  ['RTCTourTests', 'executable', 'tool'],
  ['RTCIngestTests', 'executable', 'tool'],
  ['RTCInboxFeatureTests', 'executable', 'tool'],
  ['TourWorkspaceFeatureTests', 'executable', 'tool'],
  ['RTCReviewWorkspaceFeatureTests', 'executable', 'tool'],
]) {
  const source = fs
    .readdirSync(path.join(repositoryRoot, 'native/Tests', directory))
    .filter((file) => file.endsWith('.swift'))
    .map((file) =>
      fs.readFileSync(path.join(repositoryRoot, 'native/Tests', directory, file), 'utf8'),
    )
    .join('\n');
  if (packageType === 'test' && !source.includes('XCTestCase')) {
    fail(`${directory} must remain an XCTest suite`);
  }
  if (packageType === 'executable' && !source.includes('@main')) {
    fail(`${directory} must remain an executable smoke suite`);
  }
  if (packageTargets.get(directory).type !== packageType) {
    fail(`SwiftPM target ${directory} must be ${packageType}`);
  }
  if (projectType(targetBlock(directory, project)) !== xcodeType) {
    fail(`XcodeGen target ${directory} must be ${xcodeType}`);
  }
}

for (const sourcePath of [
  'App/ReadTheCodeApp',
  'CLI/rtc/main.swift',
  'CLI/rtc/RTCCLI.swift',
  'Services/GitWorker',
  'Services/ModelWorker',
]) {
  if (!project.includes(sourcePath)) fail(`XcodeGen is missing native/${sourcePath}`);
}

console.log('Native manifest checks passed.');
