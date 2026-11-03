# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The children each owner of a has_many or has_one had from a history's
  # start onward, and has now, read once for each owner across the history
  # (see ActivityChildCandidateLoader). Preparation reads them for the owners
  # it loads, and activity then finds them here.
  class PreparedChildCandidates
    # What one class's association has read: the rows recorded under each
    # owner and its live children's ids, by the owner's id.
    class Read
      attr_reader :historical #: Hash[String, Array[Array[untyped]]]
      attr_reader :live #: Hash[String, Array[untyped]]

      #: () -> void
      def initialize
        @historical = {}
        @live = {}
        @owners = Set.new #: Set[String]
      end

      #: (Array[untyped]) -> Array[untyped]
      def unread(ids)
        ids.reject { |id| @owners.include?(id.to_s) }
      end

      #: (Array[untyped], ActivityChildCandidateLoader) -> void
      def add(owners, loader)
        loader.historical_rows.each { |row| (@historical[row.first.to_s] ||= []) << row }
        loader.current_pairs.each { |owner, child| (@live[owner.to_s] ||= []) << child }
        owners.each { |id| @owners << id.to_s }
      end
    end

    #: (untyped) -> void
    def initialize(start_at)
      @start_at = start_at
      @read = {} #: Hash[Array[untyped], Read]
    end

    # The owners not read yet are read in one statement, with the others the
    # block names, so that owners asked about later need none. Each owner
    # class reads its own, as a polymorphic row can store the class's name.
    #: (untyped, Array[untyped], untyped) ?{ () -> Array[untyped] } -> [Hash[String, Array[Array[untyped]]], Hash[String, Array[untyped]]]
    def call(model, ids, reflection)
      read = @read[[model, reflection]] ||= Read.new
      unless read.unread(ids).empty?
        owners = read.unread(block_given? ? yield | ids : ids)
        read.add(owners, ActivityChildCandidateLoader.new(model, owners, reflection, @start_at))
      end
      [read.historical, read.live]
    end

    # @rbs @start_at: untyped
    # @rbs @read: Hash[Array[untyped], Read]
  end
end
