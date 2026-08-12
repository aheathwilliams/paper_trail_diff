# Quickstart

This guide gets `paper_trail_diff` running in a Rails application and shows the
smallest useful examples. Ruby 3.1 or newer and PaperTrail 16 or 17 are
supported.

Every command and console snippet below is meant to be run in order against a
scratch application, so nothing here assumes models you already have:

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
table. The `object_changes` column created by `--with-changes` is recommended
for efficient activity analysis, although endpoint comparison is based on
reified state rather than a PaperTrail changeset.

## 2. Version a model

Create the model this guide uses, then declare it versioned:

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

Restart the Rails console after changing the Gemfile or an initializer.

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

The variable names are intentional. PaperTrail versions contain the state
*before* their event:

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

`compare` reports only the net difference between its endpoints. It does not
report intermediate changes.

### Compare a version with current state

Pass the persisted record explicitly when the second endpoint should be the
current database state:

<!-- executable:quickstart-current -->
```ruby
diff = PaperTrailDiff.compare(published_version, article)

diff.attributes["title"].to # => "Final"
```

The record must be persisted, not destroyed, and have no unsaved changes.
Current state is never inferred automatically.

## 5. Build a checkpoint timeline

Create one more historical endpoint:

<!-- executable:quickstart-timeline-state -->
```ruby
article.update!(title: "Archived")
final_version = article.versions.last # reifies to "Final"
```

Then compare every adjacent root version:

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

Empty steps remain in the timeline. Filter them only when the application's
display does not need every version boundary.

### Select mutations by time

Use `within:` when the application has a reporting window rather than saved
endpoint versions:

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

The half-open range selects the mutations recorded by `draft_version` and
`published_version`. The excluded `final_version` is still used as the trailing
boundary needed to reveal the last selected mutation. PaperTrail versions are
pre-change snapshots, so a range containing mutations must have a later root
version. The gem raises `PaperTrailDiff::IncompleteTimeRangeError` instead of
assuming that the current record is the missing endpoint.

## 6. Choose the right API

| Need | Call |
| --- | --- |
| Net difference between two endpoints | `compare` |
| Net differences for many current records | `compare_many` |
| One step per root-record version | `timeline` |
| Steps for root and selected child versions | `activity_timeline` |
| Net diff and timelines from one history pass | `analyze` |

`timeline` is a root-checkpoint timeline. A child change becomes visible at the
next root boundary. `activity_timeline` can make a versioned child change its
own boundary and can end at an explicitly supplied current record.

## 7. Ignore noise fields

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
  ignore: [] # compare every available scalar attribute
)
```

See the main README for exact path-specific ignore rules.

## 8. Add association history when needed

Associations are optional. Add PT-AT only when the application needs historical
association reconstruction:

```console
bundle add paper_trail-association_tracking
bin/rails generate paper_trail_association_tracking:install
bin/rails db:migrate
```

The generator creates `version_associations` and enables
`PaperTrail.config.track_associations`. This section also needs a second model:

```console
bin/rails generate model Comment article:references body:string
bin/rails db:migrate
```

Every model whose historical state is needed must be versioned:

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

Take an explicit root checkpoint before the example change:

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

Nested paths are explicit and bounded:

```ruby
diff = PaperTrailDiff.compare(
  before,
  current,
  associations: ["comments.replies.author"]
)
```

To see versioned child events without touching the article after each change:

<!-- executable:quickstart-activity -->
```ruby
steps = PaperTrailDiff.activity_timeline(
  article,
  from: before,
  to: current,
  associations: ["comments"]
)

steps.reject(&:empty?).each do |step|
  boundary = step.to_boundary
  puts "#{boundary.item_type} ##{boundary.item_id}"
end
```

Use a later transaction-backed root checkpoint instead of `to: current` when
the result must remain reproducible after the database changes again.

For a historical reporting window, replace `from:` and `to:` with `within:`:

```ruby
steps = PaperTrailDiff.activity_timeline(
  article,
  within: report_start...report_end,
  associations: ["comments"]
)
```

This selects versioned comment activity directly, even if the article had no
mutation during the window. Take a root checkpoint after `report_end`; it gives
the gem the historical context needed to expose the final child mutation.

## 9. Common surprises

- PaperTrail stores pre-change snapshots. The current record is not represented
  by `versions.last`; pass the record explicitly when current state is wanted.
- A `within:` window containing mutations needs a later root checkpoint. The
  trailing version is reconstruction context and may appear as a step's ending
  boundary even though its own mutation is outside the window.
- `ignore:` replaces the default list. Include `updated_at` yourself when using
  a custom list and you still want it ignored.
- Historical associations require PT-AT to be installed, loaded, migrated, and
  enabled. Restart the console after setup.
- Only requested association paths are traversed. The gem never recursively
  discovers the whole model graph.
- Historical output cannot contain data that PaperTrail or PT-AT did not record
  or can no longer reconstruct.

For performance guidance, HABTM limitations, diagnostics, discovery, path-aware
ignore rules, and complete result shapes, continue with the
[README](README.md).

Upstream setup references:
[PaperTrail installation](https://github.com/paper-trail-gem/paper_trail#1b-installation)
and
[PT-AT installation](https://github.com/westonganger/paper_trail-association_tracking#install).
