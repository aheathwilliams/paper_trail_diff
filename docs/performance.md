# Reporting performance

The gem's original purpose is to make batch reports practical without naive
per-record queries and reification. Both database round trips and repeated Ruby
reconstruction are therefore design concerns. A small SQL query count alone
does not establish that a batch API meets that purpose.

The [follow-up reconstruction investigation](reconstruction-investigation.md)
records the pre-fix N+1 paths and direct-snapshot experiments. Production now uses
prepared event successors even without changesets, and directly normalizes plain
root/direct-child states. Scoped and collection-source through batch paths require
`allow_expensive: true`; that opt-in can still cause N+1 work. Model callbacks,
custom types and callable predicates also remain outside a flat-query guarantee.

The benchmark exercises `analyze_scope` with genuine PaperTrail history. It is
a local SQLite baseline for finding work inside the gem, not a production
latency guarantee or a comparison of SQL dialects.

## Direct reconstruction follow-up: 2026-09-07

Implementation: `1b6b1b9`, followed by belongs-to discovery fix `f6a4ae2`.
[Raw measurements](https://github.com/aheathwilliams/paper_trail_diff/blob/c799d0e/benchmark/results/direct-reconstruction-2026-09-07.json)
include all samples, typed parity checks and query origins. Timing runs overlapped
development checks, so they do not establish a controlled speedup.

| Probe | SQL at 1 / 5 / 20 roots | Historical reify / prepared-instance calls |
| --- | --- | --- |
| Scalar activity | 6 / 6 / 6 | 0 / 0 |
| Direct comments activity | 12 / 12 / 12 | 0 / 0 |
| Comments without changesets | 12 / 12 / 12 | 0 / 0 |
| Direct comments checkpoints | 10 / 10 / 10 | 0 / 0 |
| Belongs-to activity | 9 / 9 / 9 | 0 / 0 |

Live records and version rows still instantiate when loaded in batches. Zero
historical instances does not mean zero allocation or constant total CPU cost.
The missing-changeset case previously used 15 / 27 / 72 queries. Limited,
owner-scoped, default-scoped and collection-source through paths now refuse
before report SQL by default. With explicit opt-in, the five-root through probe
used 199 queries and 75 reify calls, but no unrelated authorship loads.

Three diagnostic samples at 500 roots had median 742.3 ms for checkpoints and
1,365.5 ms for retained activity; each used six SQL queries and zero reifications.
One root with 5,000 updates had median 1,154.2 ms and zero reifications. Retained
Ruby memory was about 15.0, 20.8 and 19.9 MiB respectively. These timings do not
establish a retained-activity improvement.

A querying initialization callback still produced 10 / 26 / 86 queries, and a
querying historical predicate produced 8 / 12 / 27. Custom behavior, polymorphic
or advanced graph reconstruction, and non-leaf activity fallbacks may still
instantiate historical records. There is no blanket no-N+1 guarantee.

Production parity matches PaperTrail for STI, enum, decimal, date, boolean, JSON
and serialized values, including missing fields supplied by callbacks/default
scopes through the compatibility fallback. From a repository checkout (benchmark
scripts are not included in the installed gem), reproduce these checks with:

```console
PTD_PRODUCTION=1 mise exec -- bundle exec ruby benchmark/investigation/scalar_parity.rb
mise exec -- bundle exec ruby benchmark/investigation/reconstruction.rb comments_without_changes 20
PTD_PROBE_ALLOW_EXPENSIVE=1 mise exec -- bundle exec ruby benchmark/investigation/reconstruction.rb through_has_many 5
```

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
versions; `deleted_roots` adds a destroy event. The window includes all seeded
versions and uses `close_on: :current`.
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
| `attribute_no_matches` | 100 / 1,000 roots | Attribute hash matches no recorded state, without candidate reification |
| `attribute_sparse_matches` | 100 / 1,000 roots | Attribute hash matches one root in every 100 |
| `deleted_roots` | 100 / 500 roots | Batched missing roots with retained activity snapshots |

## Baseline: 2026-09-06

The library was unchanged at revision
`389ad896fbc2ef5942c6ba34b605a1eb0b3f397c`. Environment: Ruby 4.0.1,
ActiveRecord 8.1.3.1, PaperTrail 17.0.0, SQLite 3.53.2, Linux x86-64 on WSL2
(`6.18.33.2-microsoft-standard-WSL2`), AMD Ryzen 7 7800X3D, about 15.5 GiB
WSL system memory. No test suite or app server ran alongside the final
samples. This is a developer workstation, not an isolated benchmark host.

The [raw samples](https://github.com/aheathwilliams/paper_trail_diff/blob/c799d0e/benchmark/results/reporting-2026-09-06.json) include runtime
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

## Findings from the original baseline

The findings below describe the original revision. The follow-up measurements
and remaining limitations are recorded after this section.

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

## Follow-up: batched reporting, 2026-09-07 UTC

Runtime revision `fb076a4ebde62f45d639088d0bd6f843ce0879f8` addresses duplicate
checkpoint reconstruction, repeated association event discovery, and the test
app's per-deleted-root history loop. `report(scope, since:, limit:)` supplies
recent activity through the current saved ending. `include_deleted: true`
returns missing-root analyses in a separate batch with the requested graph.
The same combined root ceiling is checked before either population is analyzed.

Historical attribute hashes read recorded scalar state without reifying every
candidate. Arbitrary callables retain their earlier semantics and reconstruction
cost, with a default `max_filter_versions: 10_000` ceiling on loaded candidate
versions across batches. One extra row detects overflow before evaluating that
batch. This is separate from the matched-root ceiling.

Association regression tests compare one and five roots for live activity and
deleted activity, and exercise through-association events. The test app also
checks that adding deleted articles with children does not add per-article
queries. These tests establish query growth for their requested graphs; the
timings below remain root-only measurements.

The [54 follow-up samples](https://github.com/aheathwilliams/paper_trail_diff/blob/c799d0e/benchmark/results/reporting-after-2026-09-07.json)
use the same runtime versions, workstation, schema, and measurement procedure
as the baseline. No test suite or app server ran alongside them. Each row gives
the median of three fresh processes, with the elapsed-time range in parentheses.
Query, reify, and AR instantiation counts were identical within each set of three.
Memory uses the same definitions and limitations as the baseline.

| Scenario | Size | Total ms (range) | Queries | Reify calls | Retained Ruby MiB | RSS after MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `many_roots` | 100 | 157.1 (154.3–179.1) | 6 | 600 | 3.02 | 84.5 |
| `many_roots` | 500 | 839.7 (804.8–843.8) | 6 | 3,000 | 14.98 | 142.6 |
| `retained_activity` | 100 | 254.4 (250.4–275.8) | 6 | 600 | 4.18 | 98.7 |
| `retained_activity` | 500 | 1,344.7 (1,320.1–1,599.8) | 6 | 3,000 | 20.75 | 160.0 |
| `long_history` | 1,000 | 280.9 (256.1–307.8) | 6 | 1,001 | 4.02 | 111.1 |
| `long_history` | 5,000 | 1,392.0 (1,364.1–1,409.8) | 6 | 5,001 | 19.92 | 170.9 |
| `sparse_matches` | 100 | 94.6 (91.3–100.4) | 7 | 602 | 0.07 | 91.9 |
| `sparse_matches` | 1,000 | 844.2 (835.6–962.9) | 10 | 6,020 | 0.33 | 164.8 |
| `no_matches` | 100 | 85.3 (81.7–92.4) | 2 | 600 | 0.01 | 94.6 |
| `no_matches` | 1,000 | 869.3 (798.8–909.7) | 5 | 6,000 | 0.01 | 165.4 |
| `limit_refusal` | 100 | 10.9 (10.2–11.0) | 2 | 12 | 0.01 | 70.3 |
| `limit_refusal` | 1,000 | 32.2 (30.5–33.4) | 2 | 12 | 0.01 | 81.1 |
| `attribute_no_matches` | 100 | 89.9 (83.0–120.9) | 2 | 0 | 0.01 | 91.7 |
| `attribute_no_matches` | 1,000 | 680.3 (680.2–721.8) | 5 | 0 | 0.01 | 164.7 |
| `attribute_sparse_matches` | 100 | 82.6 (74.6–86.8) | 7 | 6 | 0.07 | 91.7 |
| `attribute_sparse_matches` | 1,000 | 759.7 (742.8–762.1) | 10 | 60 | 0.33 | 166.3 |
| `deleted_roots` | 100 | 340.4 (304.0–364.2) | 5 | 700 | 4.44 | 103.1 |
| `deleted_roots` | 500 | 1,506.4 (1,487.2–1,585.5) | 5 | 3,500 | 22.08 | 164.9 |

At 500 roots, default analysis is about 43% faster than the baseline and reifies
each checkpoint once instead of twice. Its retained Ruby memory barely changes;
this is primarily a reconstruction improvement, not a result-memory reduction.
The 1,000-root attribute no-match case avoids all 6,000 candidate reifications but
still spends 680 ms reading and deserializing states. Its RSS remains comparable
to the callable case. Avoiding reification alone does not eliminate scan cost.

The refusal case regressed: at 1,000 candidates it takes 32.2 ms versus 17.7 ms,
with median SQL time rising from 8.6 to 24.0 ms. Both runs instantiate 1,500 version
records and make 12 reify calls. The new loading ceiling remains useful, but this
query deserves further tuning; the change is not a speedup for every workload.
Deleted history has no original timed counterpart here. Its five queries at both
100 and 500 roots demonstrate batching; output reconstruction still scales.

### Remaining performance limits

- **Reconstruction still scales with requested history.** Plain roots and direct
  children avoid historical AR objects, but decoding and comparing their recorded
  states remains linear work. Compatibility fallbacks still construct records.
  Arbitrarily large histories are not cheap.
- **Callable predicates can still be expensive or issue N+1 queries.** Prefer
  attribute hashes for batch reports. The version-loading budget cannot control
  queries, network calls, or CPU work inside application callbacks. Hash predicates
  still deserialize candidate states and are not SQL-indexed historical searches.
- **Advanced association fallbacks can still query per record.** Scoped or
  default-scoped paths and other graphs that need PT-AT fallback reconstruction
  require explicit `allow_expensive: true` for batch APIs and must be measured
  before being offered in a large report. The flat-query tests
  do not establish a guarantee for every association configuration.
- **Limits are not streaming.** Candidate identities are still selected up front;
  a small root ceiling can load a full 250-candidate version batch, subject to the
  separate version budget. Requested analysis history and retained snapshots
  still consume memory proportional to the data involved.
- **Selection semantics are unchanged.** Historical filters test the states a
  record held during the window, not continuous-time membership. Scope selection needs a root
  version in the window; child-only edits do not select an otherwise quiet root.

Further batching of advanced association fallbacks needs temporal parity tests,
especially around ownership changes. A graph-wide selector for child-only activity
also needs its own bounded query design.
