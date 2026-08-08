# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Base error for failures detected by paper_trail_diff.
  class Error < StandardError; end

  # Raised when a public option has an invalid type, key, value, or path.
  class ConfigurationError < Error; end

  # Raised when compare endpoints do not belong to the same PaperTrail item.
  class VersionMismatchError < Error; end

  # Raised when a timeline boundary is absent or the requested range is reversed.
  class InvalidTimelineRangeError < Error; end

  # Raised when a requested ActiveRecord association does not exist.
  class UnknownAssociationError < Error; end

  # Raised when a requested association macro is not supported.
  class UnsupportedAssociationError < Error; end

  # Raised when association comparison is requested without an available PT-AT setup.
  class AssociationTrackingUnavailableError < Error; end

  # Raised when recorded PT-AT metadata cannot reliably reconstruct a selected association.
  class IncompleteAssociationHistoryError < Error; end
end
