# frozen_string_literal: true

require "active_job"

module Findbug
  module Jobs
    # AlertJob sends alerts asynchronously.
    #
    # WHY ASYNC ALERTS?
    # =================
    #
    # Alert sending involves:
    # - HTTP requests to Slack/Discord webhooks
    # - Email delivery (SMTP)
    # - Potential network latency
    #
    # If we did this synchronously during error capture:
    # 1. Slow alerts would slow down error persistence
    # 2. Failed alerts would block other alerts
    # 3. Network issues would impact the persist job
    #
    # By using a separate job:
    # 1. PersistJob stays fast
    # 2. Alerts can retry independently
    # 3. Network issues are isolated
    #
    class AlertJob < ActiveJob::Base
      queue_as { Findbug.config.queue_name }

      # Retry on network failures
      retry_on StandardError, attempts: 3, wait: :polynomially_longer

      def perform(error_event_id)
        error_event = ErrorEvent.find_by(id: error_event_id)
        return unless error_event

        Alerts::Dispatcher.send_alerts(error_event)
      rescue ActiveRecord::RecordNotFound
        # Event was deleted, skip alerting
        Findbug.logger.debug("[Findbug] Alert skipped: error event #{error_event_id} not found")
      end
    end
  end
end
