# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Internal activity boundary plus the selected root branches affected by its event.
  class ActivityEvent
    attr_reader :version #: untyped
    attr_reader :branches #: Array[String]?

    # The branches under which the version is of a through's join row, which
    # links the root to a target without being one. A record can be a join
    # row under one branch and a member of another.
    attr_reader :joins #: Array[String]

    #: (version: untyped, branches: Array[String]?, ?joins: Array[String]) -> void
    def initialize(version:, branches:, joins: [])
      @version = version
      @branches = (branches.uniq.sort.freeze if branches)
      @joins = joins.uniq.sort.freeze
      freeze
    end

    #: () -> bool
    def root?
      branches.nil?
    end
  end

  # Accumulates each version once while retaining every selected root branch.
  class ActivityEventRegistry
    def initialize
      @events = {} #: Hash[Array[untyped], Hash[Symbol, untyped]]
    end

    #: (Array[untyped], ?branch: String?, ?join: bool) -> void
    def add(versions, branch: nil, join: false)
      versions.each do |version|
        key = Support.row_key(version)
        existing = @events[key]
        joins = existing ? existing.fetch(:joins) : [] #: Array[String]
        @events[key] = {
          version: version,
          branches: merged_branches(existing, branch),
          joins: join && branch ? joins | [branch] : joins
        }
      end
    end

    #: () -> Array[ActivityEvent]
    def to_a
      @events.values.map do |event|
        ActivityEvent.new(
          version: event.fetch(:version),
          branches: event.fetch(:branches),
          joins: event.fetch(:joins)
        )
      end
    end

    private

    # @rbs @events: Hash[Array[untyped], Hash[Symbol, untyped]]

    #: (Hash[Symbol, untyped]?, String?) -> Array[String]?
    def merged_branches(existing, branch)
      return nil if branch.nil?
      return [branch] unless existing
      return nil if existing.fetch(:branches).nil?

      (existing.fetch(:branches) | [branch])
    end
  end

  # Resolves the branch union that PT-AT exposes atomically for one transaction.
  class ActivityTransactionGroups
    # A range ending at a version ends at the state before that version's
    # transaction: PT-AT rebuilds its associations without the changes saved
    # alongside it. A descendant version from that transaction, such as the
    # child update behind a `touch: true` parent version, is therefore past the
    # end. Kept, it would open a step whose change the closing state cannot
    # show, and that change would be reported nowhere. A range ending at a time
    # has no transaction to stop before.
    #: (Array[ActivityEvent], untyped) -> Array[ActivityEvent]
    def self.before_closing(events, range_end)
      key = transaction_key(range_end)
      return events unless key

      events.reject { |event| !event.root? && transaction_key(event.version) == key }.freeze
    end

    # Where the root's destruction takes effect, its tree is gone, so what a
    # transaction that ended later saved there is no change of the root's,
    # until the root is created again.
    #: (Array[ActivityEvent]) -> Array[ActivityEvent]
    def self.until_destroyed(events)
      gone = false
      events.reject do |event|
        gone = event.version.event == 'destroy' if event.root?
        gone && !event.root?
      end.freeze
    end

    # A version without a transaction shares one with nothing.
    #: (untyped) -> Array[untyped]?
    def self.transaction_key(version)
      transaction_id = VersionBoundary.transaction_id(version)
      [version.class.name, transaction_id] if transaction_id
    end

    #: (Array[ActivityEvent]) -> void
    def initialize(events)
      @groups = grouped_events(events)
      @branches = build_groups(@groups)
      @group_sizes = @groups.transform_values(&:length)
    end

    # The events of the event's transaction, in the order they are replayed.
    # The event is in a transaction with others.
    #: (ActivityEvent) -> Array[ActivityEvent]
    def events_for(event)
      @groups.fetch(transaction_key(event))
    end

    # An event outside a transaction, or in one it was not given, keeps its
    # own.
    #: (ActivityEvent) -> Array[String]?
    def branches_for(event)
      @branches.fetch(transaction_key(event)) { event.branches }
    end

    #: (ActivityEvent) -> bool
    def isolated?(event)
      key = transaction_key(event)
      !key || @group_sizes[key] == 1
    end

    # Whether two events were saved in one transaction.
    #: (ActivityEvent, ActivityEvent) -> bool
    def shared?(left, right)
      key = transaction_key(left)
      !key.nil? && key == transaction_key(right)
    end

    private

    # @rbs @groups: Hash[Array[untyped]?, Array[ActivityEvent]]
    # @rbs @branches: Hash[Array[untyped]?, Array[String]?]
    # @rbs @group_sizes: Hash[Array[untyped]?, Integer]

    #: (Hash[Array[untyped]?, Array[ActivityEvent]]) -> Hash[Array[untyped]?, Array[String]?]
    def build_groups(groups)
      groups.to_h do |key, selected_events|
        [key, group_branches(selected_events)]
      end
    end

    # The events of each transaction; one outside a transaction is in none.
    #: (Array[ActivityEvent]) -> Hash[Array[untyped]?, Array[ActivityEvent]]
    def grouped_events(events)
      events.group_by { |event| transaction_key(event) }.except(nil)
    end

    # A transaction with a root event is read as the root's; every other
    # event has branches.
    #: (Array[ActivityEvent]) -> Array[String]?
    def group_branches(events)
      return if events.any?(&:root?)

      branches = events.flat_map(&:branches) #: Array[String]
      branches.uniq.sort.freeze
    end

    #: (ActivityEvent) -> Array[untyped]?
    def transaction_key(event)
      self.class.transaction_key(event.version)
    end
  end
end
