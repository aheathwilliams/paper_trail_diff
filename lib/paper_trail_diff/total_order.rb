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
    # Server rejects a column listed twice. A relation answers for its model
    # the key and table name read here.
    #: (untyped) -> untyped
    def self.apply(relation)
      return relation if relation.order_values.any? { |order| key?(order, relation) }

      relation.order(relation.primary_key => :asc)
    end

    # An Arel order names its column; SQL text is read by key_in_sql?.
    #: (untyped, untyped) -> bool
    def self.key?(order, relation)
      order = order.expr if ScopeRanking::DIRECTIONS.key?(order.class.name)
      return key_in_sql?(order, relation) if order.is_a?(String)

      relation.primary_key.eql?(ScopeRanking.own_column(order, relation))
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
