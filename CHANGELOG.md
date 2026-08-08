# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- Add explicit, bounded nested association paths such as
  `comments.replies.author`.
- Add nested association changes to stable-record diffs and selected subtrees
  to added/removed record snapshots.
- Add path-aware ignore rules while preserving the existing global array form.
- Rename the root `Diff#record` lifecycle field to the more explicit
  `Diff#record_presence_change`, including its `to_h` key.

## [0.1.0] - 2026-08-07

- Initial development release.
