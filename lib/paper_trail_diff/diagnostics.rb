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
  #
  # The endpoints are a comparison's: two versions in time order, or a
  # version and the current record, in either order. Two current records read no history, so
  # nothing is checked.
  class HistoryDiagnostics
    STOPPING_CODES = %i[
      unknown_association unsupported_association association_tracking_unavailable
    ].freeze

    #: (untyped, untyped, associations: association_option) -> void
    def initialize(from, to, associations:)
      @versions = validated_versions(from, to)
      @tree = AssociationTree.build(associations)
      @traversal = AssociationTraversal.new(@tree)
      @preparer = TraversalPreparer.new(traversal: @traversal)
      @issues = [] #: Array[DiagnosticIssue]
    end

    #: () -> DiagnosticReport
    def call
      unless @versions.empty?
        model_class = Endpoint.model_class(@versions.fetch(0))
        # Nothing else can be read from a history without states.
        stateless = Support.stateless_reason(model_class)
        return report_stateless(stateless) if stateless

        ReadSnapshot.call([model_class]) do
          # Runs whether or not associations are selected: unorderable versions
          # corrupt a scalar timeline just as surely, and a report that inspected
          # nothing has no business answering `ok?`.
          inspect_version_sequence
          inspect_associations(model_class) unless @tree.empty?
        end
      end
      DiagnosticReport.new(issues: @issues)
    end

    private

    # Each refusal a comparison would raise is an error, so `ok?` is false
    # exactly when one would. The checks after them read reflections that must
    # resolve and PT-AT records that must be there.
    #: (untyped) -> void
    def inspect_associations(model_class)
      refusals = @preparer.refusals(model_class, historical: true)
      refusals.each { |refusal| add_error(refusal.code, refusal.message, refusal.path) }
      return if refusals.any? { |refusal| STOPPING_CODES.include?(refusal.code) }

      selected = @traversal.selected_reflections(model_class)
      inspect_polymorphic_targets(selected)
      inspect_checkpoint_timestamp(model_class)
    end

    # @rbs @versions: Array[untyped]
    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @preparer: TraversalPreparer
    # @rbs @issues: Array[DiagnosticIssue]

    # The endpoints that are versions, in the order given. Endpoints that
    # `compare` rejects whatever their history raise as it would.
    #: (untyped, untyped) -> Array[untyped]
    def validated_versions(from, to)
      Endpoint.validate!(from)
      Endpoint.validate!(to)
      unless Endpoint.identity(from) == Endpoint.identity(to)
        raise VersionMismatchError, 'endpoints must belong to the same PaperTrail item'
      end

      Endpoint.validate_order!(from, to)

      [from, to].select { |endpoint| Endpoint.version?(endpoint) }
    end

    #: (Array[Array[untyped]]) -> void
    def inspect_polymorphic_targets(selected)
      selected.each do |path, reflection|
        next unless reflection.polymorphic?

        add_warning(:polymorphic_target_unverified, 'polymorphic target cannot be verified', path)
      end
    end

    # With the current record as one endpoint there is one version, and the
    # sequence runs on from it.
    #: () -> void
    def inspect_version_sequence
      first, last = @versions
      @issues.concat(VersionSequenceDiagnostics.new(first, last).call)
    end

    #: (untyped) -> void
    def inspect_checkpoint_timestamp(model_class)
      return if synchronized_timestamp_disabled?(model_class)

      message = 'manual checkpoints should set synchronize_version_creation_timestamp: false'
      add_warning(:synchronized_version_timestamp, message)
    end

    #: (untyped) -> bool
    def synchronized_timestamp_disabled?(model_class)
      options = model_class.paper_trail_options
      options[:synchronize_version_creation_timestamp] == false
    rescue NoMethodError
      false
    end

    #: (String) -> DiagnosticReport
    def report_stateless(reason)
      add_error(:stateless_versions, reason)
      DiagnosticReport.new(issues: @issues)
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
