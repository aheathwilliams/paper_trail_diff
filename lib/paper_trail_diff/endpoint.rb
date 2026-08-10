# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Validates and describes explicit PaperTrail-version and live-record endpoints.
  module Endpoint
    module_function

    #: (untyped, untyped) -> void
    def validate_pair!(from_endpoint, to_endpoint)
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
    def validate_order!(from_endpoint, to_endpoint)
      return unless reversed_versions?(from_endpoint, to_endpoint)

      raise ReversedEndpointsError,
            'version endpoints must be given in chronological order; ' \
            'swap them to read the same difference in the other direction'
    end

    #: (untyped, untyped) -> bool
    def reversed_versions?(from_endpoint, to_endpoint)
      return false unless version?(from_endpoint) && version?(to_endpoint)

      Support.compare_versions(from_endpoint, to_endpoint).positive?
    end
    private_class_method :reversed_versions?

    #: (untyped) -> void
    def validate!(endpoint)
      return if version?(endpoint)

      validate_record!(endpoint)
    end

    #: (untyped) -> bool
    def version?(endpoint)
      endpoint.respond_to?(:reify) &&
        endpoint.respond_to?(:item_type) &&
        endpoint.respond_to?(:item_id)
    end

    #: (untyped) -> bool
    def record?(endpoint)
      !version?(endpoint) &&
        endpoint.respond_to?(:persisted?) &&
        endpoint.respond_to?(:destroyed?) &&
        endpoint.class.respond_to?(:base_class)
    end

    #: (untyped) -> Array[String]
    def identity(endpoint)
      if version?(endpoint)
        [endpoint.item_type.to_s, endpoint.item_id.to_s]
      elsif record?(endpoint)
        [endpoint.class.base_class.name.to_s, endpoint.id.to_s]
      else
        raise InvalidEndpointError, 'expected a PaperTrail version or persisted record endpoint'
      end
    end

    #: (untyped) -> untyped
    def model_class(version)
      subtype = version.item_subtype if version.respond_to?(:item_subtype)
      model_type = subtype.to_s.empty? ? version.item_type.to_s : subtype.to_s
      Object.const_get(model_type)
    rescue NameError => e
      raise InvalidEndpointError, "cannot resolve endpoint model: #{model_type}", cause: e
    end

    #: (untyped) -> untyped
    def reload_record(record)
      validate_record!(record)
      record.class.unscoped.find(record.id)
    rescue StandardError => e
      active_record = Object.const_get(:ActiveRecord) #: untyped
      record_not_found = active_record.const_get(:RecordNotFound) #: untyped
      raise unless e.is_a?(record_not_found)

      message = 'current record endpoint could not be reloaded from the database'
      raise InvalidEndpointError, message, cause: e
    end

    #: (untyped) -> void
    def validate_record!(record)
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
end
