# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Internal helpers for isolating and serializing values held by result objects.
  module Support
    module_function

    #: (untyped) -> untyped
    def immutable_copy(value)
      return value if value.frozen?

      case value
      when Hash
        immutable_hash(value)
      when Array
        value.map { |item| immutable_copy(item) }.freeze
      else
        duplicate_and_freeze(value)
      end
    end

    #: (Hash[untyped, untyped]) -> Hash[untyped, untyped]
    def immutable_hash(value)
      copy = {} #: Hash[untyped, untyped]
      value.each do |key, item|
        copy[immutable_copy(key)] = immutable_copy(item)
      end
      copy.freeze
    end
    private_class_method :immutable_hash

    #: (untyped) -> untyped
    def serialize(value)
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

    #: (untyped) -> Array[untyped]
    def chronological_version_key(version)
      [version.created_at, version.id.to_s.rjust(32, '0')]
    end

    # Ordering falls back to the id whenever timestamps tie, which recovers the
    # real order only while ids increase with insertion. An autoincrement id
    # does; a UUID does not, so a tie between UUID-keyed versions is genuinely
    # unorderable and any timeline built from it would be fiction.
    #: (Array[untyped]) -> Array[untyped]
    def chronological_sort(versions)
      sorted = versions.sort_by { |version| chronological_version_key(version) }
      ambiguous = ambiguous_pair(sorted)
      return sorted unless ambiguous

      raise AmbiguousVersionOrderError, ambiguous_message(ambiguous)
    end

    #: (Array[untyped]) -> Array[untyped]?
    def ambiguous_pair(sorted)
      sorted.each_cons(2).find do |left, right|
        left.created_at == right.created_at &&
          !(sequential_id?(left.id) && sequential_id?(right.id))
      end
    end

    # Versions sharing a timestamp, whether or not their ids order them. PT-AT
    # indexes association membership per version but resolves it by timestamp,
    # so association state cannot be told apart across such a pair even when the
    # scalar sequence is perfectly recoverable.
    #: (Array[untyped]) -> Array[untyped]?
    def tied_timestamp_pair(versions)
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
    def versioned?(model_class)
      model_class.respond_to?(:paper_trail_options) && !model_class.paper_trail_options.nil?
    end

    #: (untyped) -> bool
    def sequential_id?(id)
      id.is_a?(Integer) || id.to_s.match?(/\A\d+\z/)
    end

    #: (Array[untyped]) -> String
    def ambiguous_message(pair)
      left, right = pair
      "versions #{left.id.inspect} and #{right.id.inspect} share the timestamp " \
        "#{left.created_at.inspect} and have ids that do not order them, so their " \
        'sequence cannot be recovered; record versions at sub-second precision or ' \
        'with sequential ids'
    end

    #: (untyped, untyped) -> Integer
    def compare_versions(left, right)
      chronological_version_key(left) <=> chronological_version_key(right) ||
        raise(ConfigurationError, 'versions have incomparable timestamps')
    end

    #: (String, String) -> String
    def association_path(parent, name)
      parent.empty? ? name : "#{parent}.#{name}"
    end

    #: (Hash[String, Hash[Symbol, untyped]], Hash[String, Hash[Symbol, untyped]]) -> Hash[String, Hash[Symbol, untyped]]
    def merge_record_groups(existing, incoming)
      existing.merge(incoming) do |_name, left, right|
        merged = left.merge(right, ids: (left.fetch(:ids) | right.fetch(:ids)))
        owners = merge_record_owners(left[:owners], right[:owners])
        owners ? merged.merge(owners: owners) : merged
      end
    end

    #: (untyped) -> untyped
    def duplicate_and_freeze(value)
      value.dup.freeze
    rescue TypeError
      value
    end
    private_class_method :duplicate_and_freeze

    #: (Hash[String, Array[untyped]]?, Hash[String, Array[untyped]]?) -> Hash[String, Array[untyped]]?
    def merge_record_owners(left, right)
      return right unless left
      return left unless right

      left.merge(right) { |_owner, first, second| first | second }
    end
    private_class_method :merge_record_owners

    #: (untyped) -> bool
    def paper_trail_diff_value?(value)
      class_name = value.class.name
      class_name&.start_with?('PaperTrailDiff::') && value.respond_to?(:to_h)
    end
    private_class_method :paper_trail_diff_value?
  end
end
