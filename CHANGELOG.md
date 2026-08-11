# Changelog

All notable changes to this project will be documented in this file. The
project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Document that `version_scope:` selects root versions only, and that "what did
  this person change?" is answered by an activity timeline filtered on
  `step.from_boundary.whodunnit` instead. A step's diff is exactly what the
  event at that boundary did, so the predicate covers descendant edits, which a
  root-version filter cannot see at all. Filtering in Ruby rather than selecting
  fewer versions is also what keeps the attribution correct: every boundary has
  to be reconstructed, or the snapshot carried into the next step is a state the
  record had already moved past.

## [0.6.0] - 2026-08-11

### Added

- Accept `version_scope:` on `timeline`, `activity_timeline`, `analyze`, and
  `analyze_many`, narrowing which root versions count as selected mutations.
  Excluded versions are still loaded, because a version records the state before
  its own event and the one following a selected change is what reveals it;
  their own changes are never attributed to a selected mutation. Each selected
  mutation is bounded by the version that immediately followed it rather than by
  the next selected one, so its diff is exactly what that mutation did however
  many excluded changes follow it. A selected mutation nothing follows yet is
  not reported, since no version records the state it produced; a selected
  destruction is the exception, because the absence it leaves is what it
  produced and `activity_timeline` closes on it. A root left with
  no selected mutation reports an empty `Analysis`. Under `activity: true` the
  filter decides the span; `activity_timeline` still lists every boundary inside
  it, because dropping one would fold its change into a neighbouring step.
- Expose `from_snapshot` and `to_snapshot` on `Analysis`, the reconstructed
  states its diff was taken between, so a report can render unchanged columns
  without selecting versions or reifying them itself. `Analysis#to_h` keeps its
  shape by default and takes `snapshots: true` to include them, because they
  carry the whole selected graph whether or not anything changed.

## [0.5.0] - 2026-08-11

### Added

- Add `analyze_many`, which analyzes many roots over one shared `within:` window,
  or over each root's whole history when the window is omitted, selecting their
  versions and preparing their history once for the batch. Query cost is flat in
  the number of roots for the endpoint diff and checkpoint timeline; descendant
  event discovery under `activity: true` remains per-root. A root with no
  versions in range returns an empty `Analysis`, and roots are supplied as live
  records so a root deleted inside the window cannot be included.
- Accept `:first` and `:last` as `compare_many` endpoints, resolved against the
  record the pair's other endpoint names, in two queries per model class rather
  than one lookup per root. A root with no recorded history compares as an empty
  `Diff`, and an unanchored `{ from: :first, to: :last }` raises.
- Accept `reload_live_endpoints:` on `activity_timeline`, which reads live state
  whenever `to:` is a current record but previously had no way to reuse an
  already-preloaded graph. `timeline` and `analyze` are bounded by versions and
  never read live state, so the option is deliberately absent there.

## [0.4.0] - 2026-08-11

### Added

- Close an activity timeline that ends at the root's own `destroy` version with
  a step into a new `kind: :destroyed` boundary, reporting the record's removal
  as a `record_presence_change` to `nil`. `ActivityBoundary` gains a
  `destroyed?` predicate, so consumers branching only on `version?` should
  handle the third kind. `compare`, `timeline`, and `analyze`'s endpoint diff
  are unchanged.
- Accept a `within:` window whose last selected mutation is the root's own
  destruction, which no later root version can follow, instead of raising
  `IncompleteTimeRangeError` for a range that could never be satisfied. A
  destruction outside the window remains reconstruction context only.
- Accept `:first` and `:last` as `from:` and `to:` boundaries on `timeline`,
  `activity_timeline`, and `analyze`, resolved without depending on the order
  the `versions` association happens to use. A record with no versions resolves
  to an empty timeline rather than raising, so listing pages need no special
  case.

### Removed

- Reject two version endpoints given in reverse chronological order with the
  new `PaperTrailDiff::ReversedEndpointsError`, in `compare` and
  `compare_many`. A transposed pair silently produced the inverse diff, and a
  result carries no direction that would reveal it. A current-record endpoint
  may still appear on either side.

### Fixed

- Rebuild prepared scalar state with direct attribute writes so a model that
  overrides an attribute writer reconstructs the state PaperTrail recorded
  instead of reapplying the override.

### Changed

- Order collection `added`, `removed`, and `changed` results naturally within
  one id type instead of by the printed form, so numeric ids sort `2` before
  `10`. Ordering remains deterministic and total for mixed id types.
- Resolve a boundary's prepared record state by chronological search and an
  indexed boundary transaction instead of scanning a record's versions, so
  timelines over long single-record histories stay linear in their step count.
- Bound prepared scalar history at the selected range plus one trailing version
  per identity, instead of every version recorded between the range and the
  present, so a short range early in a long history no longer pays for the
  history after it.
- Document that `timeline` and `analyze(activity: true)` produce the same
  root-checkpoint steps through different reconstruction strategies, and when
  each one is cheaper.
- Borrow a connection through `with_connection` where Active Record provides
  it, so applications that opt into deprecating permanent checkouts no longer
  see a deprecation warning from association candidate selection.
- Identify carried-forward collection snapshots and per-pass reification by
  an owned serial and by record identity, rather than by `object_id`, which
  Ruby only guarantees to be unique among live objects.
- Retain activity-event routes for every event type a timeline visits, rather
  than only the most recent one, so interleaved descendant types stop
  rediscovering the same routes.
- Resolve excluded attributes once per model class and selected path, and key
  historical child identities instead of rescanning them.

## [0.3.1] - 2026-08-10

### Fixed

- Preserve immutable activity snapshots for nested events that do not match a
  selected child record, instead of reporting a false change.

### Changed

- Split activity-event reconstruction, route discovery, relationship matching,
  collection mutation, and `belongs_to` target application into focused
  internal collaborators without changing result shapes.
- Reuse immutable activity-event routes and cached branch components across
  repeated event types to reduce timeline allocation overhead.

## [0.3.0] - 2026-08-10

### Added

- Add `within:` time-range selection to checkpoint timelines, activity
  timelines, and combined analysis, with inclusive/exclusive end handling and
  explicit errors when a final mutation cannot be reconstructed.
- Add `compare_many` for collection reports, with batched current-root loading,
  bounded live-association preloading, cross-root prepared history, immutable
  identity-keyed results, and scale-invariant query regression coverage.
- Add opt-in reuse of fully preloaded current endpoints and namespaced
  ActiveSupport runtime instrumentation without automatic logging, including
  end-to-end activity-timeline duration and step counts.

### Changed

- Teach timeline filtering through the shared `Step#empty?` protocol in the
  README and quickstart examples.
- Reuse the live graph loaded by `compare_many` while preparing historical
  association state, and defer root version loading until an edge needs it.
- Reuse collection identity positions and adjacent transition hints so activity
  steps compare only the changed member, and resolve direct nested collection
  owners by foreign key instead of scanning every parent snapshot.
- Reuse prepared predecessor and successor scalar states for isolated activity
  updates instead of reifying and deserializing each PaperTrail event again.
- Preserve both sides of nested collection membership moves by using the
  general comparator when one event changes multiple parent snapshots.
- Preserve per-owner `limit`, `offset`, and owner-dependent association scopes
  in `compare_many` while retaining batched preloading for safe branches.
- Replace lifetime association-identity materialization with an indexed start-state
  checkpoint plus post-boundary activity and current members.
- Bound historical activity-child candidates at the selected end so membership
  changes after the range cannot introduce unrelated empty timeline steps.
- Decode compatible prepared scalar version payloads without constructing an
  intermediate Active Record object, with reification fallback for unsafe schemas.
- Reuse internally owned frozen collection arrays instead of defensively copying
  them a second time during immutable activity reconstruction.
- Replace pre-existing versions-relation ordering when selecting a time range's
  immediate trailing reconstruction boundary.
- Limit automatic CI to pull requests and `main` pushes, and cancel superseded
  runs for the same pull request or ref.

### Fixed

- Supply TZInfo's timezone database to the test bundle so zoned-time coverage
  runs on Windows as well as systems with a native zoneinfo database.

## [0.2.0] - 2026-08-09

### Added

- Add deterministic `Diff#each_entry` and `Diff#each_change` traversal with
  immutable `TraversalEntry` values for renderers, counters, exports, and
  notifications.
- Add immutable version metadata and record references to activity boundaries.
- Give checkpoint `Step` objects `from_boundary` and `to_boundary` readers and
  give both timeline step types an `empty?` predicate.
- Add a Rails-focused quickstart with minimal endpoint, timeline, ignore, and
  association examples.
- Execute selected README and quickstart examples in isolated core and PT-AT
  test sessions so documented behavior cannot silently drift.

## [0.1.0] - 2026-08-09

### Added

- Add explicit, bounded nested association paths such as
  `comments.replies.author`.
- Add nested association changes to stable-record diffs and selected subtrees
  to added/removed record snapshots.
- Add path-aware ignore rules while preserving the existing global array form.
- Add root and nested `has_and_belongs_to_many` collection diffs, including
  historical membership, target updates, timelines, and bounded cyclic paths.
- Reload the configured PaperTrail versions association before resolving
  timeline boundaries.
- Rename the root `Diff#record` lifecycle field to the more explicit
  `Diff#record_presence_change`, including its `to_h` key.
- Add `activity_timeline` for adjacent root and selected-descendant version
  boundaries while preserving the root-only semantics of `timeline`.
- Add one-pass `analyze`, bounded association discovery, and structured history
  diagnostics.
- Bound version loads to the requested time range, stream timeline construction,
  and reuse immutable snapshot subtrees across adjacent boundaries.
- Apply event-local snapshot deltas for direct `has_many` membership changes at
  any selected depth and selected non-polymorphic `belongs_to` target events,
  with safe reconstruction fallbacks for other association shapes.
- Reconstruct post-create/update records from PaperTrail's serialized change
  pairs to avoid per-event successor and live-record lookups.
- Derive combined endpoint, root-timeline, and activity results from one
  snapshot pass; advance isolated root changes in place and selectively refresh
  only ambiguous association branches.
- Add `RecordReference`, consistent configuration error subclasses, traversal
  foreign-key suppression, and fail-loud HABTM endpoint validation.
- Fix selective `has_many :through` reconstruction by reifying the hidden
  through collection before resolving target records.
- Prepare timeline record states and association membership once per requested
  range, using indexed resolution for direct relationships, belongs-to-source
  through collections, and transaction-backed HABTM membership.
- Retain point-in-time PT-AT reconstruction as a per-reflection fallback for
  scoped, unversioned, composite-key, and unsupported through shapes.
- Keep multiple selected descendant events in one transaction atomic instead
  of applying an individual event delta before the transaction boundary.
