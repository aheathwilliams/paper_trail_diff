# frozen_string_literal: true
# rbs_inline: enabled

require 'active_support/notifications'

module PaperTrailDiff
  # Emits quiet, namespaced runtime events for application-owned diagnostics.
  module Instrumentation
    module_function

    #: (String | Symbol, Hash[Symbol, untyped]) { () -> untyped } -> untyped
    def instrument(event, payload, &)
      active_support = Object.const_get(:ActiveSupport) #: untyped
      notifications = active_support.const_get(:Notifications) #: untyped
      notifications.instrument(
        "#{event}.paper_trail_diff",
        payload,
        &
      )
    end

    #: (association_paths: Array[String], reload_live_endpoints: bool) -> Hash[Symbol, untyped]
    def comparison_payload(association_paths:, reload_live_endpoints:)
      {
        association_paths: association_paths,
        reload_live_endpoints: reload_live_endpoints
      }
    end
  end
end
