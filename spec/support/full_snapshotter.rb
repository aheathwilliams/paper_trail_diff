# frozen_string_literal: true

# A snapshotter that rebuilds every state from scratch, as a reference the
# providers' prepared and incremental snapshots must agree with. An activity
# build finds its events in the history `provider` prepares, as the
# provider's own builds do, but no snapshot here reads that history. A
# timeline build finds no events and needs no provider.
class FullSnapshotter
  def initialize(snapshotter, provider = nil)
    @snapshotter = snapshotter
    @provider = provider
  end

  def prepare(*args, **options)
    @prepared = @provider&.prepare(*args, **options)
    self
  end

  def call(*endpoints)
    @snapshotter.call(*endpoints)
  end

  def apply_transaction(root_endpoint, context_endpoint, *)
    call(root_endpoint, context_endpoint)
  end

  # The state before the event and the event itself are not needed.
  def refresh(root_endpoint, context_endpoint, *, **)
    @snapshotter.call(root_endpoint, context_endpoint)
  end

  def advance_root(root_endpoint, context_endpoint, *, **)
    @snapshotter.call(root_endpoint, context_endpoint)
  end

  def activity_index = @prepared.activity_index

  def history = @prepared.history

  def reading(open, &block) = @prepared.reading(open, &block)

  def transaction_ends(versions) = @prepared.transaction_ends(versions)
end
