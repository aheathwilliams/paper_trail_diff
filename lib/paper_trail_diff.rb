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
require_relative 'paper_trail_diff/nested_comparator'
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
require_relative 'paper_trail_diff/activity_grouping'
require_relative 'paper_trail_diff/activity_transaction_grouper'
require_relative 'paper_trail_diff/step'
require_relative 'paper_trail_diff/analysis'
require_relative 'paper_trail_diff/activity_root_steps'
require_relative 'paper_trail_diff/analysis_batch'
require_relative 'paper_trail_diff/scoped_analysis'
require_relative 'paper_trail_diff/scoped_root_selection'
require_relative 'paper_trail_diff/batched_root_analyzer'
require_relative 'paper_trail_diff/version_range'
require_relative 'paper_trail_diff/version_sequence_diagnostics'
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
      snapshots: false,
      group: nil
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
        group: group,
        snapshots: snapshots
      )
    end

    # Builds an endpoint diff and root-checkpoint timeline while normalizing each version once.
    #: (untyped, ?from: untyped, ?to: untyped, ?within: untyped, ?associations: Array[String | Symbol], ?ignore: ignore_option, ?activity: bool, ?version_scope: untyped, ?close_on: Symbol?, ?snapshots: bool, ?group: Symbol?) -> Analysis
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
      snapshots: false,
      group: nil
    )
      PaperTrailAdapter.new(associations: associations, ignore: ignore).analyze(
        record,
        from: from,
        to: to,
        within: within,
        activity: activity,
        version_scope: version_scope,
        close_on: close_on,
        snapshots: snapshots,
        group: group
      )
    end

    # Analyzes many roots over one shared time window, preparing their selected
    # history once for the batch instead of once per record. Roots with no
    # versions in the window return an empty `Analysis`.
    #
    # Pass `records` to analyze a list you assembled, which returns a Hash keyed
    # by identity. Pass `scope:` with a `limit:` to have the roots selected for
    # you from a relation, which returns a `ScopedAnalysis` -- the same Hash,
    # plus the roots the relation could not reach. See `analyze_scope` for why
    # that second collection exists.
    #: (?Array[untyped]?, ?scope: untyped, ?limit: Integer?, ?within: untyped, ?associations: Array[String | Symbol], ?ignore: ignore_option, ?activity: bool, ?version_scope: untyped, ?close_on: Symbol?) -> (Hash[identity, Analysis] | ScopedAnalysis)
    def analyze_many( # rubocop:disable Metrics/ParameterLists
      records = nil,
      scope: nil,
      limit: nil,
      within: nil,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      activity: false,
      version_scope: nil,
      close_on: nil
    )
      adapter = PaperTrailAdapter.new(associations: associations, ignore: ignore)
      if scope
        raise ConfigurationError, 'pass either records or scope:, not both' unless records.nil?

        return adapter.analyze_scope(scope, limit: limit, within: within, activity: activity,
                                            version_scope: version_scope, close_on: close_on)
      end
      raise ConfigurationError, 'pass records or scope:' if records.nil?

      adapter.analyze_many(records, within: within, activity: activity,
                                    version_scope: version_scope, close_on: close_on)
    end

    # Analyzes every root the relation reaches whose history moved inside the
    # window, selecting them in a fixed number of queries rather than making the
    # caller rediscover them.
    #
    # `limit:` is required and exceeding it raises. Selection moves into the gem
    # here, so the bound on how much work a page can ask for has to move with
    # it, and a truncated audit report is worse than a refused one.
    #
    # Returns a `ScopedAnalysis`, which destructures:
    #
    #   analyses, unreachable = PaperTrailDiff.analyze_scope(
    #     Article.where(status: 'published'), within: july, limit: 500
    #   )
    #
    # `unreachable` names roots that changed in the window but have no live row
    # left. A relation's conditions are evaluated against the live table, so a
    # destroyed root cannot be tested against them at all -- its history is
    # intact and the state it held at destruction may well have matched. Those
    # roots are reported rather than dropped so that a page auditing deletions
    # is told where to look instead of quietly coming up short.
    #
    # Note also that a relation selects on current state, not on state during
    # the window: `where(status: 'published')` means published *now*, which is a
    # different set from what was published while the window was open.
    #: (untyped, limit: Integer?, ?within: untyped, ?associations: Array[String | Symbol], ?ignore: ignore_option, ?activity: bool, ?version_scope: untyped, ?close_on: Symbol?) -> ScopedAnalysis
    def analyze_scope( # rubocop:disable Metrics/ParameterLists
      scope,
      limit:,
      within: nil,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      activity: false,
      version_scope: nil,
      close_on: nil
    )
      PaperTrailAdapter.new(associations: associations, ignore: ignore).analyze_scope(
        scope, limit: limit, within: within, activity: activity,
               version_scope: version_scope, close_on: close_on
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

    # Looks inside an attribute the database stores whole, such as a JSON or
    # jsonb column, and reports which keys changed.
    #
    #   change = diff.attributes.fetch('config')
    #   PaperTrailDiff.nested_changes(change)
    #   # => { ['theme'] => <from "dark" to "light">,
    #   #      ['limits', 'max'] => <from 10 to 20> }
    #
    # Accepts the `ValueChange` an attribute diff already produced, or a bare
    # pair. Returns an empty hash when the pair is not two readable structures,
    # which is the honest answer: a column that held text on one side and JSON
    # on the other changed wholesale, and the caller still has that change.
    #
    # Paths are arrays because a JSON key may contain a dot. Arrays are reported
    # whole rather than by index, since their elements carry no identity and a
    # list that merely shifted would otherwise look changed throughout. A key
    # that was absent reads as `NestedComparator::ABSENT` rather than nil, which
    # JSON uses for a present null.
    #: (untyped, ?untyped) -> Hash[Array[String], ValueChange]
    def nested_changes(change, to_value = nil)
      # Tested by type rather than by responding to `from`: ActiveSupport gives
      # String#from, so duck-typing here quietly reads a plain string as a pair.
      return NestedComparator.call(change.from, change.to) if change.is_a?(ValueChange)

      NestedComparator.call(change, to_value)
    end
  end
end
