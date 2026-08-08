# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Internal activity boundary plus the selected root branches affected by its event.
  class ActivityEvent
    attr_reader :version #: untyped
    attr_reader :branches #: Array[String]?

    #: (version: untyped, branches: Array[String]?) -> void
    def initialize(version:, branches:)
      @version = version
      @branches = branches ? branches.map(&:to_s).uniq.sort.freeze : nil
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

    #: (Array[untyped], ?branch: String?) -> void
    def add(versions, branch: nil)
      versions.each do |version|
        key = [version.class.name, version.id]
        existing = @events[key]
        @events[key] = {
          version: version,
          branches: merged_branches(existing, branch)
        }
      end
    end

    #: () -> Array[ActivityEvent]
    def to_a
      @events.values.map do |event|
        ActivityEvent.new(
          version: event.fetch(:version),
          branches: event.fetch(:branches)
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
    #: (Array[ActivityEvent]) -> void
    def initialize(events)
      @branches = build_groups(events)
    end

    #: (ActivityEvent) -> Array[String]?
    def branches_for(event)
      key = transaction_key(event)
      return event.branches unless key && @branches.key?(key)

      @branches[key]
    end

    private

    # @rbs @branches: Hash[Array[untyped], Array[String]?]

    #: (Array[ActivityEvent]) -> Hash[Array[untyped], Array[String]?]
    def build_groups(events)
      grouped_events(events).to_h do |key, selected_events|
        [key, group_branches(selected_events)]
      end
    end

    #: (Array[ActivityEvent]) -> Hash[Array[untyped], Array[ActivityEvent]]
    def grouped_events(events)
      groups = {} #: Hash[Array[untyped], Array[ActivityEvent]]
      events.each do |event|
        key = transaction_key(event)
        next unless key

        groups[key] ||= [] #: Array[ActivityEvent]
        groups[key] << event
      end
      groups
    end

    #: (Array[ActivityEvent]) -> Array[String]?
    def group_branches(events)
      return if events.any?(&:root?)

      events.flat_map { |event| event.branches || [] }.uniq.sort.freeze
    end

    #: (ActivityEvent) -> Array[untyped]?
    def transaction_key(event)
      version = event.version
      return unless version.respond_to?(:transaction_id) && version.transaction_id

      [version.class.name, version.transaction_id]
    end
  end
end
