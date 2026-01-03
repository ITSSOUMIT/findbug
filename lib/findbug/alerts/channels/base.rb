# frozen_string_literal: true

module Findbug
  module Alerts
    module Channels
      # Base is the abstract base class for alert channels.
      #
      # CHANNEL PATTERN
      # ===============
      #
      # Each channel implements:
      # 1. #initialize(config) - Receive channel configuration
      # 2. #send_alert(error_event) - Send the alert
      #
      # This pattern allows adding new channels easily:
      #
      #   class PagerDuty < Base
      #     def send_alert(error_event)
      #       # Call PagerDuty API
      #     end
      #   end
      #
      class Base
        attr_reader :config

        def initialize(config)
          @config = config
        end

        # Send an alert for an error event
        #
        # @param error_event [ErrorEvent] the error to alert about
        #
        def send_alert(error_event)
          raise NotImplementedError, "#{self.class} must implement #send_alert"
        end

        protected

        # Format error for display
        def format_error_title(error_event)
          "[#{error_event.severity.upcase}] #{error_event.exception_class}"
        end

        def format_error_message(error_event)
          error_event.message.to_s.truncate(500)
        end

        def format_occurrence_info(error_event)
          if error_event.occurrence_count > 1
            "Occurred #{error_event.occurrence_count} times"
          else
            "First occurrence"
          end
        end

        def format_environment(error_event)
          error_event.environment || "unknown"
        end

        def format_first_backtrace_line(error_event)
          error_event.backtrace_lines.first || "No backtrace available"
        end

        # Build a URL to the error in the dashboard
        def error_url(error_event)
          base_url = ENV.fetch("FINDBUG_BASE_URL", nil)
          return nil unless base_url

          "#{base_url}#{Findbug.config.web_path}/errors/#{error_event.id}"
        end
      end
    end
  end
end
