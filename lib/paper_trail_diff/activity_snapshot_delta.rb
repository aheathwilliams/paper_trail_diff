# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Internal scalar transition for one isolated PaperTrail update event.
  class ActivitySnapshotDelta
    #: (before_attributes: Hash[untyped, untyped], after_attributes: Hash[untyped, untyped]) -> void
    def initialize(before_attributes:, after_attributes:)
      @before_attributes = normalize_hash(before_attributes)
      @after_attributes = normalize_hash(after_attributes)
      freeze
    end

    #: (RecordSnapshot) -> RecordSnapshot
    def apply(snapshot)
      attributes = snapshot.attributes.dup
      attributes.each_key do |name|
        attributes[name] = @after_attributes[name] if @after_attributes.key?(name)
      end
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

    #: (untyped) -> bool
    def relationship_changed?(reflection)
      relationship_keys(reflection).any? do |name|
        before_value(name).to_s != after_value(name).to_s
      end
    end

    private

    # @rbs @before_attributes: Hash[String, untyped]
    # @rbs @after_attributes: Hash[String, untyped]

    #: (Hash[untyped, untyped]) -> Hash[String, untyped]
    def normalize_hash(hash)
      hash.to_h { |name, value| [name.to_s, value] }.freeze
    end

    #: (untyped) -> Array[untyped]
    def relationship_keys(reflection)
      keys = Array(reflection.foreign_key)
      keys << reflection.type if reflection.options[:as]
      keys
    end
  end
end
