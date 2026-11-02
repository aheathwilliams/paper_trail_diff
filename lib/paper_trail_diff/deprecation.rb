# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Warns about options that are deprecated and will be removed. None is now,
  # but the deprecator stays, so that an app that registered it still boots
  # and hears of the next one. In a Rails app, register it to configure it
  # with the app's own:
  #
  #   Rails.application.deprecators[:paper_trail_diff] = PaperTrailDiff.deprecator
  module Deprecation
    # Required when first used, as the library loads nothing it does not need.
    #: () -> untyped
    def self.deprecator
      @deprecator ||= begin
        require 'active_support/deprecation'
        active_support = Object.const_get(:ActiveSupport) #: untyped
        active_support.const_get(:Deprecation).new('a future release', 'paper_trail_diff')
      end
    end
  end
end
