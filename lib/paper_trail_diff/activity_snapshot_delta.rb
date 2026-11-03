# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Internal scalar transition for one isolated PaperTrail update event.
  class ActivitySnapshotDelta
    #: (before_attributes: Hash[untyped, untyped], after_attributes: Hash[untyped, untyped]) -> void
    def initialize(before_attributes:, after_attributes:)
      @before_attributes = before_attributes.transform_keys(&:to_s)
      @after_attributes = after_attributes.transform_keys(&:to_s)
      freeze
    end

    #: (RecordSnapshot) -> RecordSnapshot
    def apply(snapshot)
      attributes = snapshot.attributes.merge(@after_attributes.slice(*snapshot.attributes.keys))
      return snapshot if attributes == snapshot.attributes

      RecordSnapshot.new(
        type: snapshot.type,
        id: snapshot.id,
        attributes: attributes,
        associations: snapshot.associations
      )
    end

    #: (untyped) -> untyped
    def before_value(name)
      @before_attributes[name.to_s]
    end

    #: (untyped) -> untyped
    def after_value(name)
      @after_attributes[name.to_s]
    end

    # Compared as text, so an id read as a string matches one read as an
    # integer.
    #: (untyped) -> bool
    def changed?(name)
      !before_value(name).to_s.eql?(after_value(name).to_s)
    end

    #: (untyped) -> bool
    def relationship_changed?(reflection)
      relationship_keys(reflection).any? { |name| changed?(name) }
    end

    private

    # @rbs @before_attributes: Hash[String, untyped]
    # @rbs @after_attributes: Hash[String, untyped]

    #: (untyped) -> Array[untyped]
    def relationship_keys(reflection)
      keys = Array(reflection.foreign_key)
      keys << reflection.type if reflection.options.key?(:as)
      keys
    end
  end
end
