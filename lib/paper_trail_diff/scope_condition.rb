# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # An association scope, or its target's default scope, read as conditions
  # on stored attributes, so membership at a boundary can be decided from each
  # record's state there rather than by a query. A limit, offset or has_one
  # order then ranks the records that meet the conditions (ScopeRanking). It
  # reads the relation the scope builds once and never runs application code
  # per record. A scope it cannot read exactly builds no condition, and the
  # caller keeps its slower path.
  class ScopeCondition
    # Relation parts that leave membership to the where clause and the
    # ranking alone.
    RELATION_VALUES = %i[where order reordering limit offset readonly strict_loading
                         extending].freeze
    # Types whose stored values compare in Ruby as the database compares them,
    # named rather than referenced so that loading needs no Active Model.
    VALUE_TYPES = %w[ActiveModel::Type::Integer ActiveModel::Type::Boolean
                     ActiveModel::Type::ImmutableString].freeze
    TEXT_TYPE = 'ActiveModel::Type::ImmutableString'
    ENUM_TYPE = 'ActiveRecord::Enum::EnumType'
    BIND_PARAM = 'Arel::Nodes::BindParam'
    ATTRIBUTE = 'Arel::Attributes::Attribute'
    # Adapters that compare strings exactly by default. MySQL and SQL Server
    # ignore case and trailing spaces by default, which Ruby cannot follow.
    EXACT_TEXT_ADAPTERS = %w[sqlite3 postgresql].freeze

    # Raised while reading a node that has no exact plain-Ruby reading.
    class Unreadable < StandardError; end
    private_constant :Unreadable

    # Whether the reflection filters its target beyond its keys at all.
    #: (untyped) -> bool
    def self.scoped?(reflection)
      !reflection.scope.nil? || reflection.klass.default_scopes?
    end

    # A through also filters by the scopes of each reflection it passes.
    #: (untyped) -> bool
    def self.scoped_path?(reflection)
      return !reflection.scope.nil? if reflection.polymorphic?
      return true if scoped?(reflection)
      return false unless reflection.through_reflection?

      scoped_path?(reflection.through_reflection) || scoped_path?(reflection.source_reflection)
    end

    # Returns nil when the scope cannot be read as plain conditions and an
    # exact ranking. A part of a has_many through is read unranked: the
    # through's query keeps only its conditions.
    #: (untyped, ?untyped, ?ranked: bool) -> ScopeCondition?
    def self.build(reflection, model_class = reflection.klass, ranked: true)
      return if ranked && ranked_through?(reflection)

      relation = scoped_relation(reflection, model_class)
      return unless relation && plain_relation?(relation)

      clause = relation.where_clause - model_class.unscoped.where_clause
      predicate = Reader.new(model_class).call(clause.ast)
      new(model_class, predicate, (ranking(relation, reflection, model_class) if ranked))
    rescue Unreadable
      nil
    end

    # nil when the relation picks its members by conditions alone.
    #: (untyped, untyped, untyped) -> ScopeRanking?
    def self.ranking(relation, reflection, model_class)
      return unless ScopeRanking.ranks?(relation, reflection)

      ScopeRanking.build(relation, reflection, model_class) || raise(Unreadable)
    end
    private_class_method :ranking

    # A has_one through orders its rows by its own order and then its parts',
    # and takes the first, so one that passes a ranked part is not read. A
    # has_many through keeps only its parts' conditions.
    #: (untyped) -> bool
    def self.ranked_through?(reflection)
      return false if reflection.collection?

      ranked_parts?(reflection)
    end

    # Whether any part of a through, at any depth, has a limit, an offset or
    # a has_one order.
    #: (untyped) -> bool
    def self.ranked_parts?(reflection)
      return false unless reflection.through_reflection?

      [reflection.through_reflection, reflection.source_reflection].any? do |part|
        ranked_part?(part) || ranked_parts?(part)
      end
    end

    # A polymorphic part's class, and so its scope, is known only per record.
    #: (untyped) -> bool
    def self.ranked_part?(part)
      return false if part.polymorphic?

      relation = scoped_relation(part, part.klass)
      !relation.nil? && ScopeRanking.ranks?(relation, part)
    end
    private_class_method :ranked_part?

    # A scope that takes the owner differs per record, so it is never read.
    #: (untyped, untyped) -> untyped
    def self.scoped_relation(reflection, model_class)
      scope = reflection.scope
      relation = model_class.default_scoped
      return relation unless scope
      return unless scope.arity.zero?

      reflection.scope_for(relation)
    end
    private_class_method :scoped_relation

    # Some parts, such as the having clause `or` sets, may be present but
    # empty.
    #: (untyped) -> bool
    def self.plain_relation?(relation)
      extra = relation.values.except(*RELATION_VALUES).values
      extra.all? { |value| value.respond_to?(:empty?) && value.empty? }
    end
    private_class_method :plain_relation?

    #: (untyped, Array[untyped], ?ScopeRanking?) -> void
    def initialize(model_class, predicate, ranking = nil)
      @model_class = model_class
      @predicate = predicate
      @ranking = ranking
      freeze
    end

    # SQL admits a row only when its condition is true, not when it is
    # unknown.
    #: (Hash[String, untyped]) -> bool
    def matches?(attributes)
      evaluate(@predicate, attributes) == true
    end

    # The members among records that are each the owner's by key: those that
    # meet the conditions, then ranked.
    #: (Array[untyped]) -> Array[untyped]
    def members(records)
      rank(records.select { |record| matches?(record.attributes) })
    end

    # Records that meet the conditions, as ranked; unchanged without a
    # ranking.
    #: (Array[untyped]) -> Array[untyped]
    def rank(records)
      ranking = @ranking
      ranking ? ranking.call(records) : records
    end

    # SQL's three values: a comparison with NULL is unknown (nil) rather than
    # false, except an IS NULL or IS NOT NULL test, an equality with nil, which
    # is always known. Unknown matters only under NOT, which leaves it
    # unknown where false would become true.
    COMPARISONS = {
      eq: ->(value, expected) { expected.nil? || !value.nil? ? value == expected : nil },
      not_eq: ->(value, expected) { expected.nil? || !value.nil? ? value != expected : nil },
      in: ->(value, expected) { expected.include?(value) unless value.nil? },
      not_in: ->(value, expected) { !expected.include?(value) unless value.nil? }
    }.freeze
    private_constant :COMPARISONS

    private

    # @rbs @model_class: untyped
    # @rbs @predicate: Array[untyped]
    # @rbs @ranking: ScopeRanking?

    # true, false, or nil for unknown.
    #: (Array[untyped], Hash[String, untyped]) -> bool?
    def evaluate(predicate, attributes)
      operator, first, second = predicate
      case operator
      when :and then all(first.map { |part| evaluate(part, attributes) })
      when :or then any(first.map { |part| evaluate(part, attributes) })
      when :not then negate(evaluate(first, attributes))
      else COMPARISONS.fetch(operator).call(stored(first, attributes), second)
      end
    end

    # False if any part is, otherwise unknown if any part is.
    #: (Array[bool?]) -> bool?
    def all(values)
      return false if values.include?(false)

      true unless values.include?(nil)
    end

    # True if any part is, otherwise unknown if any part is.
    #: (Array[bool?]) -> bool?
    def any(values)
      return true if values.include?(true)

      false unless values.include?(nil)
    end

    #: (bool?) -> bool?
    def negate(value)
      !value unless value.nil?
    end

    # The form the database holds, as the scope's own values were cast.
    #: (String, Hash[String, untyped]) -> untyped
    def stored(name, attributes)
      @model_class.type_for_attribute(name).serialize(attributes[name])
    end

    # Builds each reflection's condition once per target class.
    class Cache
      #: () -> void
      def initialize
        @conditions = {} #: Hash[Array[untyped], ScopeCondition?]
      end

      # nil when the scope cannot be read from stored attributes.
      #: (untyped, ?untyped, ?ranked: bool) -> ScopeCondition?
      def call(reflection, model_class = reflection.klass, ranked: true)
        key = [reflection, model_class, ranked]
        return @conditions.fetch(key) if @conditions.key?(key)

        @conditions[key] = ScopeCondition.build(reflection, model_class, ranked: ranked)
      end

      # The records the reflection's scope admits, as it ranks them. Its
      # condition must exist.
      #: (untyped, Array[untyped], ?untyped, ranked: bool) -> Array[untyped]
      def select(reflection, records, model_class = reflection.klass, ranked:)
        condition = call(reflection, model_class, ranked: ranked) #: ScopeCondition
        condition.members(records)
      end

      # @rbs @conditions: Hash[Array[untyped], ScopeCondition?]
    end

    # Compiles a where clause into nested arrays of plain comparisons.
    class Reader
      #: (untyped) -> void
      def initialize(model_class)
        @model_class = model_class
      end

      #: (untyped) -> Array[untyped]
      def call(node)
        case node.class.name
        when 'Arel::Nodes::And' then [:and, node.children.map { |child| call(child) }]
        when 'Arel::Nodes::Or' then [:or, either(node).map { |child| call(child) }]
        when 'Arel::Nodes::Grouping' then call(node.expr)
        when 'Arel::Nodes::Not' then [:not, call(node.expr)]
        else comparison(node)
        end
      end

      private

      # @rbs @model_class: untyped

      # An Or is binary before Rails 7.2 and n-ary from it.
      #: (untyped) -> Array[untyped]
      def either(node)
        node.respond_to?(:children) ? node.children : [node.left, node.right]
      end

      #: (untyped) -> Array[untyped]
      def comparison(node)
        case node.class.name
        when 'Arel::Nodes::Equality' then binary(:eq, node)
        when 'Arel::Nodes::NotEqual' then binary(:not_eq, node)
        when 'Arel::Nodes::HomogeneousIn' then homogeneous_in(node)
        when 'Arel::Nodes::In' then list(:in, node.left, values(node.right))
        when 'Arel::Nodes::NotIn' then list(:not_in, node.left, values(node.right))
        else raise Unreadable
        end
      end

      # Whether a value is NULL compares alike on every type.
      #: (Symbol, untyped) -> Array[untyped]
      def binary(operator, node)
        expected = value(node.right)
        [operator, column(node.left, null_test: expected.nil?), expected]
      end

      #: (untyped) -> Array[untyped]
      def homogeneous_in(node)
        list(node.type == :in ? :in : :not_in, node.attribute, node.casted_values)
      end

      # Active Record writes an empty NOT IN as a condition that is always
      # true, and a NOT IN list holding NULL matches no row.
      #: (Symbol, untyped, Array[untyped]) -> Array[untyped]
      def list(operator, attribute, expected)
        name = column(attribute)
        return [operator, name, expected] if operator == :in
        return [:and, []] if expected.empty?

        expected.include?(nil) ? [:or, []] : [operator, name, expected]
      end

      # Ruby comparison stands in for SQL only on the record's own column of
      # a type both compare alike. Whether a value is NULL, any column's
      # type compares alike.
      #: (untyped, ?null_test: bool) -> String
      def column(attribute, null_test: false)
        raise Unreadable unless ATTRIBUTE.eql?(attribute.class.name)

        table = attribute.relation
        raise Unreadable unless table.name == @model_class.table_name && table.table_alias.nil?

        name = attribute.name
        column = @model_class.columns_hash[name]
        raise Unreadable unless column && (null_test || comparable?(name, column))

        name
      end

      #: (String, untyped) -> bool
      def comparable?(name, column)
        kinds = value_type(@model_class.type_for_attribute(name)).class.ancestors.map(&:name)
        return false unless VALUE_TYPES.intersect?(kinds)

        !kinds.include?(TEXT_TYPE) || exact_text?(column)
      end

      # PostgreSQL's citext is text that compares without regard to case.
      #: (untyped) -> bool
      def exact_text?(column)
        EXACT_TEXT_ADAPTERS.include?(@model_class.connection_db_config.adapter) &&
          column.collation.nil? && !column.sql_type.casecmp?('citext')
      end

      # An enum compares the values it stores, which its subtype describes. A
      # wrapper such as a serialized or encrypted type is none of these.
      #: (untyped) -> untyped
      def value_type(type)
        ENUM_TYPE.eql?(type.class.name) ? type.subtype : type
      end

      # A list that is not plain values, such as a subquery, is unreadable.
      #: (untyped) -> Array[untyped]
      def values(nodes)
        raise Unreadable unless nodes.instance_of?(Array)

        nodes.map { |node| value(node) }
      end

      # A value out of the column's range makes Active Record write a
      # constant condition instead, so it is left unread. Active Record
      # writes IS NULL for a value that is nil before casting, but `= NULL`,
      # which matches nothing, for one that only casts to nil.
      #: (untyped) -> untyped
      def value(node)
        node = node.value if BIND_PARAM.eql?(node.class.name)
        raise Unreadable unless node.respond_to?(:value_for_database)
        raise Unreadable if node.respond_to?(:unboundable?) && node.unboundable?
        return if node.nil?

        node.value_for_database.tap { |value| raise Unreadable if value.nil? }
      end
    end
    private_constant :Reader
  end
end
