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

    # Active Record's types for a `serialize`d attribute and for an enum,
    # named so that loading needs no Active Record.
    SERIALIZED_TYPE = 'ActiveRecord::Type::Serialized'
    ENUM_TYPE = 'ActiveRecord::Enum::EnumType'

    # The date a database gives a time of day it reads back.
    TIME_OF_DAY_DATE = { year: 2000, month: 1, day: 1 }.freeze #: Hash[Symbol, Integer]

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
    # does. A change's values are a pair. JSON history keeps a time of day as
    # the text of the time it was assigned, date and offset included, which
    # decoding would read on 2000-01-01 in that offset; it is read as a time
    # first, so that its clock is taken on its own date, as the row's was.
    #: (Hash[untyped, untyped], untyped) -> Hash[String, untyped]
    def self.decodable(stored, model_class)
      times = TimeOfDay.columns(model_class)
      stored.to_h do |name, value|
        name = name.to_s
        [name, unwrapped_time(value, times.include?(name))]
      end
    end

    #: (untyped, bool) -> untyped
    def self.unwrapped_time(value, time_of_day)
      return value.map { |item| unwrapped_time(item, time_of_day) } if value.instance_of?(Array)
      return written_time(value) if time_of_day && value.is_a?(String)

      TIME_VALUE.eql?(value.class.name) ? recorded_time(value) : value
    end
    private_class_method :unwrapped_time

    # The time JSON wrote, or the text as it is when it names none.
    #: (String) -> untyped
    def self.written_time(text)
      parser = Time #: untyped
      time_of_day(parser.iso8601(text))
    rescue ArgumentError
      text
    end
    private_class_method :written_time

    # The time a stored wrapper holds -- the one it wraps, or the `@time`
    # PaperTrail reads -- on 2000-01-01, as the database keeps a time of day.
    # Active Record keeps the date of a time assigned in memory, which
    # PaperTrail stores, but the row holds only the time.
    #: (untyped) -> untyped
    def self.recorded_time(value)
      time = value.__getobj__ { value.instance_variable_get(:@time) }
      time && time_of_day(time)
    end
    private_class_method :recorded_time

    # A time of day on 2000-01-01, as the database gives it back. A time with
    # a zone keeps it. A plain time is stored as its clock reads in Active
    # Record's default time zone, and read back on that date there, where a
    # local zone can have another offset: a summer time read back in winter.
    #: (untyped) -> untyped
    def self.time_of_day(value)
      return value.change(**TIME_OF_DAY_DATE) unless value.instance_of?(Time)

      local = constant('ActiveRecord').default_timezone == :local
      clock = local ? value.getlocal : value.getutc #: untyped
      clock.change(**TIME_OF_DAY_DATE)
    end

    # PaperTrail's `reify`, with each time of day its version recorded.
    #: (untyped, **untyped) -> untyped
    def self.reify(version, **options)
      with_recorded_times(version.reify(**options))
    end

    # A record PaperTrail rebuilt, with each time of day assigned from the
    # version it was rebuilt from, which PaperTrail can decode as nil. PaperTrail
    # assigns stored attributes after building the record and links it to
    # that version, PT-AT's members too, so this assigns what PaperTrail would
    # if it unwrapped the value, or read JSON's text as decodable does. Only a
    # version whose stored text names the wrapper, or JSON history of a model
    # with a time of day, is decoded again; any other record is returned as
    # it is.
    #: [T] (T) -> T
    def self.with_recorded_times(record)
      version = rebuilt_from(record)
      return record unless version

      rebuilt = record #: untyped
      times = TimeOfDay.columns(rebuilt.class)
      version.object_deserialized.each do |name, value|
        if TIME_VALUE.eql?(value.class.name)
          assign_recorded(record, name.to_s, recorded_time(value))
        elsif written_time?(value, name, times)
          assign_recorded(record, name.to_s, written_time(value))
        end
      end
      record
    end

    # JSON writes a time of day as text.
    #: (untyped, untyped, Array[String]) -> bool
    def self.written_time?(value, name, times)
      value.is_a?(String) && times.include?(name.to_s)
    end
    private_class_method :written_time?

    #: (untyped) -> untyped
    def self.rebuilt_from(record)
      model = record.class
      return unless model.respond_to?(:version_association_name)

      version = record.public_send(model.version_association_name)
      object = version&.object
      return unless object

      # A JSON column's Hash is keyed by attribute names, never this one.
      json_times = TimeOfDay.columns(model).any? && StoredTimePrecision.digits(model)
      version if json_times || object.include?(TIME_VALUE)
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
      return value if deeply_frozen?(value)

      case value
      when Hash
        immutable_hash(value)
      when Array
        value.map { |item| immutable_copy(item) }.freeze
      else
        duplicate_and_freeze(value)
      end
    end

    # A frozen tree is returned as it is rather than copied again, as each
    # value object that holds it would.
    #: (untyped) -> bool
    def self.deeply_frozen?(value)
      members = frozen_members(value)
      !members.nil? && members.all? { |item| deeply_frozen?(item) }
    end
    private_class_method :deeply_frozen?

    # What a frozen plain Hash or Array holds, keys too, and nothing for any
    # other frozen value; nil when the value is not frozen or is a subclass.
    #: (untyped) -> Array[untyped]?
    def self.frozen_members(value)
      return unless value.frozen?
      return value.flatten if value.instance_of?(Hash)
      return value if value.instance_of?(Array)

      [] unless value.is_a?(Hash) || value.is_a?(Array)
    end
    private_class_method :frozen_members

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

    # Ids as strings, once each, in the order their records' ids take: an
    # integer id by its value, so 2 comes before 10, and any other by its text.
    #: (Array[untyped]) -> Array[String]
    def self.sort_ids(ids)
      ids.map(&:to_s).uniq.sort_by { |id| id.match?(/\A\d+\z/) ? [0, id.to_i, id] : [1, 0, id] }
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

    # Arel, which ships no signatures either.
    #: () -> untyped
    def self.arel = constant('Arel')

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

    # The earliest of some versions of one item, as chronological_sort orders
    # them. Only the versions saved at the earliest instant are compared, so a
    # tie that cannot be ordered raises there, as it does inside a range, and
    # one among later versions does not.
    #: (Array[untyped]) -> untyped
    def self.earliest_version(versions)
      earliest = versions.map(&:created_at).min
      chronological_sort(versions.select { |version| version.created_at == earliest }).first
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

    # Whether two values are one, as a diff reads them: `==`, but a NaN is the
    # same as a NaN, as PostgreSQL stores and compares it, though Ruby has
    # NaN unequal to everything. A value a serialized attribute holds can be
    # of any class, so `==` must hold both ways, which Active Support's
    # Time == String does not, and a Float is not the Integer it equals: each
    # is written differently, so the change is real. Hashes and arrays are
    # compared by their members.
    #: (untyped, untyped) -> bool
    def self.same?(left, right)
      return nan?(right) if nan?(left)
      return same_hash?(left, right) if left.is_a?(Hash)
      return same_array?(left, right) if left.is_a?(Array)

      left == right && right == left && left.is_a?(Float) == right.is_a?(Float)
    end

    #: (Hash[untyped, untyped], untyped) -> bool
    def self.same_hash?(left, right)
      right.is_a?(Hash) && left.length == right.length &&
        left.all? { |key, value| right.key?(key) && same?(value, right[key]) }
    end

    #: (Array[untyped], untyped) -> bool
    def self.same_array?(left, right)
      right.is_a?(Array) && left.length == right.length &&
        left.each_index.all? { |index| same?(left[index], right[index]) }
    end
    private_class_method :same_hash?, :same_array?

    # A Float or BigDecimal NaN.
    #: (untyped) -> bool
    def self.nan?(value)
      number = value #: untyped
      number.respond_to?(:nan?) && number.nan?
    end

    # An option that is a switch takes only true or false, so a truthy value
    # given by mistake, such as a string, is not read as one.
    #: (Symbol, untyped) -> void
    def self.boolean!(name, value)
      raise ConfigurationError, "#{name}: must be true or false" unless [true,
                                                                         false].include?(value)
    end

    # Why a versioned model's history holds no states, or nil. PaperTrail
    # can keep versions in a table without an `object` column, and every
    # state is rebuilt from that column.
    #: (untyped) -> String?
    def self.stateless_reason(model_class)
      versions = model_class.paper_trail.version_class
      return if versions.column_names.include?('object')

      "#{versions.name} has no object column, so #{model_class.name} has no recorded states " \
        'to rebuild history from: add one to its version table'
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
