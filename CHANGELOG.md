# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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
- Add `RecordReference`, consistent configuration error subclasses, traversal
  foreign-key suppression, and fail-loud HABTM endpoint validation.
- Fix selective `has_many :through` reconstruction by reifying the hidden
  through collection before resolving target records.

## [0.1.0] - 2026-08-07

- Initial development release.
