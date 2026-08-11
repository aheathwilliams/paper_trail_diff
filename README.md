# paper_trail_diff

> [!WARNING]
> **Experimental software and AI disclosure:** This gem is experimental and may
> contain incomplete behavior, reconstruction errors, performance problems, or
> breaking changes. AI-assisted coding tools made significant contributions to
> its design, implementation, tests, and documentation under maintainer
> direction. AI involvement is not a substitute for independent review: audit
> the code and validate it against your own PaperTrail history before relying on
> it in production, compliance, security, or other high-stakes workflows.

`paper_trail_diff` adds structured endpoint, checkpoint-timeline, and activity
comparisons to
[PaperTrail](https://github.com/paper-trail-gem/paper_trail). It returns immutable
Ruby value objects and hashes rather than formatted text.

PaperTrail is required. Explicit, bounded association-path comparison is
available when
[paper_trail-association_tracking](https://github.com/westonganger/paper_trail-association_tracking)
(PT-AT) is installed, loaded, and enabled.

Ruby 3.1 or newer and PaperTrail 16 or 17 are supported.

New to the gem? Start with the copyable [Quickstart](QUICKSTART.md).

## Installation

Add the gem to your bundle:

```ruby
gem "paper_trail_diff"
```

For association history, also add and configure PT-AT using its migrations:

```ruby
gem "paper_trail-association_tracking"
```

```ruby
PaperTrail.config.track_associations = true
```

All associated models whose historical state is compared must use
`has_paper_trail`.

## How PaperTrail records state

Almost everything else in this README follows from one property of PaperTrail,
so it is worth being precise about it first: **a version stores the state that
existed _before_ the event that created it.** A version is a record of what was
overwritten, not of what was written.

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

Each state is stored by the version at the *end* of the interval it was live
for. Three consequences run through the rest of this document:

- **A `create` version reifies to `nil`.** Nothing preceded it. Comparing it
  with a later state reports a structured `record_presence_change` rather than
  inventing scalar changes.
- **The newest state has no version at all.** It exists only in the table. A
  fully historical result therefore needs a version *later* than the last change
  it should reveal, which is why a `within:` window can raise
  `IncompleteTimeRangeError`, and why `activity_timeline(..., to: article)`
  exists for ending at current state instead.
- **A change is visible between two boundaries**, never "at" one. This is why
  both timeline APIs return steps rather than events.

The [Quickstart](QUICKSTART.md) walks through the same idea against a real
console session.

## Choosing an entry point

| You need | Call |
| --- | --- |
| The net difference between two endpoints | `compare` |
| The same, for many records in one pass | `compare_many` |
| One step per version of the root record | `timeline` |
| One step per version of the root *or a selected child* | `activity_timeline` |
| A net difference and a timeline from one history pass | `analyze` |

`timeline` and `activity_timeline` differ only in which recorded versions
become boundaries. Given an article with two comment edits between two article
versions:

```text
recorded versions   A1        C1      C2        A2      A = Article version
                    |         |       |         |       C = Comment version
                ────●─────────●───────●─────────●────▶ time
                    |         |       |         |
timeline            └───────── 1 step ──────────┘
                    both comment changes land inside that one step

activity_timeline   └── 1 ────┴── 2 ──┴─── 3 ───┘
                    each recorded version becomes its own boundary
```

Both report the same underlying data: a `timeline` step still contains every
selected association, because it has to describe what changed beneath the root.
They differ in how finely that change is split, and in what the reconstruction
costs. That cost trade-off is covered under
[choosing a reconstruction strategy](#choosing-between-timeline-and-analyzeactivity-true).

## Compare two endpoints

`compare` accepts two explicit endpoints: each may be a PaperTrail version or a
clean, persisted model instance representing current database state. It reports
only their net difference:

```ruby
diff = PaperTrailDiff.compare(article.versions[1], article.versions[4])

diff.attributes["title"].from # => "Draft"
diff.attributes["title"].to   # => "Published"
diff.empty?                    # => false
diff.to_h
# => {
#   record_presence_change: nil,
#   attributes: {
#     "title" => { from: "Draft", to: "Published" }
#   },
#   associations: {}
# }
```

Intermediate edits do not affect `compare`. If a title changes and later
returns to its original value, endpoint comparison reports no title change.

`record_presence_change` reports whether the root record *existed* at each
endpoint, and is `nil` for the ordinary case where it existed at both. It is
populated when one endpoint reifies to `nil` — most often a `create` version,
whose pre-change state is the absence of the record — and it then carries whole
`RecordSnapshot` values rather than fake scalar changes from `nil`.

Destroying the root record is not reported this way, and the reason follows
from the [pre-change model](#how-papertrail-records-state): the state *at* a
`destroy` version is the state immediately before the deletion, so the record
is still present there. A comparison ending at a `destroy` version reports that
last edit, not the deletion. Deleting a *selected child* is reported normally,
as a `removed` member of its parent's collection, and `activity_timeline`
reports a destroyed root through a
[closing removal step](#closing-a-destroyed-root).

Pass the record explicitly when the desired endpoint is current state:

```ruby
diff = PaperTrailDiff.compare(
  article.versions.last,
  article,
  associations: ["comments.replies"]
)
```

Two version endpoints must be given in chronological order. A transposed pair
produces the inverse diff, which is easy to do by accident and impossible to
detect afterwards because a result carries no direction of its own, so it
raises `PaperTrailDiff::ReversedEndpointsError` instead. Nothing is lost by
this: the two orders differ only in which side of each change is `from`.

A current-record endpoint is exempt and may appear on either side, because it
is self-evidently the live state and placing it first is a deliberate reverse
comparison. Current state is never inferred. The record must be persisted, not
destroyed, and free of unsaved attribute changes. The gem reloads it unscoped
before normalization, so stale association caches and in-memory edits are not
compared. Use a database
transaction with an appropriate isolation level when several live association
queries must represent one atomic application snapshot.

For collection-level reports, use `compare_many` to reload current roots and
preload each explicitly selected live association path across the batch. Each
entry has the same endpoints and options as `compare`; results are returned in
input order as a frozen hash keyed by `[item_type, item_id]` strings:

Endpoints are still supplied by the caller, so look them up in bulk too —
otherwise the per-root queries this API removes come straight back. Two
queries resolve the earliest version of every root, whatever the batch size:

```ruby
orders = Order.where(id: order_ids).to_a

earliest_ids = PaperTrail::Version
  .where(item_type: "Order", item_id: orders.map(&:id))
  .group(:item_id)
  .minimum(:id)
first_versions = PaperTrail::Version
  .where(id: earliest_ids.values)
  .index_by(&:item_id)
```

```ruby
diffs = PaperTrailDiff.compare_many(
  orders.map { |order| { from: first_versions.fetch(order.id), to: order } },
  associations: [:line_items],
  ignore: []
)

diffs.fetch(["Order", orders.first.id.to_s]) # => PaperTrailDiff::Diff
```

Endpoints may also be given as `:first` or `:last`, resolved against the record
the pair's other endpoint names. That replaces the lookup above entirely, and
resolves every root in two queries per model class rather than one per root:

```ruby
diffs = PaperTrailDiff.compare_many(
  orders.map { |order| { from: :first, to: order } },
  associations: [:line_items]
)
```

A symbol carries no identity of its own, so `{ from: :first, to: :last }` raises
rather than guessing. A root with no recorded history resolves to an empty
`Diff`, matching how the timeline APIs answer the same question.

Root identities must be unique within one call. Historical reconstruction for
ordinary versioned, unscoped association paths is also prepared across the
collection. Paths that require the existing point-in-time PT-AT fallback retain
their per-endpoint behavior and all historical reconstruction retains the same
PaperTrail Association Tracking requirements as `compare`. Live collection
scopes with per-owner semantics, such as `limit`, `offset`, or an owner
argument, are loaded per root; other selected branches remain batched. Callers
should still use an appropriate database transaction when all live queries
must observe one atomic snapshot.

### Reuse already-preloaded current endpoints

`compare`, `compare_many`, and `activity_timeline(..., to: record)` reload
current endpoints by default. A caller that already owns a consistent, fully
preloaded graph may opt out. The option has no effect on `timeline` or
`analyze`, which are bounded by versions and never read live state:

```ruby
orders = Order.where(id: order_ids).preload(line_items: :product).to_a
# `first_versions` is the same bulk endpoint lookup shown above.

diffs = PaperTrailDiff.compare_many(
  orders.map do |order|
    { from: first_versions.fetch(order.id), to: order }
  end,
  associations: ["line_items.product"],
  reload_live_endpoints: false
)
```

With `reload_live_endpoints: false`, scalar values and association targets come
from the supplied instances. Every requested association path must already be
loaded; otherwise `PaperTrailDiff::UnloadedAssociationError` is raised before
normalization instead of silently issuing an N+1 query. The caller is
responsible for the consistency and freshness of that in-memory graph.

### Runtime performance diagnostics

The gem never prints or logs automatically. It emits these
`ActiveSupport::Notifications` events so applications can choose their logger
and formatting:

- `compare.paper_trail_diff`
- `compare_many.paper_trail_diff`
- `activity_timeline.paper_trail_diff`
- `load_live_endpoints.paper_trail_diff`
- `prepare_history.paper_trail_diff`

```ruby
ActiveSupport::Notifications.subscribe(/\.paper_trail_diff\z/) do |name, start, finish, _id, payload|
  Rails.logger.debug(
    event: name,
    duration_ms: ((finish - start) * 1_000).round(1),
    **payload
  )
end
```

The payloads contain counts, model names, association paths, and reload mode,
not endpoint objects or record attributes. The activity-timeline event wraps
the complete call and includes `step_count`, so its notification duration is
the user-visible runtime. To inspect the exact SQL generated by one report,
scope a standard `sql.active_record` subscriber around it:

```ruby
callback = proc do |_name, _start, _finish, _id, payload|
  Rails.logger.debug(payload[:sql]) unless payload[:cached] || payload[:name] == "SCHEMA"
end

ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
  PaperTrailDiff.compare_many(comparisons, associations: [:line_items])
end
```

## Analyze many records over one window

`analyze_many` answers "what changed for these records during this period" for a
whole collection, selecting every root's versions and preparing their selected
association history once for the batch:

```ruby
results = PaperTrailDiff.analyze_many(
  Order.where(status: "open").to_a,
  within: Time.zone.parse("2026-08-01")...Time.zone.parse("2026-09-01"),
  associations: [:line_items]
)

results.fetch(["Order", order.id.to_s]).diff      # net change across the window
results.fetch(["Order", order.id.to_s]).timeline  # its checkpoint steps
```

Results are a frozen hash keyed by `[item_type, item_id]` strings, and each
value is the same `Analysis` that `analyze` returns for one record. A root with
no versions inside the window gets an empty `Analysis` rather than raising, so a
listing page needs no special case. Root identities must be unique.

### Reporting on a subset of mutations

`version_scope:` narrows which root versions count as *selected mutations*,
which is what a "changes made by a user" report needs:

```ruby
user_edits = ->(scope) { scope.where.not(whodunnit: nil) }

PaperTrailDiff.analyze_many(articles, within: window, version_scope: user_edits)
PaperTrailDiff.timeline(article, within: window, version_scope: user_edits)
```

The hook receives the version relation for the range and returns a narrowed one.
It is accepted by `timeline`, `activity_timeline`, `analyze`, and
`analyze_many`, with any range form.

It filters *selected mutations only*. Versions the filter excludes are still
loaded, because a version records the state before its own event: without the
one that follows a selected change, whatever that change produced cannot be
shown at all. Those extra versions are reconstruction context, so their own
changes are never attributed to a selected mutation.

Each selected mutation is bounded by the version that immediately followed it,
not by the next selected one. So each step's diff is exactly what that mutation
did, and it reads the same however many excluded changes happen to follow it:

```
versions   system → alice → system → bob → system
reported   alice: what alice changed    bob: what bob changed
```

Given a user edit followed by a system edit, filtering to user changes yields
one step running from the user version to the system version, whose diff is
exactly the user's change. A selected mutation that nothing follows yet is not
reported, since no version records the state it produced — the same blind spot
an unfiltered timeline has at its `to:` boundary. A root with no selected
mutation reports an empty `Analysis` rather than raising.

The hook applies to root versions only. Under `activity: true` the filter
decides where the span starts and ends, and `timeline` within that span reports
only selected mutations, but `activity_timeline` still lists every boundary
inside it — dropping one would fold the change it carried into a neighbouring
step and credit it to whoever made that one.

Omit `within:` to analyze each root's whole recorded history instead, which is
the batched equivalent of `analyze(record, from: :first, to: :last)`. Explicit
version endpoints are not accepted, because a single pair cannot mean the same
thing for every root.

Query cost is flat in the number of roots for the diff and timeline views:
selecting versions and preparing history are both shared across the batch. On a
twenty-root batch that is 7 queries against 120 for the same work done one
record at a time. Passing `activity: true` also works and returns the same
results, but discovering descendant events is inherently per-root, so that view
batches far less.

Roots are supplied as live records, so a root deleted inside the window cannot
be included; use `activity_timeline` for a history that ends in a deletion.

## Build a root-checkpoint timeline

`timeline` accepts two version objects from the supplied record's history, or
the symbols `:first` and `:last` when the range is simply the record's whole
recorded history:

```ruby
steps = PaperTrailDiff.timeline(article, from: :first, to: :last)
```

`:first` and `:last` are resolved by the gem, independently of the order the
`versions` association happens to use, so a caller never has to know it is
sorted. They work anywhere a version does, including mixed with an explicit
one (`from: :first, to: some_version`) and on `activity_timeline` and
`analyze`. A record with no versions has no boundaries to resolve; that is an
empty history rather than a bad request, so the result is an empty timeline
instead of an error — which is usually what an index page wants.

Combine `from: :first` with `to: article` for the fullest activity view of a
live record: the whole recorded history, ending at current state. See
[activity timelines](#build-an-activity-timeline) for why that end differs from
`to: :last`.

The range is inclusive, must be chronological, and produces one `Step` for each
adjacent pair:

```ruby
steps = PaperTrailDiff.timeline(
  article,
  from: article.versions[1],
  to: article.versions[4]
)

steps.first.from_version # the original PaperTrail version
steps.first.to_version   # the next PaperTrail version
steps.first.from_boundary # immutable presentation metadata
steps.first.to_boundary
steps.first.diff         # a PaperTrailDiff::Diff
steps.first.empty?        # delegates to the diff
steps.first.to_h
# => { from_version_id: 2, to_version_id: 3, diff: { ... } }
```

Both timeline types expose `from_boundary`, `to_boundary`, `diff`, and
`empty?`. A historical boundary has `event`, `whodunnit`, `record`,
`recorded_at`, `version?`, `current?`, and `destroyed?` readers. Checkpoint `Step` objects
also retain their original `from_version` and `to_version` for callers that
need custom PaperTrail metadata. Existing `Step#to_h` and
`ActivityBoundary#to_h` shapes remain unchanged; use the readers for the new
metadata.

Every version boundary remains in the result, even when its diff is empty after
ignored fields are removed. Equal boundaries return a frozen empty array.

This is deliberately a root-record timeline. Several child changes between two
root versions appear together in the same step.

## Build an activity timeline

`activity_timeline` merges versions for the root and explicitly selected
descendants. Child changes can therefore form separate steps instead of waiting
to be aggregated at the next root checkpoint:

```ruby
steps = PaperTrailDiff.activity_timeline(
  article,
  from: article.versions[1],
  to: article.versions[4],
  associations: ["comments.replies", :author]
)

steps.reject(&:empty?)
```

Pass the record explicitly as `to:` to include current state without creating a
final root checkpoint. This is not the same as `to: :last`: descendant
mutations recorded after the record's final root version fall outside a
version-bounded range, so only a live end reports them.

```ruby
steps = PaperTrailDiff.activity_timeline(
  article,
  from: article.versions[1],
  to: article,
  associations: ["comments.replies", :author]
)
```

The result is a frozen array of `ActivityStep` objects. Each step has immutable
`from_boundary`, `to_boundary`, and `diff` readers. Historical boundaries are
`kind: :version`; an explicitly requested live endpoint is `kind: :current`:

```ruby
steps.last.to_boundary.to_h
# => {
#   kind: :current,
#   version_id: nil,
#   item_type: "Article",
#   item_id: 42,
#   recorded_at: 2026-08-08 12:00:00 UTC
# }
```

A historical boundary may belong to the root or a selected descendant model.
PaperTrail versions describe pre-change state, so a mutation becomes visible
between its version boundary and the next historical or explicit current
boundary. Passing `to: article` is what removes the need to touch the parent
after an ordinary versioned child mutation; current state is still never
implicit.

### Closing a destroyed root

A `destroy` version is the one boundary whose following state needs no later
version: the event itself says the record is gone. When an activity timeline
ends at the root's own `destroy` version, it therefore closes with one more
step, from that version to a `kind: :destroyed` boundary, whose diff is a
`record_presence_change` from the record's final state to `nil`:

```ruby
steps = PaperTrailDiff.activity_timeline(
  article,
  from: article.versions.first,
  to: article.versions.last # a destroy version
)

removal = steps.last
removal.to_boundary.destroyed?                  # => true
removal.to_boundary.kind                        # => :destroyed
removal.diff.record_presence_change.from        # the state it was deleted in
removal.diff.record_presence_change.to          # => nil
```

The removal step's `from_boundary` is the ordinary `kind: :version` boundary
for the same destroy version, since that boundary still holds the record.
Boundaries therefore have three kinds — `:version`, `:current`, and
`:destroyed` — so a consumer that branches on `version?` alone should also
handle `destroyed?`.

`analyze(activity: true)` reports the same closing step in its
`activity_timeline`. Its `diff` and `timeline` keep their `compare` and
`timeline` semantics and do not report the deletion.

A `within:` window behaves the same way. A window whose last selected mutation
is the root's destruction needs no later root version, because none can ever
exist, so it closes on the removal instead of raising
`IncompleteTimeRangeError`. When the destruction falls *outside* the window it
remains ordinary reconstruction context and is not reported as a selected
mutation. The same relaxation lets the plain `timeline` accept such a window,
though it still reports only the edits.

Live-ended HABTM activity is rejected with
`PaperTrailDiff::UnsupportedLiveActivityError`. HABTM join rows have no model
versions, so the gem cannot reliably split their membership mutations into
intermediate events without transaction-backed owner checkpoints. Historical
HABTM activity and `compare(version, article, associations: [:tags])` remain
supported where the historical endpoint has usable PT-AT metadata.

Both timeline APIs preserve empty boundaries. A display may use
`steps.reject(&:empty?)`, while audit-oriented callers can retain every
recorded boundary.

## Select mutations by time

`timeline`, `activity_timeline`, and `analyze` also accept a finite time range
through `within:` instead of explicit `from:` and `to:` versions. Half-open
ranges are recommended for adjacent reporting windows:

```ruby
window = Time.zone.parse("2026-08-01")...Time.zone.parse("2026-09-01")

steps = PaperTrailDiff.timeline(article, within: window)

activity_steps = PaperTrailDiff.activity_timeline(
  article,
  within: window,
  associations: ["comments.replies", :author]
)

analysis = PaperTrailDiff.analyze(
  article,
  within: window,
  associations: ["comments.replies"],
  activity: true
)
```

The range selects mutations by the timestamp of their source PaperTrail
version. Ruby's inclusive (`..`) and exclusive (`...`) end semantics are
honored. A returned step's `to_boundary` may be after the range: because a
PaperTrail version is a pre-change snapshot, the gem needs one later root
version to reveal the final selected mutation. That version is reconstruction
context, not an additional selected mutation.

If the window contains a relevant mutation but no later root version exists,
the call raises `PaperTrailDiff::IncompleteTimeRangeError`. Create a root
checkpoint after the reporting window before running historical analysis. The
gem does not silently substitute current database state. A root-only window
with no selected mutation returns a frozen empty timeline. The one exception is
a window that closes on the root's own destruction, which no later version can
ever follow; see [closing a destroyed root](#closing-a-destroyed-root).

Time ranges and explicit `from:`/`to:` endpoints are mutually exclusive.
Malformed, open-ended, or reversed ranges raise
`PaperTrailDiff::InvalidTimeRangeError`. With `activity_timeline`, selected
descendant versions are included even when no root mutation occurred inside
the window; the later root checkpoint is still required so PT-AT can
reconstruct the enclosing graph and determine whether descendant activity is
present. The ordinary `timeline` remains a root-only checkpoint timeline.

## Build an endpoint and timeline together

When a caller needs the net endpoint diff and root timeline, `analyze`
normalizes each selected version once. Pass `activity: true` when the same view
also needs descendant-aware activity. The endpoint diff and root timeline are
then derived from the same activity snapshot pass instead of reconstructing the
root history separately:

```ruby
analysis = PaperTrailDiff.analyze(
  article,
  from: article.versions[1],
  to: article.versions[4],
  associations: ["comments.replies"],
  activity: true
)

analysis.diff
analysis.timeline
analysis.activity_timeline
```

Without `activity: true`, `analysis.activity_timeline` is `nil` and no activity
work is performed. `analyze` accepts explicit historical versions or
`within:`, but not a current-record endpoint; use the standalone
`activity_timeline(..., to: article)` API when the final boundary must be live.

### Choosing between `timeline` and `analyze(activity: true)`

`analysis.timeline` and `timeline` return the same root-checkpoint steps for the
same range. They are two reconstruction strategies for one result, not two
levels of detail: a `timeline` step covers only root version boundaries, but
each of its snapshots still contains every selected association, because a step
must report what changed underneath the root as well.

The one behavioural difference is at the edge of a `within:` window. Selected
descendants can move inside a window that contains no root version at all, so
the activity form requires a root boundary it can reconstruct from and raises
`IncompleteTimeRangeError` when there is none. `timeline` has no activity view
to anchor and returns no steps for that window.

The strategies differ in what that costs:

- `timeline` reconstructs the whole selected graph independently at every root
  boundary, so it costs roughly *root versions x selected graph size*. It is
  insensitive to how much descendant activity happened in between.
- `analyze(activity: true)` reconstructs once and then advances that snapshot
  through each recorded mutation, so it costs roughly *one reconstruction +
  total events*. It is insensitive to how wide the selected graph is.

Neither dominates. Reconstructing once per checkpoint wins when a few root
versions span very heavy descendant churn; advancing incrementally wins when
the selected graph is wide and descendant activity is comparable to root
activity. As a rule of thumb, prefer `analyze(activity: true)` when selected
associations are wide, and `timeline` when descendant events greatly outnumber
root versions. Measure with `ActiveSupport::Notifications` on a representative
history rather than a seeded example if the choice matters.

`timeline`, `activity_timeline`, and both forms of `analyze` prepare the selected
historical range once. The loader walks only the explicit association paths and
builds an immutable temporal index of scalar states, relationship candidates,
HABTM transaction snapshots, and live fallbacks. Direct relationships,
`has_many :through` with a `belongs_to` source, and transaction-backed HABTM
membership are resolved from that index. Endpoint-only `compare` retains the
lighter two-point reconstruction path.

Activity reconstruction then carries immutable snapshots forward between
boundaries. Isolated root and descendant events with usable serialized changes
advance only the affected immutable nodes. Events sharing a PT-AT transaction
refresh their combined branches atomically. Scoped associations, unversioned
targets, composite relationship keys, collection-source through associations,
and other unsupported shapes fall back to the ordinary PT-AT point reifier on
a per-reflection basis. This hybrid path preserves existing reconstruction
behavior while avoiding repeated association queries for supported paths.

For supported collection events, adjacent snapshots share an immutable
identity-position index and carry a one-step transition hint. Diffing therefore
visits only the changed member instead of hashing the whole collection again.
Prepared scalar history also exposes the predecessor and successor attributes
for isolated update events, allowing activity reconstruction to update the
immutable snapshot directly instead of reifying and deserializing the same
PaperTrail event again. Compatible scalar payloads are decoded into prepared
state without first constructing a disposable Active Record object. Encrypted,
schema-mismatched, missing, ambiguous, or identity-changing states fall back to
the ordinary event reifier.
For a direct nested `has_many` such as `comments.replies`, the child's foreign
key also locates its parent snapshot directly rather than walking every
comment. Membership changes and ambiguous or unsupported relationship shapes
retain the general comparator and traversal fallback.

Activity event loading is bounded to the selected range. Association identity
discovery retains one indexed checkpoint for members present at the starting
boundary, then considers later association activity and current members; it no
longer materializes every pre-range association row. Because a PaperTrail
version is a pre-change snapshot, the state at a range's final boundary can
live only in the next version after it, so prepared scalar state retains one
trailing version per selected identity. It does not retain the rest of the
history recorded after the range, so a short range early in a long history
costs the same as the same range in a short one. Keep requested paths and
ranges intentional. An activity timeline must also emit a diff for every selected
event. Repeated events within one wide collection still copy the frozen records
array when producing each immutable snapshot, so they can do pointer-copying
work proportional to the number of events times the collection width even when
SQL and Ruby-level comparison work stay linear. Bound or paginate unusually
wide activity ranges in latency-sensitive requests.

For large histories, applications should give the database a matching
composite index. A typical PaperTrail installation can add one without making
it a requirement of this gem:

```ruby
add_index :versions, %i[item_type item_id created_at id],
          name: "index_versions_on_item_and_timeline"
```

This index is especially useful for repeated `within:` queries because root
selection is constrained by `item_type`, `item_id`, and `created_at`, then
ordered deterministically by timestamp and version ID.

PT-AT's normal index beginning with `foreign_key_name`, `foreign_key_id`, and
`foreign_type` should also be retained on `version_associations`.

## Ignore noise fields

The comparison APIs ignore `updated_at` by default. `ignore:` replaces that default and
accepts string or symbol names. The array form applies to the root and every
selected association:

```ruby
PaperTrailDiff.compare(from, to, ignore: %i[updated_at lock_version])
PaperTrailDiff.compare(from, to, ignore: []) # compare every scalar field
```

For exact path control, pass `all:` plus `paths:`. `$` identifies the root:

```ruby
PaperTrailDiff.compare(
  from,
  to,
  associations: ["comments.replies"],
  ignore: {
    all: [:updated_at],
    paths: {
      "$" => [:lock_version],
      "comments.replies" => [:delivery_state]
    }
  }
)
```

Hash rules replace the default just like an array. `all:` applies everywhere;
each path entry applies only at that exact path, not its descendants. Ignore
paths must be `$` or one of the selected or implicitly selected association
paths.

Primary keys are always represented as record identity rather than scalar
attributes.

## Compare associations

Pass explicit names or dot-separated paths. Paths are finite traversal plans,
not a request to recursively inspect the whole object graph. Ancestors are
selected implicitly:

```ruby
diff = PaperTrailDiff.compare(
  from,
  to,
  associations: [:author, :profile, "comments.replies.author"]
)

diff.associations["author"].relationship
# => #<PaperTrailDiff::ValueChange ...>  # belongs_to replacement

comments = diff.associations["comments"]
comments.added   # full RecordSnapshot objects
comments.removed # full RecordSnapshot objects
comments.changed # RecordChange objects for stable identities

replies = comments.changed.first.associations["replies"]
replies.added
replies.removed
replies.changed
```

For `belongs_to` and `has_one`, replacing the related identity is a
`relationship` change. Updating attributes on the same related identity is a
`changed` record. For `has_many` and `has_and_belongs_to_many`, membership is
split into `added` and `removed`; shared identities with scalar changes appear
in `changed`. The result preserves the reflected macro in `kind`.

Both Rails many-to-many forms are supported. `has_many :through` uses PT-AT's
history for the versioned join model. HABTM reports membership and target
attribute changes, but it cannot report join attributes because HABTM has no
join model.

The same structure repeats at every selected depth. `RecordChange#associations`
contains nested changes for a stable parent identity. Added and removed record
snapshots retain their selected subtrees so nested state is not discarded.

Selecting a `belongs_to` removes its foreign-key (and polymorphic type) column
from scalar changes at that path. Without association selection, that column
remains a normal scalar attribute. A direct `has_one` or `has_many` edge also
removes its incoming foreign key from the child snapshot because membership is
already represented structurally. Join-model attributes for `has_many :through`
remain available. Cyclic model relationships are safe because only the finite
paths supplied by the caller are traversed.

Requesting associations for any historical endpoint without loaded and enabled
PT-AT raises `PaperTrailDiff::AssociationTrackingUnavailableError`. A comparison
whose endpoints are both live records can normalize associations without PT-AT,
though it will normally be empty because both records reload the same current
database state. Unknown names and unsupported macros raise explicit
`PaperTrailDiff::Error` subclasses.
Malformed public options raise `PaperTrailDiff::ConfigurationError`, also under
that base error.

## Traverse result trees

The nested tree remains the canonical, lossless result. For renderers,
counters, exports, and notifications, `Diff#each_change` provides a
deterministic depth-first stream of semantic changes:

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

`record_changed` entries are emitted before that record's attribute and nested
association changes, allowing an application to count both changed records and
changed fields. Singular relationship operations are classified separately as
`relationship_added`, `relationship_removed`, or `relationship_replaced`.
Root create/delete transitions remain `record_presence_changed`.

Added, removed, and replaced records carry complete bounded snapshots. Use
`each_entry` when a renderer also needs that nested state without writing a
second snapshot walker:

<!-- executable:readme-traversal-entries -->
```ruby
diff.each_entry do |entry|
  next unless entry.included_state?

  entry.kind     # :record_included, :attribute_included, :association_included
  entry.state    # :before or :after
  entry.context  # :included_state
end
```

An included record is historical context, not evidence that the nested record
changed independently. `each_change` therefore omits included-state entries.
Both methods return an `Enumerator` when no block is supplied and return the
diff when called with a block. Entries and their paths are immutable and have
deterministic `to_h` output. The root location uses empty association and record
paths; descendant `record_path` values contain only the explicitly traversed
descendant identities.

Traversal is path-preserving and does not deduplicate. If the same record is
reachable through two selected paths, it appears at both locations so the
consumer can choose whether path identity or record identity controls counting.
Walking a result never performs database access and never discovers additional
associations.

## Discover and diagnose associations

Configuration UIs can use bounded public reflection instead of duplicating the
gem's macro and cycle logic:

```ruby
PaperTrailDiff.supported_association_macros
PaperTrailDiff.association_paths(Article, max_depth: 3).map(&:to_h)
```

Descriptors include `path`, `kind`, `target_type`, `through`, `polymorphic`, and
`cycle`. Cycles are marked and not descended; PaperTrail's infrastructure
`versions` association is excluded.

Before relying on association history, inspect known setup hazards:

```ruby
report = PaperTrailDiff.diagnose(
  from_version,
  to_version,
  associations: [:tags, "comments.replies"]
)

report.ok?
report.errors.map(&:code)
report.warnings.map(&:code)
```

Diagnostics are read-only guidance, not proof that arbitrary old data is
complete. HABTM endpoints without transaction-backed association snapshots fail
loudly with `PaperTrailDiff::IncompleteAssociationHistoryError` during normal
comparison as well.

### Recommended checkpoint recipe

For PT-AT history—especially HABTM—use transaction-backed checkpoints, disable
PaperTrail's version timestamp synchronization on the root, and checkpoint a
fresh record instance:

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

A root checkpoint after a batch supplies an immutable historical final state.
The ordinary `timeline` aggregates that batch; `activity_timeline` uses recorded
descendant versions to split it into activity boundaries. For an interactive
view, `activity_timeline(..., to: article)` can instead terminate explicitly at
current state without touching the root. Prefer checkpoints for reproducible
audits and HABTM, and prefer an explicit join model with `has_many :through`
when join attributes or join mutations must appear as first-class history.

## Result objects

Every level of a result separates the same two kinds of change in the same way:

| | a record appears or disappears | a record stays and its fields change |
| --- | --- | --- |
| the root record | `record_presence_change` | `attributes`, `associations` |
| `has_many`, HABTM | `added`, `removed` | `changed` |
| `belongs_to`, `has_one` | `relationship` | `changed` |

The left column carries whole `RecordSnapshot` values; the right column carries
field-level `ValueChange` deltas. That split is deliberate. A record that has
just appeared has no previous value for any of its fields, so reporting one
`nil` to value change per attribute would both add noise and blur the
difference between "this field was edited" and "this record did not exist".

The consequence is that reading a result tree directly means branching on which
column applies: a created record's state is under
`record_presence_change.to.attributes`, an edited record's is under
`attributes`. Consumers that would rather not branch should use
[`each_entry`](#traverse-result-trees), which flattens both into one stream —
an edit arrives as `attribute_changed` carrying a `ValueChange`, and a created
record's fields arrive as `attribute_included` entries carrying values with
`state: :after`.

The public result types are:

- `PaperTrailDiff::Diff`
- `PaperTrailDiff::Step`
- `PaperTrailDiff::ActivityStep`
- `PaperTrailDiff::ActivityBoundary`
- `PaperTrailDiff::Analysis`
- `PaperTrailDiff::ValueChange`
- `PaperTrailDiff::TraversalEntry`
- `PaperTrailDiff::RecordReference`
- `PaperTrailDiff::RecordSnapshot`
- `PaperTrailDiff::RecordChange`
- `PaperTrailDiff::ToOneAssociationDiff`
- `PaperTrailDiff::CollectionAssociationDiff`
- `PaperTrailDiff::AssociationDescriptor`
- `PaperTrailDiff::DiagnosticReport`
- `PaperTrailDiff::DiagnosticIssue`

`Analysis` also exposes the reconstructed states its diff was taken between, as
`from_snapshot` and `to_snapshot`. A report that renders unchanged columns needs
the whole final state, not only what moved, and these are the states the gem
already reconstructed:

```ruby
analysis.to_snapshot.attributes    # every selected scalar, changed or not
analysis.to_snapshot.associations  # the selected association tree
```

Either is `nil` when that endpoint has no reconstructable state — most often a
`from_snapshot` at a `create` boundary, whose pre-change state is the absence of
the record. Following the precedent set by `Step`, `Analysis#to_h` is unchanged;
serialize `to_snapshot.to_h` when a serialized form is wanted.

They expose readers, are frozen after construction, and provide deterministic
`to_h` output. Collection results are ordered by record identity: by type, then
naturally within one id type, so numeric ids sort `2` before `10`. Mixed or
unusual id types still order totally rather than raising.

Structural hash keys are symbols; attribute and association
names are strings. Attribute values retain their Ruby types. `RecordChange#record`
is a `RecordReference` with `type` and `id` readers. `TraversalEntry#record` and
`#association` return the final components of their corresponding paths. `Step`
itself is frozen but intentionally retains the original, potentially mutable
PaperTrail version objects for metadata access; its new boundary readers provide
an immutable presentation interface, while `Step#to_h` continues to emit only
version IDs. `ActivityStep` retains only immutable boundary metadata and
serializes as `{ from: ..., to: ..., diff: ... }`.

## Historical correctness and limitations

The output is only as correct and complete as the historical state PaperTrail
and PT-AT can reconstruct. In particular:

- attributes skipped by PaperTrail, deleted versions, and changes made while
  versioning was disabled cannot be recovered;
- model/schema or serializer changes can affect reification of old versions;
- comparison and activity APIs add live state only when the caller explicitly
  passes a persisted record endpoint; the adapter reloads that record, but
  multiple queries are not automatically one database-isolated snapshot;
- PT-AT requires its schema, callbacks, versioned child models, and transaction
  metadata; callback-skipping writes may not be reconstructable;
- HABTM membership is limited to the join snapshots PT-AT recorded in
  `version_associations`; historical target attributes require versioned target
  models, otherwise PT-AT may return live target state;
- `compare`, `timeline`, and `analyze`'s endpoint diff do not report the root
  record's destruction, because the state recorded at a `destroy` version is the
  state before the deletion; `activity_timeline` closes on a `:destroyed`
  boundary instead, and a selected child's removal is reported by its parent;
- `timeline` and `analyze` are bounded by root versions; `activity_timeline`
  adds recorded descendant boundaries and may terminate at an explicitly passed
  current record, while a fully historical result still requires a later root
  version because PaperTrail stores pre-change snapshots;
- HABTM join-table mutations do not have their own model versions and therefore
  cannot become standalone activity boundaries; live-ended HABTM activity is
  rejected, and a versioned join model should be used when that activity matters;
- activity discovery uses PT-AT association rows and cannot recover descendant
  events whose relevant callbacks or association metadata were never recorded;
- PT-AT has documented edge cases, especially around some `has_one` histories;
  `paper_trail_diff` respects PT-AT's configured reification error behavior;
- deeper paths require more historical reconstruction and database work, so
  callers should select only the branches they need;
- no implicit or unbounded recursive association traversal is performed.

Review the [PaperTrail version semantics](https://github.com/paper-trail-gem/paper_trail#3-working-with-versions)
and [PT-AT limitations](https://github.com/westonganger/paper_trail-association_tracking#limitations)
before relying on reconstructed history for restoration or compliance work.

## Development

The project uses mise for its pinned development tools:

```console
mise install
mise exec -- bundle install
mise exec -- bundle exec rake
mise exec -- bundle exec rake build
mise exec -- act push -j quality --matrix ruby:4.0 --matrix paper_trail:17
```

The default Rake task runs core specs without PT-AT loaded, association specs in
a separate process, RuboCop, generated-signature verification, and Steep.
Selected Ruby blocks in this README and the quickstart are executed in those
same isolated test sessions; the `<!-- executable:... -->` marker opts a block
into the appropriate stateful session.
Inline `#:` annotations in `lib/` generate the committed RBS files under
`sig/generated/`.

Release tags matching `v*` publish through RubyGems trusted publishing. Before
tagging, replace `Unreleased` in the changelog with the release date, run the
full CI workflow, and configure the repository's `release` environment as a
trusted publisher on RubyGems. Do not store a long-lived RubyGems API key in
the repository.

## License

MIT
