# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Query pieces shared by version lookups.
  module VersionQuery
    module_function

    # Oldest first. Ids break ties between versions written in the same
    # instant, and the timestamp comes first because ids need not follow time:
    # a UUID key does not.
    #: (untyped) -> untyped
    def chronological(relation)
      relation.reorder(created_at: :asc, id: :asc)
    end

    # Every version of a model's items. They are read from the version class
    # rather than through the model's versions association, whose scope may
    # leave some out: a history replayed without them credits their changes to
    # the next version kept.
    #: (untyped) -> untyped
    def for_model(model_class)
      model_class.paper_trail.version_class.where(item_type: model_class.base_class.name)
    end

    # The versions of the given items, read the same way.
    #: (untyped, untyped) -> untyped
    def for_items(model_class, ids)
      for_model(model_class).where(item_id: ids)
    end

    # Keeps each item's earliest version among those the block also accepts:
    # no other version of the same item that the block accepts is earlier. A
    # correlated NOT EXISTS stays portable where window functions are not.
    #: (untyped) ?{ (untyped) -> untyped } -> untyped
    def no_earlier_version(table, &block)
      no_nearer_version(table, later: true, &block)
    end

    # The same for either side of an instant: each item's earliest version
    # when the versions lie after it, and its latest when they lie before.
    #: (untyped, later: bool) ?{ (untyped) -> untyped } -> untyped
    def no_nearer_version(table, later:, &block)
      arel = Object.const_get(:Arel) #: untyped
      other = table.alias('paper_trail_diff_earlier_versions')
      arel.const_get(:SelectManager).new
          .from(other)
          .project(arel.sql('1'))
          .where(nearer_version(table, other, later: later, &block))
          .exists
          .not
    end

    #: (untyped, untyped, later: bool) ?{ (untyped) -> untyped } -> untyped
    def nearer_version(table, other, later:)
      created_at = other[:created_at]
      nearer = later ? created_at.lt(table[:created_at]) : created_at.gt(table[:created_at])
      same_item = other[:item_type].eq(table[:item_type])
                                   .and(other[:item_id].eq(table[:item_id]))
                                   .and(nearer)
      block_given? ? same_item.and(yield(other)) : same_item
    end
    private_class_method :nearer_version
  end
end
