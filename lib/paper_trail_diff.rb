# frozen_string_literal: true
# rbs_inline: enabled

require 'paper_trail'

require_relative 'paper_trail_diff/version'
require_relative 'paper_trail_diff/support'
require_relative 'paper_trail_diff/instrumentation'
require_relative 'paper_trail_diff/errors'
require_relative 'paper_trail_diff/configuration'
require_relative 'paper_trail_diff/endpoint'
require_relative 'paper_trail_diff/association_traversal'
require_relative 'paper_trail_diff/traversal_preparer'
require_relative 'paper_trail_diff/association_discovery'
require_relative 'paper_trail_diff/diagnostics'
require_relative 'paper_trail_diff/collection_identity_index'
require_relative 'paper_trail_diff/collection_transition'
require_relative 'paper_trail_diff/snapshot'
require_relative 'paper_trail_diff/activity_snapshot_delta'
require_relative 'paper_trail_diff/value_objects'
require_relative 'paper_trail_diff/traversal_entry'
require_relative 'paper_trail_diff/traversal_emitter'
require_relative 'paper_trail_diff/snapshot_traversal'
require_relative 'paper_trail_diff/association_diff_traversal'
require_relative 'paper_trail_diff/traversal'
require_relative 'paper_trail_diff/collection_comparator'
require_relative 'paper_trail_diff/engine'
require_relative 'paper_trail_diff/historical_association_reifier'
require_relative 'paper_trail_diff/prepared_record_index'
require_relative 'paper_trail_diff/prepared_history'
require_relative 'paper_trail_diff/version_association_candidate_scope'
require_relative 'paper_trail_diff/prepared_edge_loader'
require_relative 'paper_trail_diff/prepared_history_loader'
require_relative 'paper_trail_diff/prepared_association_reifier'
require_relative 'paper_trail_diff/live_association_reader'
require_relative 'paper_trail_diff/live_endpoint_batch_loader'
require_relative 'paper_trail_diff/preloaded_endpoint_batch_loader'
require_relative 'paper_trail_diff/live_endpoint_provider'
require_relative 'paper_trail_diff/live_graph_collector'
require_relative 'paper_trail_diff/batch_boundary_resolver'
require_relative 'paper_trail_diff/comparison_batch'
require_relative 'paper_trail_diff/root_version_plan'
require_relative 'paper_trail_diff/version_scope_filter'
require_relative 'paper_trail_diff/root_version_selection'
require_relative 'paper_trail_diff/batched_root_versions'
require_relative 'paper_trail_diff/snapshot_normalizer'
require_relative 'paper_trail_diff/historical_snapshot_store'
require_relative 'paper_trail_diff/timeline_snapshot_provider'
require_relative 'paper_trail_diff/activity_event_record_resolver'
require_relative 'paper_trail_diff/activity_event_route_finder'
require_relative 'paper_trail_diff/activity_relationship'
require_relative 'paper_trail_diff/activity_collection_route_change'
require_relative 'paper_trail_diff/activity_collection_record_updater'
require_relative 'paper_trail_diff/activity_collection_route_updater'
require_relative 'paper_trail_diff/activity_event_record_normalizer'
require_relative 'paper_trail_diff/activity_collection_event_applier'
require_relative 'paper_trail_diff/activity_belongs_to_event_applier'
require_relative 'paper_trail_diff/activity_event_snapshot_refresher'
require_relative 'paper_trail_diff/activity_root_snapshot_refresher'
require_relative 'paper_trail_diff/branch_snapshot_refresher'
require_relative 'paper_trail_diff/activity_boundary'
require_relative 'paper_trail_diff/step'
require_relative 'paper_trail_diff/analysis'
require_relative 'paper_trail_diff/activity_root_steps'
require_relative 'paper_trail_diff/analysis_batch'
require_relative 'paper_trail_diff/batched_root_analyzer'
require_relative 'paper_trail_diff/version_range'
require_relative 'paper_trail_diff/time_range'
require_relative 'paper_trail_diff/time_version_range'
require_relative 'paper_trail_diff/timeline_range'
require_relative 'paper_trail_diff/timeline_builder'
require_relative 'paper_trail_diff/activity_range'
require_relative 'paper_trail_diff/activity_event'
require_relative 'paper_trail_diff/activity_child_candidate_loader'
require_relative 'paper_trail_diff/activity_version_collector'
require_relative 'paper_trail_diff/activity_snapshot_sequence'
require_relative 'paper_trail_diff/activity_history'
require_relative 'paper_trail_diff/time_activity_timeline_builder'
require_relative 'paper_trail_diff/activity_timeline_builder'
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
#     type comparison_input = Hash[String | Symbol, untyped]
#     type comparison_results = Hash[identity, Diff]
#     type ignore_option = Array[String | Symbol] | Hash[String | Symbol, untyped]
#     type reference_key = :type | :id | "type" | "id"
#     type traversal_context = :change | :included_state
#     type traversal_state = :before | :after
#     type traversal_association_path = Array[String]
#     type traversal_record_path = Array[RecordReference]
#   end

# Structured version comparison for PaperTrail. Each method is a thin,
# documented entry point, so this reads as an API listing rather than logic.
module PaperTrailDiff # rubocop:disable Metrics/ModuleLength
  DEFAULT_IGNORED_ATTRIBUTES = ['updated_at'].freeze
  SUPPORTED_ASSOCIATION_MACROS = %i[
    belongs_to
    has_one
    has_many
    has_and_belongs_to_many
  ].freeze

  class << self
    # Compares net state between explicit PaperTrail-version or current-record endpoints.
    #: (untyped, untyped, ?associations: Array[String | Symbol], ?ignore: ignore_option, ?reload_live_endpoints: bool) -> Diff
    def compare(
      from_version,
      to_version,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      reload_live_endpoints: true
    )
      PaperTrailAdapter.new(
        associations: associations,
        ignore: ignore,
        reload_live_endpoints: reload_live_endpoints
      ).compare(
        from_version,
        to_version
      )
    end

    # Compares many independent endpoint pairs while batching current-record loading.
    #: (Array[comparison_input], ?associations: Array[String | Symbol], ?ignore: ignore_option, ?reload_live_endpoints: bool) -> comparison_results
    def compare_many(
      comparisons,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      reload_live_endpoints: true
    )
      PaperTrailAdapter.new(
        associations: associations,
        ignore: ignore,
        reload_live_endpoints: reload_live_endpoints
      ).compare_many(comparisons)
    end

    # Compares every adjacent reconstructed state in an inclusive version range.
    #: (untyped, ?from: untyped, ?to: untyped, ?within: untyped, ?associations: Array[String | Symbol], ?ignore: ignore_option, ?version_scope: untyped, ?close_on: Symbol?) -> Array[Step]
    def timeline( # rubocop:disable Metrics/ParameterLists
      record,
      from: nil,
      to: nil,
      within: nil,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      version_scope: nil,
      close_on: nil
    )
      PaperTrailAdapter.new(associations: associations, ignore: ignore).timeline(
        record,
        from: from,
        to: to,
        within: within,
        version_scope: version_scope,
        close_on: close_on
      )
    end

    # Compares adjacent root and selected-descendant activity boundaries.
    # `reload_live_endpoints:` applies only when `to:` is a current record; the
    # other range forms never read live state.
    #: (untyped, ?from: untyped, ?to: untyped, ?within: untyped, ?associations: Array[String | Symbol], ?ignore: ignore_option, ?reload_live_endpoints: bool, ?version_scope: untyped, ?close_on: Symbol?, ?snapshots: bool) -> Array[ActivityStep]
    def activity_timeline( # rubocop:disable Metrics/ParameterLists
      record,
      from: nil,
      to: nil,
      within: nil,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      reload_live_endpoints: true,
      version_scope: nil,
      close_on: nil,
      snapshots: false
    )
      PaperTrailAdapter.new(
        associations: associations,
        ignore: ignore,
        reload_live_endpoints: reload_live_endpoints
      ).activity_timeline(
        record,
        from: from,
        to: to,
        within: within,
        version_scope: version_scope,
        close_on: close_on,
        snapshots: snapshots
      )
    end

    # Builds an endpoint diff and root-checkpoint timeline while normalizing each version once.
    #: (untyped, ?from: untyped, ?to: untyped, ?within: untyped, ?associations: Array[String | Symbol], ?ignore: ignore_option, ?activity: bool, ?version_scope: untyped, ?close_on: Symbol?, ?snapshots: bool) -> Analysis
    def analyze( # rubocop:disable Metrics/ParameterLists
      record,
      from: nil,
      to: nil,
      within: nil,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      activity: false,
      version_scope: nil,
      close_on: nil,
      snapshots: false
    )
      PaperTrailAdapter.new(associations: associations, ignore: ignore).analyze(
        record,
        from: from,
        to: to,
        within: within,
        activity: activity,
        version_scope: version_scope,
        close_on: close_on,
        snapshots: snapshots
      )
    end

    # Analyzes many roots over one shared time window, preparing their selected
    # history once for the batch instead of once per record. Roots with no
    # versions in the window return an empty `Analysis`.
    #: (Array[untyped], ?within: untyped, ?associations: Array[String | Symbol], ?ignore: ignore_option, ?activity: bool, ?version_scope: untyped, ?close_on: Symbol?) -> Hash[identity, Analysis]
    def analyze_many( # rubocop:disable Metrics/ParameterLists
      records,
      within: nil,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      activity: false,
      version_scope: nil,
      close_on: nil
    )
      PaperTrailAdapter.new(associations: associations, ignore: ignore).analyze_many(
        records,
        within: within,
        activity: activity,
        version_scope: version_scope,
        close_on: close_on
      )
    end

    # Returns the association macros this release can normalize.
    #: () -> Array[Symbol]
    def supported_association_macros
      SUPPORTED_ASSOCIATION_MACROS
    end

    # Discovers supported, finite association paths for a model or record.
    #: (untyped, ?max_depth: Integer) -> Array[AssociationDescriptor]
    def association_paths(model_or_record, max_depth: 1)
      AssociationDiscovery.new(model_or_record, max_depth: max_depth).call
    end

    # Reports known reconstruction hazards without mutating application state.
    #: (untyped, untyped, ?associations: Array[String | Symbol]) -> DiagnosticReport
    def diagnose(from_version, to_version, associations: [])
      HistoryDiagnostics.new(from_version, to_version, associations: associations).call
    end
  end
end
