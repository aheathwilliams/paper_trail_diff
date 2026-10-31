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
    ALLOW_EXPENSIVE = 'allow_expensive: is deprecated and has no effect: allow_approximate: true ' \
                      'alone accepts a path read with PT-AT, in batch methods too. Remove the ' \
                      'option.'

    # Required when first used, as the library loads nothing it does not need.
    #: () -> untyped
    def self.deprecator
      @deprecator ||= begin
        require 'active_support/deprecation'
        active_support = Object.const_get(:ActiveSupport) #: untyped
        active_support.const_get(:Deprecation).new('a future release', 'paper_trail_diff')
      end
    end

    # The one value close_on: took. It named what ends a wall-clock window,
    # so it was meaningless without one, and until it is removed it is still
    # checked as it was.
    CLOSE_ON_CURRENT = :current

    #: (Symbol?, untyped) -> void
    def self.close_on!(close_on, within)
      return if close_on.nil?
      unless close_on == CLOSE_ON_CURRENT
        raise ConfigurationError, "close_on: must be #{CLOSE_ON_CURRENT.inspect} or nil"
      end
      raise ConfigurationError, 'close_on: requires `within`' if within.nil?

      deprecator.warn(CLOSE_ON)
    end

    #: (untyped) -> void
    def self.allow_expensive!(allow_expensive)
      deprecator.warn(ALLOW_EXPENSIVE) unless allow_expensive.nil?
    end
  end
end
