# paper_trail_diff

Structured diffs and activity feeds for [PaperTrail](https://github.com/paper-trail-gem/paper_trail).
Compare states, see who changed a record and its children, or report across a collection.
Results are Ruby value objects and hashes, ready for your own UI or JSON response.

```ruby
diff = PaperTrailDiff.compare(previous_version, article, associations: [:comments])
diff.attributes["title"].to
diff.associations["comments"].added
```

Ruby 3.1+ and PaperTrail 16 or 17 are supported. Association history additionally
requires [paper_trail-association_tracking](https://github.com/westonganger/paper_trail-association_tracking)
(PT-AT). Only the association paths you request are traversed.

> **Experimental:** AI-assisted coding tools made significant contributions to
> this project. Validate results against your application's history before relying
> on them. Missing versions or unrecorded changes cannot be reconstructed.

## Get started

```ruby
# Gemfile
gem "paper_trail_diff"
```

Follow the [Rails quickstart](QUICKSTART.md) for models, migrations, and optional
association setup. To try it without a Rails application, download
[examples/demo.rb](examples/demo.rb) and run `ruby demo.rb`; it installs its own dependencies.
The [demo application](https://github.com/aheathwilliams/paper_trail_summary_test_app)
shows the gem in a Rails UI.

The recipes below use the versioned `Article` and `Comment` models from the quickstart.

## 1. Compare a previous state with the current record

<!-- executable:recipe-compare -->
```ruby
article = Article.create!(title: "Draft")
article.update!(title: "Published")

# The update's version contains the state before that update.
before = article.versions.last
diff = PaperTrailDiff.compare(before, article)

diff.attributes.fetch("title").to_h
# => { from: "Draft", to: "Published" }
```

`compare` reports the net change. An edit followed by a revert has no net change.
Pass a second version instead of `article` when both endpoints should be historical.
A `create` version represents absence, so comparing it with the record reports
`diff.record_presence_change` rather than individual attribute edits.

Add `associations: ["comments.replies"]` to include an explicitly selected subtree.
Use `diff.each_change` to walk a nested result without implementing your own traversal:

```ruby
diff.each_change do |entry|
  entry.kind              # :attribute_changed, :record_added, ...
  entry.association_path  # ["comments", "replies"]
  entry.value             # the structured change or snapshot
end
```

## 2. Build an activity feed showing who changed what

This recipe requires PT-AT and versioned comments. The explicit record endpoint
includes the newest saved state and child activity after the last parent version.

<!-- executable:recipe-activity -->
```ruby
article = Article.create!(title: "Draft")
PaperTrail.request(whodunnit: "alice") do
  Article.transaction do
    article.update!(title: "Published")
    article.comments.create!(body: "Please review")
  end
end

steps = PaperTrailDiff.activity_timeline(
  article, from: :first, to: article,
  associations: [:comments], group: :transaction, snapshots: true
)

feed = steps.reject(&:empty?).map do |step|
  {
    actor: step.source_boundary.whodunnit,
    recorded_at: step.source_boundary.recorded_at,
    changes: step.diff.to_h
  }
end

payload = steps.map { |step| step.to_h(metadata: true) }
```

`source_boundary` identifies the event whose change a step reports. `to_boundary`
is the state that reveals that change and may belong to a different person or model.
For a transaction group, the source is its **first** event; its metadata does not
claim that all grouped events have the same actor or record. Omit `group:` when
individual version events and their attribution matter.

`snapshots: true` retains the compared states for renderers that need unchanged
fields too. It adds no reconstruction queries. Serialize retained states with
`step.to_h(snapshots: true)`. `metadata: true` includes actor, event, transaction ID,
and record reference; default serialization remains compact.

## 3. Report across records for a time window

This recipe works without association tracking. Add `associations:` when needed.
For a report through now, explicitly allow the current record to supply a missing
final historical boundary:

<!-- executable:recipe-report -->
```ruby
window = 1.day.ago..Time.current
report = PaperTrailDiff.analyze_scope(
  Article.all, within: window, limit: 100,
  close_on: :current, activity: true
)

rows = report.analyses.map do |identity, analysis|
  {
    record: identity,                 # ["Article", "42"]
    changes: analysis.diff.to_h,
    activity: analysis.activity_timeline.reject(&:empty?).map do |step|
      step.to_h(metadata: true)
    end
  }
end

report.unreachable # IDs whose live rows are gone; these were not analyzed
```

A relation filters **current** rows. `Article.where(status: "open")` means open
now, not open during the window. Deleted candidates cannot be tested against those
conditions and are returned separately in `unreachable`.

To select by recorded historical root state, add a predicate:

```ruby
report = PaperTrailDiff.analyze_scope(
  Article.all, within: window, limit: 100, close_on: :current,
  historical_filter: ->(state) { state.status == "review" }
)
report.roots # the selected live model instances, in relation order
```

The predicate receives reified root records at in-window version boundaries,
without traversing associations. Create boundaries are absent and skipped. A match
at any of those boundaries selects a candidate. This tests recorded pre-event
states: it does not inspect the final live state, even with `close_on: :current`,
or states recorded only outside the window. It is not a continuous-time query.
`version_scope:` filters analysis events; it does not narrow predicate evaluation.

The relation still filters live rows. Matching deleted candidates remain in
`unreachable`. With `historical_filter:`, the safety ceiling applies to all
matching candidates, including missing roots, before the live relation's filters
and pagination. Reification stops when that ceiling is exceeded; scanning many
nonmatches or a root with a long history can still be expensive. Narrow the window
and predicate accordingly. Without this option, the existing live-root ceiling
and unpaginated missing-root behavior remain unchanged.

`roots` is a frozen array, but its ActiveRecord instances remain mutable for
ordinary application use. Changing them does not change the immutable analysis
snapshots. The scoped `analyze_many(scope: ...)` alias accepts the same predicate;
explicit record lists do not.

A deletion audit should inspect that collection explicitly. The destroy version
contains the last record state and can provide a historical root for an activity
query. Records removed without a destroy version remain explicitly unavailable:

<!-- executable:recipe-deleted -->
```ruby
unavailable = []
deleted_activity = report.unreachable.to_h do |identity|
  type, id = identity
  version = Article.paper_trail.version_class
    .where(item_type: type, item_id: id, event: "destroy")
    .reorder(created_at: :desc, id: :desc).first
  root = version&.reify
  if root
    [identity, PaperTrailDiff.activity_timeline(root, within: window)]
  else
    unavailable << identity
    [identity, nil]
  end
end
```

This explicit fallback costs work per deleted root. Do not treat `unreachable` as
proof that a deleted record matched your relation's conditions. A filtered report
needs an application-level decision about those historical records.

A relation's existing order, offset, and limit define the live selection. For
example, `Article.limit(2)` requests up to two live roots. With a plain SQL join,
that relation's pagination applies to joined rows, which may repeat a root.
Repeated roots are analyzed once, in order of first appearance.
Use a deterministic order for pagination, adding the root's ID as a tie-breaker
when sorting values can repeat. With no explicit order, roots are ordered by ID.

The separate `limit:` option is a safety ceiling on unique selected live roots;
exceeding it raises `BatchLimitExceededError`. It does not shorten the selection.
`unreachable` is a separate, unpaginated list of missing roots with history in the
window. It is not the deleted portion of the live page. The ceiling does not bound
that list or all candidate-selection work; narrow large windows. Duplicate joined
rows can require additional query pages before the safety check is decided.

If you already have the records, use `analyze_many(records, **options)` to get an
identity-keyed hash. Both batch methods accept `group:` and `snapshots:` with
`activity: true`. The older `analyze_many(scope: ..., limit: ...)` alias remains
supported and returns `ScopedAnalysis`.

`group:` and `snapshots: true` require `activity: true` on analysis methods;
otherwise they raise `ConfigurationError`.

## Choose the output you need

| Task | Method | Result |
| --- | --- | --- |
| Net change between two states | `compare(before, after)` | `Diff` |
| Net changes for supplied endpoint pairs | `compare_many(pairs)` | Hash of `Diff` |
| Steps at parent-record checkpoints | `timeline(record, ...)` | Array of `Step` |
| Steps including selected child events | `activity_timeline(record, ...)` | Array of `ActivityStep` |
| Net diff and checkpoint steps together | `analyze(record, ...)` | `Analysis` |
| Also include the activity feed | `analyze(record, activity: true, ...)` | `Analysis` |
| Analyze supplied records | `analyze_many(records, ...)` | Hash of `Analysis` |
| Select records from a relation | `analyze_scope(relation, limit: ..., ...)` | `ScopedAnalysis` |

All three single-record timeline methods accept `from: :first, to: record` for
history through current state, or two versions for historical endpoints.
`:last` means the last stored **pre-change** state; it does not mean current state.
For time windows, use `within:`. Add `close_on: :current` only when a live closing
state is appropriate. It can include state after the window's end; a reproducible
historical report needs a later recorded boundary instead.

A record with no stored versions has an empty explicit `:first`/`:last` history.
A lone creation is a presence change. Destroyed roots gain a closing removal step
in activity timelines; endpoint diffs retain PaperTrail's pre-destruction state.

## Defaults and further reading

- `updated_at` is ignored by default. `ignore:` replaces that list.
- Live endpoints must be saved, clean records. They are reloaded by default.
- Empty steps are retained; use `reject(&:empty?)` for a visible activity feed.
- Historical associations require installed, enabled PT-AT and versioned targets.
- Multiple database queries are not automatically one isolated snapshot.

See the [API reference](docs/reference.md) for nested JSON changes, ignore rules,
association support, diagnostics, result shapes, and historical limitations.
[Reconstruction and performance](docs/architecture.md) explains batching and
indexing for applications that need to tune their queries.

For development checks and database coverage, see [testing](docs/testing.md).
See [CHANGELOG.md](CHANGELOG.md) for changes and [LICENSE](LICENSE) for the MIT license.
