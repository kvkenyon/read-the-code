# Contributing

Thanks for helping make local code review calmer and safer.

## Setup

Use Node.js 20.12+ and Git. Install with `npm install`, then run `npm run check`. The full browser flow is `npm run test:e2e`; Playwright needs a Chromium browser (`npx playwright install chromium` on a new machine). `npm run fixture` creates a disposable example under the ignored `.test-state` directory.

Before opening a pull request:

1. Keep the server loopback-only and preserve the browser/CLI typed contract.
2. Add focused tests for protocol, lifecycle, security, or rendering changes.
3. Run `npm run check` and `npm run test:e2e`.
4. Describe user-visible behavior and any schema compatibility impact.

Do not add telemetry, external runtime assets, hosted dependencies, repository writes, shell-based Git invocation, or arbitrary filesystem APIs. New runtime dependencies should be narrowly scoped, maintained, and justified against a standard-library or existing-dependency solution.

Formatting is enforced with Prettier, linting with ESLint, types with TypeScript, unit/integration tests with Vitest, and real-browser tests with Playwright. The tarball smoke test ensures changes work after packaging, not just in the checkout.

By participating, you agree that your contributions are licensed under the MIT License.
