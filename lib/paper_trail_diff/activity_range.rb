# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Tests activity versions against a historical-version or wall-clock range end.
  class ActivityRange
    #: (untyped, untyped) -> void
    def initialize(start_version, end_boundary)
      @start_version = start_version
      @end_boundary = end_boundary
    end

    #: (untyped) -> bool
    def include?(version)
      Support.compare_versions(@start_version, version) <= 0 && before_end?(version)
    end

    private

    # @rbs @start_version: untyped
    # @rbs @end_boundary: untyped

    #: (untyped) -> bool
    def before_end?(version)
      if Endpoint.version?(@end_boundary)
        return Support.compare_versions(version, @end_boundary) <= 0
      end

      version.created_at <= @end_boundary
    end
  end
end
