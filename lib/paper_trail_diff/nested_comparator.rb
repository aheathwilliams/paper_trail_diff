# frozen_string_literal: true
# rbs_inline: enabled

require 'json'

module PaperTrailDiff
  # Compares the inside of a value a database column holds whole.
  #
  # A JSON or jsonb column reifies to one Hash, so an ordinary attribute diff
  # can only say that the blob changed. This says which keys changed, leaving
  # the surrounding diff untouched.
  #
  # Three decisions worth knowing about.
  #
  # Paths are arrays, not dotted strings. A JSON key may contain a dot -- host
  # names and locales routinely do -- and joining would make `a.b` ambiguous
  # between one key and two.
  #
  # Arrays are reported by membership, not by position -- see ArrayChange. Their
  # elements carry no identity, so an insertion at the front makes every later
  # index look changed, and one insertion reads as several edits. What is added
  # and removed can be answered without claiming any pairing; what cannot is the
  # same elements in a new order, so that is named rather than passed over.
  #
  # An absent key is not a null one. `{"a": null}` and `{}` mean different
  # things in JSON and an audit trail that conflated them would be lying about
  # one of them, so absence is its own value rather than nil.
  #
  # A key is its name: `:a` and `"a"` are one key at any depth, inside arrays
  # too, because a hash built in Ruby and one read back from JSON key the same
  # field differently. Values are reported as they were given.
  class NestedComparator
    # Stands in for a key that was not there at all.
    class Absent
      #: () -> String
      def inspect = '#<PaperTrailDiff absent>'

      #: () -> String
      def to_s = 'absent'
    end
    private_constant :Absent

    ABSENT = Absent.new.freeze
    # Every NaN, as a key.
    NAN = Object.new.freeze
    private_constant :NAN

    #: (untyped, untyped) -> nested_changes
    def self.call(from_value, to_value)
      new(from_value, to_value).call
    end

    # The value as it is compared: every Hash key read as a string, at any
    # depth and inside arrays, and everything else as it is.
    #: (untyped) -> untyped
    def self.comparable(value)
      case value
      when Hash then string_keyed(value) { |item| comparable(item) }
      when Array then value.map { |item| comparable(item) }
      else value
      end
    end

    # The comparable value as a Hash key: two values Support.same? reads
    # alike are one key, as the attribute diff and the walk through a hash
    # read them. A Hash looks its keys up with `eql?`, which also tells an
    # Integer from a BigDecimal of the same value, so every number is read as
    # a rational beside whether it is a Float, at any depth. One that is not
    # finite has no rational: an infinity keeps its sign, and every NaN is one
    # key, as a database stores it.
    #: (untyped) -> untyped
    def self.countable(value)
      case value
      when Hash then string_keyed(value) { |item| countable(item) }
      when Array then value.map { |item| countable(item) }
      when Numeric then number_key(value)
      else value
      end
    end

    #: (Numeric) -> untyped
    def self.number_key(number)
      key = rational(number)
      key.equal?(NAN) ? key : [number.instance_of?(Float), key].freeze
    end
    private_class_method :number_key

    # The number as a rational, or as it is when it has none: a complex
    # number, or one that is not finite, such as a Float or BigDecimal NaN.
    #: (untyped) -> untyped
    def self.rational(number)
      return NAN if Support.nan?(number)

      number.real? && number.finite? ? number.to_r : number
    end

    # The hash keyed by name, each value as the block returns it. Two keys
    # with one name, such as `:a` and `"a"`, cannot both be kept.
    #: (Hash[untyped, untyped]) { (untyped) -> untyped } -> Hash[String, untyped]
    def self.string_keyed(hash)
      normalized = {} #: Hash[String, untyped]
      hash.each do |key, value|
        name = key.to_s
        if normalized.key?(name)
          raise AmbiguousNestedKeyError, "duplicate nested key after normalization: #{name.inspect}"
        end

        normalized[name] = yield(value)
      end
      normalized
    end

    #: (untyped, untyped) -> void
    def initialize(from_value, to_value)
      @from_value = from_value
      @to_value = to_value
    end

    # Returns the changed paths, or an empty hash when the pair is not two
    # structures this can look inside. An empty result therefore means "nothing
    # to report at this depth", and the caller still has the whole-value change.
    # Two arrays at the top are one membership change, at the empty path.
    #: () -> nested_changes
    def call
      from, to = structures
      changes = {} #: nested_changes
      if from.is_a?(Hash) && to.is_a?(Hash)
        walk(from, to, [], changes)
      elsif from.is_a?(Array) && to.is_a?(Array)
        whole = [] #: Array[String]
        change = change_for(from, to)
        changes[whole.freeze] = change if change
      end
      changes.freeze
    end

    private

    # @rbs @from_value: untyped
    # @rbs @to_value: untyped

    # Both sides have to be readable as the same kind of structure for a
    # nested answer to mean anything. A column that held text on one side and
    # JSON on the other changed wholesale, and saying so is the accurate report.
    #: () -> [untyped, untyped]
    def structures
      [structure(@from_value), structure(@to_value)]
    end

    # A string is read as JSON; anything else, or JSON that is neither an
    # object nor an array, is left for #call to decline.
    #: (untyped) -> untyped
    def structure(value)
      return value unless value.is_a?(String)

      JSON.parse(value)
    rescue JSON::ParserError
      nil
    end

    #: (Hash[untyped, untyped], Hash[untyped, untyped], Array[String], nested_changes) -> void
    def walk(from_hash, to_hash, path, changes)
      from_hash = normalize_keys(from_hash)
      to_hash = normalize_keys(to_hash)
      keys(from_hash, to_hash).each do |key|
        from_item = from_hash.fetch(key, ABSENT)
        to_item = to_hash.fetch(key, ABSENT)
        visit(from_item, to_item, (path + [key]).freeze, changes) unless Support.same?(from_item,
                                                                                       to_item)
      end
    end

    #: (untyped, untyped, Array[String], nested_changes) -> void
    def visit(from_item, to_item, here, changes)
      return walk(from_item, to_item, here, changes) if from_item.is_a?(Hash) && to_item.is_a?(Hash)

      change = change_for(from_item, to_item)
      changes[here] = change if change
    end

    #: (Hash[untyped, untyped]) -> Hash[String, untyped]
    def normalize_keys(hash)
      NestedComparator.string_keyed(hash, &:itself)
    end

    # Two arrays are a membership change, or none when they hold the same
    # elements in the same order once keys are read as strings; anything else
    # is a change to the value as a whole, including an array facing something
    # that is not one.
    #: (untyped, untyped) -> nested_change?
    def change_for(from_item, to_item)
      unless from_item.is_a?(Array) && to_item.is_a?(Array)
        return ValueChange.new(from: from_item, to: to_item)
      end

      change = ArrayChange.new(from: from_item, to: to_item)
      change unless change.empty?
    end

    # Sorted so a report reads the same twice. Both hashes are already keyed by
    # strings, because a hash loaded from JSON and one built in Ruby can key the
    # same field differently.
    #: (Hash[String, untyped], Hash[String, untyped]) -> Array[String]
    def keys(from_hash, to_hash)
      (from_hash.keys | to_hash.keys).sort
    end
  end
end
