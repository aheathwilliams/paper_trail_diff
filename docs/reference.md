# API reference

Start with the [README](../README.md) examples or the
[Rails quickstart](../QUICKSTART.md). This page lists every method and option,
including ones most applications never need.

## Contents

- [How PaperTrail stores history](#how-papertrail-stores-history)
- [Choosing a method](#choosing-a-method)
- [Choosing a range](#choosing-a-range)
- [compare](#compare) and [compare_many](#compare_many)
- [timeline](#timeline)
- [activity_timeline](#activity_timeline)
- [analyze](#analyze)
- [Reports for many records](#reports-for-many-records):
  `analyze_many`, `analyze_scope`, `report`
- [Associations](#associations)
- [Ignoring fields](#ignoring-fields)
- [Reading results](#reading-results)
- [JSON columns](#json-columns)
- [Checking your setup](#checking-your-setup)
- [Models, schemas, and edge cases](#models-schemas-and-edge-cases)
- [Instrumentation](#instrumentation)
- [Errors](#errors)
- [Limitations](#limitations)

## Words used on this page

| Word | Meaning |
| --- | --- |
| Root record | The record you ask about, such as the article in `timeline(article)` |
| Child | An associated record you include with `associations:`, such as a comment |
| Current state | The record's saved values in the database right now |
| Snapshot | A read-only copy of a record's data at one point, returned by this gem |
| Identity | A key with the model's base-class name and the ID as a string, such as `["Article", "42"]` |
| PT-AT | The optional [paper_trail-association_tracking](https://github.com/westonganger/paper_trail-association_tracking) plugin, needed for association history |

## How PaperTrail stores history

Each PaperTrail version stores the record's values from **before** that
version's change. `version.reify` returns that earlier record. This gem uses
the same rule: passing a version means "the record as it was before this
version's change". Passing a saved record means its current state.

Take an article created as `"Draft"`, then updated to `"Published"`, then to
`"Final"`:

```text
        v1              v2                v3            (no version)
     "create"        "update"          "update"
         |               |                 |                 |
   ──────●───────────────●─────────────────●─────────────────●──────▶ time
         |               |                 |                 |
         └─── "Draft" ───┘                 |                 |
              stored in v2                 |                 |
                         └─ "Published" ───┘                 |
                              stored in v3                   |
                                           └──── "Final" ────┘
                                             only in the table
```

Three things follow from this:

- **A `create` version stands for "no record yet".** Its `reify` returns `nil`.
  Comparing it with a later state reports the record as added
  (`record_presence_change`), not as a list of fields changing from `nil`.
- **The newest values are in no version.** They exist only in the table. When
  nothing has been recorded after a change, the gem reads the result of that
  change from the current record.
- **A change shows up between two points, never at one.** That is why the
  timeline methods return steps, each comparing one state with the next.

## Choosing a method

| What you need | Method |
| --- | --- |
| Net difference between two versions, or a version and the current record | `compare(from, to)` |
| The same for a list of `{ from:, to: }` pairs, one per record | `compare_many(pairs)` |
| Each change to one record, version by version | `timeline(record)` |
| Each change to one record and its chosen associations, with who made it | `activity_timeline(record, associations: ...)` |
| Net difference and timeline together | `analyze(record)` |
| The same, plus the activity timeline | `analyze(record, activity: true)` |
| Analyses for an array of records | `analyze_many(records)` |
| Analyses for the records a relation selects, over a time window | `analyze_scope(scope, within:, limit:)` |
| Recent activity through now, for the records a relation selects | `report(scope, since:, limit:)` |

`timeline` and `activity_timeline` differ in which versions become steps. Given
an article with two comment edits between two article versions:

```text
recorded versions   A1        C1      C2        A2      A = Article version
                    |         |       |         |       C = Comment version
                ────●─────────●───────●─────────●────▶ time
                    |         |       |         |
timeline            └───────── 1 step ──────────┘
                    both comment changes land inside that one step

activity_timeline   └── 1 ────┴── 2 ──┴─── 3 ───┘
                    each recorded version becomes its own step
```

Both report the same changes. `activity_timeline` splits them up so each step
belongs to one recorded event, which is what you need to show who did what.

## Choosing a range

`timeline`, `activity_timeline`, and `analyze` cover the record's whole history
through its current state unless you say otherwise:

```ruby
PaperTrailDiff.timeline(article)                          # all of it
PaperTrailDiff.timeline(article, from: some_version)      # from a version to now
PaperTrailDiff.timeline(article, from: :first, to: later_version)
PaperTrailDiff.timeline(article, within: 1.week.ago..Time.current)
```

- `from:` defaults to `:first`, the record's earliest version.
- `to:` defaults to the record itself, meaning its current state. Pass a
  version instead for a result that never changes when the record is edited
  again.
- Versions must belong to the record and be given in time order.
- A record with no versions has an empty history, not an error.

`:last` is not accepted. It would mean "the state before the latest change",
which leaves that change out.

### Time windows

`within:` selects changes by the time PaperTrail recorded them (`created_at`).
It cannot be combined with `from:` or `to:`. Ruby's `..` includes the end time
and `...` excludes it, which is useful for back-to-back windows:

```ruby
window = Time.zone.parse("2026-08-01")...Time.zone.parse("2026-09-01")
steps = PaperTrailDiff.timeline(article, within: window)
```

To show what the window's last change produced, the gem reads the next version
after the window. If there is none, nothing has been recorded since, so it reads
the current record instead. The step's `to_boundary.kind` is then `:current`.
This works the same for a window that ends now and one that ended long ago.

Reading the current record has one consequence: it includes changes PaperTrail
never recorded, such as an `update_columns` call. Those appear in the last step
of the window.

If the window's last change destroyed the record, the window closes on that
deletion instead. See [a destroyed record](#a-destroyed-record).

`close_on: :current` asks for the behavior above explicitly. It is the default
now and is still accepted.

`timeline` returns no steps for a window with no versions of the root record.
`activity_timeline` still reports chosen associations that changed in such a
window.

### Reporting only some changes: `version_scope:`

`version_scope:` narrows which of the root record's versions are reported. It
receives the version relation and returns a narrower one:

```ruby
user_edits = ->(scope) { scope.where.not(whodunnit: nil) }

PaperTrailDiff.timeline(article, within: window, version_scope: user_edits)
```

It is accepted by `timeline`, `activity_timeline`, `analyze`, `analyze_many`,
and `analyze_scope`.

- Each reported change is compared with the version right after it, even if
  that version is filtered out. So each step shows exactly what that one change
  did:

  ```text
  versions   system → alice → system → bob → system
  reported   alice: what alice changed    bob: what bob changed
  ```

- It looks at the root record's versions only. Someone who only edited comments
  has no root versions to select. To find one person's changes, including to
  associations, see [one person's changes](#one-persons-changes).
- `activity_timeline` uses the filter to decide where the range starts and
  ends, but still lists every step inside it. Dropping one would move its
  change into a neighboring step and credit the wrong person.

## compare

`compare(from, to)` returns the net difference between two states. Each side is
a PaperTrail version or a saved record (its current state):

```ruby
diff = PaperTrailDiff.compare(article.versions[1], article.versions[4])
diff = PaperTrailDiff.compare(article.versions.last, article, associations: [:comments])

diff.attributes["title"].from # => "Draft"
diff.attributes["title"].to   # => "Published"
diff.empty?                   # => false
diff.to_h
# => {
#   record_presence_change: nil,
#   attributes: { "title" => { from: "Draft", to: "Published" } },
#   associations: {}
# }
```

- Only the two states matter. A field that changed and then changed back is not
  reported.
- `record_presence_change` is set when the record did not exist on one side,
  for example when `from` is a `create` version. It holds whole snapshots.
- A `destroy` version stands for the record just before deletion, so comparing
  up to one reports the last edit, not the deletion. `activity_timeline`
  reports deletions; see [a destroyed record](#a-destroyed-record).
- Two versions must be in time order. Reversed versions raise
  `ReversedEndpointsError`, because the result would look valid with every
  change backwards. A current record can be on either side.
- Both sides must belong to the same record.
- A current record must be saved, not destroyed, and have no unsaved changes.
  The gem reloads it, so in-memory edits and cached associations are ignored.
- Options: `associations:`, `ignore:`, and `reload_live_endpoints:` (see
  [reusing loaded records](#reusing-loaded-records)).

## compare_many

`compare_many` compares many pairs at once and shares the database work. Each
entry has the same `from:` and `to:` as `compare`. The result is a frozen hash
keyed by identity, in input order:

```ruby
orders = Order.where(id: order_ids).to_a

diffs = PaperTrailDiff.compare_many(
  orders.map { |order| { from: :first, to: order } },
  associations: [:line_items]
)

diffs.fetch(["Order", orders.first.id.to_s]) # => PaperTrailDiff::Diff
```

- `:first` means the record's earliest version. The gem finds it for every
  record in one query per model. It needs the other side of the pair to name the
  record, so `{ from: :first, to: :first }` raises.
- A record with no versions gets an empty `Diff`.
- Each record can appear in only one pair, because results are keyed by record.
- Options: `associations:`, `ignore:`, `reload_live_endpoints:`, and
  `allow_expensive:` (see [costly associations](#costly-associations)).

If you look up versions yourself, do it in bulk. Looking up one record at a
time brings back the per-record queries this method avoids.

### Reusing loaded records

`compare`, `compare_many`, and `activity_timeline` reload current records by
default. If you already loaded them with every requested association, you can
skip the reload:

```ruby
orders = Order.where(id: order_ids).preload(line_items: :product).to_a

diffs = PaperTrailDiff.compare_many(
  orders.map { |order| { from: :first, to: order } },
  associations: ["line_items.product"],
  reload_live_endpoints: false
)
```

The values then come from your objects, so keeping them fresh is up to you. A
requested association that is not loaded raises `UnloadedAssociationError`
instead of quietly running a query per record.

## timeline

`timeline(record)` returns one step for each pair of neighboring versions of the
root record, ending at its current state by default. See
[choosing a range](#choosing-a-range) for `from:`, `to:`, and `within:`.

```ruby
steps = PaperTrailDiff.timeline(article)

steps.first.diff            # a PaperTrailDiff::Diff
steps.first.empty?          # true if nothing reported changed
steps.first.source_boundary # the version whose change this step shows
steps.first.to_boundary     # the version (or current state) after it
steps.first.from_version    # the original PaperTrail version objects
steps.first.to_version      # nil when the step ends at current state
steps.reject(&:empty?)      # hide steps with no reported changes
```

- Steps with no reported change are kept, for example when only ignored fields
  changed. Use `reject(&:empty?)` for display.
- With `associations:`, each step also compares the chosen associations at the
  two root versions. Several child changes between two root versions appear in
  one step. Use `activity_timeline` to split them.
- `source_boundary` (also available as `from_boundary`) describes the version
  responsible for the step, including `whodunnit`, `event`, and `recorded_at`.
- `step.to_h` returns `{ from:, to:, diff: }`, the same shape as an activity
  step. `from` and `to` are boundary hashes with `kind`, `version_id`,
  `item_type`, `item_id`, and `recorded_at`. `to_h(metadata: true)` adds author,
  event, transaction ID, and record to each boundary.
- Options: `from:`, `to:`, `within:`, `associations:`, `ignore:`,
  `version_scope:`, `close_on:`.

## activity_timeline

`activity_timeline(record, associations: ...)` returns one step for each
recorded event of the root record **or** a chosen association. It ends at the
current record by default.

```ruby
steps = PaperTrailDiff.activity_timeline(article, associations: ["comments.replies", :author])

steps.reject(&:empty?).each do |step|
  step.source_boundary.whodunnit # who made this change
  step.source_boundary.item_type # "Article", "Comment", ...
  step.diff                      # what that one event changed
end
```

- Each step's `diff` is what the event at its `source_boundary` changed. Use
  `source_boundary` for attribution. `to_boundary` is only the next point in
  time and may belong to someone else.
- Boundaries have a `kind`: `:version`, `:current` (the current record), or
  `:destroyed` (after a deletion). They also have `event`, `whodunnit`,
  `recorded_at`, `item_type`, `item_id`, `transaction_id`, and `record`, and
  the predicates `version?`, `current?`, and `destroyed?`.
- `step.to_h` returns `{ from:, to:, diff: }`. `to_h(metadata: true)` adds
  author, event, transaction ID, and record. `to_h(snapshots: true)` adds the
  retained snapshots.
- A child's change becomes visible at the next recorded event, or at the
  current record. You do not need to save the article after each comment change.
- Options: `from:`, `to:`, `within:`, `associations:`, `ignore:`,
  `version_scope:`, `close_on:`, `reload_live_endpoints:`, `snapshots:`,
  `group:`.

### One person's changes

Filter the steps in Ruby by `source_boundary.whodunnit`:

<!-- executable:readme-person-changes -->
```ruby
steps = PaperTrailDiff.activity_timeline(
  article, within: window, associations: %i[comments tags]
)

attributed = steps.reject(&:empty?)
by_priya = attributed.select { |step| step.source_boundary.whodunnit == "Priya Shah" }

by_priya.first.source_boundary.whodunnit  # "Priya Shah"
by_priya.first.diff                     # exactly what that one event changed

authors = attributed.group_by { |step| step.source_boundary.whodunnit }
                    .transform_values(&:length)
```

This includes changes to associations, which `version_scope:` cannot see.
Filter after the call rather than asking the gem for fewer versions: every step
has to be rebuilt anyway for each one to be correct, so filtering earlier saves
nothing.

For many records, use `report` or `analyze_many(..., activity: true)` instead of
calling `activity_timeline` in a loop, so the database work is shared.

### One step per transaction: `group: :transaction`

Saving an article and its comments together creates one version each, so one
action shows up as several steps. `group: :transaction` combines steps from the
same database transaction:

```ruby
PaperTrailDiff.activity_timeline(article, associations: [:comments], group: :transaction)
```

- A combined step compares the state before the transaction with the state after
  it. A field set and then restored inside the transaction is not reported.
- Its `source_boundary` is the first event in the transaction. That event's
  author is not necessarily the author of every grouped change.
- Versions without a `transaction_id` are never grouped.
- Also accepted by `analyze`, `analyze_many`, and `analyze_scope` with
  `activity: true`, and by `report`.

Without grouping, a step inside a transaction can look empty. A child's new
value is only visible at the next recorded event, and inside a transaction that
event is often another part of the same save. Nothing is lost; the change
appears one step later.

### Keeping snapshots: `snapshots: true`

A step's `diff` holds only what changed. To show unchanged fields too, such as
a comment's author next to an edited comment body, keep the snapshots:

```ruby
steps = PaperTrailDiff.activity_timeline(article, associations: [:comments], snapshots: true)

step = steps.reject(&:empty?).last
step.from_snapshot.associations["comments"].records.first.attributes["author"]
```

- The gem builds these snapshots anyway, so keeping them adds no queries. They
  do use memory, because each one contains every chosen association.
- `from_snapshot` is `nil` for a step starting at a `create` version, because the
  record did not exist yet.
- Also accepted by `analyze`, `analyze_many`, and `analyze_scope` with
  `activity: true`, and by `report`.

### A destroyed record

When the range ends at the record's `destroy` version, the activity timeline
adds a final step to a `:destroyed` boundary. Its diff reports the record being
removed:

```ruby
removal = steps.last
removal.to_boundary.destroyed?           # => true
removal.diff.record_presence_change.from # the record just before deletion
removal.diff.record_presence_change.to   # => nil
```

A `within:` window whose last change is the deletion ends the same way, and the
`diff` of an `analyze` over that window ends at "no record". Removing a chosen
child is reported as `removed` in its parent's association.

### HABTM limitation

`has_and_belongs_to_many` join rows have no versions, so the gem cannot split
their changes into separate events once a range runs past the last root version
into the current record. That case raises `UnsupportedLiveActivityError`. End
the range at a version instead (see the
[checkpoint recipe](#saving-a-checkpoint)), or use a join model with
`has_many :through`.

## analyze

`analyze(record)` returns an `Analysis` with the net `diff` and the `timeline`
for one range, reading each version once:

```ruby
analysis = PaperTrailDiff.analyze(article, associations: ["comments.replies"], activity: true)

analysis.diff              # net change over the range
analysis.timeline          # the same steps timeline returns
analysis.activity_timeline # nil unless activity: true
analysis.from_snapshot     # the full state at the start (nil before creation)
analysis.to_snapshot       # the full state at the end
analysis.to_h(snapshots: true, metadata: true)
```

- It accepts the same ranges as `timeline`.
- `activity: true` also builds the activity timeline. `snapshots:` and `group:`
  apply to the activity timeline and require `activity: true`.
- Options: `from:`, `to:`, `within:`, `associations:`, `ignore:`, `activity:`,
  `version_scope:`, `close_on:`, `snapshots:`, `group:`.

## Reports for many records

Use these methods instead of calling a single-record method in a loop. They
load history for all records together.

### analyze_many

`analyze_many(records, ...)` analyzes an array of saved records and returns a
frozen hash of `Analysis` objects keyed by identity:

```ruby
results = PaperTrailDiff.analyze_many(
  Order.where(status: "open").to_a,
  within: Time.zone.parse("2026-08-01")...Time.zone.parse("2026-09-01"),
  associations: [:line_items]
)

results.fetch(["Order", order.id.to_s]).diff
```

- Without `within:`, each record's whole history through its current state is
  analyzed.
- A record with nothing to report gets an empty `Analysis`.
- Records must be saved and unique.
- Options: `within:`, `associations:`, `ignore:`, `activity:`, `version_scope:`,
  `close_on:`, `snapshots:`, `group:`, `allow_expensive:`.

### analyze_scope

`analyze_scope(scope, within:, limit:)` lets a model or relation choose the
records. It returns a `ScopedAnalysis`:

```ruby
report = PaperTrailDiff.analyze_scope(
  Order.where(status: "open"),
  within: Time.zone.parse("2026-08-01")...Time.zone.parse("2026-09-01"),
  associations: [:line_items],
  limit: 500
)

report.analyses    # { identity => Analysis } for records that still exist
report.roots       # the selected records, in relation order
report.unreachable # identities of selected records that no longer exist
report.deleted     # { identity => Analysis or nil }, with include_deleted: true

analyses, unreachable = report # destructures into the first two
```

It takes the same options as `analyze_many`, plus `limit:`, `historical_filter:`,
`max_filter_versions:`, and `include_deleted:`. `within:` can be omitted to use
all history.

### report

`report(scope, since:, limit:)` is `analyze_scope` with
`within: since..Time.now.utc` and `activity: true`. Use it for "what happened
recently":

```ruby
report = PaperTrailDiff.report(Article.all, since: 1.day.ago, limit: 100)
```

It accepts `associations:`, `ignore:`, `snapshots:`, `group:`,
`include_deleted:`, `historical_filter:`, `max_filter_versions:`, and
`allow_expensive:`.

### Which records are selected

- **A record is selected when it, or a record on a requested association,
  changed in the window.** With `activity: true`, which `report` always uses,
  editing only a comment selects its article when you request
  `associations: [:comments]`. A comment that moved between articles selects
  both. Nested paths count at every level, and a `has_many :through` counts its
  join rows too. Without `activity: true`, an analysis compares a record's own
  versions and cannot show a change to its associations alone, so only a
  record's own version selects it.
- **An analysis can still be empty.** A record is selected by any version on its
  paths, but its analysis compares only the state you requested. A join row
  whose role changed, or a version that touched only ignored columns, selects a
  record with nothing to report.
- **A relation checks current values.** `Order.where(status: "open")` means open
  now, not open during the window. Use `historical_filter:` to select by past
  values.
- **`limit:` is a safety ceiling, not a page size.** If more records are
  selected, the call raises `BatchLimitExceededError` instead of returning part
  of the answer. Narrow the relation or the window, or raise the limit.
- **To paginate, use the relation.** Its `order`, `limit`, and `offset` choose
  the page. Without an `order`, records are taken in ascending ID order. Add an
  ID tie-breaker to any other order. If a join repeats a record, it is analyzed
  once, in order of first appearance.
- Selection still scans the versions in the window, so keep windows reasonable
  for large tables. Each requested association adds one query per level, however
  many records it selects. Changes to associations are found from PT-AT's
  `version_associations`, so history recorded before PT-AT was installed selects
  nothing.

### Deleted records

A deleted record cannot be tested against a relation's conditions, because it
has no row. Records that changed in the window but no longer exist are listed in
`unreachable`, including those selected by a change to their associations. It
is not paginated and does not mean those records matched the relation.

`include_deleted: true` also analyzes them from their `destroy` versions and
returns the results in `deleted`, keyed the same way. A value is `nil` when no
`destroy` version was recorded. With this option, existing and deleted records
together count toward `limit:`.

```ruby
missing_history = report.deleted.select { |_identity, analysis| analysis.nil? }.keys
```

A deleted record's `diff` and `to_snapshot` end at "no record". Its `timeline`
lists only edits; its `activity_timeline` ends with the deletion. That last
step's `diff.record_presence_change.from` is the record just before it was
deleted, even when it was also created inside the window, where
`from_snapshot` is `nil`.

### Selecting by past values: `historical_filter:`

`historical_filter:` selects records by values they had at any point in the
window. For example, to find articles that were titled `"Published"` at some
point in the last day, including ones published during it:

```ruby
report = PaperTrailDiff.report(
  Article.all, since: 1.day.ago, limit: 100,
  historical_filter: { title: "Published" }
)
```

The filter checks the record as it was when the window started and after each
change made inside it. A record matches if any of those states match. With a
hash, every key must be equal (`==`). Values are read from the stored history
without calling `reify`, and unknown or unrecorded attributes raise an error
instead of matching `nil`. For other checks, pass a callable such as
`->(article) { article.title.start_with?("Pub") }`; it receives each state as a
model instance and may run queries of its own.

- It looks only at the record itself, not its associations, and does not check
  whether a value was held for the whole window.
- The relation still filters current rows. Matching deleted records are listed
  in `unreachable`.
- Every matching record counts toward `limit:`, including deleted ones and ones
  the relation later excludes. Matching stops as soon as the limit is exceeded.
- `max_filter_versions:` limits how many versions the filter loads, including
  the one version after the window it reads for each record. The default is
  10,000. Going over raises `FilterLimitExceededError` before the extra batch is
  checked. It does not limit queries inside a callable.
- `version_scope:` narrows which changes are reported, not which states are
  tested here.
- It is accepted by `analyze_scope` and `report`, which select records from a
  relation.

### Costly associations

Most associations are loaded for all records together. A few still need queries
per record: associations with a scope (including `limit` or owner-dependent
scopes), targets with a default scope, and `has_many :through` associations
whose source is not a `belongs_to`. Batch methods raise
`UnsupportedBatchPathError` for these by default and name the association.
Remove it from `associations:`, or pass `allow_expensive: true` to accept the
per-record cost. Single-record methods always allow them.

A polymorphic `belongs_to` is loaded together too, with one query per target
class. Its classes are known only from the records, though, so batch methods
cannot reject a default-scoped one in advance: a record that points at a
default-scoped class is read on its own, without an error.

This check covers known association cases only. Your model callbacks, custom
attribute types, and callable filters can still run queries. See the
[performance guide](performance.md) for measurements.

## Associations

Associations are only included when you name them. Use names or dot-separated
paths; the parents in a path are included automatically:

```ruby
diff = PaperTrailDiff.compare(from, to, associations: [:author, "comments.replies"])
```

Supported: `belongs_to`, `has_one`, `has_many` (including `:through`), and
`has_and_belongs_to_many`. Associated models must use `has_paper_trail`, and
historical states need PT-AT installed and enabled
(`PaperTrail.config.track_associations = true`). The gem never follows
associations you did not ask for, so cyclic models are safe.

How each kind is reported:

| Association | Record replaced, added, or removed | Same record, fields changed |
| --- | --- | --- |
| `belongs_to`, `has_one` | `relationship` (a `ValueChange` of snapshots) | `changed` |
| `has_many`, HABTM | `added`, `removed` (snapshots) | `changed` (`RecordChange`) |

```ruby
diff.associations["author"].relationship  # from one author to another
comments = diff.associations["comments"]
comments.added    # full snapshots of new comments
comments.removed  # full snapshots of removed comments
comments.changed  # RecordChange objects for edited comments
comments.changed.first.associations["replies"].added
```

- The same structure repeats at every level. Added and removed snapshots
  include their chosen children.
- When a `belongs_to` association is included, its foreign key (and type
  column for polymorphic associations) is left out of the attributes, because
  the association already reports it. The same applies to the foreign key a
  `has_one` or `has_many` child points back with. Without the association, the
  key is an ordinary attribute.
- A polymorphic `belongs_to` reads each record's target from its type
  column. Because the targets' classes differ, a path cannot continue past
  it: `"notable.comments"` raises `UnsupportedAssociationError`. A record
  whose type names a model without `has_paper_trail` raises
  `UnversionedAssociationError` when its history is read; the gem cannot
  check this earlier, since only the record names the class.
- `has_many :through` uses the versioned join model's history, so join-model
  attributes are available. HABTM reports membership and the target's
  attributes; it has no join model, so it has no join attributes.
- Requesting associations for a historical state without PT-AT raises
  `AssociationTrackingUnavailableError`. Unknown names raise
  `UnknownAssociationError`; unsupported macros raise
  `UnsupportedAssociationError`.

### Saving a checkpoint

Sometimes you want a version of the root record without changing it, for
example to fix the end of a report or to capture HABTM membership. Save one
inside a transaction on a freshly loaded record, and turn off PaperTrail's
timestamp synchronization for that model so the version records the time it
was saved:

```ruby
class Article < ApplicationRecord
  has_paper_trail synchronize_version_creation_timestamp: false
end

def checkpoint_article(article_id)
  Article.transaction do
    Article.find(article_id).paper_trail.save_with_version
  end
end
```

Without `synchronize_version_creation_timestamp: false`, the checkpoint takes the
record's old `updated_at` as its time and lands in the past.

### Files from ActiveStorage

`has_one_attached` and `has_many_attached` point to ActiveStorage's own models,
which PaperTrail does not version. Comparing them historically raises
`UnversionedAssociationError` rather than claiming nothing changed. Versioning
ActiveStorage's models does not help either, because `has_one_attached` is a
scoped `has_one`.

Record the facts you care about on a model you own, and version that:

<!-- executable:reference-file-metadata -->
```ruby
class DocumentRevision < ApplicationRecord
  belongs_to :attachable, polymorphic: true
  has_one_attached :file
  has_paper_trail

  # Attaching a file writes to ActiveStorage's tables, not to this record, so
  # nothing would be versioned without copying the facts across.
  before_save :record_file_metadata, if: -> { file.attached? }

  def record_file_metadata
    blob = file.blob
    assign_attributes(
      filename: blob.filename.to_s, content_type: blob.content_type,
      byte_size: blob.byte_size, checksum: blob.checksum
    )
  end
end
```

```ruby
class Article < ApplicationRecord
  has_many :document_revisions, as: :attachable
  has_paper_trail
end

PaperTrailDiff.compare(before, after, associations: [:document_revisions])
```

The callback sets the metadata before the save, so PaperTrail records it with
that save. Save a revision for every file change; `update_columns` and
blob-only changes are not recorded.

## Ignoring fields

`updated_at` is ignored by default. `ignore:` replaces that default list:

```ruby
PaperTrailDiff.compare(from, to, ignore: %i[updated_at lock_version])
PaperTrailDiff.compare(from, to, ignore: []) # compare every field
```

An array applies to the root record and every association. To ignore fields
only at certain paths, pass `all:` and `paths:`. `"$"` means the root record:

```ruby
PaperTrailDiff.compare(
  from, to,
  associations: ["comments.replies"],
  ignore: {
    all: [:updated_at],
    paths: { "$" => [:lock_version], "comments.replies" => [:delivery_state] }
  }
)
```

A path entry applies only at that exact path, not below it. Paths must be `"$"`
or one of the requested association paths.

Primary keys are never reported as attributes; they identify the record.
Columns listed in `has_paper_trail skip:` are also left out, because PaperTrail
never stores them.

## Reading results

All result objects are frozen and have `to_h`. Hash keys for structure are
symbols; attribute and association names are strings. Attribute values keep
their Ruby types. Collections are ordered by record type, then ID (numerically
for numeric IDs).

| Type | What it is |
| --- | --- |
| `Diff` | `record_presence_change`, `attributes`, `associations`, `empty?` |
| `ValueChange` | `from` and `to` |
| `RecordSnapshot` | `type`, `id`, `attributes`, `associations` |
| `RecordChange` | `record` (a `RecordReference`), `attributes`, `associations` |
| `ToOneAssociationDiff` | `kind`, `relationship`, `changed` |
| `CollectionAssociationDiff` | `kind`, `added`, `removed`, `changed` |
| `Step` | one `timeline` step |
| `ActivityStep` | one `activity_timeline` step |
| `ActivityBoundary` | one end of a step |
| `Analysis` | result of `analyze` |
| `ScopedAnalysis` | result of `analyze_scope` and `report` |
| `TraversalEntry`, `RecordReference` | entries from `each_change` and `each_entry` |
| `AssociationDescriptor` | result of `association_paths` |
| `DiagnosticReport`, `DiagnosticIssue` | result of `diagnose` |

A new record's fields are in `record_presence_change.to.attributes`; an edited
record's are in `attributes`. To avoid handling both shapes, walk the result.

### Walking a result

`each_change` lists every change as a flat sequence, depth first:

<!-- executable:readme-traversal-changes -->
```ruby
diff.each_change do |entry|
  entry.kind              # :attribute_changed, :record_added, ...
  entry.association_path  # ["comments", "replies"]
  entry.record_path       # frozen RecordReference objects
  entry.association_kind  # :has_many, :belongs_to, ...
  entry.attribute         # "body" for an attribute entry
  entry.value             # ValueChange, RecordChange, or RecordSnapshot
end

counts = diff.each_change.map(&:kind).tally
```

- A `:record_changed` entry comes before that record's field and child entries.
- To-one replacements are `:relationship_added`, `:relationship_removed`, or
  `:relationship_replaced`. The root being created or removed is
  `:record_presence_changed`.

`each_entry` also includes the fields of added and removed records, so you can
render a new record without a second walker:

<!-- executable:readme-traversal-entries -->
```ruby
diff.each_entry do |entry|
  next unless entry.included_state?

  entry.kind     # :record_included, :attribute_included, :association_included
  entry.state    # :before or :after
  entry.context  # :included_state
end
```

Both return an `Enumerator` without a block. They never query the database. A
record reachable through two requested paths appears at both.

## JSON columns

A `json` or `jsonb` column is compared as one value. `nested_changes` reports
which keys inside it changed:

```ruby
PaperTrailDiff.nested_changes(diff.attributes.fetch("config"))
# => { ["theme"]         => <from "dark" to "light">,
#      ["limits", "max"] => <from 10 to 20> }

PaperTrailDiff.nested_changes(from_value, to_value) # also accepts two values
```

- Paths are arrays because a key may contain a dot.
- Arrays are compared by their elements, not positions. An `ArrayChange` has
  `added`, `removed`, and `reordered?`, plus the whole `from` and `to`. Objects
  inside arrays are compared whole.
- A missing key is `PaperTrailDiff::NestedComparator::ABSENT`, not `nil`, because
  `{"a": null}` and `{}` are different.
- A value that is not JSON on both sides returns `{}`; the attribute diff still
  has the whole change.
- Keys such as `:a` and `"a"` in one object raise `AmbiguousNestedKeyError`.

## Checking your setup

List the associations a model supports, for example to build a settings
screen:

```ruby
PaperTrailDiff.supported_association_macros
PaperTrailDiff.association_paths(Article, max_depth: 3).map(&:to_h)
```

Each descriptor has `path`, `kind`, `target_type`, `through`, `polymorphic`,
and `cycle`. Cycles are marked and not followed.

Check two versions for known problems before relying on association history:

```ruby
report = PaperTrailDiff.diagnose(from_version, to_version, associations: [:tags, "comments.replies"])

report.ok?                  # no errors among the checks that ran
report.errors.map(&:code)
report.warnings.map(&:code)
```

Association checks run only for requested associations. The version-order check
always runs. `ok?` does not prove the history is complete.

## Models, schemas, and edge cases

- **Single-table inheritance.** Results are keyed by the base class, as
  PaperTrail stores it: a `Book < Publication` is `["Publication", "12"]`. Use
  `PaperTrailDiff::Endpoint.identity(record)` to build keys.
- **Non-integer primary keys**, such as UUIDs, are supported, and so is a string
  `versions.item_id` column.
- **Custom version classes** (`has_paper_trail versions: { class_name: }`) are
  supported.

### Version order

Versions are ordered by `created_at`, then by ID when timestamps are equal. That
works when IDs increase with each insert, as autoincrement IDs do. UUID version
IDs do not, so two UUID versions with the same timestamp cannot be ordered; the
gem raises `AmbiguousVersionOrderError` naming both instead of guessing.
Timestamps stored to the second, as on a MySQL `datetime` column, make ties
common. `diagnose` reports this as an error.

`created_at` comes from your application server's clock. A clock that jumps
backwards, or servers whose clocks disagree, can record a later change with an
earlier time. Keep server clocks synchronized.

Association changes between versions with the same timestamp are placed using
the same order. A few association shapes fall back to PT-AT's own reifier, which
uses timestamps only: scoped associations, unversioned targets, and the others
listed in the [architecture notes](architecture.md). For those, `diagnose` warns
about tied timestamps, and a comparison between two tied versions emits the
`ambiguous_association_boundary.paper_trail_diff` notification. Recording
timestamps below one second avoids the problem.

### History stored as JSON

PaperTrail's JSON serializer, and a `json` or `jsonb` `object` column, store
times to milliseconds by default (`ActiveSupport::JSON::Encoding.time_precision`).
For those histories the gem compares all times at that precision, so an
unchanged timestamp is not reported as changed. A change smaller than that
precision was never recorded and cannot be reported.

## Instrumentation

The gem never logs. It emits `ActiveSupport::Notifications` events you can
subscribe to:

- `compare.paper_trail_diff`
- `compare_many.paper_trail_diff`
- `activity_timeline.paper_trail_diff` (includes `step_count`)
- `analyze_many.paper_trail_diff`
- `load_live_endpoints.paper_trail_diff`
- `prepare_history.paper_trail_diff`
- `ambiguous_association_boundary.paper_trail_diff`

```ruby
ActiveSupport::Notifications.subscribe(/\.paper_trail_diff\z/) do |name, start, finish, _id, payload|
  Rails.logger.debug(event: name, duration_ms: ((finish - start) * 1_000).round(1), **payload)
end
```

Payloads contain counts, model names, association paths, and options, never
record data. To see the SQL for one call, subscribe to `sql.active_record`
around it with `ActiveSupport::Notifications.subscribed`.

## Errors

All errors inherit from `PaperTrailDiff::Error`.

| Error | Raised when |
| --- | --- |
| `ConfigurationError` | An option is invalid |
| `UnsupportedBatchPathError` | A batch requests a [costly association](#costly-associations) without `allow_expensive: true` |
| `InvalidEndpointError` | A record is unsaved, destroyed, or has unsaved changes |
| `UnloadedAssociationError` | `reload_live_endpoints: false` and an association is not loaded |
| `VersionMismatchError` | Two endpoints belong to different records |
| `ReversedEndpointsError` | Two versions are given newest first |
| `InvalidTimelineRangeError` | A range is invalid, for example `within:` with `from:`, or `:last` |
| `InvalidTimeRangeError` | `within:` is not a finite, time-ordered range |
| `IncompleteTimeRangeError` | A window's last change has no later version and the record has no saved row to read instead |
| `AmbiguousVersionOrderError` | Versions cannot be ordered (see [version order](#version-order)) |
| `BatchLimitExceededError` | More records are selected than `limit:` allows |
| `FilterLimitExceededError` | `historical_filter:` needs more than `max_filter_versions:` |
| `AssociationTrackingUnavailableError` | Association history is requested without PT-AT |
| `UnknownAssociationError` | An association name does not exist |
| `UnsupportedAssociationError` | An association's macro is not supported, or a path continues past a polymorphic `belongs_to` |
| `UnversionedAssociationError` | An association's target model has no `has_paper_trail`, including the class a polymorphic `belongs_to` names |
| `IncompleteAssociationHistoryError` | PT-AT did not record enough to rebuild an association, such as HABTM without a transaction |
| `UnsupportedLiveActivityError` | A HABTM activity range ends at the current record |
| `AmbiguousNestedKeyError` | `nested_changes` finds keys like `:a` and `"a"` together |

## Limitations

Results can only be as complete as the history PaperTrail and PT-AT recorded.

- Changes made with versioning off, with `update_columns`, or to `skip:` columns
  were never recorded. A range ending at the current record shows the first two
  in its last step, attributed to the change before them.
- Deleted versions, schema changes, and serializer changes can affect how old
  versions read.
- Several queries against the current record are not one database snapshot.
  Use a transaction with a suitable isolation level if that matters.
- HABTM membership history exists only where PT-AT recorded it in a
  transaction. HABTM changes cannot become their own activity steps.
- PT-AT has its own
  [limitations](https://github.com/westonganger/paper_trail-association_tracking#limitations),
  especially for some `has_one` histories. The gem follows PT-AT's configured
  error behavior.
- Deep association paths cost more to rebuild. Request only what you need.

Read PaperTrail's
[version semantics](https://github.com/paper-trail-gem/paper_trail#3-working-with-versions)
before relying on history for restoring data or for compliance.

For development commands, see [testing](testing.md).
