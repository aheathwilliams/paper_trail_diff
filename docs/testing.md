# Testing

The default suite uses an in-memory SQLite database:

```console
mise exec -- bundle install
mise exec -- bundle exec rake
```

The default task runs the core specs without PT-AT loaded, the association specs
and the [oracle checks](#oracle-checks) each in a separate process, RuboCop (with the rubocop-performance and rubocop-rspec
plugins), generated-signature verification, and Steep.
Ruby blocks in the README, quickstart, and API reference marked with
`<!-- executable:... -->` run inside those specs, so documented examples stay
correct.

For reporting workloads, query counts, reconstruction cost, and memory readings,
see [Reporting performance](performance.md). Those measurements run separately
from the correctness suite and have no timing-based CI gate; the
[SQL work](#sql-work) spec checks how a report's SQL grows instead.

CI keeps the Ruby 3.1–4.0 and PaperTrail 16/17 compatibility matrix on SQLite,
including Windows runs. Separate Linux jobs run both core and association suites
on PostgreSQL 17, MySQL 8.4, and SQL Server 2019 and 2022 with Ruby 4.0 and
PaperTrail 17. The SQL Server 2022 job's database allows snapshot isolation
and the 2019 job's does not, so each call's `SNAPSHOT` read is run both ways.
The SQL jobs exercise the same regressions, including joined-column ordering,
duplicate roots, pagination, and historical association reconstruction.

## JSON history

PaperTrail writes history with YAML unless an app sets its JSON serializer, so
the suites do too. To run them with JSON history instead:

```console
PAPER_TRAIL_DIFF_SERIALIZER=json mise exec -- bundle exec rake spec
```

A CI job runs them that way on Ruby 4.0 and PaperTrail 17. The PaperTrail 16
jobs run Active Support 8.0, whose JSON encoder passes a keyword
(`quirks_mode:`) that json 3 rejects, and the SQL Server adapter hands the
encoder a value it refuses, so nothing can be written as JSON there, and the
specs that switch to JSON themselves skip.

Write a fixture version with `PaperTrail.serializer.dump`, not `to_yaml`, so it
holds what either run's history would. An example about YAML history itself
is tagged `history: :yaml` and keeps YAML in both runs. JSON keeps times to
milliseconds by default, so an oracle's truth, read from live rows, cuts times
to the digits history keeps (`HistorySerializer.as_stored`), as the gem does
when it compares a live row with history. A scope that orders or bounds a
time more finely than that is refused under JSON, and the specs that read one
leave it out there.

## Consistency checks

`spec/association/consistency_spec.rb` and `spec/integration/consistency_spec.rb`
build seeded, generated histories: root edits, checkpoints, and child creates,
edits, and deletes. For each one they check that every route to the same answer
agrees: `analyze`, `analyze_many`, and `analyze_scope`; checkpoint and activity
modes; `compare` against `analyze`; and that activity steps
chain into the final state. They run over random windows as well as the whole
history, with integer and string `versions.item_id`, YAML and JSON history, and
a `has_paper_trail skip:` column. When one fails, its seed reproduces it, and
`ORACLE_SHRINK=1` reduces it, as for the oracles (see
[Reducing a failure](#reducing-a-failure)). Add a variant here when a bug
turns out to depend on a schema or configuration.

## SQL work

A statement whose plan reads a report's window again for each of its roots'
versions passes every correctness check and shows only at scale.
`spec/association/report_sql_work_spec.rb` reports on articles with their
comments, with the README's indexes, since plans depend on them. It then adds
other records' history to the window and reports again. It runs each SELECT
again on its own and reads the steps SQLite's virtual machine took, which are
the same on every run for the same data and SQLite version. It fails when
each added version costs the report more than 100 steps: about 27 when it was
written, and about 380 with the correlated subquery that once took a report
of 10,000 articles from 6 to 44 ms an article. The failure lists the
statements that grew most. It runs on SQLite only.

## Oracle checks

The consistency checks compare gem methods with each other, so a bug they
share passes. `spec/oracle` compares them with the truth instead:

1. A seeded generator (`spec/support/oracle.rb`) makes random edits to an
   article graph, one transaction each: root edits and checkpoints, comments
   and replies created, edited, moved, and deleted, an author, a profile, and
   authorships with their authors. Some transactions write several versions.
2. After each transaction it records the live state, keyed by the versions
   that transaction wrote, so every version names the state just before it.
   The state comes from the gem's current-record path, which is plain Active
   Record, and is checked against an independent read of each association.
3. Every endpoint pair, every timeline step, every activity step (grouped and
   not), and windows through `analyze`, `analyze_many`, and `analyze_scope`
   are compared with the recorded states. Two windows that meet between
   transactions, or inside one, must report each step once, as the window
   spanning both does, through both `analyze` and `analyze_many`.
   The transactions take turns between no author, `alice`, and `bob`, and
   the same windows filtered to alice's versions must report exactly the
   unfiltered steps of the transactions she saved a version in.

Five more generators cover other shapes. `scoped_membership_spec.rb` moves
notes in and out of scoped associations (conditions, order, limit, and
offset) and compares the members at every version with Active Record's own
answer. `tree_history_spec.rb` edits a tree of one model, so a root can sit
inside another root's tree, with children whose attributes are encrypted,
serialized, enums stored as strings, custom types, decimals, and JSON.
`through_history_spec.rb` edits two teams' join records and the records they
reach, through every kind of `has_many :through`: to a `belongs_to`, through a
scoped part, ranked with a limit, to a `has_many`, through another through, a
`has_one` through, and with `source_type:`. `shapes_history_spec.rb` edits two
boards and the records around them:
a polymorphic owner, cards that use single-table inheritance and change type,
comments that move between boards and cards (`as:`), labels with a default
scope, and scoped and ranked associations to the cards. Its checks, in
`spec/support/graph_oracle.rb`, follow any model's associations, so a new
shape needs only models and edits. These four read the expected states with
plain Active Record, not through the gem.

`replay_differential_spec.rb` checks activity against the gem's own full
snapshots instead. Activity carries each snapshot forward from the previous
event, reading again only what the event changed; this replays generated
histories that way and with a full snapshot at every event, and fails on any
difference. Needing no expected states, it covers what the others avoid:
`has_paper_trail only:` and `ignore:` that leave keys out of `object_changes`,
and keys written by `update_columns` or with versioning off.
Mutant cannot check that carrying forward: a mutation that turns it off
falls back to a full snapshot, which gives the same answers, more slowly. This
check is what catches one that gives a different answer.

`unversioned_writes_spec.rb` mixes saves with `update_columns` writes,
several to a transaction, and logs every write. Each change row must match
the write that made it: one credited to a version ends at a value that
version recorded, one credited to no version at a value an `update_columns`
wrote, and such a write whose value is read again has a row of its own.
With only the rows of versions kept, each article and comment must end at
the value of its last recorded save.

Every oracle that reads an activity timeline from end to end also checks its
net changes (`spec/support/net_changes_check.rb`). With every row kept, each
record's `before` and `after` must be its state where the step of its first
row starts and where the timeline ends, read from the whole snapshot tree,
and the record must be listed exactly when the two differ.

```console
mise exec -- bundle exec rake spec_oracle
ORACLE_SEEDS=1..200 ORACLE_STEPS=40 mise exec -- bundle exec rake spec_oracle
```

The 200-seed run is about 4,000 examples and takes three hours or more in one
process. Its database is in memory, so you can split it by seed range and run
the parts side by side, each in its own shell: `ORACLE_SEEDS=1..25`, then
`26..50`, and so on. Eight such parts took about 25 minutes. Check that each
part ran all its examples: a run stopped early, by `timeout` for example,
still ends with "N examples, 0 failures" for the ones it ran. Adding
`SPEC_OPTS=--dry-run` to the same command prints how many there should be.

The default seeds keep the run short; `rake spec` includes it, so
the database jobs run it too. Mutant does not, because it would slow every
mutation. A failure prints its seed, the transactions it made, its first five
mismatches (`ORACLE_SHOW=50` prints more), and the command that reduces it.

A scheduled workflow, `.github/workflows/oracle.yml`, runs 200 more seeds each
night with `ORACLE_STEPS=40`, in eight jobs of 25. The seeds move on 200 a day
from seed 201, so each night tries histories no run has; run by hand, the
workflow takes the first of its 200 seeds as `first_seed`. A job reduces the
first two examples that fail and keeps its log and `tmp/oracle` as an
artifact: copy that `tmp/oracle` into a checkout and run the `Replay it:`
command from the log.

When a bug turns out to depend on a schema, configuration, or kind of edit,
add it to the generator or as a new context, so the whole class of bug stays
covered.

### Reducing a failure

`ORACLE_SHRINK=1` cuts a failing history down to the few steps that matter, in
the oracles and the consistency checks alike. A failure ends with the command,
which runs that example alone with the settings that decide its history:

```console
ORACLE_SEEDS=103 ORACLE_SHRINK=1 mise exec -- bundle exec rspec 'spec/oracle/shapes_history_spec.rb[1:1]'
```

The generators draw their random choices through `Oracle.random(seed)`
(`spec/support/oracle_choices.rb`). It hands out what `Random.new(seed)`
would, so a seed builds the history it always has, and it keeps each draw,
grouped by step. When an example fails, the reducer
(`spec/support/oracle_reducer.rb`) runs it again with runs of steps left out,
then with each remaining choice set to the first one, such as the first
operation in a generator's list. An example that builds a history for each
seed, such as the article oracle's windows that meet inside a transaction,
first loses whole histories, half of them at a time, since every run builds
them all. The reducer keeps each change that fails with the same first
mismatch, numbers aside, and stops when no change helps or after
`ORACLE_SHRINK_RUNS` runs (300 by default). Leaving a step out keeps the
other steps' choices as they were, though they may then act on different
records. `ORACLE_SHRINK_EXAMPLES` caps how many failing examples one run
reduces; the others just print the command.

The example then fails with the reduced history: how many steps were left,
the versions it wrote if it built one history, its mismatches, and a command
that replays it from a file in `tmp/oracle`, followed by the original
failure. Tried against a bug injected into activity's carry-forward, it
brought one example of each generator from 20 to 66 steps down to 2 to 5, in
21 to 38 runs, taking from 4 seconds to 5 minutes; the shapes oracle's checks
are the slowest. Write the reduced history as a named spec beside the code it
covers, so the cause is readable without the generator.

A generator runs each loop of random steps as `@random.steps(count) { ... }`
rather than `count.times`, so the reducer can tell its steps apart. A new
generator should too.

## Comparison properties

The oracles compute the change they expect with `PaperTrailDiff::Engine`, so a
bug in the engine itself passes them. `spec/unit/engine_properties_spec.rb`
checks the engine on its own, over a few hundred generated pairs of snapshots
(`spec/support/snapshot_cases.rb`): attributes, to-one records and
collections two levels deep, with mixed id types, and collections carried
forward one record at a time, as activity builds them. For every pair:

- an equal snapshot built separately, with its keys and records in another
  order, compares as no change;
- the diff, applied to the first snapshot, gives the second, so it misses no
  change and reports none wrongly (`spec/support/diff_algebra.rb` applies a
  diff from its hash alone, without the engine);
- comparing the other way gives the opposite diff;
- every change reported is a real one, in attribute name and record order;
- a collection carried forward reports what the same collection built whole
  does;
- nothing in the diff can be changed.

`spec/unit/nested_comparator_properties_spec.rb` does the same for the values
inside a JSON column, including JSON text, symbol keys, and arrays, which are
reported by membership.

`spec/unit/net_changes_properties_spec.rb` checks the fold behind
`net_changes`, over generated histories of a few records
(`spec/support/snapshot_world.rb`) in which a record has one state wherever a
snapshot reaches it: comments that come and go, replies that move between
comments, an author who reviews several, and tags. For every history:

- the rows of a run of steps fold into each record's change from the run's
  first state to its last, whether the run is passed alone or picked out of
  the whole history by the rows kept;
- the root comes first, then each record in the order of its first kept
  change, with each source once;
- kept alone, the rows that move records in and out leave each record as its
  last move left it;
- a record that stayed changes only in fields a kept row set.

They take about a second and run with the unit specs. Each is named after
what it checks rather than its class, so mutant, which runs only the specs
that name a mutated class, leaves them out: run with every mutation of
`Engine`, `NestedComparator`, `NetChange`, and `NetChanges`, they nearly
doubled its work, from 15 to 27 minutes of worker time, while the classes'
own specs kill every mutation without them. Name a new property spec the
same way.
A failure names its case. The cases start small and grow, so the first one
that fails is a small one. `PROPERTY_SEED` and `PROPERTY_CASES` choose other
and more cases:

```console
PROPERTY_SEED=2 PROPERTY_CASES=5000 mise exec -- bundle exec rspec spec/unit/engine_properties_spec.rb
```

## Mutation testing

[Mutant](https://github.com/mbj/mutant) changes the library one expression at
a time and expects a spec to fail each time. A change that every spec still
passes is behavior nothing checks. `mutant.yml` lists the classes it mutates:

- what counts as a change: `Engine`, `CollectionComparator`,
  `CollectionIdentityIndex`, `NestedComparator`, and `CollectionTransition`;
- which columns are compared, and how precisely times are: `SnapshotNormalizer`,
  `SnapshotPool`, and `StoredTimePrecision`;
- which endpoints a call accepts, and which item and model each names:
  `Endpoint` and `EndpointKind`;
- which versions a range reads: `TimeRange`, `TimelineRange`, `VersionRange`,
  `TimeVersionRange`, `RootVersionSelection`, `RootVersionPlan`,
  `TransactionCut`, `CrossingTransactions`, `TransactionEnds`,
  `RecordedTransactionEnds`,
  `VersionBoundary`, and `VersionQuery`;
- which versions a batch or filter reads: `AnalysisBatch`,
  `BatchedRootVersions`, `BatchedRootAnalyses`, `BatchBoundaryResolver`,
  `DeletedAnalysisBatch`, `HistoricalFilter`, and `VersionScopeFilter`;
- whether a read sees one database snapshot: `ReadSnapshot`;
- what a version recorded: `RecordedChanges`, `RecordedChangesReader`, and
  `RecordedClass`;
- how a step flattens into rows: `ChangeRow` and `ChangeRows`;
- which records a scope or report selects, and in what order:
  `ScopedRootSelection`, `TotalOrder`, `AssociationActivitySelection`,
  `AssociationActivityEdge`, and `DeletedRootFilter`;
- which children and targets a record had at each point:
  `PreparedHistoryLoader`, `PreparedEdgeLoader`, `ActivityChildCandidateLoader`,
  `PreparedChildCandidates`, `ActivityTargetCandidateLoader`, and
  `PreparedActivityIndex`;
- where an activity range starts and ends, and which association history its
  query reads: `ActivityRange` and `VersionAssociationCandidateScope`;
- what activity a record shows: `ActivityTimelineBuilder`,
  `ActivityVersionCollector`, `ActivityHistoryBuilder`, `ActivityRootSteps`,
  `ActivityTransactionGrouper`, `ActivityTransactionGroups`,
  `ActivityTreeFilter`, `ActivityScopeFilter`, and `ActivityView`;
- what an update did to a record, and whether it moved the record to another
  owner: `ActivitySnapshotDelta`;
- where in a carried snapshot an event's record sits: `ActivityEventRouteFinder`;
- which association paths a request accepts: `AssociationTraversal`,
  `AssociationKey`, and `VersionTable`;
- which association paths history cannot read: `UnreadablePaths`;
- which records an association scope admits, and how it ranks them:
  `ScopeCondition`, `ScopeRanking`, and `ExactColumnType`;
- the helpers these share, which order versions, name records, and copy
  values: `Support`.

The specs for the classes that read the database use tables of their own
(`spec/support/filter_database.rb`, `spec/support/normalizer_database.rb`,
`spec/support/recorded_changes_database.rb`), so they run in both the core and
the association suite. The association classes need PT-AT, so their specs are
in `spec/association` and define any extra tables in the spec file itself.

Mutant reads `spec/unit` and `spec/association`, never `spec/integration`.
Even there it does not run every spec for every mutation, only those whose
description names the mutated class (`RSpec.describe PaperTrailDiff::Engine`),
falling back to wider names such as `PaperTrailDiff` when none does. A spec
named after a behavior, as most integration specs are, never runs. So each
mutated class has a unit spec of its own that catches every mutation in it,
and a class added to `mutant.yml` needs one too. A spec named after a
behavior can still name the class it checks with metadata, as the activity
window specs do: `RSpec.describe 'Activity over a window', mutant_expression:
'PaperTrailDiff::ActivityTimelineBuilder'`.

Mutant runs an example it picks whatever its `if:` or `unless:` metadata
says. An example that needs one database calls `skip` on the others instead,
as `spec/unit/read_snapshot_spec.rb` does for SQL Server.

Mutant counts a mutation that runs past its time limit as caught, so
`mutant.yml` sets the limit well above the time the whole suite takes. With
mutant's 5-second default, mutations no spec caught were reported as caught.

A group nested for one method, such as `describe '.call'`, names that method,
and mutant then runs only that group for it, so the group must catch every
mutation in the method by itself. A private method gets every example of its
class. Mutant cannot reach a method that `module_function` defines: it mutates
the private copy no caller uses. The mutated modules define their methods with
`def self.` instead.

In CI, a pull request mutates only the methods it changes. The full set runs
nightly in `.github/workflows/mutation.yml`, and only when `main` has a commit
that has not passed yet. Start it by hand from the Actions tab with "Run
workflow". Both split the methods across four jobs with
`script/mutant_shard.rb`, which takes every fourth method in mutant's listing,
so that a class holding most of a run's methods is split as well. To run one
shard locally, as the pull request job does:

```console
BUNDLE_GEMFILE=gemfiles/mutant.gemfile mise exec -- ruby script/mutant_shard.rb 0 4 origin/main
```

Mutant needs Ruby 3.3 or newer, so it has its own bundle:

```console
BUNDLE_GEMFILE=gemfiles/mutant.gemfile mise exec -- bundle install
mise exec -- bundle exec rake mutant
```

Pass a subject to mutate one class, and `--since main` to mutate only what a
branch changed:

```console
BUNDLE_GEMFILE=gemfiles/mutant.gemfile mise exec -- bundle exec mutant run 'PaperTrailDiff::Engine*'
BUNDLE_GEMFILE=gemfiles/mutant.gemfile mise exec -- bundle exec mutant run --since main
```

When a mutation survives, either add the spec that would catch it, or, if the
mutated code means the same thing, simplify the code to that form. Reserve a
`mutant:disable` comment for a method whose surviving mutations all mean the
same thing as the code, and say why next to it.

Mutant forks a worker per CPU; `spec/support/mutant_hooks.rb` gives each
worker its own copy of the SQLite fixture database.

## Test clock

The specs build time windows from `Time.now` around versions they have just
written, so they need a clock that never runs backwards. Virtualized hosts,
WSL2 in particular, step the wall clock back by hundreds of milliseconds when
they resynchronize, which made window-based specs fail at random.
`spec/support/monotonic_clock.rb` therefore makes `Time.now` strictly
increasing, in whole microseconds, for the test process. ActiveRecord
timestamps, PaperTrail's `created_at`, and windows built from `Time.now` all
read it, so they stay consistent however the host clock moves. The benchmark
workload, `benchmark/support/workload.rb`, loads it too, because a step back
could date a root's destroy before its last update, and so does the run of
`examples/demo.rb` in `spec/association/demo_script_spec.rb`, whose versions
are saved microseconds apart. It affects only the specs, the benchmark, and
that run; the gem and the demo itself read the ordinary clock.

## Other databases locally

Install the adapter's client development libraries first. On Debian/Ubuntu,
the packages are `libpq-dev` for PostgreSQL, `default-libmysqlclient-dev` for
MySQL, and `freetds-dev` for SQL Server. The optional development group includes
all three adapters:

```console
BUNDLE_WITH=database_adapters mise exec -- bundle install
```

Create a dedicated disposable database named `paper_trail_diff_test`. The suites
recreate their fixture tables. Set `PAPER_TRAIL_DIFF_DATABASE_URL` to its
connection URL and run both suites:

```console
BUNDLE_WITH=database_adapters PAPER_TRAIL_DIFF_DATABASE_URL=postgresql://paper_trail_diff:test@127.0.0.1:5432/paper_trail_diff_test mise exec -- bundle exec rake spec
BUNDLE_WITH=database_adapters PAPER_TRAIL_DIFF_DATABASE_URL=mysql2://paper_trail_diff:test@127.0.0.1:3306/paper_trail_diff_test mise exec -- bundle exec rake spec
BUNDLE_WITH=database_adapters PAPER_TRAIL_DIFF_DATABASE_URL=sqlserver://sa:PaperTrail_Test2026@127.0.0.1:1433/paper_trail_diff_test mise exec -- bundle exec rake spec
```

These credentials are examples for disposable local instances. SQL Server's
adapter version follows ActiveRecord's version; Bundler selects a compatible
adapter. No database driver is a runtime dependency of the gem.

SQL Server's adapter wraps datetime2 values during serialization. With
PaperTrail's default YAML serializer, the fixtures explicitly permit
`ActiveRecord::ConnectionAdapters::SQLServer::Type::Data` and
`ActiveRecord::ConnectionAdapters::SQLServer::Type::DateTime2`, in addition to
`Symbol` and `Time`. Applications using that serializer need the corresponding
`ActiveRecord.yaml_column_permitted_classes` configuration. The gem does not
change an application's YAML configuration.

PT-AT compares version times through SQL text, which SQL Server's adapter
writes as `datetime` values, up to 1/300 s off. So on SQL Server the
association specs keep their versions 5 ms apart, or the specs that compare
the gem with PT-AT would fail whenever versions were saved closer together.

The CI service configuration is in `.github/workflows/ci.yml`. PostgreSQL and
MySQL create the named database during container initialization. The SQL Server
jobs create it explicitly after the service passes its health check.

## Generated signatures

Inline RBS comments in `lib/` are the source of truth:

```console
mise exec -- bundle exec rake rbs
mise exec -- bundle exec rake typecheck
```

The typecheck task regenerates signatures and compares them with Git's index
before running Steep. Unstaged generated changes therefore fail the gate even
when they are correct. Review and stage matching source/signature changes before
running the complete gate. The Steep wrapper also fails on internal errors even
if Steep returns exit status zero.

## Releasing

Tags matching `v*` publish through RubyGems trusted publishing. Never add a
long-lived RubyGems API key. Before tagging:

1. Update `PaperTrailDiff::VERSION` and replace `Unreleased` in the changelog
   with that version and the release date.
2. Run `mise exec -- bundle exec rake release:preflight`. It runs the full gate,
   checks that the tree is clean and pushed, that the Appraisal gemfiles are
   current, and that the changelog names the version, then builds the gem. It
   does not tag, push, or publish.
3. Configure the RubyGems trusted publisher for `release.yml` and the `release`
   environment.
