# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reads a model's attribute values in the one form every account of them
  # shares: a version decoded from history, the current row, and the changes
  # a version recorded. Each would otherwise differ where nothing was edited.
  # TimeOfDay puts a time of day on one date, StoredForm reads a value as its
  # column keeps it, and for JSON history, StoredJsonValues and
  # StoredTimePrecision read values as JSON stored them.
  module StoredValues
    #: (untyped, Hash[untyped, untyped]) -> Hash[untyped, untyped]
    def self.apply(model_class, attributes)
      attributes = StoredForm.apply(model_class, TimeOfDay.apply(model_class, attributes))
      digits = StoredTimePrecision.digits(model_class)
      return attributes unless digits

      StoredTimePrecision.apply(StoredJsonValues.apply(model_class, attributes), digits)
    end

    # A copy of the record holding `stored`, its attributes as `apply` read
    # them, or the record itself where it already holds them.
    #: (untyped, Hash[String, untyped]) -> untyped
    def self.record(record, stored)
      held = record.attributes
      kept = stored.reject { |name, value| Support.same?(value, held.fetch(name)) }
      return record if kept.empty?

      copy = record.class.instantiate(record.attributes_before_type_cast)
      kept.each { |name, value| copy[name] = value }
      copy.tap(&:clear_changes_information)
    end
  end
end
