# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Query pieces shared by version lookups.
  module VersionQuery
    # Oldest first. Ids break ties between versions written in the same
    # instant, and the timestamp comes first because ids need not follow time:
    # a UUID key does not.
    #: (untyped) -> untyped
    def self.chronological(relation)
      relation.reorder(created_at: :asc, id: :asc)
    end

    # Every version of a model's items. They are read from the version class
    # rather than through the model's versions association, whose scope may
    # leave some out: a history replayed without them credits their changes to
    # the next version kept.
    #: (untyped) -> untyped
    def self.for_model(model_class)
      model_class.paper_trail.version_class.where(item_type: model_class.base_class.name)
    end

    # The versions of the given items, read the same way.
    #: (untyped, untyped) -> untyped
    def self.for_items(model_class, ids)
      for_model(model_class).where(item_id: ids)
    end

    # Keeps each item's earliest version among those the block also accepts:
    # no other version of the same item that the block accepts is earlier. A
    # correlated NOT EXISTS stays portable where window functions are not.
    #: (untyped) ?{ (untyped) -> untyped } -> untyped
    def self.no_earlier_version(table, &block)
      exists(table) { |other| earlier_version(table, other, &block) }.not
    end

    # Whether a version exists that the block's condition accepts. The block
    # is given the version table under a second name, beside `table`.
    #: (untyped) { (untyped) -> untyped } -> untyped
    def self.exists(table)
      other = other_versions(table)
      any(other, yield(other))
    end

    # Whether the item's versions say it was created after `time`: a create
    # saved after it that no version of the item precedes. An item with an
    # earlier version was there before, whatever created it again, and one
    # with no create may have been.
    #: (untyped, untyped, untyped, untyped) -> untyped
    def self.created_after(table, item_type, item_id, time)
      created = table.alias('paper_trail_diff_created_versions')
      item = created[:item_type].eq(item_type).and(created[:item_id].eq(item_id))
      any(created, item.and(first_create_after(table, created, time)))
    end

    #: (untyped, untyped, untyped) -> untyped
    def self.first_create_after(table, created, time)
      created[:event].eq('create').and(created[:created_at].gt(time))
                     .and(exists(table) { |other| earlier_version(created, other) }.not)
    end
    private_class_method :first_create_after

    #: (untyped, untyped) -> untyped
    def self.any(source, condition)
      Support.arel::SelectManager.new.from(source).project('1').where(condition).exists
    end
    private_class_method :any

    #: (untyped, untyped) ?{ (untyped) -> untyped } -> untyped
    def self.earlier_version(table, other)
      same_item = other[:item_type].eq(table[:item_type])
                                   .and(other[:item_id].eq(table[:item_id]))
                                   .and(other[:created_at].lt(table[:created_at]))
      block_given? ? same_item.and(yield(other)) : same_item
    end
    private_class_method :earlier_version

    # The version table under a second name, for a subquery over it. Any name
    # serves, and SQLite even accepts an empty one other databases refuse, so
    # no spec can tell the mutations apart.
    # mutant:disable
    #: (untyped) -> untyped
    def self.other_versions(table)
      table.alias('paper_trail_diff_other_versions')
    end
    private_class_method :other_versions
  end
end
