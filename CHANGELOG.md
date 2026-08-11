# Changelog

All notable changes to this project will be documented in this file. The
project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
