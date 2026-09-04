# RTCGit fixtures

The RTC-101 corpus is derived from the canonical `tests/git.test.ts` fixture:
rename/copy/delete/add/binary files, hostile newline/tab/HTML names, dirty
working trees, symlink roots, SHA-256 repositories, and the 1 MiB/8 MiB/2,000
file caps. Tests construct repositories under temporary directories so no
fixture writes occur in a reviewed repository.

## Exact-tree materialization benchmark

Run `native/Fixtures/Git/run-benchmark.sh` from any directory. It creates the
RTC-301 101-file/5,000-line repository in a private temporary directory, builds
RTCGit with release optimization, performs two warm-ups and 20 measured
materializations by default, and prints one schema-versioned JSON record. The
measurement starts after exact revision resolution and ends with the complete
diff manifest. Environment variables can change the iteration counts:

- `RTC_GIT_BENCHMARK_WARMUPS`
- `RTC_GIT_BENCHMARK_ITERATIONS`
- `RTC_GIT_ENFORCE_REFERENCE_BUDGET=1` to enforce the 2,000 ms p95 wall budget
  on a machine explicitly standing in for the reference host

The 2,000 ms wall gate applies automatically only on the stated reference
hardware, an Apple M1 Mac with 16 GiB RAM. Other hosts report but do not enforce
wall time. Every host enforces at most 110 Git processes per iteration, the
stable structural regression gate for the measured cause.

### RTC-301 causal record (2026-09-03)

Measurements used an Apple M5 MacBook Pro with 24 GiB RAM, macOS 26.1,
Swift 6.2.1, Apple Git 2.50.1, release builds, two warm-ups, and 20 iterations.
Variance is population variance in ms².

| implementation                                    |   p50 ms |   p95 ms | variance ms² | Git processes/iteration |
| ------------------------------------------------- | -------: | -------: | -----------: | ----------------------: |
| original per-file reads                           | 7,226.99 | 8,926.56 |   326,962.87 |                     611 |
| batched metadata/blob counterfactual              | 1,516.96 | 1,555.46 |       590.26 |                     109 |
| rebased batched reads plus four-patch concurrency | 1,299.24 | 1,428.05 |     5,466.70 |                     109 |

The earliest representative-path divergence was process amplification after
the single name-status read: each of 101 files launched two size reads, one
numstat, one patch, and two content reads. Each original iteration contained
404 `cat-file`, 102 metadata `diff`, 101 patch `diff`, and four `rev-parse`
processes. Across the original 20 measured runs, those 12,220 launches
accumulated about 140.3 seconds inside Git while wall time totaled about 148.1
seconds. The roughly 5.3% residual covered Swift parsing, allocation, line
counting, and context hashing, so those were not the first-order divergence.
The source audit also found no working-tree reads or repository-content
execution: patch parsing and hashes consume only bounded Git output. The new
blob reader caps each retained batch at 4 MB, and patch concurrency is fixed at
four.

Batching size/content reads and numstats was the smallest counterfactual; its
83% p95 reduction confirms launch volume as the leading cause. The hypothesis
would have been disproved if reducing launches from 611 to 109 had left latency
materially unchanged.

The same final build on the ordinary six-file fixture measured p50 111.18 ms,
p95 116.70 ms, and variance 7.53 ms². The existing Node baseline method was
also run five times on this checkout and representative fixture: p50 3,680 ms,
p95 3,788 ms, variance 4,970.56 ms² (Node 22.23.1). The shipped historical Node
reference remains 1,685 ms on its recorded Apple Silicon host; build cache,
host generation, fixture path depth, and current-checkout changes make these
cross-run values characterization rather than a replacement baseline.
