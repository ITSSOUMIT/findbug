# frozen_string_literal: true

require "digest"
require "socket"

module Findbug
  module Capture
    # MessageHandler captures non-exception events (messages).
    #
    # WHY CAPTURE MESSAGES?
    # =====================
    #
    # Not every important event is an exception. Sometimes you want to track:
    #
    # - Security events: "User exceeded rate limit"
    # - Business events: "Payment failed validation"
    # - Warnings: "External API response slow"
    # - Debug info: "Cache miss for critical key"
    #
    # These aren't exceptions, but you want to see them in your error dashboard
    # alongside actual errors.
    #
    # USAGE
    # =====
    #
    #   Findbug.capture_message("User exceeded rate limit", :warning, user_id: 123)
    #   Findbug.capture_message("Payment validation failed", :error, order_id: 456)
    #   Findbug.capture_message("Scheduled task completed", :info, duration: 45.2)
    #
    class MessageHandler
      class << self
        # Capture a message
        #
        # @param message [String] the message to capture
        # @param level [Symbol] severity level (:info, :warning, :error)
        # @param extra_context [Hash] additional context
        #
        def capture(message, level = :info, extra_context = {})
          return unless Findbug.enabled?

          event_data = build_event_data(message, level, extra_context)
          Storage::RedisBuffer.push_error(event_data)
        rescue StandardError => e
          Findbug.logger.error("[Findbug] MessageHandler failed: #{e.message}")
        end

        private

        def build_event_data(message, level, extra_context)
          context = Context.to_h
          context[:extra] = (context[:extra] || {}).merge(extra_context)

          {
            # For messages, we use a synthetic "exception class"
            exception_class: "Findbug::Message",
            message: message,
            backtrace: caller_backtrace,

            severity: level.to_s,
            handled: true,
            source: "message",

            context: context,
            fingerprint: generate_fingerprint(message, level),

            captured_at: Time.now.utc.iso8601(3),
            environment: Findbug.config.environment,
            release: Findbug.config.release,
            server: server_info
          }
        end

        # Get a clean backtrace from the caller
        def caller_backtrace
          # Skip Findbug internals, show where the message was captured
          caller.drop_while { |line| line.include?("/findbug/") }
                .first(20)
                .map do |line|
                  if defined?(Rails.root) && Rails.root
                    line.sub(Rails.root.to_s + "/", "")
                  else
                    line
                  end
                end
        end

        def generate_fingerprint(message, level)
          # For messages, fingerprint by the literal message + level
          # We don't normalize because messages are intentional, not variable
          Digest::SHA256.hexdigest("#{level}:#{message}")
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
