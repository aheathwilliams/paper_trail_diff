# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Arel conditions shared by the version queries that need one row per item.
  module VersionQuery
    module_function

    # Keeps each item's earliest version among those the block also accepts:
    # no other version of the same item that the block accepts is earlier. A
    # correlated NOT EXISTS stays portable where window functions are not.
    #: (untyped) ?{ (untyped) -> untyped } -> untyped
    def no_earlier_version(table, &block)
      arel = Object.const_get(:Arel) #: untyped
      earlier = table.alias('paper_trail_diff_earlier_versions')
      arel.const_get(:SelectManager).new
          .from(earlier)
          .project(arel.sql('1'))
          .where(earlier_version(table, earlier, &block))
          .exists
          .not
    end

    #: (untyped, untyped) ?{ (untyped) -> untyped } -> untyped
    def earlier_version(table, earlier)
      same_item = earlier[:item_type].eq(table[:item_type])
                                     .and(earlier[:item_id].eq(table[:item_id]))
                                     .and(earlier[:created_at].lt(table[:created_at]))
      block_given? ? same_item.and(yield(earlier)) : same_item
    end
    private_class_method :earlier_version
  end
end
