# frozen_string_literal: true

module Findbug
  module Alerts
    # Dispatcher routes alerts to configured channels.
    #
    # ALERT FLOW
    # ==========
    #
    # 1. Error captured → PersistJob runs
    # 2. PersistJob calls Dispatcher.notify(error_event)
    # 3. Dispatcher checks throttling (avoid spam)
    # 4. Dispatcher sends to enabled channels (async via AlertJob)
    #
    # THROTTLING
    # ==========
    #
    # If your app throws 1000 errors in a minute, you don't want 1000 Slack
    # messages. Throttling limits alerts to one per error fingerprint per
    # throttle period (default 5 minutes).
    #
    # CHANNEL PRIORITY
    # ================
    #
    # Different channels for different severities:
    # - Critical errors → All channels (email, Slack, etc.)
    # - Warnings → Maybe just Slack
    # - Info → Maybe just logged, no alerts
    #
    class Dispatcher
      class << self
        # Send alert for an error event
        #
        # @param error_event [ErrorEvent] the error to alert about
        # @param async [Boolean] whether to send asynchronously (default: true)
        #
        def notify(error_event, async: true)
          return unless Findbug.enabled?
          return unless Findbug.config.alerts.any_enabled?
          return unless should_alert?(error_event)
          return if throttled?(error_event)

          if async
            Jobs::AlertJob.perform_later(error_event.id)
          else
            send_alerts(error_event)
          end

          record_alert(error_event)
        end

        # Actually send alerts to all enabled channels
        #
        # @param error_event [ErrorEvent] the error to alert about
        #
        def send_alerts(error_event)
          alert_config = Findbug.config.alerts

          alert_config.enabled_channels.each do |channel_name, config|
            send_to_channel(channel_name, error_event, config)
          rescue StandardError => e
            Findbug.logger.error(
              "[Findbug] Failed to send alert to #{channel_name}: #{e.message}"
            )
          end
        end

        private

        # Check if we should alert for this error
        #
        # You might not want to alert for:
        # - Ignored errors
        # - Info-level messages
        # - Handled errors (depending on config)
        #
        def should_alert?(error_event)
          # Don't alert for ignored errors
          return false if error_event.status == ErrorEvent::STATUS_IGNORED

          # Alert for errors and warnings, not info
          %w[error warning].include?(error_event.severity)
        end

        # Check if this error is throttled
        #
        # We use Redis to track last alert time per fingerprint.
        #
        def throttled?(error_event)
          Throttler.throttled?(error_event.fingerprint)
        end

        # Record that we sent an alert (for throttling)
        def record_alert(error_event)
          Throttler.record(error_event.fingerprint)
        end

        # Send to a specific channel
        def send_to_channel(channel_name, error_event, config)
          channel_class = channel_for(channel_name)
          return unless channel_class

          channel = channel_class.new(config)
          channel.send_alert(error_event)
        end

        # Get the channel class for a channel name
        def channel_for(channel_name)
          case channel_name.to_sym
          when :email
            Channels::Email
          when :slack
            Channels::Slack
          when :discord
            Channels::Discord
          when :webhook
            Channels::Webhook
          else
            Findbug.logger.warn("[Findbug] Unknown alert channel: #{channel_name}")
            nil
          end
        end
      end
    end
  end
end
