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
    # Relation parts that choose rows, or order them, other than by the where
    # clause and the ranking the reader follows. Any other part, such as a
    # lock, a comment, a table named for a string order, or what to load,
    # leaves membership alone.
    ROW_CHOOSING_VALUES = %i[joins left_outer_joins from group having with
                             reverse_order].freeze
    BIND_PARAM = 'Arel::Nodes::BindParam'
    # Column kinds (ExactColumnType) whose values compare for equality in
    # Ruby as the database compares them.
    COMPARABLE_KINDS = %i[integer boolean text].freeze

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
      [reflection, *AssociationTraversal.through_parts(reflection)].any? do |part|
        part.polymorphic? ? !part.scope.nil? : scoped?(part)
      end
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

    # A relation's own where clause, default scope included, read as
    # conditions on stored attributes; nil when it cannot be. Its order,
    # limit, and offset choose a page of current rows rather than membership,
    # and loading or selecting columns changes neither, so they are left out.
    # A single-table subclass's type condition is left to the caller, as for
    # an association. `none` selects nothing, whatever it is chained to.
    #: (untyped, untyped) -> ScopeCondition?
    def self.for_relation(relation, model_class)
      return nothing if relation.null_relation?

      return unless plain_relation?(relation)

      clause = relation.where_clause - model_class.unscoped.where_clause
      check_recorded!(clause - model_class.default_scoped.where_clause, model_class)
      new(model_class, Reader.new(model_class).call(clause.ast))
    rescue Unreadable
      nil
    end

    # A destroyed record's state holds a column `has_paper_trail skip:`
    # leaves out of history only as its default. A default scope is read
    # with it so; a condition the caller wrote is refused.
    #: (untyped, untyped) -> void
    def self.check_recorded!(clause, model_class)
      return if clause.empty? || !model_class.respond_to?(:paper_trail_options)

      skip = model_class.paper_trail_options[:skip] #: Array[untyped]?
      skipped = Array(skip).map(&:to_s)
      Reader.new(model_class, refused: skipped).call(clause.ast)
    end
    private_class_method :check_recorded!

    # A relation `none` built, whose where clause is SQL text. A condition
    # that matches nothing reads no attribute, so it names no model.
    #: () -> ScopeCondition
    def self.nothing
      new(nil, [:or, []])
    end
    private_class_method :nothing

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
      AssociationTraversal.through_parts(reflection).any? { |part| ranked_part?(part) }
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
      relation.values.slice(*ROW_CHOOSING_VALUES).values.all? do |value|
        value.respond_to?(:empty?) ? value.empty? : !value
      end
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

    # Whether no record can match, as for a relation `none` built.
    #: () -> bool
    def none?
      operator, parts = @predicate
      operator == :or && parts.empty?
    end

    # The members among records that are each the owner's by key: those that
    # meet the conditions, then ranked.
    #: (Array[untyped]) -> Array[untyped]
    def members(records)
      rank(records.select { |record| matches?(record.attributes) })
    end

    # The one record a has_one reads of several that meet its conditions:
    # the first as ranked, or without an order of its own, the one with the
    # lowest primary key. Active Record reads an unordered has_one with
    # LIMIT 1, which SQLite, MySQL and SQL Server answer in key order for a
    # clustered or indexed key; reading any other row would differ from the
    # current record where nothing changed. PostgreSQL promises no order.
    #: (Array[untyped]) -> Array[untyped]
    def first(records)
      return records.first(1) if @ranking

      keys = Array(@model_class.primary_key)
      records.min_by(1) do |record|
        keys.map { |key| record.attributes.fetch(key) }
      end
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
      not_in: ->(value, expected) { !expected.include?(value) unless value.nil? },
      gt: ->(value, expected) { value > expected unless value.nil? },
      gteq: ->(value, expected) { value >= expected unless value.nil? },
      lt: ->(value, expected) { value < expected unless value.nil? },
      lteq: ->(value, expected) { value <= expected unless value.nil? }
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

    # The value the database compares and sorts by, as the scope's own
    # values were read (see ScopeRanking.sort_value): SQL Server holds a time
    # or date in a wrapper that only compares for equality, and history may
    # hold either as text.
    #: (String, Hash[String, untyped]) -> untyped
    def stored(name, attributes)
      ScopeRanking.sort_value(@model_class, name, attributes[name])
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
      #: (untyped, ?refused: Array[String]) -> void
      def initialize(model_class, refused: [])
        @model_class = model_class
        @refused = refused
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
        else range(node)
        end
      end

      RANGES = { 'Arel::Nodes::GreaterThan' => :gt, 'Arel::Nodes::GreaterThanOrEqual' => :gteq,
                 'Arel::Nodes::LessThan' => :lt, 'Arel::Nodes::LessThanOrEqual' => :lteq }.freeze
      private_constant :RANGES

      # A range, as `where(created_at: 1.day.ago..)` writes it, on a column
      # whose values sort in Ruby as the database sorts them.
      #: (untyped) -> Array[untyped]
      def range(node)
        name = node.class.name
        return between(node) if name == 'Arel::Nodes::Between'

        operator = RANGES[name] or raise Unreadable
        bound(operator, node.left, node.right)
      end

      #: (untyped) -> Array[untyped]
      def between(node)
        low, high = node.right.children
        [:and, [bound(:gteq, node.left, low), bound(:lteq, node.left, high)]]
      end

      #: (Symbol, untyped, untyped) -> Array[untyped]
      def bound(operator, attribute, node)
        name = column(attribute, null_test: true)
        boolean = :boolean.equal?(ExactColumnType.kind(@model_class, name))
        raise Unreadable unless ScopeRanking.orderable?(@model_class, name) && !boolean

        expected = value(node)
        raise Unreadable if expected.nil?

        [operator, name, sort_value(name, expected)]
      end

      # A bound in the form the database holds, read back as the value the
      # database sorts by. Reading it back unwraps what an adapter wraps.
      # SQLite keeps a time as text and compares a date with it as text, so
      # a date there is no midnight, and is left unread.
      #: (String, untyped) -> untyped
      def sort_value(name, stored)
        raise Unreadable if text_date?(name, stored)

        read = @model_class.type_for_attribute(name).deserialize(stored)
        ScopeRanking.sort_value(@model_class, name, read)
      end

      #: (String, untyped) -> bool
      def text_date?(name, stored)
        stored.instance_of?(Date) && :datetime.equal?(ExactColumnType.kind(@model_class, name)) &&
          @model_class.connection_db_config.adapter.to_s == 'sqlite3'
      end

      # Whether a value is NULL compares alike on every type.
      #: (Symbol, untyped) -> Array[untyped]
      def binary(operator, node)
        expected = value(node.right)
        return [operator, column(node.left, null_test: true)] if expected.nil?

        compared(operator, node.left, expected) { |name| sort_value(name, expected) }
      end

      #: (untyped) -> Array[untyped]
      def homogeneous_in(node)
        list(node.type == :in ? :in : :not_in, node.attribute, node.casted_values)
      end

      # Active Record writes an empty IN as a condition that is always false
      # and an empty NOT IN as one that is always true, for a NULL as for any
      # value, so neither is unknown under NOT. A NOT IN list holding NULL
      # matches no row.
      #: (Symbol, untyped, Array[untyped]) -> Array[untyped]
      def list(operator, attribute, expected)
        comparison = compared(operator, attribute, expected) do |name|
          expected.map { |item| sort_value(name, item) }
        end
        return [operator == :in ? :or : :and, []] if expected.empty?
        return comparison if operator == :in

        expected.include?(nil) ? [:or, []] : comparison
      end

      # A column that sorts in Ruby as in SQL (ScopeRanking) is compared as
      # the value it sorts by, which the block reads from the expected one: a
      # date, or a time history holds as it was stored, can be held as text.
      #: (Symbol, untyped, untyped) { (String) -> untyped } -> Array[untyped]
      def compared(operator, attribute, expected)
        name = ScopeRanking.own_column(attribute, @model_class)
        raise Unreadable if @refused.include?(name)

        if ScopeRanking.orderable?(@model_class, name)
          orderable = name #: String
          [operator, orderable, yield(orderable)]
        else
          [operator, column(attribute), expected]
        end
      end

      # Ruby comparison stands in for SQL only on the record's own column of
      # a type both compare alike (ExactColumnType). Whether a value is NULL,
      # any column's type compares alike.
      #: (untyped, ?null_test: bool) -> String
      def column(attribute, null_test: false)
        # Nil for anything but a column of the model's own table, which finds
        # no column below.
        name = ScopeRanking.own_column(attribute, @model_class) #: String
        exists = @model_class.columns_hash.key?(name)
        raise Unreadable unless exists && (null_test || comparable?(name))
        raise Unreadable if @refused.include?(name)

        name
      end

      #: (String) -> bool
      def comparable?(name)
        COMPARABLE_KINDS.include?(ExactColumnType.kind(@model_class, name))
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
