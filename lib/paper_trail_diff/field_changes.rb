# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # What a record's versions recorded of one field, as ChangeAttribution reads
  # it to credit a change.
  module FieldChanges
    # The changes the versions recorded of a field, each with its version:
    # nil when one of them recorded nothing, or their changes were not read.
    #: (Array[ActivityBoundary], String?) -> Array[[ActivityBoundary, ValueChange]]?
    def self.recorded(versions, name)
      changes = all_recorded(versions)
      return unless changes

      touched = [] #: Array[[ActivityBoundary, ValueChange]]
      versions.each_with_index do |version, index|
        change = changes.fetch(index)[name]
        touched << [version, change] if change
      end
      touched
    end

    # The last of the versions that recorded any of the fields changing, nil
    # when none did, or the last of them when one recorded nothing or their
    # changes were not read.
    #: (Array[ActivityBoundary], Array[String]) -> ActivityBoundary?
    def self.last_changing(versions, names)
      changes = all_recorded(versions)
      return versions.last unless changes

      found = (versions.length - 1).downto(0).find do |index|
        names.any? { |name| changes.fetch(index)[name] }
      end
      versions.fetch(found) if found
    end

    # Those of the fields the versions recorded changing, or all of them when
    # one recorded nothing or their changes were not read: none when the
    # versions are none.
    #: (Array[ActivityBoundary], Array[String]) -> Array[String]
    def self.changed_names(versions, names)
      return [] if versions.empty?

      changes = all_recorded(versions)
      return names unless changes

      names.select { |name| changes.any? { |saved| saved[name] } }
    end

    # A row about a whole record has no field name, which no version records.
    #: (Array[ActivityBoundary]) -> Array[Hash[untyped, ValueChange]]?
    def self.all_recorded(versions)
      return unless versions.all?(&:recorded_changes?)

      changes = versions.filter_map(&:recorded_changes)
      changes if changes.length == versions.length
    end
    private_class_method :all_recorded
  end
end
