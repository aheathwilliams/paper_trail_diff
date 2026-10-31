# frozen_string_literal: true

# Experimental scalar-only replacement, deliberately outside lib/. It does not
# reproduce model initialization callbacks or default-scope creation attributes.
module ScalarSnapshotSpike
  class << self
    attr_accessor :enabled

    def snapshot(version, normalizer) # rubocop:disable Metrics/AbcSize
      return unless version.object

      state = (@state_loader ||= PaperTrailDiff::PreparedVersionStateLoader.new).call(version)
      raise 'direct state unavailable' unless state

      model = state.model_class
      attributes = model.column_defaults.merge(state.attributes)
      attributes = attributes.to_h do |name, value|
        [name, model.type_for_attribute(name).cast(value)]
      end
      ignored = normalizer.instance_variable_get(:@ignore_policy).attributes_for('')
      PaperTrailDiff::RecordSnapshot.new(
        type: model.name, id: attributes[model.primary_key],
        attributes: attributes.except(*Array(model.primary_key), *ignored)
      )
    end
  end

  private

  def snapshot_from_version(version, context, tree:, normalizer:, history:)
    return super unless ScalarSnapshotSpike.enabled && tree.empty?

    ScalarSnapshotSpike.snapshot(version, normalizer)
  end
end
