# Performance baselines and migration direction

This page records shipped Node/browser characterization. Native RTC-206 containment limits and the explicitly unverified native performance gates are documented in [`native-performance.md`](native-performance.md).

Phase 0 adds reproducible large-review characterization without changing the stable browser, CLI, JSON, or TOON protocol. Run `npm run fixture:large`, build the package, then run `npm run measure:baseline`. Both fixtures live under ignored `.test-state/`; the large fixture defaults to 101 changed files, a 20-level path, and a 5,000-line file.

The Phase 1 baseline measured on 2026-08-09 on Apple Silicon with Node 22.23.1 was 93.20 KB gzip for bundled JavaScript plus CSS. The 101-file/5,000-line fixture opened in 1,685 ms and a subsequent JSON status read took 54 ms. The representative six-file packed browser workflow completed in 1.9 seconds inside Playwright. These are characterization values, not universal pass/fail thresholds; the helper emits a fresh bounded JSON record for the current machine.

Phase 1 intentionally retains the monolithic `GET /api/v1/sessions/:id` response and stable event routes. The approved future direction is additive: a bounded review index, immutable per-file diff responses, compare-and-swap workspace state, and cursor-aware long polling can be added under the existing authenticated `/api/v1` namespace. Removing hunks from the manifest or changing existing CLI/JSON meanings requires a separately reviewed protocol migration.
