# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Validates and describes explicit PaperTrail-version and live-record endpoints.
  module Endpoint
    #: (untyped, untyped) -> void
    def self.validate_pair!(from_endpoint, to_endpoint)
      validate!(from_endpoint)
      validate!(to_endpoint)
      unless identity(from_endpoint) == identity(to_endpoint)
        raise VersionMismatchError, 'endpoints must belong to the same PaperTrail item'
      end

      validate_order!(from_endpoint, to_endpoint)
    end

    # Two versions carry no visible cue about which is earlier, so transposing
    # them is easy to do by accident and impossible to detect afterwards: the
    # result is a valid inverse diff and carries no direction of its own. It is
    # also redundant, because the two orders differ only in which side of each
    # change is `from`. A current-record endpoint is exempt: it is self-evidently
    # the live state, so putting it first is a deliberate reverse comparison.
    #: (untyped, untyped) -> void
    def self.validate_order!(from_endpoint, to_endpoint)
      return unless reversed_versions?(from_endpoint, to_endpoint)

      raise ReversedEndpointsError,
            'version endpoints must be given in chronological order; ' \
            'swap them to read the same difference in the other direction'
    end

    #: (untyped, untyped) -> bool
    def self.reversed_versions?(from_endpoint, to_endpoint)
      return false unless version?(from_endpoint) && version?(to_endpoint)

      Support.compare_versions(from_endpoint, to_endpoint).positive?
    end
    private_class_method :reversed_versions?

    #: (untyped) -> void
    def self.validate!(endpoint)
      return if version?(endpoint)

      validate_record!(endpoint)
    end

    # The record a method reads the history of: a record, saved or destroyed,
    # of a model PaperTrail versions.
    #: (untyped) -> void
    def self.validate_root!(record)
      unless record?(record)
        raise InvalidEndpointError, "expected a record, got #{described(record)}"
      end
      return if Support.versioned?(record.class)

      raise InvalidEndpointError,
            "#{record.class} is not versioned, so it has no history: add has_paper_trail to it"
    end

    # What a message names the value as. A relation is named rather than
    # inspected, which would load it, and by the name Active Record gives its
    # class. A class without a name is printed, as a class given itself is.
    #: (untyped) -> (String | Module)
    def self.described(value)
      return 'nil' if value.nil?
      return "the class #{value}" if value.is_a?(Module)

      value.class.name || value.class
    end
    private_class_method :described

    #: (untyped) -> bool
    def self.version?(endpoint)
      EndpointKind.call(endpoint) == :version
    end

    #: (untyped) -> bool
    def self.record?(endpoint)
      EndpointKind.call(endpoint) == :record
    end

    #: (untyped) -> Array[String]
    def self.identity(endpoint)
      if version?(endpoint)
        [endpoint.item_type.to_s, endpoint.item_id.to_s]
      elsif record?(endpoint)
        Support.record_identity(endpoint.class, endpoint.id)
      else
        raise InvalidEndpointError, 'expected a PaperTrail version or persisted record endpoint'
      end
    end

    #: (untyped) -> untyped
    def self.model_class(version)
      subtype = version.item_subtype if subtyped?(version)
      model_named(subtype.to_s.empty? ? version.item_type.to_s : subtype)
    end

    #: (String) -> untyped
    def self.model_named(type)
      Support.constant(type)
    rescue NameError
      raise InvalidEndpointError, "cannot resolve endpoint model: #{type}"
    end
    private_class_method :model_named

    # Whether the version has an `item_subtype` to read. An Active Record
    # version is asked whether it was read with the column, which costs less
    # than respond_to? (see Support.per_model) and answers for this row: a
    # version a caller read without the column has none.
    #: (untyped) -> bool
    def self.subtyped?(version)
      return version.respond_to?(:item_subtype) unless version.class.respond_to?(:column_names)

      version.has_attribute?(:item_subtype)
    end
    private_class_method :subtyped?

    # Every PaperTrail version of the record, whatever scope its versions
    # association has. Active Record reads a record given as an item_id as its
    # id, so mutant cannot tell `record` from `record.id` here.
    # mutant:disable
    #: (untyped) -> untyped
    def self.versions(record)
      VersionQuery.for_items(record.class, record.id)
    rescue NoMethodError
      raise InvalidTimelineRangeError, 'record does not expose a PaperTrail version history'
    end

    #: (untyped) -> untyped
    def self.reload_record(record)
      validate_record!(record)
      record.class.unscoped.find(record.id)
    rescue Support.constant('ActiveRecord::RecordNotFound')
      raise InvalidEndpointError, 'current record endpoint could not be reloaded from the database'
    end

    #: (untyped) -> void
    def self.validate_record!(record)
      unless record?(record)
        raise InvalidEndpointError, 'expected a PaperTrail version or persisted record endpoint'
      end
      unless record.persisted? && !record.destroyed?
        raise InvalidEndpointError, 'current record endpoint must be persisted and not destroyed'
      end
      return unless record.respond_to?(:has_changes_to_save?) && record.has_changes_to_save?

      raise InvalidEndpointError, 'current record endpoint must not have unsaved changes'
    end
    private_class_method :validate_record!
  end

  # Whether a value is a version, a record, or neither, answered once for
  # each Active Record class (see Support.per_model).
  module EndpointKind
    @kinds = {} #: Hash[untyped, Symbol]

    #: (untyped) -> Symbol
    def self.call(endpoint)
      kinds = @kinds #: Hash[untyped, Symbol]
      Support.per_model(kinds, endpoint) { |value| classify(value) }
    end

    #: (untyped) -> Symbol
    def self.classify(endpoint)
      if endpoint.respond_to?(:reify) && endpoint.respond_to?(:item_type) &&
         endpoint.respond_to?(:item_id)
        :version
      elsif endpoint.respond_to?(:persisted?) && endpoint.respond_to?(:destroyed?) &&
            endpoint.class.respond_to?(:base_class)
        :record
      else
        :other
      end
    end
    private_class_method :classify
  end
end
