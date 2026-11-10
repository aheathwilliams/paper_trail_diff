# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Tells apart transactions that share a number.
  #
  # PaperTrail numbers a transaction by the id of the first version it saved,
  # in whichever version table that was, and writes the number on every
  # version the transaction saves, in any table. Two tables count their ids
  # apart, so a transaction that began in one can take the number of another
  # that began elsewhere, and a table then holds versions of both under one
  # number. Read by number alone, a window that starts inside the later one
  # is read from where the earlier one began, which can be years before.
  #
  # The version a transaction saved first carries its own id as its number:
  # its anchor, saved when the transaction began. Two versions of one number
  # on either side of an instant belong to one transaction only when no
  # anchor of that number lies between either of them and the instant.
  #
  # Only the version classes loaded when a history is read are known, so one
  # that nothing has loaded yet is not consulted, nor is one in another
  # database, whose table a statement here cannot read. An anchor that was
  # pruned separates nothing, and two transactions of one number that ran at
  # the same time are not told apart.
  module TransactionAnchors
    # A condition on versions of `table` that keeps those no anchor separates
    # from the edge. Nothing when the model's version table is the only one,
    # where a number names one transaction.
    #: (untyped, TransactionCut::Edge, ?untyped) -> untyped
    def self.unbroken(version_class, edge, table = version_class.arel_table)
      classes = version_classes(version_class)
      return if classes.length < 2

      classes.each_with_index.map do |anchors, index|
        none(anchors, index, edge, table)
      end.reduce(:and)
    end

    # `relation` narrowed to the versions no anchor separates from the edge.
    #: (untyped, untyped, TransactionCut::Edge) -> untyped
    def self.scope(relation, version_class, edge)
      condition = unbroken(version_class, edge)
      condition ? relation.where(condition) : relation
    end

    # `relation` narrowed to the versions of the transactions that the
    # versions of these ids, saved after the edge, belong to: of a number's
    # versions before the edge, those of the transaction that went on to save
    # one of these.
    #: (untyped, untyped, TransactionCut::Edge, Array[untyped]) -> untyped
    def self.continued(relation, version_class, edge, ids)
      condition = unbroken(version_class, edge)
      return relation unless condition

      later = version_class.where(version_class.primary_key => ids).where(condition)
      relation.where(condition).where(transaction_id: later.select(:transaction_id))
    end

    # Those of the numbers that more than one transaction took: each the id
    # of the first version of a transaction in more than one version table.
    # None when the model's version table is the only one.
    #: (untyped, Array[untyped]) -> Array[untyped]
    def self.shared(version_class, numbers)
      classes = version_classes(version_class)
      return [] if classes.length < 2

      firsts = classes.flat_map { |anchors| first_ids(anchors, numbers) }
      firsts.tally.select { |_number, count| count > 1 }.keys
    end

    # The ids among these of the versions that began a transaction.
    #: (untyped, Array[untyped]) -> Array[untyped]
    def self.first_ids(anchors, numbers)
      key = anchors.primary_key
      table = anchors.arel_table
      anchors.where(key => numbers).where(table[key].eq(table[:transaction_id])).pluck(key)
    end
    private_class_method :first_ids

    # The version classes whose ids can number a transaction of this one's
    # versions, one for each table, in the order of their tables' names.
    #: (untyped) -> Array[untyped]
    def self.version_classes(version_class)
      type = version_class.type_for_attribute('transaction_id').type
      Support.constant('ActiveRecord::Base').descendants
             .select { |candidate| numbers?(candidate, version_class, type) }
             .uniq(&:table_name).sort_by(&:table_name)
    end
    private_class_method :version_classes

    # Whether the candidate's ids number transactions the version class can
    # read here: a version table in the same database, with ids of the type
    # the number is kept as.
    #: (untyped, untyped, untyped) -> bool
    def self.numbers?(candidate, version_class, type)
      candidate.include?(Support.constant('PaperTrail::VersionConcern')) &&
        !candidate.abstract_class? &&
        candidate.connection_db_config == version_class.connection_db_config &&
        candidate.table_exists? &&
        candidate.column_names.include?('transaction_id') &&
        candidate.primary_key.is_a?(String) &&
        candidate.type_for_attribute(candidate.primary_key).type == type
    end
    private_class_method :numbers?

    # No anchor of the version's number between the version and the edge:
    # none after a version saved before the edge and before the edge, and
    # none after the edge and up to a version saved after it, which the
    # version's own anchor is when its transaction began there.
    #: (untyped, Integer, TransactionCut::Edge, untyped) -> untyped
    def self.none(anchors, index, edge, table)
      anchor = anchors.arel_table.alias("paper_trail_diff_anchors_#{index}")
      separating = numbering(anchor, anchors.primary_key, table)
                   .and(between(anchor[:created_at], table[:created_at], edge))
      Support.arel::SelectManager.new(anchor).project(Support.arel.sql('1'))
                                 .where(separating).exists.not
    end
    private_class_method :none

    # A version that carries its own id as its number, which is the number
    # of the version of `table`.
    #: (untyped, String, untyped) -> untyped
    def self.numbering(anchor, primary_key, table)
      id = anchor[primary_key]
      id.eq(table[:transaction_id]).and(anchor[:transaction_id].eq(id))
    end
    private_class_method :numbering

    # An anchor saved after the version and before the edge, or after the
    # edge and no later than the version.
    #: (untyped, untyped, TransactionCut::Edge) -> untyped
    def self.between(anchor_at, version_at, edge)
      anchor_at.gt(version_at).and(edge.left(anchor_at))
               .or(edge.right(anchor_at).and(anchor_at.lteq(version_at)))
    end
    private_class_method :between
  end
end
