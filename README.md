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
changes and then changes back, there is no net difference for that field. To
see every change instead, use `PaperTrailDiff.timeline(article)`, which covers
the article's whole history through its current saved values.

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
The timeline covers the article's whole history, including comment changes made
after the article's last version.

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
  article, associations: [:comments], group: :transaction, snapshots: true
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
A change saved without a version, such as with `update_columns`, appears in the
step for that record's previous recorded change. To also read only what each
version recorded, pass `recorded_changes: true` and read
`step.source_boundary.recorded_changes`; see
[what each event recorded](docs/reference.md#what-each-event-recorded-recorded_changes-true).

`group: :transaction` combines changes from one database transaction. Its source
information comes from the first event in that group, and `step.sources` lists
every event in it, each with its own author.

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

report.unreachable # Model names and IDs of selected records no longer in the database
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
last_state = report.deleted.transform_values do |analysis|
  analysis&.activity_timeline&.last&.diff&.record_presence_change&.from
end
```

The results are already computed; you do not need to query or reify each deleted
record. `last_state` is each record just before its deletion, which the final
step removes. Use it to show what a deleted record was, such as its title:
`analysis.from_snapshot` is the record when the window began, so it is `nil` for
one created inside the window. Omit `include_deleted:` if you only need records
that still exist.

Three selection rules matter:

- A record is selected when it, or a record on one of the `associations:` you
  request, has a PaperTrail version in the time window. With
  `associations: [:comments]`, editing only a comment selects its article, and
  the article's report shows the edit.
- A relation such as `Article.where(status: "open")` checks today's values.
  Deleted records have none, so they are listed separately. With
  `include_deleted: true`, the gem tests each against the relation as it was
  when destroyed and keeps only those that match, so a report on one account's
  records holds only that account's deletions. That needs plain conditions on
  the model's own columns; a join or SQL text raises `ConfigurationError`.
- `limit: 100` is a safety ceiling, not pagination. Selecting too many records
  raises `BatchLimitExceededError`. With `include_deleted: true`, both existing
  and deleted records count toward it. Use a narrower relation or time window,
  or deliberately raise the ceiling.

Use the relation's `order`, `offset`, and `limit` to choose a page, for example
`Article.order(:id).limit(20)`. Joined rows can repeat a record; each record is
analyzed once. See the [reporting reference](docs/reference.md#which-records-are-selected)
for pagination, deleted records, and selecting by past values with
`historical_filter:`.

For a fixed past window, use `analyze_scope(Article.all, within: start_time...end_time,
activity: true, limit: 100)`. Without `activity: true`, `analyze_scope` compares
each record's own versions, so it selects only records with a version of their
own.

## 4. Turn a report into rows

For a history table or an export, `change_rows` flattens a report into one row
per change. Each row names the record, the change, and the version it came
from. This example requires the association setup in the quickstart:

<!-- executable:recipe-summary -->
```ruby
report = PaperTrailDiff.report(
  Article.all, since: 1.day.ago, limit: 100,
  associations: [:comments], include_deleted: true
)

rows = report.change_rows.flat_map do |root, changes|
  changes.map { |row| row.to_h.merge(root: root) }
end
```

`report.change_rows` is a hash keyed like `report.analyses`, with deleted
records last. Each value lists that record's rows in time order. Each row
covers one of two things:

- **A field**: `attribute` names it, and `change` is `:changed` for an edit.
  For a record that appeared or disappeared, each of its fields gets an
  `:added` or `:removed` row, holding its value in `to` or `from`. Blank
  fields of such a record get no row.
- **A whole record**: `attribute` is `nil`, and `change` is `:added` or
  `:removed`. The record was created or deleted, a comment joined or left the
  article, or a `belongs_to` pointed somewhere new, which gives a `:removed`
  row for the old record and an `:added` row for the new one. A comment moved
  from another article is `:added` too; its `event` is then `"update"`.

`record` is the record the row is about, or `nil` for the article itself, and
`association_path` is how it was reached, such as `["comments"]`. `to_h` adds
the step's source version: `version_id`, `event`, `whodunnit`, `recorded_at`,
and `transaction_id`. With `group: :transaction`, that is the transaction's
first event; `step.sources` lists every event. `row.source` is the
`ActivityBoundary` itself.

`change_rows` is also on an `Analysis` built with `activity: true` and on each
activity step. Labels, grouping, and formatting are left to your application.

## Choose a method

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

`timeline`, `activity_timeline`, and `analyze` cover the whole history through
the current saved record by default. Narrow them with `from:` and `to:`
(versions) or `within:` (a time range). See
[choosing a range](docs/reference.md#choosing-a-range).

## Performance and defaults

Use the batch methods for reports instead of calling `reify` or a single-record
method inside a loop. They share history loading across records. Ordinary
record and direct-association histories can be read without creating a model
instance for every historical state.

Scopes and default scopes made of plain conditions, such as
`-> { where(archived: false) }`, are batched too, and so is a `limit` or
`offset` ordered by integer, boolean, date, or datetime columns down to the
primary key, such as `-> { order(:position, :id).limit(3) }`, on a direct
association or a `has_many :through`. History cannot read a few scopes, such
as a `limit` ordered by a string, a scope that takes the owner, or SQL text.
PT-AT reads those instead, one record at a time and only approximately, so
every method raises `UnsupportedAssociationError` naming the association.
Remove it from `associations:`, or pass `allow_approximate: true` to accept
PT-AT's answer and its cost. See
[costly associations](docs/reference.md#costly-associations).
Callbacks and callable historical filters can also issue queries. See the
[performance guide](docs/performance.md) for measured behavior and limitations.

On a large version table, add these indexes, or every `since:` or `within:`
report reads all of the model's versions. See
[database indexes](docs/architecture.md#database-indexes) for why.

```ruby
add_index :versions, %i[item_type item_id created_at id],
          name: "index_versions_on_item_and_timeline"
add_index :versions, %i[item_type created_at item_id],
          name: "index_versions_on_type_and_time"
```

- `updated_at` is ignored. Passing `ignore:` replaces the default list.
- Records passed as current state must be saved and have no unsaved changes.
  They are reloaded from the database.
- Empty timeline steps are kept. Use `reject(&:empty?)` to hide them in a feed.
- Only the associations you name are included.
- Historical data cannot be recovered if PaperTrail did not record it.

See the [API reference](docs/reference.md) for all options and result methods,
[testing](docs/testing.md) for development checks, and
[CHANGELOG.md](CHANGELOG.md) for changes. Licensed under the [MIT license](LICENSE).
