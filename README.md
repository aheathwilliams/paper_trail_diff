# paper_trail_diff

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

## Compare two endpoints

PaperTrail stores an object's state before each recorded event. `compare`
accepts two explicit endpoints: each may be a PaperTrail version or a clean,
persisted model instance representing current database state. It reports only
their net difference:

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
A `create` version reifies to `nil`; comparing it with a record state produces
a structured `record_presence_change` instead of fake scalar changes. For
ordinary updates, `record_presence_change` is `nil`, meaning the root record is
present at both endpoints; scalar changes remain under `attributes`.

Pass the record explicitly when the desired endpoint is current state:

```ruby
diff = PaperTrailDiff.compare(
  article.versions.last,
  article,
  associations: ["comments.replies"]
)
```

Version and record endpoints may appear in either order. Current state is never
inferred. The record must be persisted, not destroyed, and free of unsaved
attribute changes. The gem reloads it unscoped before normalization, so stale
association caches and in-memory edits are not compared. Use a database
transaction with an appropriate isolation level when several live association
queries must represent one atomic application snapshot.

For collection-level reports, use `compare_many` to reload current roots and
preload each explicitly selected live association path across the batch. Each
entry has the same endpoints and options as `compare`; results are returned in
input order as a frozen hash keyed by `[item_type, item_id]` strings:

```ruby
diffs = PaperTrailDiff.compare_many(
  [
    { from: first_versions.fetch(order_a.id), to: order_a },
    { from: first_versions.fetch(order_b.id), to: order_b }
  ],
  associations: [:line_items],
  ignore: []
)

diffs.fetch(["Order", order_a.id.to_s]) # => PaperTrailDiff::Diff
```

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

`compare` and `compare_many` reload current endpoints by default. A caller that
already owns a consistent, fully preloaded graph may opt out:

```ruby
orders = Order.where(id: ids).preload(line_items: :product).to_a

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

## Build a root-checkpoint timeline

`timeline` accepts two version objects from the supplied record's history. The
range is inclusive, must be chronological, and produces one `Step` for each
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
`recorded_at`, `version?`, and `current?` readers. Checkpoint `Step` objects
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
final root checkpoint:

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
with no selected mutation returns a frozen empty timeline.

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
work is performed. `analyze` remains version-bounded; use the standalone
`activity_timeline(..., to: article)` API for an explicit current endpoint.

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
PaperTrail event again. Missing, ambiguous, or identity-changing transitions
fall back to the ordinary event reifier.
For a direct nested `has_many` such as `comments.replies`, the child's foreign
key also locates its parent snapshot directly rather than walking every
comment. Membership changes and ambiguous or unsupported relationship shapes
retain the general comparator and traversal fallback.

Activity event loading is bounded to the selected range. Association identity
discovery retains one indexed checkpoint for members present at the starting
boundary, then considers later association activity and current members; it no
longer materializes every pre-range association row. Prepared scalar state also
retains later successor versions for selected identities because a PaperTrail
version is a pre-change snapshot and may be the only correct state for an
earlier boundary. Memory therefore scales with relevant selected history, not
only with the number of returned steps. Keep requested paths and ranges
intentional. An activity timeline must also emit a diff for every selected
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

They expose readers, are frozen after construction, and provide deterministic
`to_h` output. Structural hash keys are symbols; attribute and association
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
