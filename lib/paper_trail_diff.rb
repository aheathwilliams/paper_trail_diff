# frozen_string_literal: true
# rbs_inline: enabled

require 'paper_trail'

require_relative 'paper_trail_diff/version'
require_relative 'paper_trail_diff/support'
require_relative 'paper_trail_diff/version_query'
require_relative 'paper_trail_diff/stored_time_precision'
require_relative 'paper_trail_diff/version_boundary'
require_relative 'paper_trail_diff/instrumentation'
require_relative 'paper_trail_diff/deprecation'
require_relative 'paper_trail_diff/errors'
require_relative 'paper_trail_diff/configuration'
require_relative 'paper_trail_diff/endpoint'
require_relative 'paper_trail_diff/recorded_class'
require_relative 'paper_trail_diff/association_key'
require_relative 'paper_trail_diff/version_table'
require_relative 'paper_trail_diff/association_traversal'
require_relative 'paper_trail_diff/scope_ranking'
require_relative 'paper_trail_diff/scope_condition'
require_relative 'paper_trail_diff/approximate_paths'
require_relative 'paper_trail_diff/fallback_paths'
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
require_relative 'paper_trail_diff/change_row'
require_relative 'paper_trail_diff/collection_comparator'
require_relative 'paper_trail_diff/nested_comparator'
require_relative 'paper_trail_diff/engine'
require_relative 'paper_trail_diff/habtm_transaction_owners'
require_relative 'paper_trail_diff/historical_association_reifier'
require_relative 'paper_trail_diff/prepared_record_index'
require_relative 'paper_trail_diff/direct_record_state_loader'
require_relative 'paper_trail_diff/prepared_state_association_reader'
require_relative 'paper_trail_diff/prepared_snapshot_builder'
require_relative 'paper_trail_diff/prepared_activity_index'
require_relative 'paper_trail_diff/prepared_history'
require_relative 'paper_trail_diff/version_association_candidate_scope'
require_relative 'paper_trail_diff/prepared_edge_loader'
require_relative 'paper_trail_diff/prepared_history_loader'
require_relative 'paper_trail_diff/prepared_association_reifier'
require_relative 'paper_trail_diff/live_association_reader'
require_relative 'paper_trail_diff/batch_preload'
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
require_relative 'paper_trail_diff/recorded_changes'
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
require_relative 'paper_trail_diff/activity_view'
require_relative 'paper_trail_diff/activity_transaction_grouper'
require_relative 'paper_trail_diff/step'
require_relative 'paper_trail_diff/analysis'
require_relative 'paper_trail_diff/activity_root_steps'
require_relative 'paper_trail_diff/analysis_batch'
require_relative 'paper_trail_diff/deleted_analysis_batch'
require_relative 'paper_trail_diff/scoped_analysis'
require_relative 'paper_trail_diff/historical_filter'
require_relative 'paper_trail_diff/association_activity_edge'
require_relative 'paper_trail_diff/association_activity_selection'
require_relative 'paper_trail_diff/scoped_root_selection'
require_relative 'paper_trail_diff/deleted_root_filter'
require_relative 'paper_trail_diff/scoped_analysis_builder'
require_relative 'paper_trail_diff/batched_root_analyzer'
require_relative 'paper_trail_diff/version_range'
require_relative 'paper_trail_diff/version_sequence_diagnostics'
require_relative 'paper_trail_diff/time_range'
require_relative 'paper_trail_diff/transaction_cut'
require_relative 'paper_trail_diff/time_version_range'
require_relative 'paper_trail_diff/timeline_range'
require_relative 'paper_trail_diff/timeline_builder'
require_relative 'paper_trail_diff/activity_range'
require_relative 'paper_trail_diff/activity_event'
require_relative 'paper_trail_diff/activity_child_candidate_loader'
require_relative 'paper_trail_diff/activity_target_candidate_loader'
require_relative 'paper_trail_diff/activity_version_collector'
require_relative 'paper_trail_diff/activity_snapshot_sequence'
require_relative 'paper_trail_diff/activity_tree_filter'
require_relative 'paper_trail_diff/activity_history'
require_relative 'paper_trail_diff/activity_timeline_builder'
require_relative 'paper_trail_diff/paper_trail_adapter'

# @rbs!
#   module PaperTrailDiff
#     type snapshot_attributes = Hash[untyped, untyped]
#     type snapshot_associations = Hash[untyped, AssociationSnapshot]
#     type attribute_changes = Hash[String, ValueChange]
#     type association_diff = ToOneAssociationDiff | CollectionAssociationDiff
#     type association_diffs = Hash[String, association_diff]
#     type nested_change = ValueChange | ArrayChange
#     type nested_changes = Hash[Array[String], nested_change]
#     type association_snapshots = Hash[String, AssociationSnapshot]
#     type identity = Array[untyped]
#     type comparison_input = Hash[String | Symbol, untyped]
#     type comparison_results = Hash[identity, Diff]
#     type report_options = {
#       within: untyped, activity: bool, version_scope: untyped, view: ActivityView
#     }
#     type ignore_option = Array[String | Symbol] | Hash[String | Symbol, untyped]
#     type association_option = String | Symbol | Array[untyped] | Hash[untyped, untyped]
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

  class << self # rubocop:disable Metrics/ClassLength
    # Compares net state between explicit PaperTrail-version or current-record endpoints.
    #: (untyped, untyped, ?associations: association_option, ?ignore: ignore_option, ?reload_live_endpoints: bool?, ?allow_approximate: bool) -> Diff
    def compare( # rubocop:disable Metrics/ParameterLists
      from_version,
      to_version,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      reload_live_endpoints: nil,
      allow_approximate: false
    )
      PaperTrailAdapter.new(
        associations: associations,
        ignore: ignore,
        reload_live_endpoints: Deprecation.reload_live_endpoints!(reload_live_endpoints),
        allow_approximate: allow_approximate
      ).compare(from_version, to_version)
    end

    # Compares many independent endpoint pairs while batching current-record loading.
    #: (Array[comparison_input], ?associations: association_option, ?ignore: ignore_option, ?reload_live_endpoints: bool?, ?allow_expensive: bool?, ?allow_approximate: bool) -> comparison_results
    def compare_many( # rubocop:disable Metrics/ParameterLists
      comparisons,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      reload_live_endpoints: nil,
      allow_expensive: nil,
      allow_approximate: false
    )
      Deprecation.allow_expensive!(allow_expensive)
      PaperTrailAdapter.new(
        associations: associations,
        ignore: ignore,
        reload_live_endpoints: Deprecation.reload_live_endpoints!(reload_live_endpoints),
        allow_approximate: allow_approximate
      ).compare_many(comparisons)
    end

    # Compares every adjacent reconstructed state in an inclusive version range,
    # by default the record's whole history through its current state.
    #: (untyped, ?from: untyped, ?to: untyped, ?within: untyped, ?associations: association_option, ?ignore: ignore_option, ?version_scope: untyped, ?close_on: Symbol?, ?allow_approximate: bool) -> Array[Step]
    def timeline( # rubocop:disable Metrics/ParameterLists
      record,
      from: nil,
      to: nil,
      within: nil,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      version_scope: nil,
      close_on: nil,
      allow_approximate: false
    )
      Deprecation.close_on!(close_on, within)
      PaperTrailAdapter.new(
        associations: associations, ignore: ignore, allow_approximate: allow_approximate
      ).timeline(
        record,
        from: from,
        to: to,
        within: within,
        version_scope: version_scope
      )
    end

    # Compares adjacent root and selected-descendant activity boundaries.
    #: (untyped, ?from: untyped, ?to: untyped, ?within: untyped, ?associations: association_option, ?ignore: ignore_option, ?reload_live_endpoints: bool?, ?version_scope: untyped, ?close_on: Symbol?, ?snapshots: bool, ?group: Symbol?, ?recorded_changes: bool, ?allow_approximate: bool) -> Array[ActivityStep]
    def activity_timeline( # rubocop:disable Metrics/ParameterLists
      record,
      from: nil,
      to: nil,
      within: nil,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      reload_live_endpoints: nil,
      version_scope: nil,
      close_on: nil,
      snapshots: false,
      group: nil,
      recorded_changes: false,
      allow_approximate: false
    )
      Deprecation.close_on!(close_on, within)
      PaperTrailAdapter.new(
        associations: associations, ignore: ignore,
        reload_live_endpoints: Deprecation.reload_live_endpoints!(reload_live_endpoints),
        recorded_changes: recorded_changes, allow_approximate: allow_approximate
      ).activity_timeline(
        record,
        from: from,
        to: to,
        within: within,
        version_scope: version_scope,
        group: group,
        snapshots: snapshots
      )
    end

    # Builds an endpoint diff and root-checkpoint timeline while normalizing each version once.
    #: (untyped, ?from: untyped, ?to: untyped, ?within: untyped, ?associations: association_option, ?ignore: ignore_option, ?activity: bool, ?version_scope: untyped, ?close_on: Symbol?, ?snapshots: bool, ?group: Symbol?, ?recorded_changes: bool, ?allow_approximate: bool) -> Analysis
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
      group: nil,
      recorded_changes: false,
      allow_approximate: false
    )
      Deprecation.close_on!(close_on, within)
      PaperTrailAdapter.new(
        associations: associations, ignore: ignore, recorded_changes: recorded_changes,
        allow_approximate: allow_approximate
      ).analyze(
        record,
        from: from,
        to: to,
        within: within,
        activity: activity,
        version_scope: version_scope,
        snapshots: snapshots,
        group: group
      )
    end

    # Analyzes an array of records over one shared range, preparing their
    # selected history once for the batch instead of once per record, and
    # returns a frozen Hash keyed by identity. Roots with nothing to report in
    # the window return an empty `Analysis`. To let a relation choose the
    # records, use `analyze_scope`.
    #: (Array[untyped], ?within: untyped, ?associations: association_option, ?ignore: ignore_option, ?activity: bool, ?version_scope: untyped, ?close_on: Symbol?, ?snapshots: bool, ?group: Symbol?, ?allow_expensive: bool?, ?recorded_changes: bool, ?allow_approximate: bool) -> Hash[identity, Analysis]
    def analyze_many( # rubocop:disable Metrics/ParameterLists
      records,
      within: nil,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      activity: false,
      version_scope: nil,
      close_on: nil,
      snapshots: false,
      group: nil,
      allow_expensive: nil,
      recorded_changes: false,
      allow_approximate: false
    )
      Deprecation.close_on!(close_on, within)
      Deprecation.allow_expensive!(allow_expensive)
      PaperTrailAdapter.new(
        associations: associations, ignore: ignore,
        recorded_changes: recorded_changes, allow_approximate: allow_approximate
      ).analyze_many(records, within: within, activity: activity, version_scope: version_scope,
                              snapshots: snapshots, group: group)
    end

    # Analyzes every root the relation reaches whose history moved inside the
    # window. With `activity: true`, a change to a record on one of the
    # requested association paths also counts, because the activity timeline
    # reports it. Joined duplicates are read in bounded pages and analyzed once.
    #
    # `limit:` is required and exceeding it raises. Selection moves into the gem
    # here. The relation's own limit/offset select the live page; this separate
    # ceiling rejects too many unique roots rather than truncating that page.
    #
    # Returns a `ScopedAnalysis`, which destructures:
    #
    #   analyses, unreachable = PaperTrailDiff.analyze_scope(
    #     Article.where(status: 'published'), within: july, limit: 500
    #   )
    #
    # `unreachable` names roots that changed in the window but have no live row
    # left, independently of the live page's pagination and safety ceiling.
    # A relation's conditions are evaluated against the live table, so a
    # destroyed root cannot be tested against them at all -- its history is
    # intact and the state it held at destruction may well have matched. Those
    # roots are reported rather than dropped so that a page auditing deletions
    # is told where to look instead of quietly coming up short.
    #
    # Note also that a relation selects on current state, not on state during
    # the window: `where(status: 'published')` means published *now*, which is a
    # different set from what was published while the window was open.
    #: (untyped, limit: Integer?, ?within: untyped, ?associations: association_option, ?ignore: ignore_option, ?activity: bool, ?version_scope: untyped, ?close_on: Symbol?, ?snapshots: bool, ?group: Symbol?, ?historical_filter: untyped, ?max_filter_versions: Integer, ?include_deleted: bool, ?allow_expensive: bool?, ?recorded_changes: bool, ?allow_approximate: bool) -> ScopedAnalysis
    def analyze_scope( # rubocop:disable Metrics/ParameterLists
      scope,
      limit:,
      within: nil,
      associations: [],
      ignore: DEFAULT_IGNORED_ATTRIBUTES,
      activity: false,
      version_scope: nil,
      close_on: nil,
      snapshots: false,
      group: nil,
      historical_filter: nil,
      max_filter_versions: HistoricalFilter::DEFAULT_VERSION_LIMIT,
      include_deleted: false,
      allow_expensive: nil,
      recorded_changes: false,
      allow_approximate: false
    )
      Deprecation.close_on!(close_on, within)
      Deprecation.allow_expensive!(allow_expensive)
      adapter = PaperTrailAdapter.new(associations: associations, ignore: ignore,
                                      recorded_changes: recorded_changes,
                                      allow_approximate: allow_approximate)
      adapter.analyze_scope(
        scope, limit: limit, within: within, activity: activity,
               version_scope: version_scope, snapshots: snapshots, group: group,
               historical_filter: historical_filter, max_filter_versions: max_filter_versions,
               include_deleted: include_deleted
      )
    end

    # Recent root and selected-child activity through the current saved state,
    # for every root that changed or whose requested associations did.
    # Historical windows remain explicit on analyze_scope; this entry point is
    # deliberately named for a report through now rather than an as-of query.
    #: (untyped, since: untyped, limit: Integer, ?associations: association_option, ?ignore: ignore_option, ?snapshots: bool, ?group: Symbol?, ?include_deleted: bool, ?historical_filter: untyped, ?max_filter_versions: Integer, ?allow_expensive: bool?, ?recorded_changes: bool, ?allow_approximate: bool) -> ScopedAnalysis
    def report( # rubocop:disable Metrics/ParameterLists
      scope, since:, limit:, associations: [], ignore: DEFAULT_IGNORED_ATTRIBUTES,
      snapshots: false, group: nil, include_deleted: false, historical_filter: nil,
      max_filter_versions: HistoricalFilter::DEFAULT_VERSION_LIMIT, allow_expensive: nil,
      recorded_changes: false, allow_approximate: false
    )
      # A range here would become the start of another range.
      if since.nil? || since.is_a?(Range)
        raise InvalidTimeRangeError, '`since` must be a time, date, or string; for a range, ' \
                                     'pass it as `within:` to analyze_scope'
      end

      analyze_scope(
        scope,
        within: since..Time.now.utc, limit: limit, associations: associations,
        ignore: ignore, activity: true, snapshots: snapshots, group: group,
        include_deleted: include_deleted, historical_filter: historical_filter,
        max_filter_versions: max_filter_versions, allow_expensive: allow_expensive,
        recorded_changes: recorded_changes, allow_approximate: allow_approximate
      )
    end

    # Warns about deprecated options; see Deprecation.
    #: () -> untyped
    def deprecator
      Deprecation.deprecator
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

    # Reports known reconstruction hazards without mutating application state,
    # for the endpoints `compare` takes: two versions, or a version and the
    # current record. Every reason `compare` would refuse them is an error.
    #: (untyped, untyped, ?associations: association_option, ?allow_approximate: bool) -> DiagnosticReport
    def diagnose(from, to, associations: [], allow_approximate: false)
      HistoryDiagnostics.new(from, to, associations: associations,
                                       allow_approximate: allow_approximate).call
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
    #: (untyped, ?untyped) -> nested_changes
    def nested_changes(change, to_value = nil)
      # Tested by type rather than by responding to `from`: ActiveSupport gives
      # String#from, so duck-typing here quietly reads a plain string as a pair.
      return NestedComparator.call(change.from, change.to) if change.is_a?(ValueChange)

      NestedComparator.call(change, to_value)
    end

    # Reads what PaperTrail recorded with one version: its `object_changes`,
    # typed by the version's model, as `{ "title" => <from "Draft" to "Published"> }`.
    # Activity methods read it for every step source with `recorded_changes: true`.
    #
    # A step's diff compares the states before and after an event, so it also
    # includes anything saved without a version in between; this does not.
    # Returns nil when nothing was recorded (no `object_changes` column, or no
    # value for this version), which differs from a recorded empty hash. Unlike
    # PaperTrail's `version.changeset`, it never loads the record, so it costs no
    # query per version and still types a deleted record's changes. `ignore:`
    # takes attribute names, as an array, and defaults to `updated_at`.
    #: (untyped, ?ignore: Array[String | Symbol]) -> Hash[String, ValueChange]?
    def recorded_changes(version, ignore: DEFAULT_IGNORED_ATTRIBUTES)
      RecordedChanges.call(version, ignore: ignore)
    end
  end
end
