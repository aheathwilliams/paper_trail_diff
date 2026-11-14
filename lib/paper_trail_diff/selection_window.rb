# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # A window that selects records by activity, widened to where the earliest
  # transaction open at its start began, as its history is read (see
  # AssociationTraversal#reach_before). Associations are followed over all of
  # it, but before the start only the versions of the transactions open there
  # select a record: the window reports those transactions, and none of the
  # others, which ended before it.
  class SelectionWindow < TimeRange
    #: (TimeRange, untyped) -> void
    def initialize(window, reach)
      @window = window
      super(window.widened(reach).to_range, digits: window.digits)
    end

    #: (untyped) -> untyped
    def scope(relation)
      in_window = @window.scope(relation)
      version_class = relation.klass
      return in_window unless version_class.column_names.include?('transaction_id')

      key = version_class.primary_key
      crossing = CrossingTransactions.saved_before(version_class, @window.begin_time)
      saved = { key => crossing.select(key) } #: Hash[untyped, untyped]
      in_window.or(relation.where(saved))
    end

    # @rbs @window: TimeRange
  end
end
