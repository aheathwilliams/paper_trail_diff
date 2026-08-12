# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # One immutable historical-reconstruction setup finding.
  class DiagnosticIssue
    attr_reader :severity #: Symbol
    attr_reader :code #: Symbol
    attr_reader :message #: String
    attr_reader :path #: String?
    attr_reader :version_id #: untyped

    #: (severity: Symbol, code: Symbol, message: String, ?path: String?, ?version_id: untyped) -> void
    def initialize(severity:, code:, message:, path: nil, version_id: nil)
      @severity = severity
      @code = code
      @message = Support.immutable_copy(message)
      @path = Support.immutable_copy(path)
      @version_id = Support.immutable_copy(version_id)
      freeze
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        severity: severity,
        code: code,
        message: message,
        path: path,
        version_id: version_id
      }
    end
  end

  # Immutable diagnostics for a requested historical association comparison.
  class DiagnosticReport
    attr_reader :issues #: Array[DiagnosticIssue]

    #: (issues: Array[DiagnosticIssue]) -> void
    def initialize(issues:)
      @issues = issues.dup.freeze
      freeze
    end

    #: () -> Array[DiagnosticIssue]
    def errors
      issues.select { |issue| issue.severity == :error }.freeze
    end

    #: () -> Array[DiagnosticIssue]
    def warnings
      issues.select { |issue| issue.severity == :warning }.freeze
    end

    #: () -> bool
    def ok?
      errors.empty?
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      { ok: ok?, issues: Support.serialize(issues) }
    end
  end

  # Performs read-only checks for known PaperTrail/PT-AT reconstruction hazards.
  class HistoryDiagnostics
    #: (untyped, untyped, associations: Array[String | Symbol]) -> void
    def initialize(from_version, to_version, associations:)
      @from_version = from_version
      @to_version = to_version
      @tree = AssociationTree.build(associations)
      @issues = [] #: Array[DiagnosticIssue]
    end

    #: () -> DiagnosticReport
    def call
      model_class = validated_model_class
      # Runs whether or not associations are selected: unorderable versions
      # corrupt a scalar timeline just as surely, and a report that inspected
      # nothing has no business answering `ok?`.
      inspect_version_order
      return DiagnosticReport.new(issues: @issues) if @tree.empty?

      unless association_tracking_available?
        add_error(:association_tracking_unavailable, tracking_unavailable_message)
        return DiagnosticReport.new(issues: @issues)
      end

      traversal = AssociationTraversal.new(@tree)
      selected = traversal.selected_reflections(model_class)
      inspect_targets(selected)
      inspect_checkpoint_timestamp(model_class)
      inspect_habtm(selected)
      DiagnosticReport.new(issues: @issues)
    end

    private

    # @rbs @from_version: untyped
    # @rbs @to_version: untyped
    # @rbs @tree: AssociationTree
    # @rbs @issues: Array[DiagnosticIssue]

    #: () -> untyped
    def validated_model_class
      unless version_identity(@from_version) == version_identity(@to_version)
        raise VersionMismatchError, 'versions must belong to the same PaperTrail item'
      end

      Object.const_get(version_type(@from_version))
    rescue NoMethodError => e
      raise VersionMismatchError, 'expected PaperTrail version endpoints', cause: e
    end

    #: (Array[Array[untyped]]) -> void
    def inspect_targets(selected)
      selected.each do |path, reflection|
        if reflection.polymorphic?
          add_warning(:polymorphic_target_unverified, 'polymorphic target cannot be verified', path)
          next
        end

        inspect_versioned_model(reflection.klass, path)
        inspect_through_model(reflection, path) if reflection.options[:through]
      end
    end

    #: (Array[Array[untyped]]) -> void
    def inspect_habtm(selected)
      paths = selected.filter_map do |path, reflection|
        path if reflection.macro == :has_and_belongs_to_many
      end
      return if paths.empty?

      inspect_transaction_metadata(paths)
    end

    # Ordering falls back to the id when timestamps tie, which only recovers the
    # real sequence for ids that increase with insertion. Reported before a run
    # rather than after a wrong answer.
    #: () -> void
    def inspect_version_order
      pair = Support.ambiguous_pair(ordered_range_versions)
      return unless pair

      add_error(:ambiguous_version_order, Support.ambiguous_message(pair), nil, pair.first.id)
    rescue StandardError
      nil
    end

    #: () -> Array[untyped]
    def ordered_range_versions
      bounds = [@from_version.created_at, @to_version.created_at].compact.sort
      return [] unless bounds.length == 2

      @from_version.class
                   .where(item_type: @from_version.item_type, item_id: @from_version.item_id)
                   .where(created_at: bounds.first..bounds.last)
                   .to_a
                   .sort_by { |version| Support.chronological_version_key(version) }
    end

    #: (untyped) -> void
    def inspect_checkpoint_timestamp(model_class)
      return if synchronized_timestamp_disabled?(model_class)

      message = 'manual checkpoints should set synchronize_version_creation_timestamp: false'
      add_warning(:synchronized_version_timestamp, message)
    end

    #: (Array[String]) -> void
    def inspect_transaction_metadata(paths)
      [@from_version, @to_version].each do |version|
        if !version.respond_to?(:transaction_id)
          add_error(:transaction_id_column_missing, 'version has no transaction_id column')
        elsif version.transaction_id.nil?
          paths.each do |path|
            add_error(
              :transaction_id_missing,
              'HABTM endpoint has no transaction-backed association snapshot',
              path,
              version.id
            )
          end
        end
      end
    end

    #: (untyped, String) -> void
    def inspect_versioned_model(model_class, path)
      return if model_versioned?(model_class)

      add_warning(
        :unversioned_association_target,
        "#{model_class.name} does not appear to have PaperTrail enabled",
        path
      )
    end

    #: (untyped, String) -> void
    def inspect_through_model(reflection, path)
      model_class = reflection.through_reflection.klass
      return if model_versioned?(model_class)

      add_warning(
        :unversioned_through_model,
        "#{model_class.name} does not appear to have PaperTrail enabled",
        path
      )
    end

    #: (untyped) -> bool
    def model_versioned?(model_class)
      model_class.respond_to?(:paper_trail_options) && !model_class.paper_trail_options.nil?
    end

    #: (untyped) -> bool
    def synchronized_timestamp_disabled?(model_class)
      options = model_class.paper_trail_options
      options[:synchronize_version_creation_timestamp] == false
    rescue NoMethodError
      false
    end

    #: () -> bool
    def association_tracking_available?
      paper_trail = Object.const_get(:PaperTrail) #: untyped
      config = paper_trail.config #: untyped
      !!(defined?(::PaperTrailAssociationTracking) &&
        config.respond_to?(:track_associations?) && config.track_associations?)
    end

    #: (untyped) -> Array[String]
    def version_identity(version)
      [version.item_type.to_s, version.item_id.to_s]
    end

    #: (untyped) -> String
    def version_type(version)
      subtype = version.item_subtype if version.respond_to?(:item_subtype)
      subtype.to_s.empty? ? version.item_type.to_s : subtype.to_s
    end

    #: () -> String
    def tracking_unavailable_message
      'association tracking must be loaded and enabled to diagnose associations'
    end

    #: (Symbol, String, ?String?, ?untyped) -> void
    def add_error(code, message, path = nil, version_id = nil)
      add_issue(:error, code, message, path, version_id)
    end

    #: (Symbol, String, ?String?) -> void
    def add_warning(code, message, path = nil)
      add_issue(:warning, code, message, path, nil)
    end

    #: (Symbol, Symbol, String, String?, untyped) -> void
    def add_issue(severity, code, message, path, version_id)
      @issues << DiagnosticIssue.new(
        severity: severity,
        code: code,
        message: message,
        path: path,
        version_id: version_id
      )
    end
  end
end
