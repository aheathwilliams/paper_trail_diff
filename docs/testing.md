# Testing

The default suite uses an in-memory SQLite database:

```console
mise exec -- bundle install
mise exec -- bundle exec rake
```

The default task runs the core specs without PT-AT loaded, the association specs
in a separate process, RuboCop (with the rubocop-performance and rubocop-rspec
plugins), generated-signature verification, and Steep.
Ruby blocks in the README, quickstart, and API reference marked with
`<!-- executable:... -->` run inside those specs, so documented examples stay
correct.

For reporting workloads, query counts, reconstruction cost, and memory readings,
see [Reporting performance](performance.md). Those measurements run separately
from the correctness suite and have no timing-based CI gate.

CI keeps the Ruby 3.1–4.0 and PaperTrail 16/17 compatibility matrix on SQLite,
including Windows runs. Separate Linux jobs run both core and association suites
on PostgreSQL 17, MySQL 8.4, and SQL Server 2019 and 2022 with Ruby 4.0 and
PaperTrail 17.
The SQL jobs exercise the same regressions, including joined-column ordering,
duplicate roots, pagination, and historical association reconstruction.

## Consistency checks

`spec/association/consistency_spec.rb` and `spec/integration/consistency_spec.rb`
build seeded, generated histories: root edits, checkpoints, and child creates,
edits, and deletes. For each one they check that every route to the same answer
agrees: `analyze`, `analyze_many`, and `analyze_scope`; checkpoint and activity
modes; `compare` and `timeline` against `analyze`; and that activity steps
chain into the final state. They run over random windows as well as the whole
history, with integer and string `versions.item_id`, YAML and JSON history, and
a `has_paper_trail skip:` column. When one fails, its seed reproduces it. Add a
variant here when a bug turns out to depend on a schema or configuration.

## Mutation testing

[Mutant](https://github.com/mbj/mutant) changes the library one expression at
a time and expects a spec to fail each time. A change that every spec still
passes is behavior nothing checks. `mutant.yml` lists the classes it mutates:

- what counts as a change: `Engine`, `CollectionComparator`,
  `CollectionIdentityIndex`, and `NestedComparator`;
- which columns are compared: `SnapshotNormalizer` and `SnapshotPool`;
- which history a range or filter reads: `TimelineRange`, `RootVersionPlan`,
  and `HistoricalFilter`.

The specs for the classes that read the database use tables of their own
(`spec/support/filter_database.rb`, `spec/support/normalizer_database.rb`), so
they run in both the core and the association suite.

Mutant does not run every spec for every mutation. It runs the specs whose
description names the mutated class (`RSpec.describe PaperTrailDiff::Engine`),
and only falls back to wider names such as `PaperTrailDiff` when none does. A
spec named after a behavior, as most integration specs are, never runs. So
each mutated class has a unit spec of its own that catches every mutation in
it, and a class added to `mutant.yml` needs one too.

Mutant counts a mutation that runs past its time limit as caught, so
`mutant.yml` sets the limit well above the time the whole suite takes. With
mutant's 5-second default, mutations no spec caught were reported as caught.

In CI, a pull request mutates only the methods it changes. The full set runs
nightly in `.github/workflows/mutation.yml`, and only when `main` has a commit
that has not passed yet. Start it by hand from the Actions tab with "Run
workflow".

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
same thing as the code, and say why next to it. Mutant forks a worker per CPU; `spec/support/mutant_hooks.rb`
gives each worker its own copy of the SQLite fixture database.

## Test clock

The specs build time windows from `Time.now` around versions they have just
written, so they need a clock that never runs backwards. Virtualized hosts,
WSL2 in particular, step the wall clock back by hundreds of milliseconds when
they resynchronize, which made window-based specs fail at random.
`spec/support/monotonic_clock.rb` therefore makes `Time.now` strictly
increasing, in whole microseconds, for the test process. ActiveRecord
timestamps, PaperTrail's `created_at`, and windows built from `Time.now` all
read it, so they stay consistent however the host clock moves. It affects only
the test process; the gem itself reads the ordinary clock.

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
