# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The changes PaperTrail wrote with one version, typed by the version's model.
  #
  # A step's diff compares reconstructed states, so it also holds whatever was
  # saved without a version before the next one was read. This is the other
  # account of the same event: only what PaperTrail recorded for it. Comparing
  # the two is how a caller tells an unrecorded write from the event's own edit.
  #
  # PaperTrail's `version.changeset` finds the model through `version.item`,
  # which is a query per version and nothing at all once the record is deleted.
  # The version already names its model, so neither is needed here.
  class RecordedChanges
    IGNORE_NAMES_REQUIRED = 'ignore: must be an array of strings or symbols; a version ' \
                            'has no association path for paths: to match'
    private_constant :IGNORE_NAMES_REQUIRED

    #: (untyped, ignore: untyped) -> Hash[String, ValueChange]?
    def self.call(version, ignore:)
      new(version, ignore: ignore).call
    end

    #: (untyped, ignore: untyped) -> void
    def initialize(version, ignore:)
      @version = version
      @ignore = ignore
    end

    #: () -> Hash[String, ValueChange]?
    def call
      raise InvalidEndpointError, 'expected a PaperTrail version' unless Endpoint.version?(@version)

      ignored = ignored_names
      return unless recorded?

      model_class = Endpoint.model_class(@version)
      changes = ActivityEventRecordResolver.new.deserialized_changeset(@version, model_class)
      return if changes.nil?

      value_changes(changes, Array(model_class.primary_key) + ignored)
    end

    private

    # @rbs @version: untyped
    # @rbs @ignore: untyped

    # Validated before anything is read, so a bad option fails the same way
    # whether or not this version happened to record changes. Subclasses of
    # Array and String pass, as in other methods' `ignore:`; Symbol has none.
    #: () -> Array[String]
    def ignored_names
      valid = @ignore.is_a?(Array) && @ignore.all? do |name|
        name.is_a?(String) || name.instance_of?(Symbol)
      end
      raise ConfigurationError, IGNORE_NAMES_REQUIRED unless valid

      @ignore.map(&:to_s)
    end

    # Without the column, or with it left empty for this version, nothing was
    # recorded. That is not the same answer as a recorded empty changeset.
    #: () -> bool
    def recorded?
      @version.class.column_names.include?('object_changes') && !@version.object_changes.nil?
    end

    # Primary keys identify the record rather than describe it, as in a diff.
    #: (untyped, Array[String]) -> Hash[String, ValueChange]
    def value_changes(changes, excluded)
      recorded = {} #: Hash[String, ValueChange]
      changes.each do |name, values|
        key = name.to_s
        next if excluded.include?(key)

        recorded[key] = ValueChange.new(from: values.first, to: values.last)
      end
      recorded.sort.to_h.freeze
    end
  end
end
