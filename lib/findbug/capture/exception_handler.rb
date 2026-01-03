# frozen_string_literal: true

require "digest"
require "socket"

module Findbug
  module Capture
    # ExceptionHandler provides the public API for capturing exceptions.
    #
    # This is used by:
    # - Findbug.capture_exception (public API)
    # - Manual captures in user code
    #
    # It's separate from Middleware/Subscriber because those are automatic.
    # This is for explicit, manual captures.
    #
    # WHEN TO USE MANUAL CAPTURE
    # ==========================
    #
    # 1. Handled exceptions you still want to track:
    #
    #    begin
    #      external_api.call
    #    rescue ExternalAPIError => e
    #      Findbug.capture_exception(e)
    #      # Handle gracefully...
    #    end
    #
    # 2. Exceptions in background jobs (if not auto-captured):
    #
    #    class HardWorker
    #      def perform
    #        do_work
    #      rescue => e
    #        Findbug.capture_exception(e)
    #        raise # Re-raise for Sidekiq retry
    #      end
    #    end
    #
    # 3. Exceptions with extra context:
    #
    #    Findbug.capture_exception(e, order_id: order.id, action: "payment")
    #
    class ExceptionHandler
      class << self
        # Capture an exception
        #
        # @param exception [Exception] the exception to capture
        # @param extra_context [Hash] additional context for this error
        #
        def capture(exception, extra_context = {})
          return unless Findbug.enabled?
          return unless should_capture?(exception)

          event_data = build_event_data(exception, extra_context)
          Storage::RedisBuffer.push_error(event_data)
        rescue StandardError => e
          Findbug.logger.error("[Findbug] ExceptionHandler failed: #{e.message}")
        end

        private

        def should_capture?(exception)
          Findbug.config.should_capture_exception?(exception)
        end

        def build_event_data(exception, extra_context)
          # Get current context and merge with extra
          context = Context.to_h
          context[:extra] = (context[:extra] || {}).merge(extra_context)

          {
            exception_class: exception.class.name,
            message: exception.message,
            backtrace: clean_backtrace(exception.backtrace),
            severity: "error",
            handled: true, # Manual captures are "handled"
            source: "manual",
            context: context,
            fingerprint: generate_fingerprint(exception),
            captured_at: Time.now.utc.iso8601(3),
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
end
