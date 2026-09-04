# Security policy

The compiled native source boundaries, native export allowlist, and diagnostic preview/confirmation behavior are documented in [`docs/native-security.md`](docs/native-security.md). Those source checks are not evidence of a signed or notarized native release.

Please report a suspected vulnerability privately through GitHub's security advisory feature rather than a public issue. Include the affected version, operating system, reproduction steps, and expected impact when possible.

Read the Code processes adversarial repository names, filenames, patches, and comments. Security-sensitive changes should cover capability checks, loopback/Host/Origin restrictions, Git argument handling, path and symlink behavior, HTML injection, size limits, persistence races, or secret-free exports with regression tests.

The authenticated browser URL is a bearer capability. Do not include it in screenshots, issue reports, terminal transcripts, or exported review records.
