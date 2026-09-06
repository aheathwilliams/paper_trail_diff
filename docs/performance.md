# Reporting performance

The gem's original purpose is to make batch reports practical without naive
per-record queries and reification. Both database round trips and repeated Ruby
reconstruction are therefore design concerns. A small SQL query count alone
does not establish that a batch API meets that purpose.

The benchmark exercises `analyze_scope` with genuine PaperTrail history. It is
a local SQLite baseline for finding work inside the gem, not a production
latency guarantee or a comparison of SQL dialects.

## Reproduce

From a repository checkout:

```console
mise exec -- bundle install
mise exec -- bundle exec ruby benchmark/reporting.rb --output /tmp/reporting.json
mise exec -- bundle exec ruby benchmark/reporting.rb --case no_matches --size 1000 --samples 3
```

The default run takes three samples of each population size below. Each sample
starts a fresh Ruby process and creates its own in-memory SQLite database. It
does not use `PAPER_TRAIL_DIFF_DATABASE_URL` or an application's database. Setup,
seeding, and the initial garbage collection are excluded from report timing.
The measured call runs without the ActiveRecord query cache. Successful calls
validate the selected root count; the refusal scenario must raise
`BatchLimitExceededError`.

Each article has a title, status, and 1 KiB body, using PaperTrail's default YAML
serializer. Except for the long-history case, each has one create and five update
versions. The window includes all seeded versions and uses `close_on: :current`.
There are no associations. The fixture has an `(item_type, item_id)` version
index; a different schema, serializer, database, or graph needs its own run.

| Scenario | Population | Selection and output |
| --- | --- | --- |
| `many_roots` | 100 / 500 roots | Default analysis, including checkpoint timelines |
| `retained_activity` | 100 / 500 roots | Adds `activity: true, snapshots: true` |
| `long_history` | One root, 1,000 / 5,000 updates | Default analysis |
| `sparse_matches` | 100 / 1,000 roots | Historical status matches one root in every 100 |
| `no_matches` | 100 / 1,000 roots | Historical status matches no recorded state |
| `limit_refusal` | 100 / 1,000 roots | Every non-nil historical state matches; `limit: 5` refuses the sixth root |

## Baseline: 2026-09-06

The library was unchanged at revision
`389ad896fbc2ef5942c6ba34b605a1eb0b3f397c`. Environment: Ruby 4.0.1,
ActiveRecord 8.1.3.1, PaperTrail 17.0.0, SQLite 3.53.2, Linux x86-64 on WSL2
(`6.18.33.2-microsoft-standard-WSL2`), AMD Ryzen 7 7800X3D, about 15.5 GiB
WSL system memory. No test suite or app server ran alongside the final
samples. This is a developer workstation, not an isolated benchmark host.

The [raw samples](../benchmark/results/reporting-2026-09-06.json) include runtime
versions, allocations, SQL duration, query-cache hits, record instantiation,
reification counts, and memory readings. Times below are medians of three fresh
processes; the range is the minimum–maximum. Query and instantiation counts were identical across each set of three samples.
Reify counts are medians: one 100-root retained-activity sample made 599 calls
instead of 600; the cause of that small variation was not established. These
internal counts are observations, not API guarantees. SQL time is included in
total time.

| Scenario | Size | Total ms (range) | SQL ms | Queries | Reify calls | AR records instantiated |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `many_roots` | 100 | 304.5 (301.1–328.6) | 3.9 | 6 | 1,200 | 800 |
| `many_roots` | 500 | 1,463.0 (1,460.8–1,824.8) | 16.8 | 6 | 6,000 | 4,000 |
| `retained_activity` | 100 | 302.3 (272.2–354.1) | 4.3 | 6 | 600 | 800 |
| `retained_activity` | 500 | 1,452.3 (1,371.7–1,520.6) | 16.3 | 6 | 3,000 | 4,000 |
| `long_history` | 1,000 | 505.5 (463.3–550.7) | 4.7 | 6 | 2,002 | 1,003 |
| `long_history` | 5,000 | 2,414.5 (2,334.5–3,077.6) | 19.2 | 6 | 10,002 | 5,003 |
| `sparse_matches` | 100 | 113.1 (95.2–114.1) | 3.6 | 7 | 608 | 608 |
| `sparse_matches` | 1,000 | 1,043.1 (830.1–1,213.0) | 36.1 | 10 | 6,080 | 6,080 |
| `no_matches` | 100 | 103.3 (99.9–109.5) | 3.6 | 2 | 600 | 600 |
| `no_matches` | 1,000 | 878.4 (822.3–922.5) | 32.0 | 5 | 6,000 | 6,000 |
| `limit_refusal` | 100 | 7.1 (7.0–7.7) | 2.7 | 2 | 12 | 600 |
| `limit_refusal` | 1,000 | 17.7 (17.5–17.9) | 8.6 | 2 | 12 | 1,500 |

Memory medians (MiB; 1 MiB = 1,048,576 bytes):

| Scenario | Size | Retained Ruby | RSS before | RSS after |
| --- | ---: | ---: | ---: | ---: |
| `many_roots` | 100 | 3.04 | 70.8 | 108.1 |
| `many_roots` | 500 | 15.09 | 74.6 | 136.2 |
| `retained_activity` | 100 | 4.18 | 70.5 | 99.4 |
| `retained_activity` | 500 | 20.75 | 75.0 | 160.8 |
| `long_history` | 1,000 | 4.06 | 71.8 | 116.9 |
| `long_history` | 5,000 | 20.11 | 78.3 | 166.2 |
| `sparse_matches` | 100 | 0.07 | 70.9 | 91.9 |
| `sparse_matches` | 1,000 | 0.34 | 80.7 | 165.1 |
| `no_matches` | 100 | 0.01 | 70.4 | 91.6 |
| `no_matches` | 1,000 | 0.01 | 81.0 | 164.8 |
| `limit_refusal` | 100 | 0.01 | 70.9 | 71.4 |
| `limit_refusal` | 1,000 | 0.01 | 81.0 | 81.2 |

### What memory readings mean

Retained Ruby memory is the change in `ObjectSpace.memsize_of_all` after a full
GC while the result (or expected error) remains reachable. It includes lazily
initialized library state, not just result objects, and excludes native
allocations. RSS is whole-process resident memory before and immediately after
the report, before the final GC. It includes Ruby, libraries, and the in-memory
SQLite database. The raw process high-water RSS also includes startup and seeding;
it is not an isolated peak for the report. RSS fields are unavailable off Linux.
The measurements should not be interpreted as exact per-request memory budgets.

## Findings and next optimization targets

1. **Reconstruction deserves attention before query-count tuning.** Default
   analysis keeps the same query count as population/history grows, but reifies
   each version twice in these fixtures. The retained-activity path makes
   approximately half as many calls. Investigate sharing reconstruction between endpoint and checkpoint
   analysis, preserving immutable results, ordering, and association semantics.
   Fewer reifications can offset the extra work of retained activity; do not
   assume that enabling activity always makes a report slower.
2. **A small result does not mean a cheap historical predicate.** Nonmatching
   candidates require all their recorded states to be tried. A 1,000-root empty
   result still reifies 6,000 versions. A matched-root `limit:` cannot cap that
   work. Do not present arbitrary `historical_filter:` predicates as an efficient
   large-report path in their current form. Evaluate whether a constrained
   attribute predicate can use bulk-loaded immutable state instead of creating
   an ActiveRecord object per version. Any retained arbitrary callback needs an
   explicit work budget or clearly restricted use. A background job can move the
   delay out of a request, but does not fix the reconstruction cost.
   Do not replace historical selection with current-state
   filtering merely to make it faster: that changes which roots qualify.
3. **The safety ceiling stops reification before it stops batch loading.** With
   `limit: 5`, refusal takes 12 reify calls: the nil create and first update state
   for each of six roots. At 1,000 candidates, 1,500 version records have already
   been instantiated for the first 250-root batch. Investigate smaller or streamed
   candidate loading if this is a memory problem in an application's workload.
   Changes must preserve match-before-limit semantics and deterministic selection.
4. **Retained snapshots have a measurable memory cost.** Request them when the
   consumer needs historical context. Many roots and long histories increase
   retained data even when database round trips stay flat. Measure explicitly
   requested associations next; this root-only baseline cannot characterize
   their additional queries or reconstruction cost.
5. **The test app's deleted-history fallback is an N+1 pattern.** Its
   `DeletedArticleHistory#call` loops over missing identities, selects each
   destroy version, calls `reify`, and then calls `activity_timeline` separately.
   Its 25-root cap limits exposure but does not make the approach batched.
   This path is outside the measurements above and should not become the
   recommended reporting recipe. A gem-level batch operation should load missing
   roots and their histories together and return structured deletion/unavailable
   results, so callers do not rebuild this loop themselves.

Before adding a higher-level reporting facade, address duplicate reconstruction
and deleted-root batching, then decide whether to redesign or restrict historical
predicates. Verify both query growth and reification growth over representative
populations. Linear work to produce requested output can be necessary; repeated
reconstruction of the same state and scanning thousands of states for an empty
report should not be accepted merely because SQL round trips are bounded.

The Rails test app now makes its missing-closing-boundary demonstration opt-in.
Previously that example reran selection on every report request, including
historical predicates. Its regression test checks that a normal historical report
selects candidates once. No gem runtime optimization is included with this
baseline; it provides a repeatable comparison for a subsequent focused change.

Do not enforce these workstation timings as CI thresholds. Re-run matching
workloads before and after an optimization, compare structural counts as well
as timing and memory, and validate the existing correctness suites separately.
