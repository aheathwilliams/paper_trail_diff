# frozen_string_literal: true

# A snapshotter that rebuilds every state from scratch, as a reference the
# providers' prepared and incremental paths must agree with. It prepares
# nothing and keeps no activity index.
class FullSnapshotter
  def initialize(snapshotter)
    @snapshotter = snapshotter
  end

  def prepare(*, **); end

  def call(*endpoints)
    @snapshotter.call(*endpoints)
  end

  # The state before the event and the event itself are not needed.
  def refresh(root_endpoint, context_endpoint, *, **)
    @snapshotter.call(root_endpoint, context_endpoint)
  end

  def advance_root(root_endpoint, context_endpoint, *, **)
    @snapshotter.call(root_endpoint, context_endpoint)
  end

  def activity_index; end
end
