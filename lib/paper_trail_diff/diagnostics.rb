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
    #: (untyped, untyped, associations: association_option) -> void
    def initialize(from, to, associations:)
      @versions = validated_versions(from, to)
      @tree = AssociationTree.build(associations)
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

    #: (untyped) -> void
    def inspect_associations(model_class)
      unless association_tracking_available?
        return add_error(:association_tracking_unavailable, tracking_unavailable_message)
      end

      selected = AssociationTraversal.new(@tree).selected_reflections(model_class)
      inspect_targets(selected)
      inspect_checkpoint_timestamp(model_class)
      inspect_habtm(model_class, selected)
    end

    # @rbs @versions: Array[untyped]
    # @rbs @tree: AssociationTree
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

    #: (untyped, String) -> void
    def inspect_versioned_model(model_class, path)
      return if model_versioned?(model_class)

      # An error rather than a warning: `ok?` must not stay true for a
      # comparison that cannot work, and this one raises at runtime.
      add_error(
        :unversioned_association_target,
        "#{model_class.name} does not appear to have PaperTrail enabled",
        path
      )
    end

    # An error, as for a target: a through reads past membership from the
    # versions of the model it goes through, so comparisons raise.
    #: (untyped, String) -> void
    def inspect_through_model(reflection, path)
      model_class = reflection.through_reflection.klass
      return if model_versioned?(model_class)

      add_error(
        :unversioned_through_model,
        "#{model_class.name} does not appear to have PaperTrail enabled",
        path
      )
    end

    #: (untyped) -> bool
    def model_versioned?(model_class)
      Support.versioned?(model_class)
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
