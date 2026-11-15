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
  # The version already names its model, and an STI subclass's types are
  # read from the class it recorded (see RecordedClass), so neither is needed
  # here.
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
      ReadableHistory.check_version!(@version, 'object_changes')
      return unless recorded?

      model_class = RecordedClass.for(@version)
      changes = ActivityEventRecordResolver.new.deserialized_changeset(@version, model_class)
      return if changes.nil?

      value_changes(model_class, changes, Array(model_class.primary_key) + ignored)
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
    # recorded. That is not the same answer as a recorded empty changeset. A
    # version need not be an Active Record model, as for compare.
    #: () -> bool
    def recorded?
      @version.respond_to?(:object_changes) && !@version.object_changes.nil?
    end

    # An adapter may name its changes with symbols.
    #: (untyped) -> Hash[String, untyped]
    def named(changes)
      changes.to_h { |name, values| [name.to_s, values] }
    end

    # Primary keys identify the record rather than describe it, as in a diff.
    # Each side is read as a step's diff reads it (see StoredValues), so a
    # value compares equal to the state the change produced. A name the model
    # no longer has, such as a column since dropped, is left out, as a diff
    # leaves it out. So is a change whose sides read alike, as a diff compares
    # them: Rails records a value assigned in another form than the column
    # keeps, such as a time of day with another date, though the row holds
    # what it held.
    # Each side of the changes in the form the database stores it.
    #: (untyped, Hash[String, untyped]) -> [Hash[String, untyped], Hash[String, untyped]]
    def stored_sides(model_class, kept)
      [StoredValues.apply(model_class, kept.transform_values(&:first)),
       StoredValues.apply(model_class, kept.transform_values(&:last))]
    end

    #: (untyped, untyped, Array[String]) -> Hash[String, ValueChange]
    def value_changes(model_class, changes, excluded)
      kept = named(changes).slice(*model_class.column_names).except(*excluded)
      from, to = stored_sides(model_class, kept)
      kept.keys.sort.filter_map do |key|
        before = from.fetch(key)
        after = to.fetch(key)
        [key, ValueChange.new(from: before, to: after)] unless Support.same?(before, after)
      end.to_h.freeze
    end
  end
end
