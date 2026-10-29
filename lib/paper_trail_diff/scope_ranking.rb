# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The order, offset and limit by which a scope picks its members from the
  # records that meet its conditions, as the database would rank them. It is
  # read only when the order is total and every key compares in Ruby as SQL
  # compares it; otherwise build returns nil and the caller keeps its slower
  # path.
  class ScopeRanking
    DIRECTIONS = { 'Arel::Nodes::Ascending' => false, 'Arel::Nodes::Descending' => true }.freeze
    ATTRIBUTE = 'Arel::Attributes::Attribute'
    ENUM_TYPE = 'ActiveRecord::Enum::EnumType'
    # Integers and booleans sort alike everywhere. Strings follow a collation
    # and times the precision each history kept, so neither is read.
    ORDER_TYPES = %w[ActiveModel::Type::Integer ActiveModel::Type::Boolean].freeze
    # Where each adapter sorts NULL in an ascending order by default; a
    # descending order reverses it. Another adapter's ranking is not read.
    NULLS_LAST = { 'postgresql' => true, 'sqlite3' => false, 'mysql2' => false,
                   'trilogy' => false, 'sqlserver' => false }.freeze
    # Places in a sort key, of which only the order counts: a value between a
    # NULL sorted first and one sorted last, and false before true.
    NULL_PLACE = { false => -1, true => 1 }.freeze
    VALUE_PLACE = 0
    BOOLEAN_VALUE = { false => 0, true => 1 }.freeze

    # Whether the relation picks members by rank rather than by condition
    # alone. A has_one takes the first record its order names.
    #: (untyped, untyped) -> bool
    def self.ranks?(relation, reflection)
      !relation.limit_value.nil? || !relation.offset_value.nil? ||
        (reflection.has_one? && !relation.order_values.empty?)
    end

    # Only a direct has_many or has_one is ranked per owner as its own query
    # ranks it. Returns nil when the ranking cannot be read exactly.
    #: (untyped, untyped, untyped) -> ScopeRanking?
    def self.build(relation, reflection, model_class)
      return unless direct?(reflection) && plain_offset?(relation)

      keys = keys(relation.order_values, model_class)
      return unless keys

      nulls_last = NULLS_LAST[model_class.connection_db_config.adapter]
      return if nulls_last.nil?

      new(model_class, keys, nulls_last, relation.limit_value, relation.offset_value)
    end

    #: (untyped) -> bool
    def self.direct?(reflection)
      %i[has_many has_one].include?(reflection.macro) && !reflection.through_reflection?
    end
    private_class_method :direct?

    # Active Record casts a limit to an integer but keeps an offset as given,
    # which may be a String or SQL.
    #: (untyped) -> bool
    def self.plain_offset?(relation)
      !relation.offset_value.is_a?(String)
    end
    private_class_method :plain_offset?

    # The order's keys up to the primary key, which makes it total. Keys
    # after it never decide anything.
    #: (Array[untyped], untyped) -> Array[[String, bool]]?
    def self.keys(nodes, model_class)
      names = nodes.map { |node| column(node, model_class) }
      total = names.index(model_class.primary_key)
      return unless total

      deciding = nodes.first(total + 1).zip(names)
      return unless deciding.all? { |_node, name| name }

      deciding.map do |node, name|
        column = name #: String
        [column, DIRECTIONS.fetch(node.class.name)]
      end
    end
    private_class_method :keys

    # The record's own column, sorted plainly in one direction.
    #: (untyped, untyped) -> String?
    def self.column(node, model_class)
      return unless DIRECTIONS.key?(node.class.name)

      attribute = node.expr
      return unless ATTRIBUTE.eql?(attribute.class.name)

      table = attribute.relation
      return unless table.name == model_class.table_name && table.table_alias.nil?

      name = attribute.name
      name if orderable?(model_class, name)
    end
    private_class_method :column

    #: (untyped, String) -> bool
    def self.orderable?(model_class, name)
      return false unless model_class.columns_hash.key?(name)

      type = model_class.type_for_attribute(name)
      type = type.subtype if ENUM_TYPE.eql?(type.class.name)
      ORDER_TYPES.intersect?(type.class.ancestors.map(&:name))
    end
    private_class_method :orderable?

    #: (untyped, Array[[String, bool]], bool, Integer?, Integer?) -> void
    def initialize(model_class, keys, nulls_last, limit, offset)
      @model_class = model_class
      @keys = keys
      @nulls_last = nulls_last
      @limit = limit
      @offset = offset
      freeze
    end

    # The members among records that met the scope's conditions, in order.
    #: (Array[untyped]) -> Array[untyped]
    def call(records)
      offset = @offset
      limit = @limit
      ranked = records.sort_by { |record| sort_key(record.attributes) }
      ranked = ranked.drop(offset) if offset
      limit ? ranked.first(limit) : ranked
    end

    private

    # @rbs @model_class: untyped
    # @rbs @keys: Array[[String, bool]]
    # @rbs @nulls_last: bool
    # @rbs @limit: Integer?
    # @rbs @offset: Integer?

    # Keys compare in turn, and the primary key always decides. A descending
    # key negates its places, which also moves NULL to the other end, as each
    # adapter does by default.
    #: (Hash[String, untyped]) -> Array[Array[Integer]]
    def sort_key(attributes)
      @keys.map do |name, descending|
        place = place(stored(name, attributes))
        descending ? place.map(&:-@) : place
      end
    end

    # NULL holds the adapter's place alone, so it never compares as a value.
    # A version saved before its column existed holds NULL there too.
    #: (untyped) -> Array[Integer]
    def place(value)
      return [NULL_PLACE.fetch(@nulls_last)] if value.nil?

      [VALUE_PLACE, BOOLEAN_VALUE.fetch(value, value)]
    end

    # The value the database sorts by, as the key's type casts it.
    #: (String, Hash[String, untyped]) -> untyped
    def stored(name, attributes)
      @model_class.type_for_attribute(name).serialize(attributes[name])
    end
  end
end
