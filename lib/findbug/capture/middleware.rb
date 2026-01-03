# frozen_string_literal: true

require_relative "context"
require_relative "../storage/redis_buffer"
require "digest"
require "socket"

module Findbug
  module Capture
    # Middleware captures uncaught exceptions at the Rack level.
    #
    # WHY MIDDLEWARE + SUBSCRIBER?
    # ============================
    #
    # You might wonder: "We already have ExceptionSubscriber. Why middleware?"
    #
    # The subscriber catches errors reported via Rails.error, but:
    # 1. Not all Rails errors go through Rails.error
    # 2. Errors in middleware (before Rails) don't hit the subscriber
    # 3. Some gems raise directly without using Rails.error
    #
    # The middleware is a safety net that catches EVERYTHING at the Rack level.
    #
    # MIDDLEWARE ORDER
    # ================
    #
    # We're inserted AFTER ActionDispatch::ShowExceptions:
    #
    #   [Rack Stack]
    #   ...
    #   ActionDispatch::ShowExceptions  ← Converts exceptions to 500 pages
    #   Findbug::Capture::Middleware    ← WE ARE HERE
    #   ...
    #   YourController
    #
    # When an exception bubbles up:
    # 1. Controller raises
    # 2. WE catch it first, capture it, then re-raise
    # 3. ShowExceptions catches it and renders 500 page
    #
    # We capture and RE-RAISE so Rails can still do its thing.
    #
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        # Skip if Findbug is disabled
        return @app.call(env) unless Findbug.enabled?

        # Set up request context
        setup_context(env)

        # Call the next middleware/app
        response = @app.call(env)

        # Capture any error that was stored in the environment
        # (Some Rails error handlers store the error but don't re-raise)
        capture_env_exception(env)

        response
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Capture the exception
        capture_exception(e, env)

        # Re-raise so Rails can handle it (show 500 page, etc.)
        raise
      ensure
        # Always clean up context
        Context.clear!
      end

      private

      # Set up context from the Rack request
      #
      # WHY SET UP CONTEXT HERE?
      # ------------------------
      # The middleware runs BEFORE controllers. By setting up context here,
      # all request data is available even if the error occurs early.
      #
      def setup_context(env)
        # Only set up if not already set (avoid overwriting controller-set context)
        return if Context.request.present?

        rack_request = Rack::Request.new(env)

        # Skip non-HTTP paths (assets, etc.)
        return unless should_capture_path?(rack_request.path)

        Context.set_request(Context.from_rack_request(rack_request))

        # Add automatic breadcrumb for the request
        Context.add_breadcrumb(
          message: "HTTP Request",
          category: "http",
          data: {
            method: rack_request.request_method,
            path: rack_request.path
          }
        )
      end

      # Capture an exception
      def capture_exception(exception, env)
        return unless should_capture_exception?(exception)

        # Check if this exception was already captured by the subscriber
        # (to avoid duplicates)
        return if already_captured?(env, exception)

        # Mark as captured
        mark_captured(env, exception)

        # Build event data
        event_data = build_event_data(exception, env)

        # Push to Redis (async)
        Storage::RedisBuffer.push_error(event_data)
      rescue StandardError => e
        # NEVER let Findbug crash your app
        Findbug.logger.error("[Findbug] Middleware capture failed: #{e.message}")
      end

      # Capture exceptions stored in env (by error handlers)
      def capture_env_exception(env)
        # ActionDispatch::ShowExceptions stores the exception in env
        exception = env["action_dispatch.exception"]
        return unless exception

        capture_exception(exception, env)
      end

      def should_capture_exception?(exception)
        return false unless Findbug.config.should_capture_exception?(exception)

        # Skip exceptions that indicate normal HTTP flows
        # These are "expected" and don't need tracking
        exception_class = exception.class.name

        expected_exceptions = %w[
          ActionController::RoutingError
          ActionController::UnknownFormat
          ActionController::BadRequest
        ]

        !expected_exceptions.include?(exception_class)
      end

      def should_capture_path?(path)
        Findbug.config.should_capture_path?(path)
      end

      # Check if already captured (deduplication)
      def already_captured?(env, exception)
        captured_id = env["findbug.captured_exception_id"]
        return false unless captured_id

        captured_id == exception.object_id
      end

      def mark_captured(env, exception)
        env["findbug.captured_exception_id"] = exception.object_id
      end

      def build_event_data(exception, env)
        {
          # Exception details
          exception_class: exception.class.name,
          message: exception.message,
          backtrace: clean_backtrace(exception.backtrace),

          # Metadata
          severity: "error",
          handled: false,
          source: "middleware",

          # Context
          context: Context.to_h,

          # Fingerprint
          fingerprint: generate_fingerprint(exception),

          # Timing
          captured_at: Time.now.utc.iso8601(3),

          # Environment
          environment: Findbug.config.environment,
          release: Findbug.config.release,
          server: server_info
        }
      end

      def clean_backtrace(backtrace)
        return [] unless backtrace

        backtrace.first(50).map do |line|
          if defined?(Rails.root) && Rails.root
            line.sub(Rails.root.to_s + "/", "")
          else
            line
          end
        end
      end

      def generate_fingerprint(exception)
        components = [
          exception.class.name,
          normalize_message(exception.message),
          top_frame(exception.backtrace)
        ]

        Digest::SHA256.hexdigest(components.join("\n"))
      end

      def normalize_message(message)
        return "" unless message

        message
          .gsub(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, "{uuid}")
          .gsub(/\b\d+\.?\d*\b/, "{number}")
          .gsub(/'[^']*'/, "'{string}'")
          .gsub(/"[^"]*"/, '"{string}"')
      end

      def top_frame(backtrace)
        return "" unless backtrace&.any?

        app_line = backtrace.find do |line|
          line.include?("/app/") || line.include?("/lib/")
        end

        (app_line || backtrace.first).to_s
      end

      def server_info
        {
          hostname: Socket.gethostname,
          pid: Process.pid,
          ruby_version: RUBY_VERSION,
          rails_version: (Rails.version if defined?(Rails))
        }
      end
    end
  end
end
