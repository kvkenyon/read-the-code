import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const usage =
  'usage: node scripts/native-release/generate-sbom.mjs [--out <path> | --validate-only]';
const args = process.argv.slice(2);
let outputPath;
let validateOnly = false;

for (let index = 0; index < args.length; index += 1) {
  if (args[index] === '--validate-only') validateOnly = true;
  else if (args[index] === '--out' && args[index + 1]) {
    outputPath = args[index + 1];
    index += 1;
  } else throw new Error(usage);
}

if (validateOnly && outputPath) throw new Error(usage);

const root = process.cwd();
const resolved = JSON.parse(await readFile(resolve(root, 'native/Package.resolved'), 'utf8'));
const licenses = JSON.parse(
  await readFile(resolve(root, 'native/Packaging/licenses.json'), 'utf8'),
);
if (licenses.schemaVersion !== 1 || !licenses.packages || Array.isArray(licenses.packages)) {
  throw new Error('native/Packaging/licenses.json must contain schemaVersion 1 and a package map');
}

const packages = [...resolved.pins]
  .sort((left, right) => left.identity.localeCompare(right.identity))
  .map((pin) => {
    const license = licenses.packages[pin.identity];
    if (typeof license !== 'string' || !/^[A-Za-z0-9.+-]+$/.test(license))
      throw new Error(`missing or invalid declared license for ${pin.identity}`);
    if (pin.kind !== 'remoteSourceControl' || !pin.location.startsWith('https://'))
      throw new Error(`unsupported package source for ${pin.identity}`);
    if (!/^[0-9a-f]{40}$/.test(pin.state.revision) || typeof pin.state.version !== 'string')
      throw new Error(`package ${pin.identity} must be pinned to a revision and version`);
    return {
      SPDXID: `SPDXRef-Package-${pin.identity.replace(/[^A-Za-z0-9.-]/g, '-')}`,
      name: pin.identity,
      versionInfo: pin.state.version,
      downloadLocation: pin.location,
      licenseConcluded: license,
      licenseDeclared: license,
      checksums: [{ algorithm: 'SHA1', checksumValue: pin.state.revision }],
    };
  });

for (const identity of Object.keys(licenses.packages)) {
  if (!packages.some((pkg) => pkg.name === identity))
    throw new Error(`license declaration has no resolved package: ${identity}`);
}

const sbom = {
  spdxVersion: 'SPDX-2.3',
  dataLicense: 'CC0-1.0',
  SPDXID: 'SPDXRef-DOCUMENT',
  name: 'ReadTheCodeNative-dependencies',
  documentNamespace: 'https://sbom.invalid/read-the-code/native/dependencies',
  creationInfo: { creators: ['Tool: scripts/native-release/generate-sbom.mjs'] },
  packages,
};

if (validateOnly) console.log(`Validated ${packages.length} pinned native dependency licenses.`);
else if (outputPath) {
  await writeFile(resolve(root, outputPath), `${JSON.stringify(sbom, null, 2)}\n`);
  console.log(`Wrote SBOM to ${outputPath}.`);
} else console.log(`${JSON.stringify(sbom, null, 2)}\n`);
