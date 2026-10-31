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
  # The endpoints are a comparison's: two versions, or a version and the
  # current record, in either order. Two current records read no history, so
  # nothing is checked.
  class HistoryDiagnostics
    STOPPING_CODES = %i[
      unknown_association unsupported_association association_tracking_unavailable
    ].freeze

    #: (untyped, untyped, associations: association_option, ?allow_approximate: bool) -> void
    def initialize(from, to, associations:, allow_approximate: false)
      @versions = validated_versions(from, to)
      @tree = AssociationTree.build(associations)
      @traversal = AssociationTraversal.new(@tree)
      @preparer = TraversalPreparer.new(tree: @tree, traversal: @traversal,
                                        allow_approximate: allow_approximate)
      @allow_approximate = allow_approximate
      @issues = [] #: Array[DiagnosticIssue]
    end

    #: () -> DiagnosticReport
    def call
      unless @versions.empty?
        model_class = Endpoint.model_class(@versions.fetch(0))
        # Runs whether or not associations are selected: unorderable versions
        # corrupt a scalar timeline just as surely, and a report that inspected
        # nothing has no business answering `ok?`.
        inspect_version_sequence
        inspect_associations(model_class) unless @tree.empty?
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
      inspect_approximate_paths(model_class) if @allow_approximate
      inspect_checkpoint_timestamp(model_class)
      inspect_habtm(model_class, selected)
    end

    # @rbs @versions: Array[untyped]
    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @preparer: TraversalPreparer
    # @rbs @allow_approximate: bool
    # @rbs @issues: Array[DiagnosticIssue]

    # The endpoints that are versions, in the order given.
    #: (untyped, untyped) -> Array[untyped]
    def validated_versions(from, to)
      Endpoint.validate!(from)
      Endpoint.validate!(to)
      unless Endpoint.identity(from) == Endpoint.identity(to)
        raise VersionMismatchError, 'endpoints must belong to the same PaperTrail item'
      end

      [from, to].select { |endpoint| Endpoint.version?(endpoint) }
    end

    #: (Array[Array[untyped]]) -> void
    def inspect_polymorphic_targets(selected)
      selected.each do |path, reflection|
        next unless reflection.polymorphic?

        add_warning(:polymorphic_target_unverified, 'polymorphic target cannot be verified', path)
      end
    end

    # Accepted, but read the way `allow_approximate:` describes.
    #: (untyped) -> void
    def inspect_approximate_paths(model_class)
      BatchSafety.fallback_paths(@traversal, model_class).each do |path, reason|
        add_warning(:approximate_association,
                    "association #{path} is read approximately with PT-AT (#{reason}): a " \
                    'record that entered or left it since is reported wrongly', path)
      end
    end

    #: (untyped, Array[Array[untyped]]) -> void
    def inspect_habtm(model_class, selected)
      habtm = selected.select { |_, reflection| reflection.macro == :has_and_belongs_to_many }
      return if habtm.empty?

      inspect_transaction_metadata(habtm.map(&:first))
      inspect_shared_transactions(model_class, habtm)
    end

    # PT-AT does not record which owner a HABTM member belongs to, so a
    # transaction that more than one owner recorded members in cannot be read.
    #: (untyped, Array[Array[untyped]]) -> void
    def inspect_shared_transactions(model_class, habtm)
      versions = @versions.select do |version|
        version.respond_to?(:transaction_id) && version.transaction_id
      end
      habtm.each do |path, reflection|
        owners = HabtmTransactionOwners.new(model_class, reflection)
        versions.each do |version|
          next unless owners.ambiguous?(version.transaction_id)

          add_error(:habtm_transaction_shared,
                    'HABTM endpoint shares its transaction with another owner of the association',
                    path, version.id)
        end
      end
    end

    # With the current record as one endpoint there is one version, and the
    # sequence runs on from it.
    #: () -> void
    def inspect_version_sequence
      first, last = @versions
      @issues.concat(
        VersionSequenceDiagnostics.new(first, last, associations_selected: !@tree.empty?).call
      )
    end

    #: (untyped) -> void
    def inspect_checkpoint_timestamp(model_class)
      return if synchronized_timestamp_disabled?(model_class)

      message = 'manual checkpoints should set synchronize_version_creation_timestamp: false'
      add_warning(:synchronized_version_timestamp, message)
    end

    #: (Array[String]) -> void
    def inspect_transaction_metadata(paths)
      @versions.each do |version|
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

    #: (untyped) -> bool
    def synchronized_timestamp_disabled?(model_class)
      options = model_class.paper_trail_options
      options[:synchronize_version_creation_timestamp] == false
    rescue NoMethodError
      false
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
