# paper_trail_diff

`paper_trail_diff` adds structured endpoint and timeline comparisons to
[PaperTrail](https://github.com/paper-trail-gem/paper_trail). It returns immutable
Ruby value objects and hashes rather than formatted text.

PaperTrail is required. Explicit, bounded association-path comparison is
available when
[paper_trail-association_tracking](https://github.com/westonganger/paper_trail-association_tracking)
(PT-AT) is installed, loaded, and enabled.

Ruby 3.1 or newer and PaperTrail 16 or 17 are supported.

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

All associated models being compared must use `has_paper_trail`.

## Compare two endpoints

PaperTrail stores an object's state before each recorded event. `compare`
reifies exactly the two versions supplied and reports their net difference:

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

## Build a timeline

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
steps.first.diff         # a PaperTrailDiff::Diff
steps.first.to_h
# => { from_version_id: 2, to_version_id: 3, diff: { ... } }
```

Every version boundary remains in the result, even when its diff is empty after
ignored fields are removed. Equal boundaries return a frozen empty array.

## Ignore noise fields

Both APIs ignore `updated_at` by default. `ignore:` replaces that default and
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
remains a normal scalar attribute. Cyclic model relationships are safe because
only the finite paths supplied by the caller are traversed.

Requesting associations without loaded and enabled PT-AT raises
`PaperTrailDiff::AssociationTrackingUnavailableError`. Unknown names and
unsupported macros raise explicit `PaperTrailDiff::Error` subclasses.

## Result objects

The public result types are:

- `PaperTrailDiff::Diff`
- `PaperTrailDiff::Step`
- `PaperTrailDiff::ValueChange`
- `PaperTrailDiff::RecordSnapshot`
- `PaperTrailDiff::RecordChange`
- `PaperTrailDiff::ToOneAssociationDiff`
- `PaperTrailDiff::CollectionAssociationDiff`

They expose readers, are frozen after construction, and provide deterministic
`to_h` output. Structural hash keys are symbols; attribute and association
names are strings. Attribute values retain their Ruby types.

## Historical correctness and limitations

The output is only as correct and complete as the historical state PaperTrail
and PT-AT can reconstruct. In particular:

- attributes skipped by PaperTrail, deleted versions, and changes made while
  versioning was disabled cannot be recovered;
- model/schema or serializer changes can affect reification of old versions;
- `compare` and `timeline` never add the live current record as an implicit
  endpoint;
- PT-AT requires its schema, callbacks, versioned child models, and transaction
  metadata; callback-skipping writes may not be reconstructable;
- HABTM membership is limited to the join snapshots PT-AT recorded in
  `version_associations`; historical target attributes require versioned target
  models, otherwise PT-AT may return live target state;
- a timeline is bounded by root-record versions, so a child-only change without
  a later root version cannot form a separate timeline step;
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
```

The default Rake task runs core specs without PT-AT loaded, association specs in
a separate process, RuboCop, generated-signature verification, and Steep.
Inline `#:` annotations in `lib/` generate the committed RBS files under
`sig/generated/`.

## License

MIT
