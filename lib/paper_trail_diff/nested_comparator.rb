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
  class NestedComparator
    # Stands in for a key that was not there at all.
    ABSENT = Object.new
    def ABSENT.inspect = '#<PaperTrailDiff absent>'
    def ABSENT.to_s = 'absent'
    ABSENT.freeze

    #: (untyped, untyped) -> nested_changes
    def self.call(from_value, to_value)
      new(from_value, to_value).call
    end

    #: (untyped, untyped) -> void
    def initialize(from_value, to_value)
      @from_value = from_value
      @to_value = to_value
    end

    # Returns the changed paths, or an empty hash when the pair is not two
    # structures this can look inside. An empty result therefore means "nothing
    # to report at this depth", and the caller still has the whole-value change.
    #: () -> nested_changes
    def call
      from_structure, to_structure = structures
      return {} unless from_structure && to_structure

      changes = {} #: nested_changes
      walk(from_structure, to_structure, [], changes)
      changes.freeze
    end

    private

    # @rbs @from_value: untyped
    # @rbs @to_value: untyped

    # Both sides have to be readable as a Hash for a nested answer to mean
    # anything. A column that held text on one side and JSON on the other
    # changed wholesale, and saying so is the accurate report.
    #: () -> [Hash[untyped, untyped]?, Hash[untyped, untyped]?]
    def structures
      [structure(@from_value), structure(@to_value)]
    end

    #: (untyped) -> Hash[untyped, untyped]?
    def structure(value)
      return value if value.is_a?(Hash)
      return unless value.is_a?(String)

      parsed = begin
        JSON.parse(value)
      rescue JSON::ParserError, TypeError
        nil
      end
      parsed if parsed.is_a?(Hash)
    end

    #: (Hash[untyped, untyped], Hash[untyped, untyped], Array[String], nested_changes) -> void
    def walk(from_hash, to_hash, path, changes)
      keys(from_hash, to_hash).each do |key|
        from_item = from_hash.key?(key) ? from_hash[key] : ABSENT
        to_item = to_hash.key?(key) ? to_hash[key] : ABSENT
        next if from_item == to_item

        here = [*path, key.to_s].freeze
        if from_item.is_a?(Hash) && to_item.is_a?(Hash)
          walk(from_item, to_item, here, changes)
        else
          changes[here] = change_for(from_item, to_item)
        end
      end
    end

    # Two arrays are a membership change; anything else is a change to the
    # value as a whole, including an array facing something that is not one.
    #: (untyped, untyped) -> nested_change
    def change_for(from_item, to_item)
      if from_item.is_a?(Array) && to_item.is_a?(Array)
        ArrayChange.new(from: from_item, to: to_item)
      else
        ValueChange.new(from: from_item, to: to_item)
      end
    end

    # Sorted so a report reads the same twice, and stringified because a hash
    # loaded from JSON and one built in Ruby can key the same field differently.
    #: (Hash[untyped, untyped], Hash[untyped, untyped]) -> Array[untyped]
    def keys(from_hash, to_hash)
      (from_hash.keys | to_hash.keys).sort_by(&:to_s)
    end
  end
end
