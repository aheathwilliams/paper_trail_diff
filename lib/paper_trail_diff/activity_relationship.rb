# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reads event-side foreign keys and matches them to an immutable snapshot owner.
  class ActivityRelationship
    #: (untyped, untyped, RecordSnapshot, ?state: Symbol) -> bool
    def member_of_owner?(record, reflection, owner, state: :after)
      actual = relationship_owner_values(record, reflection, state: state)
      expected_ids = Array(owner.id)
      # @type var expected_ids: Array[untyped]
      expected = expected_ids.map { |id| id.to_s } # rubocop:disable Style/SymbolProc
      return false unless actual == expected
      return true unless reflection.options[:as]

      type = event_attribute(record, reflection.type, state: state).to_s
      owner_types(reflection, owner).include?(type)
    end

    #: (untyped, untyped, state: Symbol) -> untyped
    def owner_id(record, reflection, state:)
      values = Array(reflection.foreign_key).map do |foreign_key|
        event_attribute(record, foreign_key, state: state)
      end
      values.one? ? values.first : values
    end

    private

    #: (untyped, untyped, state: Symbol) -> Array[String]
    def relationship_owner_values(record, reflection, state:)
      Array(reflection.foreign_key).map do |key|
        event_attribute(record, key, state: state).to_s
      end
    end

    #: (untyped, untyped, state: Symbol) -> untyped
    def event_attribute(record, name, state:)
      if record.is_a?(ActivitySnapshotDelta)
        return state == :before ? record.before_value(name) : record.after_value(name)
      end

      record.public_send(name)
    end

    #: (untyped, RecordSnapshot) -> Array[String]
    def owner_types(reflection, owner)
      [
        owner.type.to_s,
        reflection.active_record.name.to_s,
        reflection.active_record.base_class.name.to_s
      ]
    end
  end
end
