# API reference

Start with the [README](../README.md) examples or the
[Rails quickstart](../QUICKSTART.md). This page lists every method and option,
including ones most applications never need.

## Contents

- [How PaperTrail stores history](#how-papertrail-stores-history)
- [Choosing a method](#choosing-a-method)
- [Choosing a range](#choosing-a-range)
- [compare](#compare) and [compare_many](#compare_many)
- [analyze](#analyze), with its [timeline](#timeline) and
  [activity_timeline](#activity_timeline)
- [Reports for many records](#reports-for-many-records):
  `analyze_many`, `analyze_scope`, `report`
- [Associations](#associations)
- [Ignoring fields](#ignoring-fields)
- [Reading results](#reading-results)
- [JSON columns](#json-columns)
- [What a version recorded](#what-a-version-recorded): `recorded_changes`
- [Checking your setup](#checking-your-setup)
- [Models, schemas, and edge cases](#models-schemas-and-edge-cases)
- [Instrumentation](#instrumentation)
- [Errors](#errors)
- [Limitations](#limitations)

## Words used on this page

| Word | Meaning |
| --- | --- |
| Root record | The record you ask about, such as the article in `analyze(article)` |
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

Six things follow from this:

- **A `create` version stands for "no record yet".** Its `reify` returns `nil`.
  Comparing it with a later state reports the record as added
  (`record_presence_change`), not as a list of fields changing from `nil`.
- **The newest values are in no version.** They exist only in the table. When
  nothing has been recorded after a change, the gem reads the result of that
  change from the current record.
- **A change shows up between two points, never at one.** That is why the
  timeline methods return steps, each comparing one state with the next.
- **A change saved without a version joins the change before it.** Writing
  with `update_columns` or with versioning off creates no version, but it
  changes the values the record's next version stores, or its current row. The
  gem reads the result of a change from there, so the write appears in the step
  for that record's previous recorded change and is attributed to its author.
  Ending a range at a version leaves out only the writes after it. A column
  that `has_paper_trail only:` or `ignore:` leaves out of `object_changes` is
  read the same way, so a key saved with a version is that version's change.
  Rails updates `counter_cache` columns like this, so a parent's count changes
  in the step of the parent's previous change; pass the column in `ignore:` to
  leave it out.
  [`recorded_changes`](#what-a-version-recorded) reads what a version itself
  recorded, and activity steps can [include it](#what-each-event-recorded-recorded_changes-true).
  With it, [change rows](#change-rows) give such a write a row of its own,
  credited to no one.
- **A record created without a version looks as if it always existed.** A
  row written with versioning off, or imported with `insert_all`, has no
  `create` version, so history never reports it as added: its earliest
  version's stored values are its state from before history began, and an
  association includes it there. Rows from before PaperTrail was installed
  are the same, which is usually what you want. One such row is missed: a
  child whose first version moves it to another owner. That version stores
  the old owner's key, but PaperTrail-AssociationTracking records the new
  one, and the gem finds a past owner's children by those records, so the
  owner it left never held it. Every later move is found.
- **Pruned history is gone.** With `has_paper_trail limit:`, PaperTrail
  deletes a record's oldest versions, and the earliest one left becomes its
  start: states before it cannot be read, and an older version passed in is
  no longer there to pass.

## Choosing a method

| What you need | Method |
| --- | --- |
| Net difference between two versions, or a version and the current record | `compare(from, to)` |
| The same for a list of `{ from:, to: }` pairs, one per record | `compare_many(pairs)` |
| Net difference and each change to one record, version by version | `analyze(record)`, then `diff` and `timeline` |
| The same, plus each change to its chosen associations, with who made it | `analyze(record, associations: ..., activity: true)`, then `activity_timeline` |
| Analyses for an array of records | `analyze_many(records)` |
| Analyses for the records a relation selects, over a time window | `analyze_scope(scope, within:, limit:)` |
| Recent activity through now, for the records a relation selects | `report(scope, since:, limit:)` |

An analysis's `timeline` and `activity_timeline` differ in which versions
become steps. Given
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

`analyze` covers the record's whole history through its current state unless
you say otherwise:

```ruby
PaperTrailDiff.analyze(article)                          # all of it
PaperTrailDiff.analyze(article, from: some_version)      # from a version to now
PaperTrailDiff.analyze(article, from: :first, to: later_version)
PaperTrailDiff.analyze(article, within: 1.week.ago..Time.current)
```

- `from:` defaults to `:first`, the record's earliest version.
- `to:` defaults to the record itself, meaning its current state. Pass a
  version instead to anchor the result there. It does not change when the
  record is edited again, unless a transaction that stamped changes before that
  version commits after it; see [version order](#version-order).
- A version stands for the state before its transaction, since PT-AT rebuilds
  associations as they were before it. Child changes saved in the same
  transaction, such as the update behind a `touch: true` parent version, fall
  after a range that ends there and inside a range that starts there. So a
  history split at that version reports each such change exactly once, in the
  later part.
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
steps = PaperTrailDiff.analyze(article, within: window).timeline
```

A bound is read to the microsecond, as adapters write it into SQL, so a
version saved in the microsecond of a `Time.now` start is inside the window.
Where the versions table's `created_at` keeps fewer digits, as a MySQL
`datetime` column without a precision keeps whole seconds, a bound is read to
those: a window from 12:00:00.7 starts at 12:00:00, with the versions saved in
that second.

A `Date` bound is a whole day in `Time.zone`, so `Date.today..Date.today` is
all of today and `august...september` stops before September 1. A string is a
time in `Time.zone` unless it names an offset, and must name a real day:
`"12"` or `"2026-02-30"` raises `InvalidTimeRangeError`. Without `Time.zone`, both are
read in UTC, never in the server's own zone.

An endless range, such as `1.day.ago..`, runs through the current saved state:
it holds every version saved since it began, whatever time its server's clock
gave it, and it ends at the current record. `report` uses one.

A transaction takes effect where it saved its last version, so a window
reports the transactions that end inside it, each of them whole. One that
began before the window and ends inside it is reported there, with what it
saved before the window: a comment edit, say, and the `touch: true` article
version saved with it after the window's start. One that begins inside the
window and ends after it is left to the window its last version is in. So
back-to-back windows, or a `report` with `since:` after an earlier report,
show each change exactly once, credited to the transaction that made it and to
its own version, and a
[transaction group](#one-step-per-transaction-group-transaction) lists every
version its transaction saved, wherever they fall.

Where a transaction ends is read from its version table: the last version it
saved there, of any record, on the requested paths or not. So every window
places a transaction alike, whichever of its records the window reads. A
version table whose ids do not count up, such as one keyed by UUID, names the
last version by when it was saved. Without associations, each version of the
record is reported where it was saved, since nothing else of its transaction
is read. `analyze` without `activity:` compares the record's
own versions, and report each where it was saved too. With associations, the
records around each of those versions still read as they stood before every
transaction that had not ended yet, so an associated record's change is
reported once, in the step where its transaction ends.

A history read without a window begins at the record's first version, or at
`from:`, before that version's transaction took effect, and ends where the
transaction of its last version, or of `to:`, took effect. What another
transaction saved before the start, such as an author it renamed before the
article was created, is part of the state the history begins in if that
transaction ended first, and is reported in its own step if it ended later.
So two ranges that meet at a version report each change once, as the range
over both does, and `compare` reads a version as both ranges do. A destroyed
record's history ends where its destruction took effect; a change another
transaction committed later is not the record's.

Two transactions that save in one record's tree at the same time interleave
their versions. Each is reported as if it ran alone, in the order they end: a
record reads as it stood before every transaction that had not ended yet.

The window itself does not move. `analysis.window` is the window you asked
for, as a Ruby range, endless for `report` and any other endless window, and
`nil` when `within:` or `since:` was not given. A step of a transaction that
began before the window can hold a version saved before `analysis.window`
begins.

```ruby
analysis = PaperTrailDiff.analyze_many(articles, within: window, activity: true).values.first
analysis.window # => window
```

A closed window can still change. PaperTrail stamps a version's `created_at`
when it builds the version, inside its transaction, and the transaction commits
later. A transaction that stamped a change inside the window and committed
after the window was read adds that change to it. Wait longer than your longest
transaction after the window ends before you rely on it, so that every
transaction that could have written in the window has committed. A report
through now is final only for changes older than that delay. The gem cannot see
open transactions, so it cannot tell when a window has settled.

To show what the window's last change produced, the gem reads the state just
before the next change after the window:

- With `activity: true`, that is the next
  version of the record or of any record on a requested association path. If
  none was recorded after the window, it reads the current record instead,
  and the last step's `to_boundary.kind` is `:current`. So a window that ended
  long ago ends at its own end, even when only a comment changed since.
- Without `activity:`, `analyze` compares the record's own
  versions. The last step runs to the record's next version, or to the
  current record when it has none, and an association change made in between
  is part of that step, credited to its author. Use `activity: true` to keep
  a past window's associations as they were at its end.

Reading the current record has one consequence: it includes changes PaperTrail
never recorded, such as an `update_columns` call. Like any
[change saved without a version](#how-papertrail-stores-history), each appears
in the step for that record's last recorded change.

If the window's last change destroyed the record, the window closes on that
deletion instead. See [a destroyed record](#a-destroyed-record).

`timeline` holds no steps for a window with no versions of the root record.
`activity_timeline` still reports chosen associations that changed in such a
window.

### Reporting only some changes: `version_scope:`

`version_scope:` narrows which changes are reported. It receives the version
relation and returns a narrower one:

```ruby
user_edits = ->(scope) { scope.where.not(whodunnit: nil) }

PaperTrailDiff.analyze(article, within: window, version_scope: user_edits)
```

It is accepted by `analyze`, `analyze_many`, `analyze_scope`, and `report`. It may return the relation narrowed, or an
array of versions taken from it. Anything else, such as a relation on another
class or an array of IDs, raises `ConfigurationError`.

- Each reported change is compared with the version right after it, even if
  that version is filtered out. So each step shows exactly what that one change
  did:

  ```text
  versions   system → alice → system → bob → system
  reported   alice: what alice changed    bob: what bob changed
  ```

- `timeline` looks at the root record's versions only, so someone who only
  edited comments has none for it to report. Activity reports their changes:
  see [one person's changes](#one-persons-changes).
- In activity (`activity: true`, and `report`), it
  chooses the changes on the requested associations as well. A transaction is
  reported whole, every step of it, when the filter keeps any version saved
  in it, of whichever record: PT-AT shows a transaction's changes together, at
  its last step, so no step inside one belongs to a single version. A version
  saved outside a transaction is reported when the filter keeps it. Every
  version is still read, so each step shows what its own change did, and an
  analysis starts at the first change the filter keeps and ends after the
  last, a kept version of a record outside the root's tree being no change
  of the root's. Without associations, the steps are the root's versions the filter
  keeps, as `timeline` reports them.
- In `analyze_scope` and `report`, it also chooses which records are selected:
  a record is selected only when the filter keeps one of its own versions in
  the window, or a version of a record on a requested association. With
  associations, as activity reports them, it keeps a version when it keeps
  any version of that version's transaction, so a record is selected
  whenever its activity reports something. A record changed only by versions
  it drops would have nothing to report, so it is left out, and it does not
  count toward `limit:`.
- The record and its requested associations keep their versions in one table
  (see [custom version classes](#models-schemas-and-edge-cases)), and the
  filter reads it for all of them. A condition on `item_type` or `item_id`
  therefore leaves out the associations' changes; filter on the version's own
  columns, such as `whodunnit` or `event`.

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
- Associations at a version are read from the history recorded since then, plus
  the current rows for records that have not changed since. A comment that later
  moved to another article is still found at the versions where it belonged.
  This also holds when both sides are versions, or the record has since been
  deleted.
- A current record must be saved, not destroyed, and have no unsaved changes.
  The gem reloads it, so in-memory edits and cached associations are ignored.
- Options: `associations:`, `ignore:`, and `allow_approximate:` (see
  [costly associations](#costly-associations)).

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
- Options: `associations:`, `ignore:`, and `allow_approximate:` (see
  [costly associations](#costly-associations)).

If you look up versions yourself, do it in bulk. Looking up one record at a
time brings back the per-record queries this method avoids.

## analyze

`analyze(record)` returns an `Analysis` with the net `diff` and the `timeline`
for one range, reading each version once:

```ruby
analysis = PaperTrailDiff.analyze(article, associations: ["comments.replies"], activity: true)

analysis.diff              # net change over the range
analysis.timeline          # one step per version of the record
analysis.activity_timeline # nil unless activity: true
analysis.from_snapshot     # the full state at the start (nil before creation)
analysis.to_snapshot       # the full state at the end
analysis.window            # the time window it covers, or nil without within:
analysis.to_h(snapshots: true, metadata: true)
```

- See [choosing a range](#choosing-a-range) for `from:`, `to:`, and `within:`.
- `from_snapshot` is the record as it was when the range began: before the
  first change in a window, or before the change of the version you passed as
  `from:`. With `version_scope:`, a window begins at the first change the
  filter keeps, on the record or, with `activity: true`, on its associations.
  It is `nil` when the record was created inside the range; the state right
  after it was created is then the first activity step's `to_snapshot`, which
  `snapshots: true` keeps.
- To read the record at one version, with its values typed and its
  associations, take `from_snapshot` from a range that starts there:
  `PaperTrailDiff.analyze(article, from: version, to: article).from_snapshot`.
  Don't decode `version.object` yourself; the gem casts what PaperTrail
  stores, which a `json` column or an enum leaves in another form.
- When nothing in the range is reported, the analysis is empty: an empty
  `diff` and timelines, and `nil` for `from_snapshot` and `to_snapshot`. Here
  `nil` means no state was read, not that the record did not exist; reading
  one would rebuild the record's whole graph, a cost per record in a batch.
  Use `compare` with a version and the record to see a state that did not
  change.
- `activity: true` also builds the activity timeline. `snapshots:`, `group:`,
  and `recorded_changes:` apply to the activity timeline and require
  `activity: true`.
- Options: `from:`, `to:`, `within:`, `associations:`, `ignore:`, `activity:`,
  `version_scope:`, `snapshots:`, `group:`, `recorded_changes:`,
  `allow_approximate:`.

## timeline

An analysis's `timeline` holds one step for each pair of neighboring versions
of the root record, ending at its current state by default. See
[choosing a range](#choosing-a-range) for `from:`, `to:`, and `within:`.

```ruby
steps = PaperTrailDiff.analyze(article).timeline

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

## activity_timeline

With `activity: true`, an analysis's `activity_timeline` holds one step for
each recorded event of the root record **or** a chosen association. It ends at
the current record by default.

```ruby
steps = PaperTrailDiff.analyze(
  article, associations: ["comments.replies", :author], activity: true
).activity_timeline

steps.reject(&:empty?).each do |step|
  step.source_boundary.whodunnit # who made this change
  step.source_boundary.item_type # "Article", "Comment", ...
  step.diff                      # what that one event changed
end
```

- Each step's `diff` is what the event at its `source_boundary` changed, plus
  anything [saved without a version](#how-papertrail-stores-history) to the
  same record before its next version. Use `source_boundary` for attribution.
  `to_boundary` is only the next point in time and may belong to someone else.
- Boundaries have a `kind`: `:version`, `:current` (the current record), or
  `:destroyed` (after a deletion). They also have `event`, `whodunnit`,
  `recorded_at`, `item_type`, `item_id`, `transaction_id`, and `record`, and
  the predicates `version?`, `current?`, and `destroyed?`.
- `step.sources` lists the events whose changes the step shows, oldest first.
  That is just `source_boundary`, unless the step is a
  [transaction group](#one-step-per-transaction-group-transaction).
- A record's versions are steps only while it is in the tree. A comment edited
  on another article and moved to this one later shows up when it moves, not
  when it was edited there.
- `step.to_h` returns `{ from:, to:, diff: }`. `to_h(metadata: true)` adds
  author, event, transaction ID, and record, and a `sources` list.
  `to_h(snapshots: true)` adds the retained snapshots.
- A child's change becomes visible at the next recorded event, or at the
  current record. You do not need to save the article after each comment change.

### One person's changes

Pass a [`version_scope:`](#reporting-only-some-changes-version_scope) that
keeps their versions. Activity then reports only the transactions they saved
a version in, on the record or on its associations:

<!-- executable:readme-person-scope -->
```ruby
priya = ->(versions) { versions.where(whodunnit: "Priya Shah") }
steps = PaperTrailDiff.analyze(
  article, within: window, associations: %i[comments tags], activity: true,
           version_scope: priya
).activity_timeline

steps.map { |step| step.source_boundary.whodunnit }.uniq  # ["Priya Shah"]
```

To count everyone's changes from one read, group the steps in Ruby by
`source_boundary.whodunnit` instead:

<!-- executable:readme-person-changes -->
```ruby
steps = PaperTrailDiff.analyze(
  article, within: window, associations: %i[comments tags], activity: true
).activity_timeline

attributed = steps.reject(&:empty?)
by_priya = attributed.select { |step| step.source_boundary.whodunnit == "Priya Shah" }

by_priya.first.source_boundary.whodunnit  # "Priya Shah"
by_priya.first.diff                     # what that one event changed

authors = attributed.group_by { |step| step.source_boundary.whodunnit }
                    .transform_values(&:length)
```

For many records, use `report` or `analyze_many(..., activity: true)` instead of
calling `analyze` in a loop, so the database work is shared. With
`version_scope:`, `report` selects only the records that person changed.

### One step per transaction: `group: :transaction`

Saving an article and its comments together creates one version each, so one
action shows up as several steps. `group: :transaction` combines steps from the
same database transaction:

```ruby
PaperTrailDiff.analyze(article, associations: [:comments], activity: true, group: :transaction)
```

- A combined step compares the state before the transaction with the state after
  it. A field set and then restored inside the transaction is not reported.
- Its `source_boundary` is the first event in the transaction. That event's
  author is not necessarily the author of every grouped change. `step.sources`
  lists every event in the transaction, each with its own author, except two
  kinds: those of records outside the tree before the transaction, after it,
  and at every version of the root it saved; and those saved before a window
  that starts inside a transaction of associated records only (see
  [time windows](#time-windows)). Its [change rows](#change-rows) each name
  the event of their own record.
- Versions without a `transaction_id` are never grouped.
- A savepoint that rolls back can split one transaction into more than one
  group. PT-AT clears the transaction id when the savepoint rolls back, so the
  versions the transaction saves afterwards form a separate group. Releasing
  the savepoint keeps one group.
- A step joins only the group of the step just before it. Two transactions
  that save in the same tree at the same time, so that their versions
  interleave, each form a group for every run of their own versions. A
  transaction's changes to associated records are read once it has ended
  (see [version order](#version-order)), so they appear in the group of its
  last run; the changes its root versions record appear in their own runs.
- Also accepted by `analyze_many` and `analyze_scope` with `activity: true`,
  and by `report`.

Without grouping, a step inside a transaction can look empty. A child's new
value is only visible at the next recorded event, and inside a transaction that
event is often another part of the same save. Nothing is lost; the change
appears one step later. When the range ends at the version that closes that
save, there is no later step, so the change is
[outside the range](#choosing-a-range).

### Keeping snapshots: `snapshots: true`

A step's `diff` holds only what changed. To show unchanged fields too, such as
a comment's author next to an edited comment body, keep the snapshots:

```ruby
steps = PaperTrailDiff.analyze(
  article, associations: [:comments], activity: true, snapshots: true
).activity_timeline

step = steps.reject(&:empty?).last
step.from_snapshot.associations["comments"].records.first.attributes["author"]
```

- The gem builds these snapshots anyway, so keeping them adds no queries. They
  do use memory, because each one contains every chosen association.
- `from_snapshot` is `nil` for a step starting at a `create` version, because the
  record did not exist yet.
- Also accepted by `analyze_many` and `analyze_scope` with `activity: true`,
  and by `report`.
- [`net_changes`](#net-changes) reads them, so it needs this option.

### What each event recorded: `recorded_changes: true`

A step's `diff` compares the state before and after an event. To also see what
PaperTrail [stored with each version](#what-a-version-recorded), such as for an
audit log, pass `recorded_changes: true`:

<!-- executable:reference-step-sources -->
```ruby
steps = PaperTrailDiff.analyze(
  article, associations: [:comments], activity: true, group: :transaction,
           recorded_changes: true
).activity_timeline

steps.reject(&:empty?).flat_map(&:sources).map do |source|
  {
    version_id: source.version_id,
    record: source.record.to_h,     # { type: "Comment", id: 7 }
    event: source.event,
    actor: source.whodunnit,
    recorded_at: source.recorded_at,
    transaction_id: source.transaction_id,
    changes: source.recorded_changes # { "body" => <from "Old" to "New"> }
  }
end
```

- Each boundary's `recorded_changes` is what
  `PaperTrailDiff.recorded_changes(version)` returns for its version: `nil`
  when nothing was recorded, and always `nil` for the current record. The
  versions are already loaded, so this adds no queries. A version's changes
  are decoded the first time a boundary's `recorded_changes` is read, and once
  for the whole call, however many steps or records share the version. Read
  them from the boundary rather than calling `PaperTrailDiff.recorded_changes`
  for its version, which decodes it again each time.
- Without the option, `recorded_changes` raises `ConfigurationError` instead of
  returning `nil`, so a missing option cannot look like a version that recorded
  nothing.
- `to_h(metadata: true)` includes them on each boundary and source.
- Names in `ignore:`, or in `ignore: { all: }`, are left out. So are names
  ignored on the root path, `"$"`, for the root's own versions. Names ignored
  on an association path are not left out, because a child's version does not
  say which path reached it.
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

With `activity: true` and associations, the deletion is reported in the
window its transaction ends in, like any other change. So a window after the
`destroy` version can still report it, when the transaction went on saving
other records, and a window after that transaction's end reports nothing: an
empty timeline and an empty diff.

A record restored afterwards under its id, as saving `version.reify` does,
is the same root before and after. A range that ends at its `destroy` then
ends before the deletion, as at any other version, and the range from the
`destroy` reports the removal, in its step to the version that restored it,
so the two report it once. The transaction that restored it is the root's
from its first event, as for a record created afresh.

### HABTM limitation

`has_and_belongs_to_many` join rows have no versions, so the gem cannot split
their changes into separate events once a range runs past the last root version
into the current record. That case raises `UnsupportedLiveActivityError`. End
the range at a version instead (see the
[checkpoint recipe](#saving-a-checkpoint)), or use a join model with
`has_many :through`.

PT-AT records HABTM members under the transaction a version was saved in, and
does not say which record they belong to. If another record with a HABTM of the
same name, such as a second article, also saved a version in that transaction
and members were recorded there, reading the root's membership at that version
raises `IncompleteAssociationHistoryError` instead of mixing both records'
members. Save each HABTM owner's versions in a transaction of its own.

PT-AT records membership only when the owner saves a version, so the gem knows
it only at root versions. A change made between two root versions is reported
in the first step after the earlier one, and credited to that step's source:
usually the earlier root version, which someone else may have saved. A member
created between them is reported in the step that starts with its creation
instead. A change attached before a checkpoint is therefore credited to
whoever saved the version before the checkpoint, not to the checkpoint's
author. To credit a change to the person who made it, save a checkpoint just
before the change as well as after it: the step between the two checkpoints is
theirs.

PT-AT works out the membership a version records from the instance that saves
it: the instance's current members, with the changes that instance made undone,
so that the version holds the membership from before its own event. It never
forgets those changes, not even on `reload`. Only the first version an instance
saves after changing a HABTM is right; each later save from it records the
membership from before that change again. The gem then reports the change late,
or reports a member that never left as removed and added again. Load the record
again, with `find`, before saving it a second time, and save checkpoints from a
freshly loaded record, as the [checkpoint recipe](#saving-a-checkpoint) does.

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
- A record with nothing to report gets an empty `Analysis`, whose snapshots
  are `nil` (see [analyze](#analyze)).
- Records must be saved and unique.
- Options: `within:`, `associations:`, `ignore:`, `activity:`, `version_scope:`,
  `snapshots:`, `group:`, `recorded_changes:`, `allow_approximate:`.

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

report.roots.each do |order|
  report.analysis_for(order) # its Analysis, without building the identity
end

analyses, unreachable = report # destructures into analyses and unreachable
```

It takes the same options as `analyze_many`, plus `limit:`, `historical_filter:`,
`max_filter_versions:`, and `include_deleted:`. `within:` can be omitted to use
all history.

### report

`report(scope, since:, limit:)` is `analyze_scope` with `within: since..`, an
endless window, and `activity: true`. Use it for "what happened recently":

```ruby
report = PaperTrailDiff.report(Article.all, since: 1.day.ago, limit: 100)
```

It accepts `associations:`, `ignore:`, `version_scope:`, `snapshots:`, `group:`,
`recorded_changes:`, `include_deleted:`, `historical_filter:`, `max_filter_versions:`,
and `allow_approximate:`.

### Which records are selected

- **A record is selected when it, or a record on a requested association,
  changed in the window.** With `activity: true`, which `report` always uses,
  editing only a comment selects its article when you request
  `associations: [:comments]`. A comment that moved between articles selects
  both. Nested paths count at every level, and a `has_many :through` counts its
  join rows too. Without `activity: true`, an analysis compares a record's own
  versions and cannot show a change to its associations alone, so only a
  record's own version selects it. With
  [`version_scope:`](#reporting-only-some-changes-version_scope), only the
  versions the filter keeps select it, the record's own and its associations',
  each with its whole transaction when associations are requested.
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
  the page. Without an `order`, records are taken in ascending ID order. Any
  other order gets the ID as a last tie-breaker unless it already sorts by it,
  so that records that tie are neither skipped nor read twice. SQL text counts
  as sorting by the ID when it names the column, alone or after the table's
  name, as `order("title, id")` does. Give the queries that show the page the
  same tie-breaker, such as `order(:status, :id)`, so that they list the
  records the report analyzed. If a join repeats a record, it is analyzed
  once, in order of first appearance. A relation grouped by anything but the
  ID, such as `select("MAX(id) AS id").group(:author_id)`, keeps its own
  order, since a database sorts groups only by what they group or aggregate.
  It needs one that tells its groups apart, such as `order(:author_id)`;
  without any order it raises `ConfigurationError`.
- Selection still scans the versions in the window, so keep windows reasonable
  for large tables. Each requested association adds one query per level, however
  many records it selects. Changes to associations are found from PT-AT's
  `version_associations`, so history recorded before PT-AT was installed selects
  nothing, and neither does a `belongs_to` target's change for a record that
  has no version of its own, such as one created with PaperTrail turned off:
  `analyze` on that record reports the change, but no selection finds it. A
  change below a `has_many` or `has_one` child that has no version selects
  the owner its row names now, since such a child has held that key
  throughout, as an analysis reads it.
- **A window with associations reads from where the transactions open at
  its start began**, and selects by the versions those transactions saved
  before it, but by no other version saved before the start.

### Deleted records

A relation's conditions read the table, and a deleted record has no row.
Records that changed in the window but no longer exist are listed in
`unreachable`, including those selected by a change to their associations,
when the state each held when it was destroyed meets the relation's
conditions. That test needs conditions it can read, as `include_deleted:`
below does; for any other relation, such as one with SQL text or a join,
`unreachable` lists every such record of the model, whatever the relation. It
is not paginated.

`include_deleted: true` tests each of them against the relation's conditions,
as it stood when it was destroyed, and keeps only those that match. So a report
on `Article.where(account_id: account.id)` returns that account's deletions,
not every account's. The relation's conditions must be plain conditions on the
model's own columns, as a [readable association scope's](#costly-associations)
must, ranges and equality on a date or a time included; anything else, such
as a join or SQL text, raises
`ConfigurationError`. `Article.none` keeps none. Its order, limit, and offset
are ignored here, since they choose a page of existing rows. A record whose
destroy PaperTrail did not record has no state to test and stays listed.

It then analyzes the kept records from their `destroy` versions and returns the
results in `deleted`, keyed the same way. A value is `nil` when no `destroy`
version was recorded. With this option, existing and deleted records together
count toward `limit:`.

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
change saved inside it. It reads each version where it was saved, not where
its transaction ended (see [time windows](#time-windows)), so a record whose
transaction began before the window and ends inside it is checked from the
state its versions before the window left. A record matches if
any of those states match. With a
hash, every key must be equal (`==`) once both sides are cast to the
attribute's type, as `where` casts its values: `{ status: :published }` matches
an enum, and a date or time matches whether the history stored it as YAML or
as a string in a `json` column. Text or a date given for a datetime
attribute is read as `where` sends it, in Active Record's default time zone
rather than `Time.zone`, and a value the attribute cannot take, such as a
hash for a time, raises `ConfigurationError`. Values are read from the stored history
without calling `reify`, except for a model whose stored values only a record
can read, such as one with an encrypted attribute, whose versions are rebuilt
with `reify` and compared by their decrypted values. Unknown or unrecorded
attributes raise an error instead of matching `nil`, and so does an
attribute the model declares without a column, which `where` cannot name. So does a list or a
range as a value, such as `{ status: %i[published archived] }`, which `where`
would read as any of them, unless the attribute itself holds one. For other
checks, pass a callable such as
`->(article) { article.title.start_with?("Pub") }`; it receives each state as a
model instance and may run queries of its own.

- It looks only at the record itself, not its associations, and does not check
  whether a value was held for the whole window.
- Only the history of records the relation selects is read, and the relation's
  order, `limit`, and `offset` then page the ones that match. Deleted records,
  which a relation cannot test, are read too, and those that match are listed
  in `unreachable`.
- Matching records the relation selects count toward `limit:`, and matching
  stops as soon as the limit is exceeded. Matching deleted records count only
  with `include_deleted: true`, as without a filter.
- A relation with a `limit` pages the matches: records are read in the
  relation's order, matching stops when the page is full, and only the page
  counts toward `limit:`. So `Article.order(:id).limit(20).offset(40)` with
  `limit: 20` returns the third page however many records match, and reads
  history only as far as that page. A grouped relation, and one without a
  `limit`, still read every match.
- `max_filter_versions:` limits how many versions the filter loads, including
  the one version after the window it reads for each record, and the versions
  of deleted records. The default is 10,000. Going over raises
  `FilterLimitExceededError` before the extra batch is checked. It does not
  limit queries inside a callable.
- `version_scope:` narrows which changes are reported, not which states are
  tested here.
- It is accepted by `analyze_scope` and `report`, which select records from a
  relation.

### Costly associations

Most associations are loaded for all records together. That includes an
association whose scope, or whose target's default scope, is plain conditions
on the target's own columns:

```ruby
has_many :active_cards, -> { where(archived: false) }, class_name: "Card"
has_many :urgent_cards, -> { where(priority: [1, 2]).order(:id) }, class_name: "Card"
default_scope { where.not(hidden: true) }
```

The gem reads such a scope once and checks each record's stored values against
it at every point, so a record that moves into or out of the scope is added or
removed at the version that moved it. It reads equality, `IN`, their
`where.not` forms, and `and`/`or`/`not` combinations of them on integer,
boolean, and enum columns, with SQL's rules for NULL. A `nil` test
(`IS NULL`, `IS NOT NULL`) is read on a column of any type, so a soft-delete
scope such as `where(deleted_at: nil)` is read too. String and text columns
are read only on SQLite and PostgreSQL, and only without a column collation:
MySQL and SQL Server compare strings without regard to case or trailing spaces
by default, which the gem cannot repeat. Neither is PostgreSQL's `citext`,
which ignores case, nor its `character(n)`, which pads with spaces.

The gem lists the SQL column types it reads this way for each of SQLite,
PostgreSQL, MySQL (`mysql2` and `trilogy`), and SQL Server. A condition or
order on a column of any other type, or on another adapter, is not read,
like the scopes described below. On SQL Server a `datetime2` is read but not
a legacy `datetime` or `smalldatetime`, which round the times they store.

Ranges, such as `where(position: 2..)` or `where(created_at: 1.day.ago...)`,
and Arel's `gt`, `gteq`, `lt`, and `lteq`, are read on the columns an order
can sort by, below: integer, integer enum, date, and datetime columns, with
the same conditions on a datetime's precision. Equality and `IN` on a date or a
datetime column, such as `where(due_on: Date.current)`, are read under those
conditions too.

A `limit` or `offset`, and the order of a `has_one`, are read the same way
when the order is total and the gem can repeat it:

```ruby
has_many :first_comments, -> { order(:position, :id).limit(3) }
has_one :latest_comment, -> { order(id: :desc) }
```

At every point the gem ranks the records that meet the scope's conditions by
the order, then skips the offset and keeps the limit, as the association's own
query would have. The order must reach the primary key, so that no two records
tie, and each key before it must be an integer, boolean, integer enum, date,
or datetime column of the target, ascending or descending. NULL sorts where the
database puts it by default: last in an ascending order on PostgreSQL, first on
SQLite, MySQL, and SQL Server.

A datetime key, such as `order(created_at: :desc)`, is read when its column
declares a precision, as Rails 7 and later give every new `datetime` column,
when history keeps that many fractional digits, and when Active Record stores
times in UTC, its default. Active Record truncates a time to its column's
precision before writing it, so history then holds the value the database
sorts by. YAML history keeps every digit; JSON history, and a `json` or
`jsonb` object column, keep `ActiveSupport::JSON::Encoding.time_precision`
digits, 3 by default, so with them only a `datetime(3)` or coarser column is
read. A time-of-day column is not read: Active Record keeps the date it was
given in memory but stores only the time.

A `has_many :through` reads its parts as Active Record's own query joins them:
it keeps each part's conditions but not its `limit`, `offset`, or `has_one`
cut, so a through over `has_one :latest_comment` holds the records of every
comment that meets the part's conditions, not only the latest. Its own `limit`
or `offset` ranks the rows the join yields, so a record reached through two
join records fills two places, as in the query. A `has_one :through` whose
own scope or whose parts have a limit, an offset, or a `has_one` order is not
read. One without an order reads, as Active Record does, the target of its
first join row by key.

The gem cannot read the rest: a `limit` or `offset` whose order is not total or
sorts by another column type (strings follow a collation) or by a datetime
history cannot rank exactly, scopes that take the owner
(`->(article) { ... }`), scopes written as SQL strings, ranges on other column
types, scopes that join or select, and conditions on other column types or
other tables, such as a string column on MySQL. For these it asks PT-AT, which costs queries per
record and is approximate: PT-AT rebuilds an association from its current
members, swapping in their older versions, and never checks the scope against
them. A record that entered the scope since is reported as a member it was
not, so a comment moved into `-> { where("position > 2") }`, or restored from
a soft delete, shows as changed rather than added.

So every method that reads history raises `UnsupportedAssociationError` for
such a path and names it. Remove it from `associations:`, rewrite its scope as
plain conditions on the target's own columns, or pass `allow_approximate:
true` to accept PT-AT's answer, which also accepts its cost of queries per
record in batch methods. A comparison of two current records reads no history
and needs no opt-in.

A polymorphic `belongs_to` is loaded together too, with one query per target
class. Its classes are known only from the records, though, so batch methods
cannot reject one with a scope they cannot read in advance: a record that
points at such a class is read on its own, without an error. A scope on the
polymorphic `belongs_to` itself is rejected.

This check covers known association cases only. Your model callbacks, custom
attribute types, and callable filters can still run queries. See the
[performance guide](performance.md) for measurements.

## Associations

Associations are only included when you name them. Use names or dot-separated
paths; the parents in a path are included automatically:

```ruby
diff = PaperTrailDiff.compare(from, to, associations: [:author, "comments.replies"])
```

`associations:` also takes what `includes` takes: a single name
(`associations: :comments`) or hashes of names to what to include below them
(`associations: [:author, { comments: :replies }]`).

Supported: `belongs_to`, `has_one`, `has_many` (including `:through`), and
`has_and_belongs_to_many`. Associated models must use `has_paper_trail`, the
target of a `has_one` or `has_many` must declare the `belongs_to` back, and
historical states need PT-AT installed and enabled
(`PaperTrail.config.track_associations = true`). The gem never follows
associations you did not ask for, so cyclic models are safe.

When more than one record points at the owner of a `has_one` without an
order, history reads the one with the lowest primary key, as Active Record's
`LIMIT 1` does on SQLite, MySQL, and SQL Server. PostgreSQL promises no order
there, so its current record can read another one: give such a `has_one` an
order, or a unique index, to make the choice the same everywhere.

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
  check this earlier, since only the record names the class. A type that
  names no class, such as one a renamed model left in its versions, raises
  `IncompleteAssociationHistoryError` naming the record.
- `has_many :through` uses the versioned join model's history, so join-model
  attributes are available. HABTM reports membership and the target's
  attributes; it has no join model, so it has no join attributes.
- A `has_many :through` holds, at each point, the records the owner reached
  through the join records it had then. A record that moves to another join
  record leaves one owner and joins the other, and so does every record under
  a join record that moves to another owner.
- A `has_many :through` with `source_type:` holds only the records reached
  through join records whose type column names that class, as Active Record
  reads it. A join record that points at another type is never a member, and
  its changes add no activity step. A join record whose type changes adds or
  removes its target in the step of that version.
- A `has_many :through` that goes through a HABTM, as its `through:`, its
  `source:`, or further down its chain, raises `UnsupportedAssociationError`
  up front in every method. Active Record joins a HABTM through a hidden
  model with no versions, so the through cannot be rebuilt from history.
  Replace the HABTM with a `has_many :through` a versioned join model to
  compare it. `association_paths` leaves such a through out.
- A HABTM can only be rebuilt on the root record. PT-AT records membership
  when the record that owns it saves a version, in rows that name the
  transaction and the association but not the owner, so a root checkpoint
  holds the root's membership and no one else's. A HABTM later in a path, such
  as `"tags.articles"` or `"author.articles.tags"`, raises
  `UnsupportedAssociationError` up front in every method, even when the path
  leads back to the root, as `"comments.article.tags"` does.
  `association_paths` leaves such a path out. To follow another record's
  memberships, compare that record's own checkpoints, or replace the HABTM
  with a `has_many :through` a versioned join model.
- A HABTM with a scope, such as `-> { where(active: true) }`, or whose target
  has a default scope, raises `UnsupportedAssociationError` up front in every
  method. PT-AT records a HABTM's members by loading the association through
  its scope when the owner saves, so a target outside the scope then is never
  recorded, and one that enters the scope before the owner's next save is a
  member history cannot show. Replace it with a `has_many :through` a
  versioned join model, which can be scoped. `association_paths` leaves it
  out.
- An association keyed on a column other than a primary key, such as
  `has_many :comments, primary_key: :legacy_id`, raises
  `UnsupportedAssociationError` up front in every method, and so does a
  `has_many :through` with such a part. PT-AT records which record a child
  pointed at by that record's ID, so history read that way would show other
  records' children. `association_paths` leaves it out. Naming the primary key
  itself, `primary_key: :id`, is accepted.
- A `has_many` or `has_one` whose target declares no `belongs_to` on its
  foreign key, such as `has_many :comments` when `Comment` has no
  `belongs_to :article`, raises `UnsupportedAssociationError` up front in
  every method, and so does a `has_many :through` with such a part. PT-AT
  records a record's owner on the record's own versions, once for each
  `belongs_to` it declares, so with none nothing says a comment that was
  destroyed or moved away was ever the article's. `association_paths` leaves
  it out. Declare the `belongs_to` to request the path; versions saved before
  then recorded no owner, so a record that left before then is not reported.
- A root that uses single-table inheritance gets the associations of the
  class it had at each version, so you can request one that only a subclass
  declares. Without an `item_subtype` column, PaperTrail stores only the base
  class; the gem reads the subclass from the type column the version stored.
  A version where the record was a class without that association raises
  `UnknownAssociationError`, as a current record of that class would. A
  stored type that names no class raises `InvalidEndpointError`. A child's
  `belongs_to` may name any class of the owner's table: PT-AT records the
  class it names, and the gem looks for each one the target declares.
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
record's old `updated_at` as its time and lands in the past. Save one record per
transaction: HABTM membership cannot be read from a transaction in which
another record with the same HABTM also saved a version (see the
[HABTM limitation](#habtm-limitation)). A checkpoint records membership as it
is when saved, including a member attached or created earlier in the same
transaction. A change it captures is credited to the step before it, so its
author is whoever saved the version before the checkpoint, unless that is a
checkpoint the same person saved just before the change. A member created in
the checkpoint's transaction is reported in the step of its creation instead,
or, when the range ends at the checkpoint, in the step before it. Don't save
the instance that made the HABTM change again; it records the old membership.

### Files from ActiveStorage

`has_one_attached` and `has_many_attached` point to ActiveStorage's own models,
which PaperTrail does not version. Comparing them historically raises
`UnversionedAssociationError` rather than claiming nothing changed, and
`association_paths` leaves them out. Versioning
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
| `ChangeRow` | one row from `change_rows` |
| `NetChange` | one record's entry from `net_changes` |
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

### Change rows

For a table or an export, `change_rows` flattens activity into one row per
change, each credited to the version that made it:

```ruby
steps.last.change_rows                    # one activity step
analysis.change_rows                      # an Analysis built with activity: true
report.change_rows                        # { identity => rows }, deleted records last

row = report.change_rows.values.first.first
row.change           # :changed, :added, or :removed
row.attribute        # "body", or nil for a row about a whole record
row.from             # nil for :added
row.to               # nil for :removed
row.record           # a RecordReference, or nil for the root
row.association_path # ["comments"], or [] for the root
row.source           # the ActivityBoundary of the version that made the change
row.unversioned?     # true for a change saved without a version
row.to_h             # the above, plus version_id, event, whodunnit, recorded_at,
                     # and transaction_id
```

- An edited field is one `:changed` row. A record that appeared or disappeared
  gets an `:added` or `:removed` row with `attribute` `nil`, then a row for each
  field that is not `nil` and for each record it holds.
- A replaced `belongs_to` or `has_one` target gives the old record `:removed`
  rows, then the new one `:added` rows.
- Rows follow the diff's walking order, and an analysis's rows follow its steps
  in time order.
- `Analysis#change_rows` raises `ConfigurationError` without `activity: true`.
  `report.change_rows` leaves out a deleted record without destroy history.

Which version a row names:

- A field's change names the version of the row's own record that made it,
  among those its step's transaction saved. Inside a transaction, a record's
  change can show up at a later event than its own, in a step another record's
  version opens; the row still names its own record's version. With
  `recorded_changes: true`, that is the version that recorded the field's new
  value. Without it, the gem cannot tell which of a record's versions made
  the change, so the row names the last of them.
- A record created or destroyed names its `create` or `destroy`. Its fields
  name the version that recorded each value: the `create`, or a later save in
  the same step. A record that joined or left by its own update, such as a
  comment moved to another article, names the last of its versions in the
  step's transaction. A record that joined or left through another record's
  change, such as a new `belongs_to` target or a `has_and_belongs_to_many`
  member, names the step's `source_boundary`.

With `recorded_changes: true`, a change PaperTrail did not record gets a row of
its own: a write [saved without a version](#how-papertrail-stores-history),
such as `update_columns`. Its source has kind `:unversioned` and names the
record, with no version, event, author, or time, so `to_h` has `nil` for
`version_id`, `event`, `whodunnit`, `recorded_at`, and `transaction_id`. A
field a version recorded changing from `10` to `20`, and that a later
`update_columns` set to `99`, gives two rows: `10` to `20`, credited to the
version, then `20` to `99`, unversioned. To report only what versions
recorded, leave such rows out:

<!-- executable:reference-unversioned-rows -->
```ruby
analysis = PaperTrailDiff.analyze(
  article, associations: [:comments], activity: true, recorded_changes: true
)

analysis.change_rows.reject(&:unversioned?)
```

The gem splits off only what the versions show was not recorded. A row stays
whole, credited to a version, where they cannot:

- the version recorded no changes, as a `touch` does, or the version table
  has no `object_changes` column;
- the column is one `has_paper_trail ignore:` or `skip:` names, or `only:`
  leaves out;
- the field is one a `create` left at its default, which no version records:
  a later write to it reads as the value the record was created with;
- the version is in a transaction that began before a window and saved no
  version of the root (see [time windows](#time-windows)), whose earlier
  versions the window does not read.

Rows follow each step's diff, so a change a version recorded and a later write
without a version undid, leaving the field as it was, has no row.

### Net changes

`net_changes` folds change rows into one entry per record: its fields before
the rows a block keeps, and its fields with only their changes made. This
example keeps the rows with an author. A write saved without a version has
none, so with `recorded_changes: true` it is left out:

<!-- executable:reference-net-changes -->
```ruby
analysis = PaperTrailDiff.analyze(
  article, associations: [:comments], activity: true, snapshots: true,
  recorded_changes: true
)

changes = analysis.net_changes { |row| row.source.whodunnit }
```

```ruby
change = changes.first
change.root?            # true for the article, which comes first
change.record           # a RecordReference, or nil for the root
change.association_path # ["comments"], or [] for the root
change.before           # a RecordSnapshot of its fields, or nil if it was added
change.after            # its fields after the kept changes, or nil if removed
change.diff             # a Diff of before and after
change.added?           # before is nil
change.removed?         # after is nil
change.sources          # the ActivityBoundary of each kept change, each once
report.net_changes { |row| ... } # { identity => changes }, keyed as change_rows
```

Without a block, every row is kept, and `before` and `after` are the record's
states around all of its changes.

- `before` is the record's state when the step holding its first kept change
  began, so it includes the changes dropped before then.
- `after` is `before` with only the kept changes made: each field takes the
  value of its last kept row. A record that appears takes the fields it
  appeared with. A record appears or disappears only through its own row,
  whose `attribute` is `nil`, so a block that keeps only some fields also
  leaves out the records added and removed.
- A record whose kept changes leave it as it was is left out, as is one added
  and removed again.
- The root comes first whenever anything is listed. When only the records it
  holds changed, its `before` and `after` are the same and its `diff` is
  empty.
- `before` and `after` hold only the record's own fields; each record it holds
  has an entry of its own. A record has one entry for each association path,
  whichever records along the path hold it, so a reply moved from one comment
  to another is one entry.
- The states come from the steps' snapshots, so `net_changes` raises
  `ConfigurationError` without `snapshots: true`, as it does without
  `activity: true`.
- To leave out only the writes saved without a version, keep the other rows:
  `{ |row| !row.unversioned? }`.

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
- `:a` and `"a"` are one key at any depth, inside arrays too, so a path's keys
  are strings. Values are reported as they were given.
- Arrays are compared by their elements, not positions. An `ArrayChange` has
  `added`, `removed`, and `reordered?`, plus the whole `from` and `to`. Objects
  inside arrays are compared whole. Elements match as values under a key do,
  so `1` and `1.0` are different elements.
- A missing key is `PaperTrailDiff::NestedComparator::ABSENT`, not `nil`, because
  `{"a": null}` and `{}` are different.
- Two arrays at the top, as a `json` column can hold, return one `ArrayChange`
  at the empty path: `{ [] => <added [3], removed [2]> }`.
- A value that is not JSON on both sides, or an object facing an array, returns
  `{}`; the attribute diff still has the whole change.
- Keys such as `:a` and `"a"` in one object raise `AmbiguousNestedKeyError`.

## What a version recorded

`recorded_changes(version)` returns the changes PaperTrail stored with one
version in its `object_changes` column, as a frozen hash of `ValueChange`
objects in attribute-name order:

```ruby
PaperTrailDiff.recorded_changes(version)
# => { "title" => <from "Draft" to "Published"> }
```

A step's `diff` compares the record before and after an event instead. The two
usually agree. They differ when:

- something was [saved without a version](#how-papertrail-stores-history)
  before the record's next version. The diff includes it; this does not.
- `has_paper_trail` ignores an attribute or leaves it out of `only:`. PaperTrail
  stores its value but not its changes, so only the diff reports them.
- the version is a `create` or a `destroy`. The diff reports
  `record_presence_change`; this lists each attribute changing from `nil`, or
  to `nil`.
- an included association's foreign key changed. The diff reports the
  association instead; this keeps the column.

Other details:

- It returns `nil` when nothing was recorded: the version table has no
  `object_changes` column, or this version has no value in it. A version that
  recorded no changes, such as a [checkpoint](#saving-a-checkpoint), returns
  `{}`.
- `ignore:` takes an array of attribute names and defaults to `updated_at`, as
  elsewhere. It does not take `paths:`, because a version does not say which
  association path it was reached through. Primary keys are left out, and so
  is a name the model no longer has, such as a column dropped since.
- Unlike PaperTrail's `version.changeset`, it never loads the record. That
  saves a query per version, and a deleted record's values keep their types,
  such as an enum's label rather than the integer PaperTrail stored.
- Values read as a step's `diff` reads them, so a recorded value equals the
  state it produced: a time of day falls on 2000-01-01, and with
  [JSON history](#history-stored-as-json), times keep the digits history
  stores and binary and `serialize`d values read as JSON stored them.

For activity steps, pass `recorded_changes: true` instead of loading the
versions again. Each step's sources then carry what their versions recorded,
with no extra queries; see
[what each event recorded](#what-each-event-recorded-recorded_changes-true):

<!-- executable:reference-recorded-changes -->
```ruby
steps = PaperTrailDiff.analyze(
  article, associations: [:comments], activity: true, recorded_changes: true
).activity_timeline

steps.last.source_boundary.recorded_changes
```

## Checking your setup

List the associations a model supports, for example to build a settings
screen:

```ruby
PaperTrailDiff.supported_association_macros
PaperTrailDiff.association_paths(Article, max_depth: 3).map(&:to_h)
```

Each descriptor has `path`, `kind`, `target_type`, `through`, `polymorphic`,
and `cycle`. Cycles are marked and not followed.

Only associations a request accepts are listed, so each path can be passed to
`associations:`. The PaperTrail versions association, a `has_many :through`
that goes through a HABTM, a scoped HABTM, a HABTM below the root, an
association keyed on a column other than a primary key, one whose ends keep
their versions in different tables, and one whose target, or a model its
`has_many :through` goes through, has no `has_paper_trail` are left out. A path
history can read only approximately, such as one with a scope written as SQL
text, is listed, but requesting it also takes `allow_approximate: true` (see
[costly associations](#costly-associations)). A `has_many :through` Active
Record cannot follow, such as one through a polymorphic `belongs_to`, raises
Active Record's own error from any model discovery reaches, as requesting it
does.

Check a comparison's endpoints for known problems before relying on
association history. They are what `compare` takes: two versions, or a version
and the current record.

```ruby
report = PaperTrailDiff.diagnose(from_version, article, associations: [:tags, "comments.replies"])

report.ok?                  # no errors among the checks that ran
report.errors.map(&:code)
report.warnings.map(&:code)
```

Association checks run only for requested associations. The version-order check
always runs. Every reason `compare` would refuse the same request is an error,
with the message `compare` would raise, so `ok?` is false whenever `compare`
would refuse: an unknown or unsupported association, missing association
tracking, an unversioned target, or a path read only approximately. Pass
`allow_approximate: true`, as you would to `compare`, and such a path is a
warning instead. Endpoints `compare` rejects whatever their history holds,
such as versions given newest first, two records, or an unsaved record, raise
the error `compare` raises. `ok?` does not prove the history is complete.

## Models, schemas, and edge cases

- **Single-table inheritance.** Results are keyed by the base class, as
  PaperTrail stores it: a `Book < Publication` is `["Publication", "12"]`. Use
  `PaperTrailDiff::Endpoint.identity(record)` to build keys, or
  `analysis_for(record)` on the result of `analyze_scope` or `report`.
- **Non-integer primary keys**, such as UUIDs, are supported, and so is a string
  `versions.item_id` column.
- **Custom version classes** (`has_paper_trail versions: { class_name: }`) are
  supported. For association history, a model and each association you ask
  for must keep their versions, and their PT-AT version associations, in the
  same tables. PT-AT reads an association's history from its owner's
  tables, so it cannot follow an association into a different version
  table. Such an association raises `UnsupportedAssociationError` naming
  both tables, and `association_paths` leaves it out. One custom table
  shared by the models works like PaperTrail's own.

  PaperTrail numbers a transaction by the id of the first version it
  saved, in whichever table that was, so with more than one version table
  two transactions can share a number. Where a [time window](#time-windows)
  looks for the start of a transaction, the gem tells them apart by the
  version each began with, which carries its own id as its number. It
  consults the version classes loaded at the time, in the model's
  database: load them eagerly, as production does, or name them before
  reading. It cannot tell two apart when the earlier one's first version
  has been deleted, or when both ran at the same time. Within the history
  of one record and its associations, versions are still grouped by number
  alone, so where two transactions of one number both saved them, their
  versions are read as one transaction's: one step, or one group, runs from
  the first of them to the last, and the changes of every step between are
  reported inside it. In a young database both tables count from 1, so
  such numbers are common there. The version a transaction began with also
  marks where it began only when it is dated first: with a second version
  table, a callback that saves other records before its own version (see
  [version order](#version-order)) can make a window read that transaction
  as two.
- **A scoped versions association** (`has_paper_trail versions: { scope: }`)
  does not change what is read: every method reads all of a record's
  versions, because a history replayed without some of them would credit
  their changes to the next version kept. To report only some changes, pass
  [`version_scope:`](#reporting-only-some-changes-version_scope).
- **Values the database rounds.** PaperTrail stores the value a record held
  in memory, and the database may have stored less of it. The gem compares
  every side in the form the database keeps: times to the column's precision
  (a SQL Server `datetime` to 1/300 s, read back to the millisecond), a MySQL
  `float` to single precision, a SQLite decimal as the number SQLite returns,
  and a fixed-width `char` column padded (PostgreSQL, SQL Server) or with its
  trailing spaces stripped (MySQL). So saving `12:00:00.1234567` to a column
  that keeps microseconds is not reported as a change. A date assigned to a
  datetime column, which Active Record leaves on the instance when time zone
  aware attributes are off or `update_columns` writes it, is read as
  midnight in Active Record's default time zone, as the database stores it.
  A `serialize`d hash in a `json` or `jsonb` history keeps string keys only
  (see [history stored as JSON](#history-stored-as-json)).
- **Attributes without a column**, such as one declared with `attribute` for
  a form, are left out of every diff, snapshot and change row. PaperTrail
  stores whatever the instance held for one, but no row holds it.

### Version order

Versions are ordered by `created_at`, then by ID when timestamps are equal. That
works when IDs increase with each insert, as autoincrement IDs do, in one
table. UUID version IDs do not, and models with their own version tables count
IDs separately, so two such versions with the same timestamp cannot be ordered;
the gem raises `AmbiguousVersionOrderError` naming both instead of guessing.
That includes a tie for the first version after a `within:` window, which
holds the state the window ends in.
Timestamps stored to the second, as on a MySQL `datetime` column, make ties
common. `diagnose` reports this as an error.

A record's versions should also be dated in the order they were saved.
PaperTrail dates an update with the record's `updated_at` unless the model
sets `has_paper_trail synchronize_version_creation_timestamp: false`, so a save
that sets `updated_at` itself, such as an import that keeps another system's
times, a `touch(time:)`, or one made with timestamps off, can date its version
before the one saved before it. Versions are read in time order, so such an update is read
before the change it followed, and one dated before the record's `create`
reads as the record deleted and created again. When IDs that count up show a
record's versions dated out of the order they were saved in, `diagnose` warns
with `inverted_version_order`. Set the option on models whose `updated_at`
your application sets, and correct the stored `created_at` of versions
already saved.

The versions of different records in one transaction can be dated out of
the order they were saved in too: a callback or nested save that a model
declares before `has_paper_trail` saves other records' versions first and
the model's own last, dated as its save began. A transaction takes effect at
its latest dated version, ids breaking a tie, and a window reads it as open
across its start when it has versions dated on both sides, so its changes
are reported once whichever version it saved last.

`created_at` comes from your application server's clock. A clock that jumps
backwards, or servers whose clocks disagree, can record a later change with an
earlier time. Keep server clocks synchronized.

Versions are ordered by when they were stamped, not by when their transactions
committed. A transaction stamps its versions while it is open, so one that
commits last can still sort first. The gem cannot see commit order. A report
can therefore show a state the database never held, and a result for an earlier
version or a closed window can change once that transaction commits.
[Time windows](#time-windows) explains how to settle a report.

Two transactions that save in one record's tree at the same time interleave
their versions. Each version was saved while the other transaction's changes
were not yet committed, so at a version of one, a record the other saved
reads as it stood before the other began, as a record the version's own
transaction saved does. A version reads so wherever it is used: in
`compare`, and as the start or the end of a range. The other's changes appear from the event after its
last version, in a step it opens, so a record it changed and changed back,
such as a comment it created and deleted again, appears in no step and in no
window's starting state or diff. A transaction is open from its first
version on the requested paths in the range, or from the range's start when
it began before it, to the latest dated version it saved of any record in
the same version table. Row locks keep the two from saving the same
record. The association shapes below that fall back to PT-AT's own reifier
still read by time.

Association changes between versions with the same timestamp are placed using
the same order. A few association shapes fall back to PT-AT's own reifier, which
uses timestamps only: a path history reads only approximately, which takes
`allow_approximate: true`, a composite foreign key, and a polymorphic
`belongs_to` whose target's default scope history cannot read. The
[architecture notes](architecture.md) list them. When a request includes such a
path, or any polymorphic `belongs_to`, whose targets are known only per record,
`diagnose` warns about tied timestamps and a comparison between two tied
versions emits the `ambiguous_association_boundary.paper_trail_diff`
notification. Recording timestamps below one second avoids the problem. On SQL Server, PT-AT compares
those timestamps only to about 3 milliseconds (a `datetime` tick, 1/300 s),
because the adapter writes the times in its queries that way, so for these
shapes two versions saved closer together than that may be read in the wrong
order.

### History stored as JSON

PaperTrail's JSON serializer, and a `json` or `jsonb` `object` column, store
times to milliseconds by default (`ActiveSupport::JSON::Encoding.time_precision`).
The gem reads the digits from what the history's writer writes, a serializer
of your own that wraps the JSON one included, so the legacy JSON format,
which writes whole seconds, keeps whole seconds. For those histories the gem
compares all times at that precision, so an
unchanged timestamp is not reported as changed. A change smaller than that
precision was never recorded and cannot be reported. For the same reason
`historical_filter:` compares a time at that precision too: a filter for
`12:00:00.123456` also matches a version that stored `12:00:00.123`, since
the history cannot tell them apart. A `json` or `jsonb`
column also returns times and dates as strings, which PaperTrail leaves as
they are; the gem casts them back to the attribute's type.

Two kinds of value come back as something their type cannot cast back:

- A `json` or `jsonb` `object` column stores a `serialize`d attribute as
  JSON writes it, so keys come back as strings, and dates, times, and symbols
  inside it as strings. The gem reads that attribute in this form on every
  side, the current record's too, so a value nothing changed is not reported
  as changed: `{ due: Date.new(2026, 11, 3) }` appears as
  `{ "due" => "2026-11-03" }`.
- PaperTrail's JSON serializer stores a `binary` column as
  `{ "value" => bytes }`, and cannot store bytes that are not UTF-8. The gem
  reads the bytes. On PostgreSQL, PaperTrail cannot read such a `bytea` value
  back at all: its `reify` raises `TypeError`, and so does the gem.

### Writing history in tests

To give versions fixed times in a test, save them at those times with
`travel_to`:

```ruby
travel_to(Time.zone.local(2026, 8, 15, 9, 1)) do
  PaperTrail.request(whodunnit: "alice") { article.update!(title: "Published") }
end
```

If you change `created_at` after saving instead, change every version saved
in the same transaction, not only the ones you check. PT-AT gives all of
them the same `transaction_id`, including versions of other models saved by
callbacks. A version left at the time the test ran makes that transaction
seem to last from your chosen time until today. The transaction is then
reported where it ends, today (see [Time windows](#time-windows)), and a window
around your chosen time loses the changes the test expects.

```ruby
def set_version_time(version, time)
  same = version.transaction_id && { transaction_id: version.transaction_id }
  PaperTrail::Version.where(same || { id: version.id }).update_all(created_at: time)
end
```

## Instrumentation

The gem never logs. It emits `ActiveSupport::Notifications` events you can
subscribe to:

- `compare.paper_trail_diff`
- `compare_many.paper_trail_diff`
- `analyze.paper_trail_diff` (includes `step_count`, the length of
  `activity_timeline` with `activity: true` and of `timeline` without)
- `analyze_many.paper_trail_diff`
- `load_live_endpoints.paper_trail_diff`
- `prepare_history.paper_trail_diff`
- `ambiguous_association_boundary.paper_trail_diff`

```ruby
ActiveSupport::Notifications.subscribe(/\.paper_trail_diff\z/) do |name, start, finish, _id, payload|
  Rails.logger.debug(event: name, duration_ms: ((finish - start) * 1_000).round(1), **payload)
end
```

Payloads contain counts, model names, ids, times, association paths, and
options, never record data. To see the SQL for one call, subscribe to `sql.active_record`
around it with `ActiveSupport::Notifications.subscribed`.

`PaperTrailDiff.deprecator` warns when an option is deprecated; none is now. In
a Rails app, register it with
`Rails.application.deprecators[:paper_trail_diff] = PaperTrailDiff.deprecator`
to handle its warnings as the app's own.

## Errors

All errors inherit from `PaperTrailDiff::Error`.

| Error | Raised when |
| --- | --- |
| `ConfigurationError` | An option is invalid, or the version class has no `object` column to read states from |
| `InvalidEndpointError` | A record is unsaved, destroyed, or has unsaved changes, a version was loaded without its `object`, a model has no `has_paper_trail`, or `recorded_changes` is given something other than a version |
| `VersionMismatchError` | Two endpoints belong to different records |
| `ReversedEndpointsError` | Two versions are given newest first |
| `InvalidTimelineRangeError` | A range is invalid, for example `within:` with `from:`, or `:last`, or a boundary symbol is unknown |
| `InvalidTimeRangeError` | `within:` is not a range with a beginning, in time order |
| `IncompleteTimeRangeError` | A window's last change has no later version and the record has no saved row to read instead |
| `AmbiguousVersionOrderError` | Versions cannot be ordered (see [version order](#version-order)) |
| `BatchLimitExceededError` | More records are selected than `limit:` allows |
| `FilterLimitExceededError` | `historical_filter:` needs more than `max_filter_versions:` |
| `AssociationTrackingUnavailableError` | Association history is requested without PT-AT |
| `UnknownAssociationError` | An association name does not exist |
| `UnsupportedAssociationError` | An association's macro is not supported, a path continues past a polymorphic `belongs_to`, a `has_many :through` goes through a HABTM, a HABTM is scoped or below the root, an association is keyed on a column other than a primary key, the target of a `has_one` or `has_many` declares no `belongs_to` on its foreign key, or history cannot read a [costly association](#costly-associations) and `allow_approximate: true` was not passed |
| `UnversionedAssociationError` | An association's target model, or a model a `has_many :through` goes through, has no `has_paper_trail`, including the class a polymorphic `belongs_to` names |
| `IncompleteAssociationHistoryError` | PT-AT did not record enough to rebuild an association, such as HABTM without a transaction or in a transaction another record with that HABTM also saved a version in, or a polymorphic type names no class |
| `UnsupportedLiveActivityError` | A HABTM activity range ends at the current record |
| `AmbiguousNestedKeyError` | `nested_changes` finds keys like `:a` and `"a"` together |

## Limitations

Results can only be as complete as the history PaperTrail and PT-AT recorded.

- Changes made with versioning off, with `update_columns`, or to `skip:` columns
  were never recorded. The first two still appear, in the step for the record's
  previous recorded change and attributed to its author; see
  [how PaperTrail stores history](#how-papertrail-stores-history).
- Deleted versions, schema changes, and serializer changes can affect how old
  versions read.
- With PaperTrail's default YAML serializer, PaperTrail 16 and 17 decode a
  `time` (time of day) column as `nil`, in `reify` and `changeset` alike,
  unless the column is time-zone aware, as a Rails app's are, and the time
  zone is UTC. The gem reads the time each version recorded, including in
  the records it passes to a callable `historical_filter:`, but your own
  calls to those PaperTrail methods still return `nil`. PaperTrail's JSON
  serializer, and SQL Server, whose adapter stores a time its own way, are
  not affected. Snapshots and diffs show every time of day on 2000-01-01 in
  its own zone, as Active Record 8.1 reads one. Active Record before 8.1
  reads a zone-aware time from the database on 2000-01-01 in UTC, so
  `record.opens_at` can show another date than the snapshot of that time.
- Each call reads its history and live rows in one snapshot on PostgreSQL and
  MySQL (through mysql2 or trilogy), and on adapters built on them such as
  PostGIS, so a commit that lands during the call is seen by none of its
  statements. On SQL Server it does so only when the database allows snapshot
  isolation, which you turn on with
  `ALTER DATABASE your_database SET ALLOW_SNAPSHOT_ISOLATION ON`; each call
  checks the setting first. The snapshot covers the database of the record's
  model and its versions; an associated model on another database is read
  outside it. A call made inside a transaction of your own keeps that
  transaction's isolation level. To make the whole call see one snapshot,
  start that transaction at `REPEATABLE READ` or stricter, or at `SNAPSHOT` on
  SQL Server. SQLite, and SQL Server without snapshot isolation, take no
  snapshot, so a commit during a call can appear in some of its statements
  and not others. A long call holds its snapshot until it ends: on PostgreSQL
  that can keep VACUUM from reclaiming old row versions, on MySQL it keeps
  undo history, and on SQL Server it keeps row versions in `tempdb`.
- A savepoint that rolls back, or another transaction saving in the same tree
  at the same time, can split one transaction into several transaction groups;
  see [one step per transaction group](#one-step-per-transaction-group-transaction).
- A transaction that saves in two version tables is read in each as far as
  its versions there: where it ends is read from one version table at a time.
- HABTM membership history exists only where PT-AT recorded it in a
  transaction, and only for the root record without a scope: a scoped HABTM,
  or one below the root, raises `UnsupportedAssociationError`, and a transaction that another record with
  that HABTM also saved a version in raises `IncompleteAssociationHistoryError`. HABTM changes cannot become their own
  activity steps.
- PT-AT has its own
  [limitations](https://github.com/westonganger/paper_trail-association_tracking#limitations),
  especially for some `has_one` histories. The gem follows PT-AT's configured
  error behavior.
- Deep association paths cost more to rebuild. Request only what you need.

Read PaperTrail's
[version semantics](https://github.com/paper-trail-gem/paper_trail#3-working-with-versions)
before relying on history for restoring data or for compliance.

For development commands, see [testing](testing.md).
