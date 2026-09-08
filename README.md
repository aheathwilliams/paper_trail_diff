# paper_trail_diff

Compare past and present records using the history saved by
[PaperTrail](https://github.com/paper-trail-gem/paper_trail). Show changed fields,
include changes to associated records, or build a report for many records.
Results are Ruby objects with methods for reading the changes and `to_h` for
turning them into hashes. The gem does not generate display text or save changes.

If you already use `has_paper_trail` and `record.versions`, you can pass those
versions directly to this gem. You do not need to call `reify` yourself.

## Get started

Add the gem to your Rails application:

```console
bundle add paper_trail_diff
```

Already have a model with `has_paper_trail`? Try the comparison below.
Otherwise, follow the [Rails quickstart](QUICKSTART.md) to set up PaperTrail
and create your first comparison.

To try it without Rails, download [examples/demo.rb](examples/demo.rb) and run
`ruby demo.rb`. It installs its dependencies on the first run. The
[demo application](https://github.com/aheathwilliams/paper_trail_summary_test_app)
shows reports in a Rails UI.

Ruby 3.1+ and PaperTrail 16 or 17 are supported, subject to
[PaperTrail's Ruby and ActiveRecord requirements](https://github.com/paper-trail-gem/paper_trail#1a-compatibility).
Comparing association history also requires
[paper_trail-association_tracking](https://github.com/westonganger/paper_trail-association_tracking),
an optional PaperTrail plugin. The quickstart includes its setup.

> **Experimental:** AI-assisted coding tools made significant contributions to
> this project. Check results against your application's history before relying
> on them. Changes that were never recorded cannot be recovered.

## 1. Compare an earlier version with the current record

This example assumes an `Article` model with a `title` column and `has_paper_trail`:

<!-- executable:recipe-compare -->
```ruby
article = Article.create!(title: "Draft")
article.update!(title: "Published")

# PaperTrail stores the values from BEFORE the update.
before = article.versions.last
diff = PaperTrailDiff.compare(before, article)

diff.attributes.fetch("title").to_h
# => { from: "Draft", to: "Published" }
```

PaperTrail's `version.reify` returns the record as it was before that version's
change. Passing a version to `compare` uses that same earlier state. Passing
`article` uses its current saved values. Pass two versions to compare two
historical states.

PaperTrail's `version.changeset` describes one recorded change. `compare`
describes the net difference between the two states you choose. If a field
changes and then changes back, there is no net difference for that field.

An attribute appears in `diff.attributes` only when it changed. `diff.empty?`
tells you whether anything changed. A PaperTrail `create` version has no earlier
record (`reify` returns `nil`), so comparing it with the current record reports
`diff.record_presence_change`, meaning the record was added.

To include comments, add `associations: [:comments]`. If comments have replies,
`associations: ["comments.replies"]` includes those too. Associated models must
also use `has_paper_trail`, and association tracking must be enabled.

For nested results, `each_change` lets you read changes without walking every
association yourself:

```ruby
diff.each_change do |entry|
  entry.kind              # e.g. :attribute_changed or :record_added
  entry.association_path  # e.g. ["comments", "replies"]
  entry.value             # the changed values or the added/removed record's data
end
```

## 2. Show who changed a record and its comments

This example requires the association setup in the quickstart. PaperTrail's
`whodunnit` records who made a change; here we set it with `PaperTrail.request`.
Pass `to: article` to include the latest saved article and comment changes.

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

Each step contains a `diff`. `source_boundary` describes the PaperTrail version
responsible for that change, including its `whodunnit`, `event`, `item_type`,
and `item_id`. Its `recorded_at` is the version's `created_at`.
Use this source information for attribution: the version used to read the
resulting state, exposed as `to_boundary`, may have been saved by someone else.

`group: :transaction` combines changes from one database transaction. Its source
information comes from the first event in that group. Omit `group:` if you need
to attribute each version separately.

`snapshots: true` also keeps copies of the compared records' data, including
unchanged fields. These read-only copies are called snapshots. Access them as
`step.from_snapshot` and `step.to_snapshot`, or include them in a hash with
`step.to_h(snapshots: true)`. Keeping them uses more memory. Omit the option if
changed values are enough. `metadata: true` adds event and author information
to the hash.

## 3. Report on records changed since a given time

Use `report` with a model or ActiveRecord relation. It includes activity from
`since:` through the current saved state. Association tracking is only needed
if you also pass `associations:`.

<!-- executable:recipe-report -->
```ruby
report = PaperTrailDiff.report(
  Article.all, since: 1.day.ago, limit: 100, include_deleted: true
)

rows = report.analyses.map do |identity, analysis|
  {
    record: identity,                 # ["Article", "42"]: model name and ID
    changes: analysis.diff.to_h,
    activity: analysis.activity_timeline.reject(&:empty?).map do |step|
      step.to_h(metadata: true)
    end
  }
end

report.unreachable # Model names and IDs for records no longer in the database
report.deleted     # Reports for those records, or nil when destroy history is missing
```

`report.analyses` is a hash of reports for records that still exist. Each key is
`[model_name, id_as_a_string]`. Each value has the net `diff` and an
`activity_timeline`. `report.roots` returns the selected ActiveRecord objects.

`include_deleted: true` also builds reports from PaperTrail's destroy versions.
Read them from `report.deleted` using the same keys:

<!-- executable:recipe-deleted -->
```ruby
unavailable = report.deleted.select { |_identity, analysis| analysis.nil? }.keys
deleted_activity = report.deleted.transform_values do |analysis|
  analysis&.activity_timeline
end
```

The results are already computed; you do not need to query or reify each deleted
record. Omit `include_deleted:` if you only need records that still exist.

Three selection rules matter:

- The record itself needs a PaperTrail version in the time window. For example,
  editing only a comment does not select its article. Comment activity is included
  for selected articles when you request `associations: [:comments]`.
- A relation such as `Article.where(status: "open")` checks today's values.
  It cannot establish whether deleted articles matched that condition. Deleted
  records are therefore listed separately.
- `limit: 100` is a safety ceiling, not pagination. Selecting too many records
  raises `BatchLimitExceededError`. With `include_deleted: true`, both existing
  and deleted records count toward it. Use a narrower relation or time window,
  or deliberately raise the ceiling.

Use the relation's `order`, `offset`, and `limit` to choose a page, for example
`Article.order(:id).limit(20)`. Joined rows can repeat a record; each record is
analyzed once. See the [reporting reference](docs/reference.md#letting-a-relation-choose-the-roots)
for historical filters, deleted-record selection, and pagination details.

For a fixed past window, use `analyze_scope(Article.all, within: start_time..end_time,
limit: 100)`. PaperTrail needs a later version to supply the values after the
window's last change. See the [quickstart](QUICKSTART.md#select-changes-by-time)
for an example and an explanation of `close_on: :current`.

## Choose a method

| What you need | Method |
| --- | --- |
| Net difference between a version and a record, or between two versions | `compare(before, after)` |
| Net differences for a list of `{ from:, to: }` pairs | `compare_many(pairs)` |
| Changes between successive versions of one record | `timeline(record, ...)` |
| Activity for a record and its requested associations | `activity_timeline(record, ...)` |
| Net difference and version timeline together | `analyze(record, ...)` |
| The same analysis, plus activity | `analyze(record, activity: true, ...)` |
| Reports for an array of records | `analyze_many(records, ...)` |
| Recent activity through now, selected by a relation | `report(scope, since: ..., limit: ...)` |
| Reports for a past time window, selected by a relation | `analyze_scope(scope, within: ..., limit: ...)` |

For `timeline`, `activity_timeline`, and `analyze`, `from: :first, to: article`
means history through the current saved record. `:last` means the last stored
version's **before-change** state, just like `article.versions.last.reify`;
it does not mean the current record.

## Performance and defaults

Use the batch methods for reports instead of calling `reify` or a single-record
method inside a loop. They share history loading across records. Ordinary
record and direct-association histories can be read without creating a model
instance for every historical state.

Some associations still need per-record queries. Batch methods reject scoped
associations and certain `has_many :through` histories by default with
`UnsupportedBatchPathError`. The error names the association. Remove it from
`associations:`, or pass `allow_expensive: true` if you accept that cost.
Callbacks and callable historical filters can also issue queries. See the
[performance guide](docs/performance.md) for measured behavior and limitations.

- `updated_at` is ignored. Passing `ignore:` replaces the default list.
- Records passed as current state must be saved and have no unsaved changes.
  They are reloaded from the database.
- Empty timeline steps are kept. Use `reject(&:empty?)` to hide them in a feed.
- Only the associations you name are included.
- Historical data cannot be recovered if PaperTrail did not record it.

See the [API reference](docs/reference.md) for all options and result methods,
[testing](docs/testing.md) for development checks, and
[CHANGELOG.md](CHANGELOG.md) for changes. Licensed under the [MIT license](LICENSE).
