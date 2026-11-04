# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # A relation's order, completed by its primary key. Reading a relation by
  # offset holds only under a total order: a database may return rows that tie
  # in a different order for each query, so that pages read some records twice
  # and others never.
  module TotalOrder
    # The relation sorted by its key after its own order, unless that order
    # already sorts by the key. Such an order is kept as given, since SQL
    # Server rejects a column listed twice. So is the order of a relation
    # grouped by anything but the key: each of its rows is a group, which a
    # database sorts only by what it groups or aggregates. A relation answers
    # for its model the key and table name read here.
    #: (untyped) -> untyped
    def self.apply(relation)
      orders = relation.order_values
      return relation if orders.any? { |order| key?(order, relation) }
      return relation if !orders.empty? && grouped_by_other?(relation)

      relation.order(relation.primary_key => :asc)
    end

    #: (untyped) -> bool
    def self.grouped_by_other?(relation)
      groups = relation.group_values
      !groups.empty? && groups.none? { |group| key?(group, relation) }
    end
    private_class_method :grouped_by_other?

    # An Arel order or group names its column; SQL text, or the name a group
    # may be given as, is read by key_in_sql?.
    #: (untyped, untyped) -> bool
    def self.key?(term, relation)
      term = term.expr if ScopeRanking::DIRECTIONS.key?(term.class.name)
      return key_in_sql?(term.to_s, relation) if term.is_a?(String) || term.instance_of?(Symbol)

      relation.primary_key.eql?(ScopeRanking.own_column(term, relation))
    end
    private_class_method :key?

    # Whether SQL text names the key, alone or after its table's name. That
    # also finds a key the text only uses, as in `LENGTH(id)`, which then goes
    # without the tie-breaker, but it misses no sort by the key.
    #: (String, untyped) -> bool
    def self.key_in_sql?(sql, relation)
      names = sql.scan(/(?:(\w+)\.)?(\w+)/) #: Array[[String?, String]]
      names.any? do |table, column|
        column.casecmp?(relation.primary_key) && (table.nil? || table.casecmp?(relation.table_name))
      end
    end
    private_class_method :key_in_sql?
  end
end
