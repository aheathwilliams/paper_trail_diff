# Changelog

All notable changes to this project will be documented in this file. The
project follows [Semantic Versioning](https://semver.org/).

## Unreleased

### Changed

- `include_deleted:` reads the deleted records' `destroy` versions 500
  records per query, as `unreachable`'s test below does, instead of in one
  query for all of them.

- The reference says what `from_snapshot` holds at the start of a window,
  under `version_scope:`, and for a record created inside the range, and how
  to read a record at one version from an analysis rather than by decoding
  `version.object`, which skips the casting the gem applies.

- `analyze_scope` and `report` with `version_scope:` select a record by its
  own versions only when the filter keeps one of them in the window. A record
  whose versions there it all dropped was selected anyway, with an empty
  analysis, and counted toward `limit:`. A change on a requested association
  still selects a record, as before.

- `report` and `analyze_scope` list in `unreachable` only the deleted records
  whose state when destroyed meets the relation's conditions, also without
  `include_deleted:`, whenever those conditions can be read. A report on
  `Article.where(account_id: account.id)` listed every account's deleted
  articles there, and one on `Article.none` listed some too. A relation whose
  conditions cannot be read, such as one with SQL text, lists every deleted
  record of the model as before.

### Added

- `report` accepts `version_scope:`, as `analyze_scope` does, to report only
  some changes, such as those made by people rather than by background jobs.

- `Analysis#window` is the time window an analysis covers: the `within:` or
  `since:` range, or that range with an edge moved back to where a crossing
  transaction began. Check steps against it rather than against the range you
  passed, which the first step of a moved window starts before. It is `nil`
  without a window.

- A `moved_window.paper_trail_diff` notification reports each window edge that
  moved, with the requested and the moved window. A move far longer than a
  transaction takes means the versions' times were changed after saving, as in
  a test that rewrote some versions' `created_at` and not the others saved in
  the same transaction. The reference shows how to give versions fixed times
  in tests.

- Association scopes and `include_deleted:` relations read ranges, such as
  `where(position: 2..)` or `where(created_at: 1.day.ago..)`, and Arel's `gt`,
  `gteq`, `lt`, and `lteq`, on integer, integer enum, date, and datetime
  columns. Such a scope was read through PT-AT, which needs
  `allow_approximate: true`, and such a relation raised `ConfigurationError`
  under `include_deleted: true`.

- `include_deleted: true` accepts `Article.none`, which keeps no deleted
  record, instead of raising `ConfigurationError`. Authorization scopes often
  return `none`.

### Fixed

- Batch methods with `within:` or `since:` look for transactions that cross
  the window's edges in one statement per 500 records. 0.15.0 wrote a
  separate lookup for each record into the statement, which SQL Server took
  about a second to compile per 200 records, so a report on 10,800 records
  spent nearly two minutes there. With 1.4 million versions, those 10,800
  records' edges now take about 6 seconds on SQL Server, and about 1.5 on
  PostgreSQL and MySQL, down from 13.6 and 10.2.

- On PostgreSQL and MySQL (through mysql2 or trilogy), and adapters built on
  them such as PostGIS, each call reads its history and live rows in one
  REPEATABLE READ transaction on the database of the model and its versions.
  A comment that
  committed between two statements of an activity read could make it raise an
  internal `KeyError`, and one statement could see a row that another did not.
  A call now reflects the database as of its first statement, so a commit
  during the call appears in the next call. Each call adds two or three
  transaction statements on those databases. A call made inside a transaction
  of your own keeps that transaction's isolation level. SQLite and SQL Server
  are unchanged.

- Activity reports a change to a root's `belongs_to` key in the step of the
  root version that made it, also when `object_changes` leaves the key out:
  under `has_paper_trail only:` or `ignore:` that do not list it, or when
  `update_columns`, `update_all`, or a save with versioning off wrote it. The
  root kept its old target until a later event read the branch again, so the
  change was credited to whoever saved that, two windows that met between
  the two reported it in neither, and `analyze(activity: true).timeline`
  differed from `timeline`.

- Activity reads a child or a `belongs_to` target whose key changed without a
  version, such as a comment moved by `update_columns`, or by any save under
  `has_paper_trail only:` or `ignore:` that leave the key out. In a past
  window or a range that ends at a version, the record had no events: it
  joined at an arbitrary later step, or was left out of the window's diff,
  and a reviewer set this way kept its later renames out of activity.

- `analyze_many`, and the `deleted` analyses of `analyze_scope`, give a record
  with nothing in the window an `activity_timeline` of `nil` unless
  `activity: true` was passed, as `analyze` does, so its `change_rows` raises
  `ConfigurationError` as for any other record. It was `[]`, so code that read
  `change_rows` without asking for activity passed while nothing changed.

- An STI root that changes class names its new class in the activity
  snapshots after the change, not its old one, and a subclass root's
  snapshot is carried from one of its versions to the next instead of being
  rebuilt at each one.

- Activity reports a change to a key that a child's own `belongs_to`
  follows, such as a comment's `reviewer_id` under `comments.reviewer`, in
  the step of the child's update. The child kept its old target until its
  next edit, or a root version, read the branch again, so the change showed
  up in a later step, credited to whoever saved that, and a window that
  held only the change reported nothing.

- Activity removes a `has_many :through` member when its join record moves
  to another owner or points at another record, also when a path below the
  through reads that join model again, as `contributors.authorships` does.
  The update changed only the copy under that path, so the through kept the
  member until another event read the branch again.

- A HABTM member created in a checkpoint's transaction appears in activity
  from its creation on, as in 0.14.0. Since 0.15.0, which counts such a
  member at the checkpoint, it appeared in every step back to the previous
  root version, before it existed and before members attached earlier. A
  range that ends at the checkpoint still ends with it, as `compare` does.

### Development

- `spec/oracle/replay_differential_spec.rb` replays generated histories
  with activity's incremental snapshots and with a full snapshot at every
  event, under `has_paper_trail only:` and `ignore:` and with keys written
  without a version, and fails on any difference. It found the first two
  bugs above.

- The through oracle renames a team at most once per transaction. A second
  rename made it expect a version to read the state before its transaction,
  which made `ORACLE_SEEDS=40..49` fail on seed 45 without a bug. The scoped
  membership oracle covers range scopes.

- Two oracle generators compare rebuilt history with plain Active Record:
  `spec/oracle/through_history_spec.rb` for every kind of `has_many :through`,
  and `spec/oracle/habtm_history_spec.rb` for HABTM membership between
  checkpoints. They found the three activity bugs above.

- Specs check that a range orders versions by time when their ids run the
  other way, and that an STI subclass's selection names only its own
  destroyed rows. A stub of the versions association these specs relied on
  stopped reaching the gem when it began reading versions from the version
  class, which left six mutations alive in a full mutation run.

## [0.15.0] - 2026-10-31

### Breaking changes

- A `within:` or `since:` window, and a range that starts at a version, can
  begin earlier than asked: an edge inside a transaction moves back to where
  the transaction began, as the two entries under Fixed describe. The first
  step of such a range has a `from_boundary` before the time or version you
  passed, so code that drops steps outside the range it asked for loses that
  step. (This entry was added after release; 0.15.0 listed the change only
  under Fixed.)

- An association whose model keeps its versions, or its PT-AT version
  associations, in different tables than its owner's raises
  `UnsupportedAssociationError` in every method, and `association_paths`
  leaves it out. History read through it was wrong: PT-AT records a child's
  membership with the child's versions but reads it from the owner's tables,
  so a child that moved to another owner was never reported as removed, and a
  root with its own version table raised `ActiveRecord::StatementInvalid`.

- An association keyed on a column other than a primary key
  (`primary_key: :legacy_id`), or a `has_many :through` with such a part,
  raises `UnsupportedAssociationError` up front in every method, and
  `association_paths` leaves it out. PT-AT records which record a child
  pointed at by that record's ID, and history matched children by ID, so an
  article's history showed another article's comments, and a comment's past
  article was the wrong one. Comparisons against the current record were
  right, so the same range disagreed with itself.
- An association path history cannot read, such as one with a scope written
  as SQL text, a scope that takes the owner, or a condition on a string
  column on MySQL or SQL Server, raises `UnsupportedAssociationError` in every
  method that reads history, unless you pass the new `allow_approximate: true`.
  The gem reads such a path with PT-AT, which rebuilds an association from its
  current members and never checks the scope against them: a record that
  entered the scope since was reported as a member it was not, so a comment
  moved into `-> { where("position > 2") }` showed as changed rather than
  added. Single-record methods did this without warning, and batch methods
  described it only as costly.
- `include_deleted: true` keeps only the deleted records that met the
  relation's conditions when they were destroyed, in both `deleted` and
  `unreachable`. It returned every deleted record of the model that changed in
  the window, so a report on one account's articles included other accounts'
  deleted articles with their contents. The relation's conditions must be
  plain conditions on the model's own columns; a join or SQL text raises
  `ConfigurationError`.

### Added

- `diagnose` reports every reason `compare` would refuse the same request as
  an error, with `compare`'s message, so `ok?` is false whenever `compare`
  would refuse. It said `ok?` for a path `compare` reads only approximately,
  such as a scope written as SQL text, raised on an unknown or unsupported
  association instead of reporting it, and checked only the join model a
  `has_many :through` goes through first, not every model it reads. It
  takes `allow_approximate:`, and with `true` reports such a path as an
  `:approximate_association` warning. The new error codes are
  `:unknown_association`, `:unsupported_association`, and
  `:approximate_association`; an unversioned target's message now matches
  `compare`'s.

- `diagnose` takes the current record as either endpoint, as `compare` does,
  so `compare(version, record)` can be checked before it runs. Its version
  checks then run from the version to the latest one. An endpoint that is
  neither a version nor a saved record raises `InvalidEndpointError` naming
  that, rather than `VersionMismatchError`.

- Activity steps list the events whose changes they show as `step.sources`,
  oldest first. A step from `group: :transaction` lists every event in the
  transaction, each with its own author, record, and version ID, where
  `source_boundary` names only the first. `to_h(metadata: true)` adds a
  `sources` list.
- `recorded_changes: true` on `activity_timeline`, on `analyze`, `analyze_many`,
  and `analyze_scope` with `activity: true`, and on `report` gives each
  boundary the changes its version recorded, as `recorded_changes(version)`
  returns them. The versions are already loaded, so it adds no queries, and it
  replaces the reference recipe that loaded every step's version again.
  Without the option, `boundary.recorded_changes` raises `ConfigurationError`
  rather than returning `nil`. Names in `ignore:` or `ignore: { all: }` are
  left out, and so are names on the root path, `"$"`, for the root's own
  versions. Names on an association path are not, because a child's version
  does not say which path reached it.
- `change_rows` on an activity step, on an `Analysis` built with
  `activity: true`, and on a `report` or `analyze_scope` result flattens
  activity into `ChangeRow` objects: one per edited field, and one per record
  that appeared or disappeared followed by its fields. Each names its record,
  association path, and source version, and `to_h` gives a flat hash. It
  replaces the README recipe for turning a report into rows, which had no rows
  for whole records, so a record added or removed with only blank fields left
  no trace.

- `associations:` takes what `includes` takes: a single name
  (`associations: :comments`) or hashes of names to what to include below them
  (`associations: [:author, { comments: :replies }]`), as well as the arrays of
  names and dotted paths it took before.

- `nested_changes` compares two top-level arrays, as a `json` column can hold,
  and reports one `ArrayChange` at the empty path, `[]`. It returned `{}`,
  although arrays nested in an object were compared.

### Changed

- The reference describes how PT-AT records HABTM membership and how the gem
  credits it. A change made between two root versions is credited to the
  step after the earlier one, so a checkpoint's capture is credited to whoever
  saved the version before it; a checkpoint just before the change as well
  credits it to its author. Only the first version an instance saves after
  changing a HABTM is right; PT-AT never forgets the instance's changes, not
  even on `reload`. A later save from it records the old membership, and the
  gem reports members removed and added again that never left.

- The performance guide describes current behavior instead of logging each
  past change: what the batch methods cost, what still grows with a report,
  the version indexes, what costs a query per record, historical filters,
  large reports, and how to measure. Its measurements were taken again. The
  earlier ones remain in `benchmark/results/` and in the changelog.

- `historical_filter:` reads the history of the relation's records only, and
  of deleted records, which a relation cannot test. It read every record of
  the model that changed in the window, so a report on one account's articles
  raised `BatchLimitExceededError` when another account had more matching
  articles than `limit:`, and spent `max_filter_versions:` on their versions.
  Matching deleted records no longer count toward `limit:` unless
  `include_deleted: true` is given, as without a filter.

- The reference says how a record created without a version, such as one
  imported with `insert_all`, and history pruned with `has_paper_trail
  limit:` read.

- `IncompleteTimeRangeError` no longer advises the deprecated
  `close_on: :current`. The quickstart and performance guide no longer say
  that `has_many :through` or limited associations need the opt-ins, and the
  reference says that `association_paths` lists paths that need
  `allow_approximate: true`.

- The quickstart sets PaperTrail's `yaml_column_permitted_classes`. In a new
  Rails 8.1 app, versions hold timestamps as `ActiveSupport::TimeWithZone`,
  and the quickstart's first `reify` raised `Psych::DisallowedClass` without
  it. Its documentation spec now reads a version in that form.

- The README and architecture guide recommend a second version index,
  `(item_type, created_at, item_id)`. Batch methods with `since:` or
  `within:` find changed records by type and time, which the one index they
  recommended cannot narrow, so each report read every version of the model:
  about 230 ms instead of 2 ms on PostgreSQL with 5 million versions.
- The gemspec requires Active Record 7.1 to 8.1. CI tests 7.2 through 8.1,
  and the suite passes on 7.1. It named only PaperTrail, so Bundler could
  install the gem with Active Record 6.1 or 7.0, whose relations and Arel
  nodes the gem reads differently.
- `close_on:` is deprecated and warns through the new
  `PaperTrailDiff.deprecator`. It has had no effect since a window began
  closing on the current record by default; remove it. In a Rails app,
  register the deprecator with
  `Rails.application.deprecators[:paper_trail_diff] = PaperTrailDiff.deprecator`.
- `allow_expensive:` is deprecated and has no effect. It refused exactly the
  paths `allow_approximate:` refuses, so batch methods needed both or
  neither; `allow_approximate: true` alone now accepts such a path in every
  method, and `UnsupportedBatchPathError` is no longer raised. Batch methods
  refuse such a path before their first query, as before, now with
  `UnsupportedAssociationError`.
- `reload_live_endpoints:` is deprecated and warns. It still works until it
  is removed. Skipping the reload saves a query for the records and one per
  association level in each call, 2 for 500 articles with their comments,
  and reads values from objects that may be stale; it also needs every
  requested association loaded, and reads limited ones again anyway. It was
  on `compare`, `compare_many`, and `activity_timeline` only. Remove it.

### Fixed

- A HABTM member created in the same transaction as the checkpoint that
  records it is a member at that checkpoint, as a member attached there
  already was. It was left out, because it had no state before the
  transaction, so the checkpoint missed it and a comparison from the
  checkpoint to now reported it added.

- `association_paths` leaves out an association whose target, or a model its
  `has_many :through` goes through, has no `has_paper_trail`, such as the
  `file_attachment` and `file_blob` that `has_one_attached` defines. Every
  request that reads history refused them with `UnversionedAssociationError`,
  so a settings screen built from the list offered paths that always failed.

- `diagnose` reports `:tied_version_timestamps`, and `compare` emits
  `ambiguous_association_boundary.paper_trail_diff`, only when the request can
  read a path with PT-AT: one history reads only approximately, a composite
  foreign key, or a polymorphic `belongs_to`. PT-AT places association changes
  by timestamp alone. For every other path, since 0.14.0, versions that share a
  timestamp are ordered by ID, so a change between them is reported, yet both
  warned that it could not be detected. A request refused for a path PT-AT
  would read now raises before the notification.

- `timeline`, `activity_timeline`, and `analyze` read every version of a
  model whose versions association has a scope
  (`has_paper_trail versions: { scope: }`), as the other methods already did.
  They read only the versions the scope kept, so a change saved in a version
  it left out was credited to the next one kept: with a bot's edits hidden,
  an editor's step showed the bot's later edit too, and the same record and
  window gave different steps in `analyze` and `analyze_many`. A version the
  scope leaves out is also accepted as an endpoint. To report only some
  changes, pass `version_scope:`.

- Activity steps leave out the versions a record saved while it was outside
  the root's tree. A comment edited on another article, then moved to this
  one, brought that edit into the article's timeline as a step, and a
  transaction group's `sources` listed it. Saved together with a comment added
  to the article, the edit took the credit for the addition. The same went for
  a comment edited after it moved away or left a scope, and for an author
  renamed after the article changed authors. A version now counts when its
  record is in the tree before or after its transaction. The versions of a
  `has_many :through`'s join rows are all still kept.

- `timeline`, `activity_timeline`, `analyze`, and `analyze_many` raise
  `InvalidEndpointError` naming what they were given when it is not a record
  of a versioned model, such as `nil`, a model class, a relation, or a
  version. They raised a bare `NoMethodError`, or said to provide `from` and
  `to`. `report` names `since` when it is `nil` or a range.

- A scope ordered by a datetime, such as
  `-> { order(created_at: :desc, id: :desc).limit(3) }`, is read from history
  under Rails' default time-zone-aware attributes. Rails wraps those
  attributes' types, which hid the datetime, so every method raised
  `UnsupportedAssociationError` for the documented recipe.

- A `Date` bound of `within:` or `since:` is a whole day in `Time.zone`, and
  a string a time in `Time.zone`, or in UTC without one. They were read in
  the server's own zone, so the same window covered different hours on
  different servers, and a same-day `Date..Date` window covered one instant
  and found nothing.

- A `has_many :through` whose join model is not versioned raises
  `UnversionedAssociationError` naming the join model when its history is
  read, and `diagnose` reports it as an error, so `ok?` is false. A
  comparison raised a bare `KeyError` while `diagnose` reported only a
  warning.

- `reload_live_endpoints: false` reads an association with a `limit` or
  `offset`, directly or in a part it goes through, or a scope that takes the
  owner, again for each record. Active Record's `preload` applies the limit across all the records
  it loads, so with three articles preloaded, two kept one comment each and
  the third none, and their unchanged comments were reported as removed.

- A root and its associations that share one version table other than
  PaperTrail's `versions` can be compared. Association lookups joined PT-AT's
  version associations to the `versions` table whatever table the versions
  were in, so every method raised `ActiveRecord::StatementInvalid`.

- A `within:` or `since:` window whose edge falls inside a transaction that
  saved a version of the root record reports the whole transaction in the
  later window. A window starting between a comment edit and the `touch: true`
  article version saved with it showed the edit at the article's next change,
  credited to that change's author, and the window ending there left it out;
  when the article saved first, its version was in one window and the comment
  edit in the other. Each root's edges move back to the transaction's start,
  read in a fixed number of queries per 200 records.

- `activity_timeline`, and `analyze` with `activity: true`, no longer report a
  child version saved in the same transaction as the root version that ends
  the range. A `touch: true` parent version is saved this way after every
  child save. PT-AT rebuilds the parent's associations at that version as they
  were before the transaction, so the child's step was always empty and its
  change was reported nowhere. The range now ends before that transaction, as
  `compare` and `timeline` already did. End at a later version or at the
  current record to include the change, with `group: :transaction` to credit it
  to the child's version.
- A range that starts at a version now starts before that version's
  transaction, as one that ends there already ended. A child version saved
  earlier in the same transaction, such as the update behind a `touch: true`
  parent version, was read after its change, so `compare`, `analyze`,
  `timeline`, and `activity_timeline` from that version left the change out.
  It was also missing from the range ending there, so a history split at that
  version reported it nowhere. It is now inside the range that starts there.
- A past `within:` window in `activity_timeline`, and in `analyze`,
  `analyze_many`, `analyze_scope`, and `report` with `activity: true`, no
  longer includes association changes made after it. When the root had no
  version after the window, the window closed on current state, so a comment
  edited in August appeared in a July window, in its last step, `to_snapshot`,
  and `diff`; with a later root version the same window was right. It now
  closes on current state only when nothing on a requested path was recorded
  after it. The reasoning in 0.8.0, that nothing had been recorded since,
  checked only the root's own versions. `timeline`, and `analyze` without
  `activity:`, still run their last step to the root's next version or the
  current record; the reference now says so.
- Association scopes read from history now cover `IS NULL` and `IS NOT NULL`
  on a column of any type, such as a soft-delete scope's
  `where(deleted_at: nil)`, and `NOT` with SQL's rules for NULL, such as
  `where.not(position: [1, nil])`. These were read with PT-AT before, so a
  record restored from a soft delete showed as changed rather than added, and
  batch methods refused them without `allow_expensive: true`. A condition on a
  PostgreSQL `citext` column, which compares without regard to case, is no
  longer read as exact text.
- A `historical_filter:` hash casts its values, and the recorded ones, to each
  attribute's type before comparing them, as `where` does. An enum given as a
  symbol (`{ status: :published }`), and a date or time read from a `json` or
  `jsonb` version column, which PaperTrail returns as a string, never matched,
  so the report silently selected nothing.
- Versions from two version tables saved in the same instant raise
  `AmbiguousVersionOrderError`, as the reference promises, instead of being
  ordered by their ids. Each table counts its ids separately, so their order
  said nothing about which change came first, and an activity timeline built
  from them could credit a change to the wrong step.
- `compare_many`, `analyze_many`, `analyze_scope`, and `report` load a
  `has_one` of every current record in one query again, as before 0.14.0.
  0.14.0 meant to load only a `has_one` with a declared limit or offset per
  record, but checked the association's scope, to which Active Record adds
  `limit(1)` for every `has_one`, so every `has_one` cost one query per
  record.
- `report`, `analyze_scope`, and `analyze_many` with `activity: true` no
  longer read a root's current row once more for activity through a
  `has_many :through` after its last version. The batch has already loaded
  it, so the query count no longer grows with the number of roots.
- A snapshot's collections list their records by type, then ID, as the
  reference says, wherever the snapshot was read from. Snapshots rebuilt from
  history or carried through an activity timeline listed them in the order
  they were found, and a ranked association in its query's order, so `to_h` of
  the same state differed between methods. Diffs were already ordered.
- With a `json` or `jsonb` `object` column, an activity step no longer
  reports an unchanged timestamp as changed. PaperTrail returns such a
  column's times as strings, and a step after a child's update carried them
  into the snapshot as they were, so the next step that read the child again
  reported `created_at` changing from a string to the same time. Activity now
  casts them as it does every other recorded state. The specs had covered the
  JSON serializer on a text column only, which PaperTrail casts.

### Development

- A new oracle suite, `rake spec_oracle`, checks rebuilt history against the
  truth rather than against other gem methods. It makes seeded random edits to
  an article graph one transaction at a time, records the live state after
  each, and compares every endpoint, timeline step, activity step, window, and
  batch result with those states. It also checks that two windows meeting
  between transactions or inside one report each step once, scoped membership
  against Active Record, and a tree of one model whose children have
  encrypted, serialized, enum, custom-type, decimal, and JSON attributes.
  `rake spec` runs it, so CI runs it on every database. `ORACLE_SEEDS` and
  `ORACLE_STEPS` widen a run. See `docs/testing.md`.
- `PTD_PROBE_ALLOW_APPROXIMATE=1` makes the reconstruction probe pass
  `allow_approximate: true`, so its PT-AT-read scenario runs rather than
  raising, and neither benchmark passes the deprecated `close_on:` any more.
- On SQL Server the association specs keep their versions 5 ms apart. Specs
  that compare the gem with PT-AT failed at random there: PT-AT compares
  version times through SQL text, which the SQL Server adapter writes as
  `datetime` values up to 1/300 s off, and after the host clock stepped back
  the test clock packed versions microseconds apart until it caught up.
- The reporting benchmark loads the monotonic test clock, so its results no
  longer depend on the host clock. A clock that stepped backwards, as WSL2's
  does, could date a root's destroy before its last update, and
  `deleted_roots` then raised `IncompleteTimeRangeError`. The seeded history
  and query counts are unchanged. Allocations rise by under 1% in
  `many_roots` and `retained_activity`, where the gem reads the clock once
  per root. The investigation scripts that seed through the same workload
  load the clock too; `scalar_cost.rb` freezes time in front of it, so its
  parity check still sees one instant.

## [0.14.0] - 2026-10-29

### Breaking changes

- A `has_and_belongs_to_many` with a scope, or whose target has a default
  scope, raises `UnsupportedAssociationError` up front in every method, and
  `association_paths` leaves it out. PT-AT records a HABTM's members through
  its scope when the owner saves, so a target that entered the scope between
  saves was missing from history, and `activity_timeline` raised `KeyError`.
  Replace it with a `has_many :through` a versioned join model.
- `report`, and `analyze_scope` with `activity: true`, also select a record
  when only a record on one of its requested `associations:` changed in the
  window: editing a comment selects its article. They used to skip it, although
  `analyze_many` reports that activity. A report can therefore return more
  records and reach `limit:` sooner. Nested paths count at every level,
  `has_many :through` counts its join rows, and a child that moved selects its
  old and new owner. Selection adds one query per association level, not per
  record. Checkpoint analyses (`activity: false`) are unchanged: they compare a
  record's own versions, so only those select it. To keep only records that
  changed themselves, drop analyses whose `timeline` is empty. A record
  selected through a HABTM path in a window that ends at the current record
  raises `UnsupportedLiveActivityError`, as one that changed itself already
  does.
- A path that continues past a polymorphic `belongs_to`, such as
  `"notable.comments"`, raises `UnsupportedAssociationError`. The part after
  it used to be ignored without a word.
- A HABTM below the root, such as `"tags.articles"`, `"author.articles.tags"`,
  or `"comments.article.tags"`, raises `UnsupportedAssociationError` up front
  in every method, naming the path and the HABTM. `association_paths` leaves
  such a path out. PT-AT records HABTM membership only when its owner saves a
  version, in rows that do not name the owner, so a root checkpoint holds the
  root's membership alone. These paths read the root's rows instead and
  returned a wrong diff. An article that joined a tag went unreported, and
  against the current record every member read as added. A sibling article
  reached through its author was given the root's tags. `activity_timeline`
  raised `KeyError`. Only a path that led back to the root, like
  `"comments.article.tags"`, read correctly; request `"tags"` instead.
- A root HABTM read at a version saved in the same transaction as a version of
  another record with a HABTM of that name raises
  `IncompleteAssociationHistoryError`, naming the association and the
  transaction, when PT-AT recorded members there. Those rows do not say which
  record they belong to, so the root used to read every such record's members
  as its own: two articles updated in one transaction each gained the other's
  tags, and an unchanged article reported them removed. It happened in every
  method, with no error. A transaction where only one record with that
  association saved a version, or where none recorded a member, reads as
  before, and `diagnose` reports the shared case as `habtm_transaction_shared`.
  Save HABTM owners' versions in separate transactions, as a
  [checkpoint](docs/reference.md#saving-a-checkpoint) does.

### Added

- `recorded_changes(version)` returns what PaperTrail stored with one version
  in `object_changes`, as a frozen hash of `ValueChange` objects, typed by the
  version's model. Unlike PaperTrail's `version.changeset`, it never loads the
  record, so it costs no query per version and still types a deleted record's
  values. It returns `nil` when nothing was recorded, and takes an `ignore:`
  array that defaults to `updated_at`.

### Changed

- Batch reads of a `has_many :through` and of a polymorphic `belongs_to` no
  longer call `reify` on each root version. They are read from stored
  attributes like other associations. In the reconstruction probe, `report`
  over a through went from 7 `reify` calls per root to none and builds about
  half as many model instances. Results are unchanged. A type that names no
  class, an unversioned target, and a scope that cannot be read as conditions
  still take the record path.
- Batch methods read an association scope, or a target's default scope, made
  of plain conditions on the target's columns (equality, `IN`, `nil`, their
  `where.not` forms, combined with `and` and `or`) from prepared history, so
  they no longer need `allow_expensive: true` for it and its query count no
  longer grows with the records. String conditions are read this way only on
  SQLite and PostgreSQL. Scopes that take the owner and other conditions are
  still rejected without the opt-in. A default-scoped model whose scope assigns
  no attributes is read without `reify`.
- Batch methods also read a `limit` or `offset`, and the order of a `has_one`,
  from prepared history when the order is total, reaching the primary key, and
  sorts only by integer, boolean, or integer enum columns of the target. NULL
  sorts as each adapter puts it by default. In the reconstruction probe,
  `report` over `order(:id).limit(1)` went from 252 queries and 160 `reify`
  calls at 20 roots, with the opt-in, to 32 queries and none without it. A
  string order, an order with ties, and a `has_one :through` over a ranked
  part are still rejected without the opt-in.
- Batch methods also rank by date columns, and by datetime columns when the
  column declares a precision that history keeps and times are stored in UTC,
  such as `order(created_at: :desc).limit(5)` with YAML history. JSON history
  keeps milliseconds by default, so with it only a `datetime(3)` column is
  read. A time-of-day column, and a datetime without a precision, are still
  rejected without the opt-in.
- Batch methods read a `has_many :through` over a part with a `limit`,
  `offset`, or `has_one` order, and one with its own `limit` or `offset`, from
  prepared history without the opt-in.
- The README recipe for deleted records also reads each record as it was just
  before deletion, which a record created inside the window has no other
  snapshot of.
- The documentation now says where a change saved without a version, such as
  with `update_columns`, appears: in the step for that record's previous
  recorded change, credited to its author, anywhere in a range. It used to say
  only that the last step of a range ending at the current record shows them,
  and that a step's diff is exactly what its event changed. Ending a range at a
  version leaves out only the writes after it. Specs pin this behavior, which
  is unchanged.
- The README has a recipe that turns a report into one row per changed field,
  with the record, whether it changed, appeared, or disappeared, and the step's
  author, event, and time.
- Batch methods no longer need `allow_expensive: true` for a
  `has_many :through` whose source is a `has_many`, such as an author's
  comments through articles. It is read from prepared history like the other
  associations, so its queries no longer grow with the records: the five-record
  probe in `docs/performance.md` went from 200 queries to 20.

### Fixed

- A `limit` or `offset` scope, or an ordered `has_one`, read at a version
  returns the records its query returned then, when the order is total and
  sorts by columns batch methods can rank. It used to start from
  the association's current rows, so a range whose records later changed
  reported the wrong ones: with comments `first` and `second` under
  `order(:id).limit(1)`, destroying `first` and adding `third` reported
  `third` added instead of `second`. Other ranked scopes still read the
  current rows.
- A `has_many :through` reads its parts as its own query does, keeping their
  conditions but not their `limit`, `offset`, or `has_one` cut. History used
  to apply them, and read with the opt-in it could raise PT-AT's
  `FoundMoreThanOne`; batched history kept only one record through a `has_one`
  part. A through's own `limit` or `offset` counts a record reached through
  two join records twice, as the query does.
- Batch comparisons with a current endpoint load a `has_many :through` over a
  part with a `limit`, `offset`, or `has_one` per record. Active Record's
  preloader applied the part's limit across every record in the batch, so a
  record could show another's members or none.
- A record reached through two join records is one member of a current
  association, as it already was of a historical one, so a through loaded per
  record no longer raises a duplicate identity error.
- In a batch, a `has_one` with an `offset` is loaded per record at the current
  end. The preloader applied the offset across all records at once, so a
  record could show another record's member.
- Activity reports a change to a `belongs_to` target that is an STI subclass.
  When the target was destroyed, or its `type` changed between a subclass and
  another class, activity reported nothing while checkpoint analysis reported
  it, because a target's version names only the base class. This includes the
  same target further down a path, such as `"note.badge"`.
- An association that only an STI subclass declares can be requested on a
  root of that subclass in every method. Without an `item_subtype` column on
  versions, each version resolved to the base class, so every method raised
  `UnknownAssociationError`. The subclass is now read from the type the
  version stored, or for a `create`, from its recorded changes. A stored type
  that names no class raises `InvalidEndpointError`.
- A `has_many :through` with `source_type:` holds only the records reached
  through join records of that type, in every method. History used to ignore
  the option, so a join record pointing at another type made its target a
  member: a holder whose links named a tag reported the tag among its authors,
  and the tag's changes opened activity steps and selected the holder in
  `report`. The current record was read correctly, so a comparison with it
  reported the tag as removed. A join record whose type changes now adds or
  removes its target in the step of that version.
- A scoped or default-scoped association read from history now holds the
  records that met the scope at each point. It used to ignore the scope's
  conditions for history: a record that left the scope was reported as
  changed instead of removed, one that entered it as changed instead of
  added, and a record outside the scope could be reported as removed when it
  was destroyed or moved. Activity reports entering or leaving the scope as
  an addition or removal at the version that did it.
- `compare` and `compare_many` between two versions report a `has_many` child
  that moved to another owner afterwards. They reported no change: the
  comparison read associations through PT-AT, which finds children by the keys
  their versions recorded after each change, so the child was not found at the
  earlier version. Version pairs now read the same prepared history as a
  comparison with the current record, including for a record that was deleted.
- Historical analysis through a polymorphic `belongs_to` works in every method.
  Only comparisons between two versions used to work: timelines, analyses,
  reports, and comparisons with the current record raised `ArgumentError`.
  Batches load the targets with one query per target class. A target class
  without `has_paper_trail` raises `UnversionedAssociationError` when a record
  names it, rather than a `NoMethodError` from PT-AT, and a default-scoped
  target class is read as its association returns it. A type that names no
  class, such as one a renamed model left in its versions, raises
  `IncompleteAssociationHistoryError` naming the record and the type, rather
  than a `NameError` that names neither.
- Activity leaves out the `belongs_to` target a record moves to in the
  version that closes the window. Its changes inside the window used to add
  empty steps, attributed to a record the root never pointed at there.
- Activity reports a change to a `belongs_to` target, or to the source of a
  `has_many :through`, when the record pointing at it did not change in the
  window: an author renamed under an article nobody edited. It used to report
  nothing. A record that changed its target in the window also reports
  changes to the target it pointed at before.
- `include_deleted: true` with `activity: true` reports the association
  activity of a deleted record that did not change itself in the window. Its
  analysis used to be empty.
- History of an association to an STI subclass, such as
  `has_many :pinned_badges, class_name: 'PinnedBadge'`, holds only that class
  and its subclasses, as the live association does. It used to hold the
  sibling classes' records too, so a range ending at the current record
  reported them as removed. Activity used to report a sibling's changes under
  the association too, and to open a step for each version of a sibling or of
  its children.
- Activity reports a record whose STI type changed in the step of the version
  that changed it, as a removal of the old type and an addition of the new,
  and adds it to or removes it from an association to an STI subclass there.
  It used to add the new type alongside the old one and leave the old one in
  place until a later step, or to the end of a range ending at a version.
- `activity_timeline`, and `analyze` with `activity: true`, return no steps for
  a range that ends at a version when `version_scope:` keeps none of its
  versions, as a checkpoint timeline does. They used to raise `NoMethodError`.
- `analyze_scope` and `report` list `unreachable` in the same sorted order
  whatever the type of `versions.item_id`. With a string `item_id` it used to
  follow the database's order.
- On SQL Server, activity places a version saved within two milliseconds of a
  window's start or end on the side it was saved. The window's bounds used to
  be rounded to 1/300 second, so such a version could be read as outside the
  window, or one just past its end as inside it.
- A `has_many :through` that goes through a `has_and_belongs_to_many`, as its
  `through:`, its `source:`, or further down its chain, raises
  `UnsupportedAssociationError` up front in every method, naming the path and
  the HABTM. Comparing two versions used to raise `NoMethodError` from inside
  PT-AT, and analyses `ActiveRecord::StatementInvalid`. A `has_many :through`
  Active Record cannot follow at all, such as one through a polymorphic
  `belongs_to`, likewise raises Active Record's own error in every method,
  where historical work used to fail partway with `ArgumentError` or
  `NoMethodError`.
- `association_paths` leaves out a `has_many :through` that goes through a
  `has_and_belongs_to_many`, so every path it lists can be requested. It
  decides with the same check a request makes. It used to list such a path,
  and a settings screen built from it offered one that failed when picked. A
  model it reaches with a `has_many :through` Active Record cannot follow,
  such as one through a polymorphic `belongs_to`, raises Active Record's own
  error, where discovery used to raise `ArgumentError`, `NameError`, or
  `NoMethodError` from inside the reflection, or list a path that raised when
  requested.
- A `has_many :through` whose source is a `has_many` follows records that
  move. A comment moved to another article leaves the first article's author
  and joins the other's, and an article that moves to another author takes its
  comments with it. Analyses, timelines, and comparisons with the current
  record used to report no change for such a move, and could report a record
  that left and came back as changed. They read these associations through
  PT-AT, which finds a record by the keys its later versions recorded.
- A `has_many :through` whose `through:` is itself a `has_many :through`, such
  as `has_many :comment_reviewers, through: :comments, source: :reviewer` with
  `comments` through `articles`, reports its changes in analyses, timelines,
  and batches. It used to read as empty at every point, so it never reported a
  change.

### Development

- Mutation testing also covers `ScopeCondition`, which decides the records an
  association scope admits. The reconstruction probe has a `scoped` scenario.
- The consistency specs also check that activity selection includes every
  record whose analysis reports a change.
- Mutation testing also covers `TimeRange`, `VersionRange`,
  `TimeVersionRange`, `BatchedRootVersions`, and `DeletedAnalysisBatch`, each
  with a unit spec of its own; all 5,485 mutations across the fourteen classes
  are caught.
- Mutation testing also covers `RecordedChanges`; all 257 of its mutations are
  caught.
- Mutation testing also covers the association code: `ScopedRootSelection`,
  `AssociationActivitySelection`, `AssociationActivityEdge`,
  `ActivityTargetCandidateLoader`, `PreparedHistoryLoader`,
  `PreparedEdgeLoader`, `ActivityTimelineBuilder`,
  `ActivityTransactionGrouper`, and `BatchSafety`, each with a spec of its
  own. All 10,732 mutations across the 24 classes are caught.
- Mutation testing also covers `AssociationTraversal`, which decides which
  association paths a request accepts, with a spec of its own; all 764 of its
  mutations are caught.
- Mutation testing also covers range and boundary handling:
  `ActivityRange`, `VersionAssociationCandidateScope`, and
  `PreparedActivityIndex`, each with a spec of its own; all 1,507 of their
  mutations are caught.
- Mutation testing also covers `HabtmTransactionOwners`, which decides whether
  a transaction's HABTM members can be read as one record's, with a spec of
  its own.
- `benchmark/investigation/reconstruction.rb` runs again: the association
  fixtures load the monotonic test clock they use. Its `prepared-through`
  experiment and `benchmark/investigation/prepared_through_override.rb` are
  removed, since the gem now reads those throughs that way.
- `spec/association/through_membership_spec.rb` writes out the expected
  membership of a `has_many :through` with a `has_many` source over moves,
  deletions, transactions, and changes saved without a version, alone and in
  a batch.
- `ActivityEventRouteFinder` no longer checks for a polymorphic `belongs_to`
  before following a path below it. Validation already rejects such a path,
  so the check could not be reached.
- The `PreparedHistoryLoader` spec checks that an edge into a versioned model
  with records stays prepared. A full mutation run of the 29 classes now
  catches all 13,284 mutations.

## [0.13.1] - 2026-10-28

### Fixed

- A collection transition whose before and after records have different
  identities reports the before record as removed and the after record as
  added. It used to report nothing. No current caller builds one, but
  `AssociationSnapshot#transition_to` accepts it.
- A record with a composite primary key, read from prepared history, gets the
  same id as when it is read live: the key's values. It was `nil`.

### Changed

- `RecordSnapshot.new` requires `type:` to be a String and raises
  `ArgumentError` otherwise. It used to convert any value with `to_s`.

### Development

- Mutation testing gives each mutation 60 seconds instead of mutant's 5-second
  default. Mutant counts a timeout as a kill, so mutations no spec caught were
  reported as caught. With the longer limit, 123 surfaced in
  `CollectionComparator` and `CollectionIdentityIndex`; each class now has a
  unit spec, and all of them are caught.
- Mutation testing also covers `SnapshotNormalizer`, `SnapshotPool`,
  `TimelineRange`, `RootVersionPlan`, and `HistoricalFilter`, each with a unit
  spec of its own; all 4,040 mutations across the nine classes are caught.
  Versions are ordered by time and then id through one shared helper.
- The full mutation run moves to a nightly workflow that runs only when `main`
  has an untested commit, so a later push no longer cancels it. Pull requests
  still mutate the methods they change.

## [0.13.0] - 2026-10-28

### Breaking changes

- `:last` is no longer accepted as an endpoint. It named the last version, whose
  recorded state is the one *before* the latest change, so ranges ending there
  silently left that change out. Omit `to:` to end at current state, or pass a
  version. Passing `:last` raises with that advice.
- `analyze_many` without `within:` now ends each record's history at its current
  state, so the latest change is included. It previously stopped at the last
  version.
- Batch methods reject scoped associations, default-scoped targets, and
  `has_many :through` associations whose source is not a `belongs_to`, because
  they need queries per record. The error names the association. Pass
  `allow_expensive: true` to accept that cost.
- `Step#to_h` returns `{ from:, to:, diff: }`, the same shape as
  `ActivityStep#to_h`, with boundary hashes on both sides. Read the version ids
  from `from[:version_id]` and `to[:version_id]` instead of `from_version_id`
  and `to_version_id`; `metadata: true` adds details to both boundaries.
- `analyze_many` takes only an array of records. Use `analyze_scope` with a
  model or relation; `analyze_many(scope:, limit:)` and the scoped options it
  accepted have been removed.

### Added

- `report(scope, since:, limit:)` for recent activity through current state.
- `historical_filter:` on `analyze_scope` and `report`, selecting records by
  values they had at any point in the window: their state when it started and
  after each change inside it. Pass an attribute hash, which reads stored values
  without reifying, or a callable. `max_filter_versions:` (default 10,000) caps
  the versions it loads and raises `FilterLimitExceededError` beyond that.
- `include_deleted: true` on `analyze_scope` and `report`, returning analyses of
  deleted records in `deleted` (`nil` when no destroy version was recorded).
  Existing and deleted records together count toward `limit:`.
- `ScopedAnalysis#roots`, the selected records in relation order.
- `timeline`, `activity_timeline`, and `analyze` default to `from: :first` and
  `to: record`, so `timeline(article)` covers the whole history through the
  current saved record.
- `source_boundary` on both step types names the event whose change a step
  reports. For a transaction group it is the first event.
- `metadata: true` on `to_h` for boundaries, steps, and analyses adds author,
  event, transaction ID, and record. `ActivityStep#to_h(snapshots: true)` and
  `Analysis#to_h(snapshots: true)` include retained states.
- `group:` and `snapshots:` on `analyze_many` and `analyze_scope` with
  `activity: true`.
- Explicit current-record `to:` endpoints on `timeline` and `analyze`.

### Changed

- A `within:` window with no version after its last change closes on the current
  record instead of raising `IncompleteTimeRangeError`. Nothing has been
  recorded since that change, so the current record holds what it produced.
  This also applies to windows in which only chosen associations changed.
  `close_on: :current` is no longer needed and is still accepted.
- Live-ended HABTM activity is rejected only when a range actually ends at the
  current record, including in batches.
- `compare` with `associations:` reads association state from the prepared
  history `compare_many` uses, instead of PT-AT's timestamp-only reifier.
- Plain recorded attributes of root and direct-child records are read without
  building a model instance per historical state. Models with initialization
  callbacks, custom types or defaults, default scopes, or encrypted attributes
  still use PaperTrail's `reify`.
- Batch activity reports share association discovery and prepared history
  across records, and each analysis reuses its checkpoint snapshots, so standard
  reports no longer add queries per record.
- Activity without changesets uses prepared successor states instead of a query
  per event.
- `has_many :through` reconstruction visits only the requested source
  association.
- Scope selection keeps candidate records in a database subquery when
  `versions.item_id` and the primary key share a column type, reads joined rows
  in pages of 250, and sorts `unreachable`.
- `snapshots: true` without `activity: true` raises `ConfigurationError`, as
  `group:` already did, instead of being ignored.
- The README is now a set of recipes; the full API reference and architecture
  notes are separate pages.

### Fixed

- Association timelines no longer raise `duplicate record identity` when
  `versions.item_id` is a string column (PaperTrail's setup for UUID keys) and
  associated models use integer keys.
- Columns listed in `has_paper_trail skip:` are left out of snapshots. PaperTrail
  never stores them, so comparing history with the current record reported them
  as changed from their default.
- `analyze_many(..., activity: true)` reports association activity for a record
  with no version of its own in the window, matching `analyze`. It previously
  returned an empty analysis.
- Histories stored with PaperTrail's JSON serializer or a `json`/`jsonb` object
  column no longer report every timestamp as changed when compared with the
  current record.
- Association changes at versions sharing a timestamp are placed by version id,
  so `compare`, `compare_many`, and `timeline` no longer put them on the wrong
  side of a boundary. Ties that ids cannot order raise
  `AmbiguousVersionOrderError`.
- A window that closes on the record's deletion ends its `diff` and
  `to_snapshot` at "no record". A record created and deleted inside the window
  previously read as added.
- `compare_many` resolves `:first` to each record's earliest version by time,
  not the lowest id, which differs for UUID version ids.
- `version_scope:` is honored on activity timelines that end at the current
  record.
- Batch, single-record, and scoped activity results agree on the reporting
  window and closing state.
- A lone creation or update in an activity window that ends at the current
  record is reported.
- Joined relations count unique records against `limit:` without adding SQL
  `DISTINCT`, so ordering by joined columns works on PostgreSQL and SQL Server.
- Nested results are fully frozen, including nested paths and empty results.
- Nested object diffs match string and symbol keys consistently and raise
  `AmbiguousNestedKeyError` on collisions instead of losing a change.

### Development

- CI runs both suites on PostgreSQL 17, MySQL 8.4, and SQL Server 2022 alongside
  the SQLite Ruby/PaperTrail matrix. Database adapters are optional development
  dependencies.
- The type-check gate fails on Steep internal errors and checks public API call
  examples.
- RuboCop runs with the rubocop-performance and rubocop-rspec plugins.
- Consistency specs check that every method agrees on seeded, generated
  histories across schema and serializer variants.
- Mutation testing with mutant covers the comparison code, in CI and through
  `rake mutant`. New specs close the gaps it found: attributes present on only
  one side, a record removed, singular relationships added or removed, and
  JSON values held in Hash, Array, or String subclasses.

## [0.12.0] - 2026-08-19

### Changed

- Report an array inside a JSON column by membership rather than as one opaque
  value. `nested_changes` now returns a `PaperTrailDiff::ArrayChange` for a pair
  of arrays, carrying `added`, `removed` and `reordered?` alongside the whole
  `from` and `to` it already had. Position is deliberately not reported:
  elements carry no identity, so an insertion at the front makes every later
  index look changed and one insertion reads as several edits. Membership is
  answerable without claiming any pairing. Matching is by value and respects
  duplicates, so `["a", "a"]` to `["a"]` reports one removal. The one thing
  membership cannot see -- the same elements in a new order -- is named rather
  than passed over. An element that is itself an object is reported whole,
  since saying which of its fields changed would require pairing before- and
  after-elements that nothing in the value licenses.

## [0.11.0] - 2026-08-18

### Added

- Add `PaperTrailDiff.analyze_scope`, which selects the roots to analyze from an
  ActiveRecord relation or model class instead of an array the caller assembled,
  in a fixed number of queries. Also reachable as
  `PaperTrailDiff.analyze_many(scope: ..., limit: ...)`. Every other option
  behaves as it does for `analyze_many`.
- `analyze_scope` returns a `ScopedAnalysis`, which destructures into the usual
  analyses hash and the roots the relation could not reach. A relation's
  conditions are evaluated against the live table, so a root destroyed during
  the window cannot be tested against them at all, even though its history is
  intact and the state it held at destruction may have matched. Those roots are
  named rather than dropped, so a page auditing deletions is told where to look
  instead of coming up short without saying so.
- Add `PaperTrailDiff.nested_changes`, which reports the keys that changed
  inside an attribute the database stores whole, such as a JSON or jsonb column
  or one holding JSON as text. An attribute diff could only say the blob
  changed, leaving the caller to diff it again by hand. Paths are arrays rather
  than dotted strings, because a JSON key may itself contain a dot. Arrays are
  reported whole rather than by index, since their elements carry no identity
  and a list that merely shifted would otherwise look changed throughout. A key
  that was absent reads as `NestedComparator::ABSENT` rather than nil, because
  `{"a": null}` and `{}` mean different things in JSON and an audit trail that
  showed them alike would be lying about one of them. Additive: the existing
  attribute diff is unchanged, and a pair that is not two readable structures
  reports nothing.
- Raise `PaperTrailDiff::BatchLimitExceededError` when a relation selects more
  roots than `limit:` allows. `limit:` is required for `analyze_scope`: root
  selection moves into the gem, so the bound on how much work one page can ask
  for moves with it. It refuses rather than truncating, because a report that is
  quietly short is worse than one that fails.
- Accept `group: :transaction` on `activity_timeline` and `analyze(activity:
  true)`, reporting one saved transaction as one step. A parent and its
  children saved together produce a version each, so one deliberate action
  arrived as several steps, and some of them read as empty even though a change
  was made at that boundary: a version records the state before its own event,
  so a child's new value is revealed only by a later version of that child, its
  destroy version, or the live row, none of which exists yet inside the
  transaction. The change therefore surfaced a step or more later, folded in
  with whatever that step carried. A step belongs to the transaction of the
  event that opens it, since that is the event whose change it reports; a step
  therefore belongs to its `from_boundary`'s transaction, and consecutive steps
  sharing one are the parts of a single save. Merging compares the group's
  outer states rather than combining the diffs between them, so a field set and
  restored inside one transaction correctly reports as unchanged. Off by
  default.
- Expose `ActivityBoundary#transaction_id`.
- A boundary that records no transaction groups with nothing. PaperTrail leaves
  the column nil outside a transaction and a custom version class need not
  carry it at all, so treating those as one shared transaction would merge
  unrelated history into a single step.

### Changed

- Check that the generated Appraisal gemfiles match the `Gemfile`, in CI and in
  `rake release:preflight`. Every other job runs against a generated gemfile, so
  a dependency changed only in the `Gemfile` was one CI never installed: the
  jobs passed having exercised the old version.

### Fixed

- Resolve "does this model record history" through one predicate,
  `Support.versioned?`. Three copies existed and one of them tested only
  `respond_to?(:paper_trail)`, which PaperTrail defines on every ActiveRecord
  model and which therefore answers true for models that never called
  `has_paper_trail`. Nothing reached that copy with an unversioned model, since
  the traversal preparer rejects those first, so no released behaviour changed --
  but the check looked right while being unable to fail, and reading history
  through it would have raised at the version class rather than at the question.

## [0.10.0] - 2026-08-15

### Added

- Add `rake release:preflight`, which runs the full gate and then checks
  everything that must hold before a tag: a clean working tree, a HEAD that
  matches its upstream, an unused tag, a dated changelog section for the
  version, and that the version is not already on RubyGems. It reports and
  never tags, pushes, or publishes. An unreachable RubyGems is reported as
  unknown rather than treated as "not published".
- Raise `PaperTrailDiff::UnversionedAssociationError` when a selected
  association's target is not versioned and history is being reconstructed.
  Such a comparison could only ever answer "nothing changed", which is a wrong
  answer rather than an empty one. Live-to-live comparison reads current state
  and is unaffected. `diagnose` now reports the same condition as an error
  rather than a warning, so `ok?` no longer stays true for a comparison that
  will raise.
- Document ActiveStorage attachments, which this reaches through:
  `has_one_attached` points at models Rails owns and PaperTrail never versions,
  so attachments are audited through a versioned model of your own that mirrors
  the metadata onto ordinary columns.

## [0.9.0] - 2026-08-14

### Added

- Report versions that share a timestamp, which hides any association change
  between them: PT-AT records membership per version but resolves it by
  timestamp, so such a pair is indistinguishable even when sequential ids order
  it correctly. `diagnose` reports `:tied_version_timestamps` as a warning when
  `associations:` are selected, and a comparison in that state emits
  `ambiguous_association_boundary.paper_trail_diff`. It warns rather than
  raising because the result may be perfectly correct — if nothing associated
  changed, nothing was lost — and the gem cannot distinguish the cases, since
  not seeing the change is the symptom.

### Changed

- Link the demo application from the README now that it is public.

## [0.8.0] - 2026-08-12

### Added

- Accept `snapshots: true` on `activity_timeline` and `analyze(activity: true)`,
  retaining the reconstructed states each step was compared between as
  `ActivityStep#from_snapshot` and `#to_snapshot`. A diff names what changed; a
  renderer that has to name an unchanged field of a changed record needed the
  whole state and had no way to reach it, so consumers were rebuilding it from
  the version table by hand — slower, and easy to get wrong in ways that stay
  quiet. The gem already builds these states to compute each diff and discarded
  them, so the option costs no extra queries. Off by default because each one
  holds the whole selected graph.
- Add `examples/demo.rb`, a self-contained tour that needs no application: it
  builds an in-memory database, writes a small multi-author history, and prints
  an endpoint diff, a checkpoint timeline, per-person attribution across a
  nested record, and one person's changes alone. It runs standalone, inside a
  project, or under `bundle exec`, fetching what it needs on first run.

- Raise `PaperTrailDiff::AmbiguousVersionOrderError` when versions sharing a
  timestamp have ids that cannot order them. Ordering falls back to the id when
  timestamps tie, which recovers the real sequence only while ids increase with
  insertion; a UUID version id does not, and a MySQL `datetime` column stores
  whole seconds, so the two together are ordinary rather than exotic. The gem
  previously returned a plausible-looking timeline with steps in the wrong
  order and others dropped. `diagnose` reports the same condition as an error
  so it can be caught before a run rather than after a wrong answer.
- Document the model and schema shapes the suite covers: single-table
  inheritance (results are keyed by the base class, so build keys with
  `Endpoint.identity`), non-integer primary keys, and a custom version class
  via `has_paper_trail versions: { class_name: }`.

### Changed

- Create the models it uses in the quickstart. It declared `has_paper_trail` on
  an `Article` and then used `Comment` without ever generating either, so
  following it in a new application failed on a missing table at the first
  console step.
- Run `diagnose`'s version-order check whether or not `associations:` are
  selected, so a report never answers `ok?` having inspected nothing. Document
  that `ok?` means no errors among the checks that ran.

### Fixed

- Cover `Analysis#to_h(snapshots: true)` with specs. It was shipped in 0.6.0
  with no test at all.

## [0.7.1] - 2026-08-11

### Fixed

- Load each current endpoint once per call instead of once per request for it,
  so `close_on: :current` no longer costs a live read per root and
  `analyze_many` keeps the flat query cost it exists for. A twenty-root batch
  closing on current state issued 43 queries against the 3 a closed window
  needs. Every root in one result now also reflects the same instant rather
  than whenever its turn came.

### Changed

- Name the way out in `IncompleteTimeRangeError`: the message now points at
  `close_on: :current` and at narrowing the window. Its previous advice — add a
  checkpoint after the window — cannot be followed by a report about the
  present, which is the case that raises it most.
- Correct the `reload_live_endpoints:` documentation, which claimed `timeline`
  and `analyze` never read live state. They do under `close_on: :current`, and
  they do not accept the option.

## [0.7.0] - 2026-08-11

### Added

- Accept `close_on: :current` on `timeline`, `activity_timeline`, `analyze`, and
  `analyze_many`, closing a wall-clock window on the live record when no later
  root version can reveal its final mutation. A window ending at the present
  otherwise raises `IncompleteTimeRangeError`, since a version records the state
  before its own event and nothing follows the last one. The closing step's
  `to_boundary.kind` is `:current` and its `to_version` is `nil`; `Step#to_h`
  now carries `to_boundary` so a serialized step still names its endpoint. Only
  valid alongside `within:`, because an explicit `from:`/`to:` range already
  says where it ends. Under `activity: true` the window runs to the instant
  state is captured rather than to the last root version, so a descendant that
  moved after that version is reported rather than dropped. A destroyed root has
  no current state to close on and keeps closing on its own destruction.

### Changed

- Document that `version_scope:` selects root versions only, and that "what did
  this person change?" is answered by an activity timeline filtered on
  `step.from_boundary.whodunnit` instead. A step's diff is exactly what the
  event at that boundary did, so the predicate covers descendant edits, which a
  root-version filter cannot see at all. Filtering in Ruby rather than selecting
  fewer versions is also what keeps the attribution correct: every boundary has
  to be reconstructed, or the snapshot carried into the next step is a state the
  record had already moved past.

## [0.6.0] - 2026-08-11

### Added

- Accept `version_scope:` on `timeline`, `activity_timeline`, `analyze`, and
  `analyze_many`, narrowing which root versions count as selected mutations.
  Excluded versions are still loaded, because a version records the state before
  its own event and the one following a selected change is what reveals it;
  their own changes are never attributed to a selected mutation. Each selected
  mutation is bounded by the version that immediately followed it rather than by
  the next selected one, so its diff is exactly what that mutation did however
  many excluded changes follow it. A selected mutation nothing follows yet is
  not reported, since no version records the state it produced; a selected
  destruction is the exception, because the absence it leaves is what it
  produced and `activity_timeline` closes on it. A root left with
  no selected mutation reports an empty `Analysis`. Under `activity: true` the
  filter decides the span; `activity_timeline` still lists every boundary inside
  it, because dropping one would fold its change into a neighbouring step.
- Expose `from_snapshot` and `to_snapshot` on `Analysis`, the reconstructed
  states its diff was taken between, so a report can render unchanged columns
  without selecting versions or reifying them itself. `Analysis#to_h` keeps its
  shape by default and takes `snapshots: true` to include them, because they
  carry the whole selected graph whether or not anything changed.

## [0.5.0] - 2026-08-11

### Added

- Add `analyze_many`, which analyzes many roots over one shared `within:` window,
  or over each root's whole history when the window is omitted, selecting their
  versions and preparing their history once for the batch. Query cost is flat in
  the number of roots for the endpoint diff and checkpoint timeline; descendant
  event discovery under `activity: true` remains per-root. A root with no
  versions in range returns an empty `Analysis`, and roots are supplied as live
  records so a root deleted inside the window cannot be included.
- Accept `:first` and `:last` as `compare_many` endpoints, resolved against the
  record the pair's other endpoint names, in two queries per model class rather
  than one lookup per root. A root with no recorded history compares as an empty
  `Diff`, and an unanchored `{ from: :first, to: :last }` raises.
- Accept `reload_live_endpoints:` on `activity_timeline`, which reads live state
  whenever `to:` is a current record but previously had no way to reuse an
  already-preloaded graph. `timeline` and `analyze` are bounded by versions and
  never read live state, so the option is deliberately absent there.

## [0.4.0] - 2026-08-11

### Added

- Close an activity timeline that ends at the root's own `destroy` version with
  a step into a new `kind: :destroyed` boundary, reporting the record's removal
  as a `record_presence_change` to `nil`. `ActivityBoundary` gains a
  `destroyed?` predicate, so consumers branching only on `version?` should
  handle the third kind. `compare`, `timeline`, and `analyze`'s endpoint diff
  are unchanged.
- Accept a `within:` window whose last selected mutation is the root's own
  destruction, which no later root version can follow, instead of raising
  `IncompleteTimeRangeError` for a range that could never be satisfied. A
  destruction outside the window remains reconstruction context only.
- Accept `:first` and `:last` as `from:` and `to:` boundaries on `timeline`,
  `activity_timeline`, and `analyze`, resolved without depending on the order
  the `versions` association happens to use. A record with no versions resolves
  to an empty timeline rather than raising, so listing pages need no special
  case.

### Removed

- Reject two version endpoints given in reverse chronological order with the
  new `PaperTrailDiff::ReversedEndpointsError`, in `compare` and
  `compare_many`. A transposed pair silently produced the inverse diff, and a
  result carries no direction that would reveal it. A current-record endpoint
  may still appear on either side.

### Fixed

- Rebuild prepared scalar state with direct attribute writes so a model that
  overrides an attribute writer reconstructs the state PaperTrail recorded
  instead of reapplying the override.

### Changed

- Order collection `added`, `removed`, and `changed` results naturally within
  one id type instead of by the printed form, so numeric ids sort `2` before
  `10`. Ordering remains deterministic and total for mixed id types.
- Resolve a boundary's prepared record state by chronological search and an
  indexed boundary transaction instead of scanning a record's versions, so
  timelines over long single-record histories stay linear in their step count.
- Bound prepared scalar history at the selected range plus one trailing version
  per identity, instead of every version recorded between the range and the
  present, so a short range early in a long history no longer pays for the
  history after it.
- Document that `timeline` and `analyze(activity: true)` produce the same
  root-checkpoint steps through different reconstruction strategies, and when
  each one is cheaper.
- Borrow a connection through `with_connection` where Active Record provides
  it, so applications that opt into deprecating permanent checkouts no longer
  see a deprecation warning from association candidate selection.
- Identify carried-forward collection snapshots and per-pass reification by
  an owned serial and by record identity, rather than by `object_id`, which
  Ruby only guarantees to be unique among live objects.
- Retain activity-event routes for every event type a timeline visits, rather
  than only the most recent one, so interleaved descendant types stop
  rediscovering the same routes.
- Resolve excluded attributes once per model class and selected path, and key
  historical child identities instead of rescanning them.

## [0.3.1] - 2026-08-10

### Fixed

- Preserve immutable activity snapshots for nested events that do not match a
  selected child record, instead of reporting a false change.

### Changed

- Split activity-event reconstruction, route discovery, relationship matching,
  collection mutation, and `belongs_to` target application into focused
  internal collaborators without changing result shapes.
- Reuse immutable activity-event routes and cached branch components across
  repeated event types to reduce timeline allocation overhead.

## [0.3.0] - 2026-08-10

### Added

- Add `within:` time-range selection to checkpoint timelines, activity
  timelines, and combined analysis, with inclusive/exclusive end handling and
  explicit errors when a final mutation cannot be reconstructed.
- Add `compare_many` for collection reports, with batched current-root loading,
  bounded live-association preloading, cross-root prepared history, immutable
  identity-keyed results, and scale-invariant query regression coverage.
- Add opt-in reuse of fully preloaded current endpoints and namespaced
  ActiveSupport runtime instrumentation without automatic logging, including
  end-to-end activity-timeline duration and step counts.

### Changed

- Teach timeline filtering through the shared `Step#empty?` protocol in the
  README and quickstart examples.
- Reuse the live graph loaded by `compare_many` while preparing historical
  association state, and defer root version loading until an edge needs it.
- Reuse collection identity positions and adjacent transition hints so activity
  steps compare only the changed member, and resolve direct nested collection
  owners by foreign key instead of scanning every parent snapshot.
- Reuse prepared predecessor and successor scalar states for isolated activity
  updates instead of reifying and deserializing each PaperTrail event again.
- Preserve both sides of nested collection membership moves by using the
  general comparator when one event changes multiple parent snapshots.
- Preserve per-owner `limit`, `offset`, and owner-dependent association scopes
  in `compare_many` while retaining batched preloading for safe branches.
- Replace lifetime association-identity materialization with an indexed start-state
  checkpoint plus post-boundary activity and current members.
- Bound historical activity-child candidates at the selected end so membership
  changes after the range cannot introduce unrelated empty timeline steps.
- Decode compatible prepared scalar version payloads without constructing an
  intermediate Active Record object, with reification fallback for unsafe schemas.
- Reuse internally owned frozen collection arrays instead of defensively copying
  them a second time during immutable activity reconstruction.
- Replace pre-existing versions-relation ordering when selecting a time range's
  immediate trailing reconstruction boundary.
- Limit automatic CI to pull requests and `main` pushes, and cancel superseded
  runs for the same pull request or ref.

### Fixed

- Supply TZInfo's timezone database to the test bundle so zoned-time coverage
  runs on Windows as well as systems with a native zoneinfo database.

## [0.2.0] - 2026-08-09

### Added

- Add deterministic `Diff#each_entry` and `Diff#each_change` traversal with
  immutable `TraversalEntry` values for renderers, counters, exports, and
  notifications.
- Add immutable version metadata and record references to activity boundaries.
- Give checkpoint `Step` objects `from_boundary` and `to_boundary` readers and
  give both timeline step types an `empty?` predicate.
- Add a Rails-focused quickstart with minimal endpoint, timeline, ignore, and
  association examples.
- Execute selected README and quickstart examples in isolated core and PT-AT
  test sessions so documented behavior cannot silently drift.

## [0.1.0] - 2026-08-09

### Added

- Add explicit, bounded nested association paths such as
  `comments.replies.author`.
- Add nested association changes to stable-record diffs and selected subtrees
  to added/removed record snapshots.
- Add path-aware ignore rules while preserving the existing global array form.
- Add root and nested `has_and_belongs_to_many` collection diffs, including
  historical membership, target updates, timelines, and bounded cyclic paths.
- Reload the configured PaperTrail versions association before resolving
  timeline boundaries.
- Rename the root `Diff#record` lifecycle field to the more explicit
  `Diff#record_presence_change`, including its `to_h` key.
- Add `activity_timeline` for adjacent root and selected-descendant version
  boundaries while preserving the root-only semantics of `timeline`.
- Add one-pass `analyze`, bounded association discovery, and structured history
  diagnostics.
- Bound version loads to the requested time range, stream timeline construction,
  and reuse immutable snapshot subtrees across adjacent boundaries.
- Apply event-local snapshot deltas for direct `has_many` membership changes at
  any selected depth and selected non-polymorphic `belongs_to` target events,
  with safe reconstruction fallbacks for other association shapes.
- Reconstruct post-create/update records from PaperTrail's serialized change
  pairs to avoid per-event successor and live-record lookups.
- Derive combined endpoint, root-timeline, and activity results from one
  snapshot pass; advance isolated root changes in place and selectively refresh
  only ambiguous association branches.
- Add `RecordReference`, consistent configuration error subclasses, traversal
  foreign-key suppression, and fail-loud HABTM endpoint validation.
- Fix selective `has_many :through` reconstruction by reifying the hidden
  through collection before resolving target records.
- Prepare timeline record states and association membership once per requested
  range, using indexed resolution for direct relationships, belongs-to-source
  through collections, and transaction-backed HABTM membership.
- Retain point-in-time PT-AT reconstruction as a per-reflection fallback for
  scoped, unversioned, composite-key, and unsupported through shapes.
- Keep multiple selected descendant events in one transaction atomic instead
  of applying an individual event delta before the transaction boundary.
