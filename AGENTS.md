# Repository guide

## Purpose and architecture

`paper_trail_diff` adds structured endpoint and timeline diffing to PaperTrail.
PaperTrail integration must normalize reified records into immutable snapshot
objects before the comparison engine runs. The engine must remain independent
of ActiveRecord and PaperTrail.

Association tracking is optional. Never add
`paper_trail-association_tracking` as a runtime dependency or require it from
the library entrypoint. Association support is first-level only.

Keep the public API small and explicit. Return value objects and hashes, never
formatted diff text.

## Ruby and style

- Maintain compatibility with Ruby 3.1 and newer.
- Use frozen-string-literal headers and the repository RuboCop configuration.
- Inline RBS comments in `lib/` are the source of truth. Regenerate committed
  signatures with `rake rbs`; never hand-edit `sig/generated/`.
- Preserve deterministic ordering and immutable public result objects.

## Commands

Run Ruby and package commands through mise in non-interactive shells:

```console
mise exec -- bundle install
mise exec -- bundle exec rake spec_core
mise exec -- bundle exec rake spec_associations
mise exec -- bundle exec rake rubocop
mise exec -- bundle exec rake typecheck
mise exec -- bundle exec rake
mise exec -- bundle exec rake build
```

If mise reports that the project is untrusted, run `mise trust`. If a pinned
tool is missing, run `mise install`.

