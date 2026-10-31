# Repository guide

## Purpose and architecture

`paper_trail_diff` adds structured endpoint and timeline diffing to PaperTrail.
PaperTrail integration must normalize reified records into immutable snapshot
objects before the comparison engine runs. The engine must remain independent
of ActiveRecord and PaperTrail.

Association tracking is optional. Never add
`paper_trail-association_tracking` as a runtime dependency or require it from
the library entrypoint. Association traversal must remain explicit and bounded
by requested paths; never automatically recurse through an entire model graph.
Supported macros are `belongs_to`, `has_one`, `has_many` (including through),
and `has_and_belongs_to_many`.

Keep the public API small and explicit. Return value objects and hashes, never
formatted diff text.

## Ruby and style

- Maintain compatibility with Ruby 3.1 and newer.
- Use frozen-string-literal headers and the repository RuboCop configuration.
- Inline RBS comments in `lib/` are the source of truth. Regenerate committed
  signatures with `rake rbs`; never hand-edit `sig/generated/`.
- Preserve deterministic ordering and immutable public result objects.
- Keep global-array and exact-path ignore behavior backward compatible.

## Changes

- Record every user-visible change under `Unreleased` in `CHANGELOG.md`, in
  the section that fits: Breaking changes, Added, Changed, Fixed, or
  Development.
- `mutant.yml` lists the classes under mutation testing, and CI fails a pull
  request on any mutation that survives in a method it changes. Before pushing
  a change to one of them, run mutant with `--since origin/main` (see
  Commands) and handle what survives as `docs/testing.md` describes.
- When a change is meant to alter behavior, update the specs that pinned the
  old behavior, often a class's own mutation spec, and say why in the commit.
  Never bend the change to keep an old expectation passing, and never assume
  a spec that breaks unexpectedly is outdated.
- SQLite is the default test database. "Other databases locally" in
  `docs/testing.md` covers PostgreSQL, MySQL, and SQL Server. Disposable
  containers of the images in `.github/workflows/ci.yml` work; SQL Server
  needs `CREATE DATABASE paper_trail_diff_test` before the run. A database
  you cannot run locally is covered by CI's database jobs: report it as not
  run, not as passing.

## Commands

Run Ruby and package commands through mise in non-interactive shells:

```console
mise exec -- bundle install
mise exec -- bundle exec rake spec_core
mise exec -- bundle exec rake spec_associations
mise exec -- bundle exec rake spec_oracle
mise exec -- bundle exec rake rubocop
mise exec -- bundle exec rake typecheck
mise exec -- bundle exec rake
mise exec -- bundle exec rake build
BUNDLE_GEMFILE=gemfiles/mutant.gemfile mise exec -- bundle install
BUNDLE_GEMFILE=gemfiles/mutant.gemfile mise exec -- bundle exec mutant run --since origin/main
mise exec -- act -l
mise exec -- act push -j quality --matrix ruby:4.0 --matrix paper_trail:17
mise exec -- act push
```

If mise reports that the project is untrusted, run `mise trust`. If a pinned
tool is missing, run `mise install`.

`act` can exercise the Linux CI jobs locally but cannot reproduce the Windows
jobs. Release tags matching `v*` publish through RubyGems trusted publishing;
never add a long-lived RubyGems API key. Before tagging, replace `Unreleased`
in the changelog with the release date, run all checks, and configure the
RubyGems trusted publisher for `release.yml` and the `release` environment.
