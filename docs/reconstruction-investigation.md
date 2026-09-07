# Remaining N+1 and reconstruction costs

Investigated library revision `4cd54d641b71dc96181969217e0a206dd749a917` on
2026-09-07 UTC. Several remaining costs are avoidable. The current gem does not
provide an N+1-free batch contract, and the problem is not limited to exotic
application callbacks.

The probes and prototypes live under `benchmark/investigation/`. They do not
change `lib/`; experimental patches apply only inside their subprocesses.
The [raw evidence](../benchmark/results/reconstruction-investigation-2026-09-07.json)
records structural counts, query origins, scalar timings, and parity results.

## Query growth

Each fresh process uses the development association fixture in an in-memory
SQLite database, regardless of any configured application database URL. Each
root has an author, two comments, and two article updates; one comment is updated.
Through-association reporting uses the author as root. Root counts are validated.
Queries exclude schema/transaction statements and run without the query cache.
The SQL stack tracing adds overhead, so use these probes for counts, not latency.

One preliminary sweep aborted on an unexpected selected-root count before the
probe identified the scenario in its error. A subsequent complete sweep passed
all population checks; the earlier mismatch was not diagnosed. These small
fixtures establish the recorded costs, not exhaustive reporting correctness.

| Requested report | 1 root | 5 roots | 20 roots |
| --- | ---: | ---: | ---: |
| Scalar activity | 6 | 6 | 6 |
| Ordinary comments activity | 12 | 12 | 12 |
| Comments activity without recorded `object_changes` | 15 | 27 | 72 |
| Limited comments | 16 | 32 | 92 |
| Owner-dependent comment scope | 16 | 32 | 92 |
| Default-scoped comments | 15 | 27 | 72 |
| Through association with a `has_many` source | 122 | 534 | 2,079 |
| Scalar report with a querying initialization callback | 10 | 26 | 86 |
| Callable historical filter that queries comments | 8 | 12 | 27 |

The callback and callable cases deliberately contain an application query. The
other growing cases use gem-owned loading/reconstruction paths.

### Ordinary child activity can query per event

`ActivityEventRecordResolver#record_after` falls back to `version.next` and then
`model_class.unscoped.find_by` when it cannot reconstruct an event's after-state
from a changeset. In the five-root comments probe with `object_changes` cleared,
those two sites add ten successor queries and five live-record queries. The
ordinary scalar-only probe remains at six queries with the same missing changesets.

This is a supported situation: the quickstart recommends `object_changes` but
does not require it. The selected graph already has prepared version/live data;
event reconstruction should consume an indexed successor/after-state provider
instead of issuing these queries per event. Absence after destruction must be
represented separately from an unavailable state, so a missing result cannot
silently trigger another lookup.

### Through fallback also expands beyond requested paths

`PreparedHistoryLoader#deferred_macro?` declines through associations whose source
is not `belongs_to`. `PreparedAssociationReifier` then delegates to
`HistoricalAssociationReifier`, which calls PT-AT's `HasManyThrough` reifier.

In the installed PT-AT 2.3.0 implementation, `collection_through_has_many` calls
`PaperTrail::Reifier.reify_has_manys` on each intermediate record. That method
enumerates **all** of that model's `has_many` reflections. An author-comments
report therefore also queried the intermediate article's unrequested authorships:
30 `TrackedAuthorship Load` statements for five roots. This violates the intended
bounded-path design as well as adding queries and repeated reconstruction.

The five-root through probe made 155 `reify` calls for 35 distinct versions.
The source of the repeated queries is visible in the raw SQL-origin counters.
This fallback should not silently remain an ordinary batch-reporting path.

An experimental override allowing the existing prepared through resolver reduced
the simple five-root case from 534 queries to 19, with equal serialized output.
Its query count stayed at 19 for one, five, and twenty roots.
However, running the full association suite with that override produced **209
examples, one failure** in the existing prepared-history parity test involving
an ownership change. Its historical `author.comments` membership differed.
Disabling the guard is therefore not a validated fix. A bounded through resolver
needs explicit temporal-membership tests, including moves, deletions, transaction
boundaries, and source/through scopes. Matching PT-AT alone is not a substitute
for establishing the intended historical result.

### Scope fallbacks are intentional but still costly

`LiveEndpointBatchLoader#batch_safe?` routes owner-dependent scopes and collection
limits/offsets into `load_individually`. Batching a global `LIMIT 1` would change
per-owner results, so this is a semantic precaution, not an accidental missing
preload. `PreparedHistory#supported?` also declines scoped/default-scoped targets,
which sends historical reads into PT-AT.

Some static predicates can be evaluated against prepared attributes. Per-owner
limits require correct per-owner ordering/ranking. Arbitrary owner-dependent Ruby
scopes cannot generally be translated into one bounded query. Batch methods
should identify unsupported paths before reconstruction and refuse them or
require an explicit expensive-path choice, rather than quietly query per root.

## Reification counts understate object construction

`PreparedRecordSeries` caches immutable states, but `record_before` and `records`
call `PreparedRecordState#instantiate`, which invokes `model_class.new` each time.
`PreparedEdgeLoader#belongs_to_groups` also constructs historical owners merely
to read their foreign keys. `ActivityEventRecordResolver` creates/reifies records
for event after-states. Root snapshots still pass through `reify(dup: true)`.

For five roots with ordinary comment checkpoint timelines, the probe counted
15 `reify` calls **plus 20 prepared-record constructions**. These paths can run
initialization callbacks and allocate attribute sets even without extra SQL.
The probe's broader `model_initializations` counter includes both loaded AR rows
and newly reconstructed objects; it must not be described as reification alone.
Repeated `reify` invocations can include nil create states, so raw evidence also
counts repeated invocations with a present object payload.

The ordinary activity probe also repeated one non-nil root-version reification
per root. The earlier checkpoint cache did not eliminate duplicate work across
all activity reconstruction paths.

## Direct scalar snapshot experiment

A scalar-only prototype reads `PreparedVersionStateLoader` output, casts attributes,
applies the existing ignore policy, and constructs `RecordSnapshot` directly.
It creates no historical ActiveRecord root instances. It is deliberately not
loaded by the gem entrypoint.

The cost experiment uses the existing 500-root/five-update benchmark fixture.
Each mode ran in three fresh processes, without other test/probe processes running
alongside the measured calls. Current-boundary time is fixed after seeding so an
untimed serialized-output comparison can include boundary metadata and snapshots.
Initialization counting is enabled in both modes. These are paired experimental
measurements, not a direct comparison to earlier benchmark runs.

| Measurement | Current path | Scalar prototype |
| --- | ---: | ---: |
| Median report time | 937.0 ms | 702.1 ms |
| Time range | 934.6–941.7 ms | 678.4–715.6 ms |
| SQL queries | 6 | 6 |
| `reify` invocations | 3,000 | 0 |
| Root model initializations | 3,500 | 1,000 |
| Allocated Ruby objects, median | 581,884 | 520,397 |

The remaining 1,000 initializations are live roots loaded by selection and endpoint
loading. Eliminating historical construction improved this fixture by about 25%,
but retained result memory remained about 15 MiB. Deserializing requested history
and retaining output still cost work and memory.

Parity checks passed for ordinary and STI records with enum, decimal, date,
boolean, JSON, serialized attributes, and a missing attribute with a column default.
They **failed** for missing attributes supplied by an initialization callback or
a default scope: current reification included the callback/scope value, while the
prototype included the column default. The current direct loader also declines
encrypted models and attributes removed from the schema. Arbitrary custom types
and application-defined behavior are not covered by this experiment.

Direct snapshots are feasible for a defined subset. Replacing every `reify` call
without a compatibility policy would change results. Renaming object construction
to `instantiate` is not the performance fix; keeping typed immutable state through
edge resolution and normalization is.

## Recommended implementation order

1. Remove per-event successor/live queries from child activity, including histories
   without `object_changes`, using the prepared version and live-state indexes.
2. Replace the through fallback with explicit path-bounded resolution and temporal
   membership tests. Until that is correct, expose/refuse the expensive path before
   starting a batch rather than traversing unrequested associations.
3. Add direct immutable root and child normalization for the supported scalar
   subset. Define missing-field/default/callback behavior and explicit handling of
   unsupported serializers; preserve engine independence from ActiveRecord.
4. Validate batch association support up front. Keep owner-specific scopes and
   unimplemented ranking semantics out of an implicitly efficient batch contract.
5. Measure SQL, duplicate state reconstruction, all historical AR constructions,
   allocations, and retained memory. Test growth across roots and events, not only
   final result size or `reify` call counts.

Application callbacks can still query when live rows are instantiated, and custom
types/predicates can execute arbitrary Ruby. A defensible guarantee must distinguish
the gem's own reconstruction queries from application behavior. It cannot promise
that arbitrary consumer code becomes query-free.

## Reproduce

These commands use disposable in-memory data and do not modify application tables:

```console
mise exec -- bundle exec ruby benchmark/investigation/reconstruction.rb comments_without_changes 20
mise exec -- bundle exec ruby benchmark/investigation/reconstruction.rb through_has_many 20
mise exec -- bundle exec ruby benchmark/investigation/reconstruction.rb checkpoints 5
mise exec -- bundle exec ruby benchmark/investigation/reconstruction.rb through_has_many 5 prepared-through
mise exec -- bundle exec ruby benchmark/investigation/scalar_cost.rb baseline 500
mise exec -- bundle exec ruby benchmark/investigation/scalar_cost.rb direct 500
mise exec -- bundle exec ruby benchmark/investigation/scalar_parity.rb
```

Run sizes 1, 5, and 20 to inspect query growth. Run each scalar mode three times
for the timing comparison. `scalar_parity.rb` reports known mismatches as data;
they are intentional evidence that the prototype is not a compatible replacement.

To reproduce the failing through-prototype parity check across the existing suite:

```console
PAPER_TRAIL_DIFF_COVERAGE=associations mise exec -- bundle exec ruby -Ilib -Ispec -rspec_helper -r./benchmark/investigation/prepared_through_override -S rspec --pattern 'spec/{unit,association}/**/*_spec.rb' --exclude-pattern spec/unit/loading_spec.rb
```
