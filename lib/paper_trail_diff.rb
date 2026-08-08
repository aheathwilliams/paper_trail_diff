# frozen_string_literal: true
# rbs_inline: enabled

require 'paper_trail'

require_relative 'paper_trail_diff/version'
require_relative 'paper_trail_diff/support'
require_relative 'paper_trail_diff/configuration'
require_relative 'paper_trail_diff/errors'
require_relative 'paper_trail_diff/association_traversal'
require_relative 'paper_trail_diff/snapshot'
require_relative 'paper_trail_diff/value_objects'
require_relative 'paper_trail_diff/engine'
require_relative 'paper_trail_diff/historical_association_reifier'
require_relative 'paper_trail_diff/step'
require_relative 'paper_trail_diff/timeline_builder'
require_relative 'paper_trail_diff/paper_trail_adapter'

# @rbs!
#   module PaperTrailDiff
#     type snapshot_attributes = Hash[untyped, untyped]
#     type snapshot_associations = Hash[untyped, AssociationSnapshot]
#     type attribute_changes = Hash[String, ValueChange]
#     type association_diff = ToOneAssociationDiff | CollectionAssociationDiff
#     type association_diffs = Hash[String, association_diff]
#     type association_snapshots = Hash[String, AssociationSnapshot]
#     type identity = Array[untyped]
#     type ignore_option = Array[String | Symbol] | Hash[String | Symbol, untyped]
#   end

# Structured version comparison for PaperTrail.
module PaperTrailDiff
  DEFAULT_IGNORED_ATTRIBUTES = ['updated_at'].freeze

  class << self
    # Compares the net state reconstructed by two PaperTrail versions.
    #: (untyped, untyped, ?associations: Array[String | Symbol], ?ignore: ignore_option) -> Diff
    def compare(from_version, to_version, associations: [], ignore: DEFAULT_IGNORED_ATTRIBUTES)
      PaperTrailAdapter.new(associations: associations, ignore: ignore).compare(
        from_version,
        to_version
      )
    end

    # Compares every adjacent reconstructed state in an inclusive version range.
    #: (untyped, from: untyped, to: untyped, ?associations: Array[String | Symbol], ?ignore: ignore_option) -> Array[Step]
    def timeline(record, from:, to:, associations: [], ignore: DEFAULT_IGNORED_ATTRIBUTES)
      PaperTrailAdapter.new(associations: associations, ignore: ignore).timeline(
        record,
        from: from,
        to: to
      )
    end
  end
end
