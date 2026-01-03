# frozen_string_literal: true

module Findbug
  module RailsExt
    # ControllerMethods provides helper methods for Rails controllers.
    #
    # These methods are automatically included in all controllers via the Railtie.
    # They let you add custom context to errors and performance data.
    #
    # WHY CONTROLLER HELPERS?
    # =======================
    #
    # When an error occurs, you often want to know:
    # - Which user was affected?
    # - What were the request params?
    # - What was the user's plan/tier?
    # - What A/B experiment variant were they in?
    #
    # These helpers let you attach this context easily:
    #
    #   class ApplicationController < ActionController::Base
    #     before_action :set_findbug_context
    #
    #     def set_findbug_context
    #       findbug_set_user(current_user)
    #       findbug_set_context(
    #         plan: current_user&.plan,
    #         experiment: session[:ab_variant]
    #       )
    #     end
    #   end
    #
    # Then when an error occurs, all this context is captured automatically.
    #
    module ControllerMethods
      extend ActiveSupport::Concern

      included do
        # Store context in a thread-local variable
        # Thread-local means each request has its own context
        # This is important for thread-safe operation in Puma
        before_action :findbug_clear_context
        after_action :findbug_clear_context
      end

      # Set the current user for error context
      #
      # @param user [Object] the user object (any object with id, email, etc.)
      #
      # @example
      #   findbug_set_user(current_user)
      #
      # WHY A SEPARATE USER METHOD?
      # ---------------------------
      # Users are special - they're the most common context and have
      # special handling (we extract id, email, username automatically).
      #
      def findbug_set_user(user)
        return unless user

        Findbug::Capture::Context.set_user(
          id: user.try(:id),
          email: user.try(:email),
          username: user.try(:username) || user.try(:name)
        )
      end

      # Set custom context data
      #
      # @param data [Hash] key-value pairs to attach to errors
      #
      # @example
      #   findbug_set_context(
      #     organization_id: current_org.id,
      #     feature_flags: current_flags
      #   )
      #
      def findbug_set_context(data = {})
        Findbug::Capture::Context.merge(data)
      end

      # Add a tag (short key-value pair for filtering)
      #
      # @param key [String, Symbol] the tag key
      # @param value [String] the tag value
      #
      # @example
      #   findbug_tag(:environment, "production")
      #   findbug_tag(:region, "us-east-1")
      #
      # Tags are optimized for filtering/grouping in the dashboard.
      # Use context for detailed data, tags for filterable attributes.
      #
      def findbug_tag(key, value)
        Findbug::Capture::Context.add_tag(key, value)
      end

      # Add a breadcrumb (for debugging what happened before the error)
      #
      # @param message [String] what happened
      # @param category [String] category for grouping
      # @param data [Hash] additional data
      #
      # @example
      #   findbug_breadcrumb("User logged in", category: "auth")
      #   findbug_breadcrumb("Loaded products", category: "query", data: { count: 50 })
      #
      # Breadcrumbs help you understand the sequence of events leading to an error.
      # Think of them like a trail of breadcrumbs Hansel & Gretel left.
      #
      def findbug_breadcrumb(message, category: "default", data: {})
        Findbug::Capture::Context.add_breadcrumb(
          message: message,
          category: category,
          data: data,
          timestamp: Time.now.utc.iso8601(3)
        )
      end

      # Capture an exception manually with current context
      #
      # @param exception [Exception] the exception to capture
      # @param extra [Hash] additional context for this specific error
      #
      # @example
      #   begin
      #     external_api.call
      #   rescue ExternalAPIError => e
      #     findbug_capture(e, api: "payment_gateway")
      #     # handle gracefully
      #   end
      #
      def findbug_capture(exception, extra = {})
        Findbug.capture_exception(exception, extra)
      end

      private

      # Clear context between requests
      #
      # WHY CLEAR CONTEXT?
      # ------------------
      # Without clearing, context from one request could leak into another.
      # This is especially important in threaded servers like Puma where
      # threads are reused across requests.
      #
      def findbug_clear_context
        Findbug::Capture::Context.clear!
      end
    end
  end
end
