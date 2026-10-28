# Quickstart

This guide sets up PaperTrail, saves a few versions of an article, and reads
its changes with `paper_trail_diff`. You need Ruby, Bundler, and Rails installed.
The gem supports Ruby 3.1+ with PaperTrail 16 or 17; your Rails and PaperTrail
versions may require a newer Ruby.

Already using PaperTrail? Skip the setup and use your own model in
[Create a little history](#3-create-a-little-history).

Otherwise, start with a new Rails application. Run the following examples in
order. Commands run in your terminal; Ruby examples run in the Rails console
unless a file path is shown:

```console
rails new diff-demo --minimal
cd diff-demo
```

**Just want to see it work?** [`examples/demo.rb`](examples/demo.rb) is a single
self-contained file — no application, no migrations, nothing to undo. Download
it anywhere and run `ruby demo.rb`; it fetches what it needs on first run.

## 1. Install the gem

From the Rails application directory:

```console
bundle add paper_trail_diff
bin/rails generate paper_trail:install --with-changes
bin/rails db:migrate
```

Skip the generator if the application already has a PaperTrail `versions`
table. `--with-changes` adds `object_changes`, which PaperTrail uses for
`version.changeset`. Keep it if you want PaperTrail to store the changed values
for each event. This gem can also compare the full earlier records saved in
PaperTrail's `object` column.

## 2. Version a model

Create an article model and tell PaperTrail to track its changes:

```console
bin/rails generate model Article title:string
bin/rails db:migrate
```

```ruby
# app/models/article.rb
class Article < ApplicationRecord
  has_paper_trail
end
```

Restart the Rails console after changing dependencies, model configuration, or an initializer.

## 3. Create a little history

Run this in `bin/rails console`:

<!-- executable:quickstart-history -->
```ruby
article = Article.create!(title: "Draft")

article.update!(title: "Published")
draft_version = article.versions.last

article.update!(title: "Final")
published_version = article.versions.last
```

PaperTrail saves the record's values **before** each change. Its public
`reify` method builds an earlier record from a version:

```ruby
draft_version.reify.title     # => "Draft"
published_version.reify.title # => "Published"
article.title                 # => "Final" (current database state)
```

## 4. Compare two states

<!-- executable:quickstart-compare -->
```ruby
diff = PaperTrailDiff.compare(draft_version, published_version)

diff.empty? # => false
diff.attributes["title"].from # => "Draft"
diff.attributes["title"].to   # => "Published"

diff.to_h
# => {
#   record_presence_change: nil,
#   attributes: {
#     "title" => { from: "Draft", to: "Published" }
#   },
#   associations: {}
# }
```

Pass the PaperTrail versions themselves to `compare`; you do not need to call
`reify` first. The result has one entry per changed attribute, with `from` and
`to` values. Unchanged attributes are left out.

`compare` reports the net difference between the two records. For every change
in between, use `timeline`, shown below. Reading a diff does not save or modify
any record.

### Compare a version with current state

Pass `article` instead of a second version to compare with its current saved
values:

<!-- executable:quickstart-current -->
```ruby
diff = PaperTrailDiff.compare(published_version, article)

diff.attributes["title"].to # => "Final"
```

The article must still exist in the database and have no unsaved changes.
The gem reloads it before comparing. `article.versions.last` is different: it
contains the values from before the latest recorded change.

## 5. Read changes between versions

Save another change so PaperTrail records the previous title, `"Final"`:

<!-- executable:quickstart-timeline-state -->
```ruby
article.update!(title: "Archived")
final_version = article.versions.last # reifies to "Final"
```

Read the changes between each pair of article versions:

<!-- executable:quickstart-timeline -->
```ruby
steps = PaperTrailDiff.timeline(
  article,
  from: draft_version,
  to: final_version
)

steps.map do |step|
  change = step.diff.attributes["title"]
  [change.from, change.to]
end
# => [["Draft", "Published"], ["Published", "Final"]]

visible_steps = steps.reject(&:empty?)
```

Each item in `steps` has a `diff`, just like the comparison above. Steps with
no reported changes are kept; `reject(&:empty?)` removes them for display.

Without `from:` and `to:`, `PaperTrailDiff.timeline(article)` reads the whole
history through the current saved article, including the change to
`"Archived"`. Pass a version as `to:` when the result should stay the same after
later edits.

### Select changes by time

Use `within:` to choose changes by their PaperTrail version's `created_at`:

<!-- executable:quickstart-time-range -->
```ruby
window = draft_version.created_at...final_version.created_at
ranged_steps = PaperTrailDiff.timeline(article, within: window)

ranged_steps.map do |step|
  change = step.diff.attributes["title"]
  [change.from, change.to]
end
# => [["Draft", "Published"], ["Published", "Final"]]
```

Ruby's `...` excludes the end of the range. Here the selected versions are
`draft_version` and `published_version`.

Each PaperTrail version stores the values **before** its own change, so the
values after the window's last change are in the next version, `final_version`.
The gem reads that version even though it is outside the window. When no later
version exists, nothing has been recorded since, and the gem reads the current
saved article instead.

### Report through now

To report on many articles, pass a model or ActiveRecord relation to `report`.
It includes changes from `since:` through now:

```ruby
report = PaperTrailDiff.report(
  Article.all, since: 1.day.ago, limit: 100, include_deleted: true
)
report.analyses # Hash: [model name, ID string] => report for an existing record
report.deleted # Same keys for deleted records; nil if no destroy version was saved
report.analyses.each_value { |analysis| analysis.diff.to_h }
```

`limit: 100` is a safety ceiling. If more than 100 existing and deleted articles
are selected, the call raises instead of returning a partial report. Omit
`include_deleted:` if you only need articles that still exist.

An article needs its own PaperTrail version in the time window to be selected.
Editing a comment alone does not select its article. A relation's `where`
conditions check current values; they cannot check a deleted article's values.

For one article, use a window ending now:

<!-- executable:quickstart-current-window -->
```ruby
current_steps = PaperTrailDiff.timeline(article, within: 1.day.ago..Time.current)
```

The same `within:` option works on `activity_timeline`, `analyze`,
`analyze_many`, and `analyze_scope`.

## 6. Choose a method

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

Use the batch methods for many records so they can share database queries.
Some scoped associations and `has_many :through` histories still need queries
for each record. Batch calls reject those with `UnsupportedBatchPathError`.
The error names the association. `allow_expensive: true` permits that extra work;
see the [performance guide](docs/performance.md) before using it in a large report.

When associations are included, `timeline` compares their values at the article's
versions. `activity_timeline` also reports the comments' own version events, even
when the article was not edited. The next section on associations shows this.

## 7. Choose fields to ignore

`updated_at` is ignored by default. Passing `ignore:` replaces that default:

<!-- executable:quickstart-ignore -->
```ruby
PaperTrailDiff.compare(
  draft_version,
  published_version,
  ignore: %i[updated_at lock_version]
)

PaperTrailDiff.compare(
  draft_version,
  published_version,
  ignore: [] # include updated_at too
)
```

See the [API reference](docs/reference.md) to ignore different fields on different associations.

## 8. Add association history when needed

To compare an article's earlier comments, install the optional
`paper_trail-association_tracking` plugin (called PT-AT in the reference):

```console
bundle add paper_trail-association_tracking
bin/rails generate paper_trail_association_tracking:install
bin/rails db:migrate
```

The generator creates `version_associations` and enables
`PaperTrail.config.track_associations` in an initializer. If your application
already has that initializer, check that it contains
`PaperTrail.config.track_associations = true`.

Add a comment model:

```console
bin/rails generate model Comment article:references body:string
bin/rails db:migrate
```

Add `has_paper_trail` to both models so their earlier values are recorded:

```ruby
class Article < ApplicationRecord
  has_many :comments, dependent: :destroy
  has_paper_trail synchronize_version_creation_timestamp: false
end

class Comment < ApplicationRecord
  belongs_to :article
  has_paper_trail
end
```

The article option `synchronize_version_creation_timestamp: false` lets
manually saved versions record the time they were taken. Restart the console
after this setup and reload your article with `article = Article.first!`.

Use PaperTrail's `paper_trail.save_with_version` to save an article version even
though none of its attributes changed. That gives the comparison a starting
point before adding the comment. The transaction also records the information
needed for association history:

<!-- executable:quickstart-association -->
```ruby
Article.transaction do
  Article.find(article.id).paper_trail.save_with_version
end
before = article.versions.reload.last

article.comments.create!(body: "First comment")
current = Article.find(article.id)

diff = PaperTrailDiff.compare(
  before,
  current,
  associations: [:comments]
)

diff.associations["comments"].added.first.attributes["body"]
# => "First comment"
```

If your models also define `replies` and `author`, name those associations to include them:

```ruby
diff = PaperTrailDiff.compare(
  before,
  current,
  associations: ["comments.replies.author"]
)
```

To show the comment creation as its own activity step, without updating the article:

<!-- executable:quickstart-activity -->
```ruby
steps = PaperTrailDiff.activity_timeline(
  article,
  from: before,
  to: current,
  associations: ["comments"]
)

steps.reject(&:empty?).each do |step|
  source = step.source_boundary
  puts "#{source.item_type} ##{source.item_id}"
end
```

`source_boundary` describes the version responsible for a step. Its `item_type`
and `item_id` are PaperTrail's model name and record ID. It also exposes the
version's `whodunnit` and `event`. See the README for a feed using these values.

To keep the result fixed after later edits, save another article version with
`paper_trail.save_with_version` inside a transaction, then pass that version
instead of `to: current`.

You can also pass `within: start_time...end_time`. This single-article method
includes comment changes even if the article was not edited in that period.
Unlike this method, a relation-based `report` needs an article version in the
window to select that article.

## 9. Common surprises

- `article.versions.last.reify` gives the article **before** its latest recorded
  change. Pass `article` to read the current saved values.
- PaperTrail's creation version returns `nil` from `reify`. There was no record
  before creation; the diff reports the record being added.
- A range ending at the current article includes changes PaperTrail never
  recorded, such as `update_columns`. Pass a version as `to:` to stop at
  recorded history.
- `ignore:` replaces the default list. Include `updated_at` yourself when using
  a custom list and you still want it ignored.
- Historical associations require PT-AT to be installed, loaded, migrated, and
  enabled. Restart the console after setup.
- Only the associations listed in `associations:` are included. Asking for
  comments does not automatically include every association on each comment.
- Historical output cannot contain data that PaperTrail or PT-AT did not record
  or can no longer reconstruct.

For association support, performance, error handling, ignore rules, and all
available result methods, see the
[API reference](docs/reference.md). For complete activity-feed and batch-report
recipes, including deleted records, see the [README](README.md).

Upstream setup references:
[PaperTrail installation](https://github.com/paper-trail-gem/paper_trail#1b-installation)
and
[PT-AT installation](https://github.com/westonganger/paper_trail-association_tracking#install).
