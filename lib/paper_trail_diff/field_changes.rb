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
