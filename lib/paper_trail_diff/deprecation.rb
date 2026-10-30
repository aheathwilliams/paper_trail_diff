# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Warns about options that do nothing any more and will be removed. In a
  # Rails app, register the deprecator to configure it with the app's own:
  #
  #   Rails.application.deprecators[:paper_trail_diff] = PaperTrailDiff.deprecator
  module Deprecation
    CLOSE_ON = 'close_on: is deprecated and has no effect: a window already closes on the ' \
               'current record when nothing on its requested paths was recorded after it. ' \
               'Remove the option.'

    # Required when first used, as the library loads nothing it does not need.
    #: () -> untyped
    def self.deprecator
      @deprecator ||= begin
        require 'active_support/deprecation'
        active_support = Object.const_get(:ActiveSupport) #: untyped
        active_support.const_get(:Deprecation).new('a future release', 'paper_trail_diff')
      end
    end

    #: (Symbol?) -> void
    def self.close_on!(close_on)
      deprecator.warn(CLOSE_ON) unless close_on.nil?
    end
  end
end
