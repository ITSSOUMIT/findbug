# frozen_string_literal: true

module Findbug
  module Capture
    # ExceptionSubscriber integrates with Rails 7's ErrorReporter.
    #
    # RAILS ERROR REPORTER (Rails 7+)
    # ===============================
    #
    # Rails 7 introduced a centralized error reporting API:
    #
    #   Rails.error.handle { risky_operation }  # Swallows error, reports it
    #   Rails.error.record { risky_operation }  # Re-raises, but reports first
    #
    # Third-party gems can subscribe to receive ALL reported errors:
    #
    #   Rails.error.subscribe(MySubscriber.new)
    #
    # This is better than just middleware because it catches:
    # - Errors handled gracefully with Rails.error.handle
    # - Background job errors
    # - Errors in non-request contexts
    #
    # HOW IT WORKS
    # ============
    #
    # 1. Rails catches an exception
    # 2. Rails calls Rails.error.report(exception, ...)
    # 3. Rails calls our subscriber's #report method
    # 4. We capture the exception asynchronously
    #
    class ExceptionSubscriber
      # Called by Rails when an error is reported
      #
      # @param error [Exception] the exception that occurred
      # @param handled [Boolean] whether the error was handled
      # @param severity [Symbol] :error, :warning, or :info
      # @param context [Hash] additional context from Rails
      # @param source [String] where the error came from
      #
      def report(error, handled:, severity:, context:, source: nil)
        return unless Findbug.enabled?
        return unless should_capture?(error)

        # Build event data
        event_data = build_event_data(error, handled, severity, context, source)

        # Push to Redis buffer (async, non-blocking)
        Storage::RedisBuffer.push_error(event_data)
      rescue StandardError => e
        # CRITICAL: Never let Findbug crash your app
        Findbug.logger.error("[Findbug] ExceptionSubscriber failed: #{e.message}")
      end

      private

      def should_capture?(error)
        Findbug.config.should_capture_exception?(error)
      end

      def build_event_data(error, handled, severity, rails_context, source)
        {
          # Exception details
          exception_class: error.class.name,
          message: error.message,
          backtrace: clean_backtrace(error.backtrace),

          # Metadata
          severity: map_severity(severity),
          handled: handled,
          source: source,

          # Context from Findbug
          context: Context.to_h,

          # Context from Rails
          rails_context: sanitize_context(rails_context),

          # Fingerprint for grouping
          fingerprint: generate_fingerprint(error),

          # Timing
          captured_at: Time.now.utc.iso8601(3),

          # Environment info
          environment: Findbug.config.environment,
          release: Findbug.config.release,
          server: server_info
        }
      end

      # Clean up the backtrace
      #
      # WHY CLEAN BACKTRACE?
      # --------------------
      # Raw backtraces include:
      # - Full file paths (privacy concern, also verbose)
      # - Gem internals (not useful for debugging YOUR code)
      # - Framework internals (noisy)
      #
      # We clean it to show only relevant lines.
      #
      def clean_backtrace(backtrace)
        return [] unless backtrace

        # Limit to reasonable size
        backtrace = backtrace.first(50)

        backtrace.map do |line|
          # Replace full paths with relative paths
          line.sub(Rails.root.to_s + "/", "") if defined?(Rails.root)
          line
        end
      end

      # Map Rails severity to our severity levels
      def map_severity(severity)
        case severity
        when :error then "error"
        when :warning then "warning"
        when :info then "info"
        else "error"
        end
      end

      # Sanitize context from Rails (may contain non-serializable objects)
      def sanitize_context(context)
        return {} unless context.is_a?(Hash)

        context.transform_values do |value|
          case value
          when String, Numeric, TrueClass, FalseClass, NilClass
            value
          when Array
            value.map { |v| sanitize_value(v) }
          when Hash
            sanitize_context(value)
          else
            value.to_s
          end
        end
      rescue StandardError
        {}
      end

      def sanitize_value(value)
        case value
        when String, Numeric, TrueClass, FalseClass, NilClass
          value
        else
          value.to_s
        end
      end

      # Generate a fingerprint for grouping similar errors
      #
      # WHAT IS FINGERPRINTING?
      # -----------------------
      # Multiple occurrences of the "same" error should be grouped together.
      # But what makes two errors "the same"?
      #
      # We use:
      # 1. Exception class name (e.g., "NoMethodError")
      # 2. Exception message (normalized to remove variable parts)
      # 3. Top stack frame (where the error originated)
      #
      # This groups errors by WHERE they happened and WHAT type they are.
      #
      def generate_fingerprint(error)
        components = [
          error.class.name,
          normalize_message(error.message),
          top_frame(error.backtrace)
        ]

        Digest::SHA256.hexdigest(components.join("\n"))
      end

      # Normalize error message for fingerprinting
      #
      # WHY NORMALIZE?
      # --------------
      # Error messages often contain variable data:
      #   "undefined method `foo' for nil:NilClass"
      #   "Couldn't find User with ID=123"
      #   "Connection timed out after 30.5 seconds"
      #
      # If we used these raw, each user ID would create a new "group".
      # We normalize by replacing:
      # - Numbers with {number}
      # - UUIDs with {uuid}
      # - Quoted strings with {string}
      #
      def normalize_message(message)
        return "" unless message

        message
          .gsub(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, "{uuid}")
          .gsub(/\b\d+\.?\d*\b/, "{number}")
          .gsub(/'[^']*'/, "'{string}'")
          .gsub(/"[^"]*"/, '"{string}"')
          .gsub(/ID=\d+/, "ID={number}")
      end

      # Get the top relevant stack frame
      def top_frame(backtrace)
        return "" unless backtrace&.any?

        # Skip framework internals, find first app line
        app_line = backtrace.find do |line|
          line.include?("/app/") || line.include?("/lib/")
        end

        (app_line || backtrace.first).to_s
      end

      # Collect server information
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
