# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Internal helpers for isolating and serializing values held by result objects.
  module Support # rubocop:disable Metrics/ModuleLength
    # Ids per statement, for the queries that list them in slices. SQL Server
    # compiles every statement afresh, since its ids are written into it, in
    # time that grows with their number; fewer statements than this cost more
    # than they save.
    IDS_PER_STATEMENT = 500

    # PaperTrail's YAML serializer stores a `time` column's value as this
    # wrapper, which PaperTrail 16 and 17 decode by reading its `@time`. Only
    # some zone-aware times are stored with one, as a TimeWithZone's fields
    # under the wrapper's tag; any other wraps its time, and decodes as nil.
    TIME_VALUE = 'ActiveRecord::Type::Time::Value'

    # Answers a question about `value` once for each Active Record class, in
    # `answers`: its respond_to? also looks through the instance's attributes,
    # which costs more than most of what reading a version does, and every
    # instance of a model answers alike, since this gem reads versions with
    # all their columns. Anything else is asked each time.
    #: [T] (Hash[untyped, T], untyped) { (untyped) -> T } -> T
    def self.per_model(answers, value)
      model = value.class
      return yield(value) unless model.respond_to?(:column_names)

      answers.fetch(model) { answers[model] = yield(value) }
    end

    # Stored attributes or changes ready for PaperTrail to decode: keyed by
    # name, with each time of day unwrapped, which then decodes as any value
    # does. A change's values are a pair.
    #: (Hash[untyped, untyped]) -> Hash[String, untyped]
    def self.decodable(stored)
      stored.to_h { |name, value| [name.to_s, unwrapped_time(value)] }
    end

    #: (untyped) -> untyped
    def self.unwrapped_time(value)
      return value.map { |item| unwrapped_time(item) } if value.instance_of?(Array)

      TIME_VALUE.eql?(value.class.name) ? recorded_time(value) : value
    end
    private_class_method :unwrapped_time

    # The time a stored wrapper holds: the one it wraps, or the `@time`
    # PaperTrail reads.
    #: (untyped) -> untyped
    def self.recorded_time(value)
      value.__getobj__ { value.instance_variable_get(:@time) }
    end
    private_class_method :recorded_time

    # PaperTrail's `reify`, with each time of day its version recorded.
    #: (untyped, **untyped) -> untyped
    def self.reify(version, **options)
      with_recorded_times(version.reify(**options))
    end

    # A record PaperTrail rebuilt, with each time of day assigned from the
    # version it was rebuilt from, which PaperTrail can decode as nil. PaperTrail
    # assigns stored attributes after building the record and links it to
    # that version, PT-AT's members too, so this assigns what PaperTrail would
    # if it unwrapped the value. Only a version whose stored text names the
    # wrapper is decoded again; any other record is returned as it is.
    #: [T] (T) -> T
    def self.with_recorded_times(record)
      version = rebuilt_from(record)
      return record unless version

      version.object_deserialized.each do |name, value|
        next unless TIME_VALUE.eql?(value.class.name)

        assign_recorded(record, name, recorded_time(value))
      end
      record
    end

    #: (untyped) -> untyped
    def self.rebuilt_from(record)
      model = record.class
      return unless model.respond_to?(:version_association_name)

      version = record.public_send(model.version_association_name)
      # A JSON column's Hash is keyed by attribute names, never this one.
      version if version&.object&.include?(TIME_VALUE)
    end
    private_class_method :rebuilt_from

    # As PaperTrail assigns a stored attribute.
    #: (untyped, String, untyped) -> void
    def self.assign_recorded(record, name, value)
      if record.has_attribute?(name)
        record[name.to_sym] = value
      elsif record.respond_to?(:"#{name}=")
        record.public_send(:"#{name}=", value)
      end
    end
    private_class_method :assign_recorded

    #: (untyped) -> untyped
    def self.immutable_copy(value)
      case value
      when Hash
        immutable_hash(value)
      when Array
        value.map { |item| immutable_copy(item) }.freeze
      else
        value.frozen? ? value : duplicate_and_freeze(value)
      end
    end

    #: (Hash[untyped, untyped]) -> Hash[untyped, untyped]
    def self.immutable_hash(value)
      copy = {} #: Hash[untyped, untyped]
      value.each do |key, item|
        copy[immutable_copy(key)] = immutable_copy(item)
      end
      copy.freeze
    end
    private_class_method :immutable_hash

    #: (untyped) -> untyped
    def self.serialize(value)
      case value
      when Hash
        serialized = {} #: Hash[untyped, untyped]
        value.each do |key, item|
          serialized[key] = serialize(item)
        end
        serialized
      when Array
        value.map { |item| serialize(item) }
      else
        paper_trail_diff_value?(value) ? value.to_h : value
      end
    end

    # Records sort by type first so that mixed id types stay comparable, then
    # naturally within one type. Ordering by the printed form instead would put
    # id 10 before id 2, which is deterministic but reads as unsorted wherever a
    # result is rendered.
    #: (untyped, untyped) -> Array[untyped]
    def self.sortable_identity(type, id)
      key = case id
            when Numeric then [0, id]
            when String, Symbol then [1, id.to_s]
            else [2, id.inspect]
            end
      [type.to_s, key]
    end

    # Which loaded row a version or record is, across the lookups of a call:
    # by its class's name rather than the class, so a row still matches after
    # its class is reloaded.
    #: (untyped) -> Array[untyped]
    def self.row_key(row)
      [row.class.name, row.id]
    end

    # Which record a model and id name, as Endpoint.identity reads a record:
    # by its base class, so a subclass and its base name the same row.
    #: (untyped, untyped) -> Array[String]
    def self.record_identity(model_class, id)
      [model_class.base_class.name, id.to_s]
    end

    # Only quoting helpers are needed where this is used, so the model's
    # connection is borrowed for the block rather than checked out
    # permanently, which Active Record 7.2 and newer can deprecate. Active
    # Record 7.1 has no `with_connection` and reaches the same connection
    # through the accessor.
    #: [T] (untyped) { (untyped) -> T } -> T
    def self.with_connection(model, &block)
      return model.with_connection(&block) if model.respond_to?(:with_connection)

      yield(model.connection)
    end

    # A constant by its full name, such as a model's or one of Active
    # Record's, untyped: Active Record and the models ship no signatures. Any
    # spelling of the lookup finds the same constant.
    # mutant:disable
    #: (String) -> untyped
    def self.constant(name)
      Object.const_get(name)
    end

    #: (untyped) -> Array[untyped]
    def self.chronological_version_key(version)
      version_key(version.created_at, version.id)
    end

    #: (untyped, untyped) -> Array[untyped]
    def self.version_key(created_at, id)
      [created_at, id.to_s.rjust(32, '0')]
    end

    # Ordering falls back to the id whenever timestamps tie, which recovers the
    # real order only while ids increase with insertion. An autoincrement id
    # does; a UUID does not, so a tie between UUID-keyed versions is genuinely
    # unorderable and any timeline built from it would be fiction.
    #: (Array[untyped]) -> Array[untyped]
    def self.chronological_sort(versions)
      sorted = versions.sort_by { |version| chronological_version_key(version) }
      ambiguous = ambiguous_pair(sorted)
      return sorted unless ambiguous

      raise AmbiguousVersionOrderError, ambiguous_message(ambiguous)
    end

    #: (Array[untyped]) -> Array[untyped]?
    def self.ambiguous_pair(sorted)
      sorted.each_cons(2).find do |left, right|
        left.created_at == right.created_at && !orderable_tie?(left, right)
      end
    end

    # Ids order versions saved in one instant only when they count up in one
    # table. Two version tables count separately, so ids there say nothing.
    #: (untyped, untyped) -> bool
    def self.orderable_tie?(left, right)
      version_table(left) == version_table(right) &&
        sequential_id?(left.id) && sequential_id?(right.id)
    end

    #: (untyped) -> untyped
    def self.version_table(version)
      version.class.respond_to?(:table_name) ? version.class.table_name : version.class
    end
    private_class_method :version_table

    # Versions sharing a timestamp, whether or not their ids order them. PT-AT
    # indexes association membership per version but resolves it by timestamp,
    # so association state cannot be told apart across such a pair even when the
    # scalar sequence is perfectly recoverable.
    #: (Array[untyped]) -> Array[untyped]?
    def self.tied_timestamp_pair(versions)
      versions.each_cons(2).find { |left, right| left.created_at == right.created_at }
    end

    # Whether a model records history at all.
    #
    # PaperTrail defines `paper_trail` on every ActiveRecord model, so asking
    # whether a class responds to it says nothing -- it is true for models that
    # never called `has_paper_trail`, and reading history from one of those fails
    # at the version class rather than at the question. Only configured options
    # distinguish the two, which is why this lives in one place: the predicate is
    # easy to write in a form that looks right and always answers true.
    #: (untyped) -> bool
    def self.versioned?(model_class)
      model_class.respond_to?(:paper_trail_options) && !model_class.paper_trail_options.nil?
    end

    # `versions.item_id` is often a string column -- PaperTrail's setup for UUID
    # keys -- while the model's own key is an integer. An id read from history
    # is cast to the key's type, or the same record read once from history and
    # once from its live row would count as two.
    #: (untyped, untyped) -> untyped
    def self.record_id(model_class, id)
      key = model_class.primary_key
      return id unless key.instance_of?(String)

      model_class.type_for_attribute(key).cast(id)
    end

    # A relation's limit and offset as Active Record writes them into SQL.
    # Before 8.1 it keeps a limit as given, as every version keeps an offset,
    # so either may be a String, as request parameters are.
    #: (untyped) -> Integer?
    def self.limit(relation)
      value = relation.limit_value
      Integer(value) unless value.nil?
    end

    #: (untyped) -> Integer
    def self.offset(relation)
      relation.offset_value.to_i
    end

    #: (untyped) -> bool
    def self.sequential_id?(id)
      id.instance_of?(Integer) || id.to_s.match?(/\A\d+\z/)
    end

    #: (Array[untyped]) -> String
    def self.ambiguous_message(pair)
      left, right = pair
      "versions #{left.id.inspect} and #{right.id.inspect} share the timestamp " \
        "#{left.created_at.inspect} and have ids that do not order them, so their " \
        'sequence cannot be recovered; record versions at sub-second precision or ' \
        'with sequential ids'
    end

    #: (untyped, untyped) -> Integer
    def self.compare_versions(left, right)
      chronological_version_key(left) <=> chronological_version_key(right) ||
        raise(ConfigurationError, 'versions have incomparable timestamps')
    end

    #: (String, String | Symbol) -> String
    def self.association_path(parent, name)
      parent.empty? ? name.to_s : "#{parent}.#{name}"
    end

    # Groups of one name are joined: their ids, and their owners where both
    # know some. A group that knows none has no :owners key.
    #: (Hash[String, Hash[Symbol, untyped]], Hash[String, Hash[Symbol, untyped]]) -> Hash[String, Hash[Symbol, untyped]]
    def self.merge_record_groups(existing, incoming)
      existing.merge(incoming) do |_name, left, right|
        merged = left.merge(right, ids: (left.fetch(:ids) | right.fetch(:ids)))
        next merged unless left.key?(:owners) && right.key?(:owners)

        owners = left.fetch(:owners).merge(right.fetch(:owners)) do |_owner, first, second|
          first | second
        end
        merged.merge(owners: owners)
      end
    end

    #: (untyped) -> untyped
    def self.duplicate_and_freeze(value)
      value.dup.freeze
    rescue TypeError
      value
    end
    private_class_method :duplicate_and_freeze

    #: (untyped) -> bool
    def self.paper_trail_diff_value?(value)
      class_name = value.class.name
      class_name&.start_with?('PaperTrailDiff::') && value.respond_to?(:to_h)
    end
    private_class_method :paper_trail_diff_value?
  end
end
