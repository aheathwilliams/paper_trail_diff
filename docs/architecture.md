# Reconstruction and performance

[Back to the API reference](reference.md).

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
