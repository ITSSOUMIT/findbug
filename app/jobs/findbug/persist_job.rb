# frozen_string_literal: true

module Findbug
  # PersistJob moves data from Redis buffer to the database.
  #
  # THE TWO-PHASE STORAGE PATTERN
  # =============================
  #
  # Phase 1: Real-time capture (Redis)
  # - Happens in your request thread
  # - Must be FAST (1-2ms)
  # - Non-blocking
  # - Data is temporary (24h TTL)
  #
  # Phase 2: Persistence (Database)
  # - Happens in background job
  # - Can be slow (50-100ms per batch)
  # - Doesn't affect user requests
  # - Data is permanent
  #
  # WHY THIS PATTERN?
  # =================
  #
  # Direct database writes in the request cycle would:
  # 1. Add 50-100ms latency to every error
  # 2. Risk database connection exhaustion under high error rates
  # 3. Create contention with app's own database traffic
  #
  # By buffering in Redis first:
  # 1. Capture is instant (Redis LPUSH is ~1ms)
  # 2. Database writes are batched (more efficient)
  # 3. Load is smoothed out over time
  #
  # SCHEDULING
  # ==========
  #
  # This job should run periodically (every 30 seconds is a good default).
  # You can set this up with:
  #
  # 1. Sidekiq-scheduler / sidekiq-cron:
  #
  #    findbug_persist:
  #      cron: "*/30 * * * * *"  # Every 30 seconds
  #      class: Findbug::PersistJob
  #
  # 2. Whenever gem (cron):
  #
  #    every 30.seconds do
  #      runner "Findbug::PersistJob.perform_now"
  #    end
  #
  # 3. Solid Queue (Rails 8):
  #
  #    Findbug::PersistJob.set(wait: 30.seconds).perform_later
  #    (then reschedule itself at the end)
  #
  class PersistJob < ActiveJob::Base
    queue_as { Findbug.config.queue_name }

    # Maximum number of events to process in one job run
    # This prevents the job from running too long
    MAX_EVENTS_PER_RUN = 1000

    def perform
      return unless Findbug.enabled?

      persist_errors
      persist_performance
    rescue StandardError => e
      Findbug.logger.error("[Findbug] PersistJob failed: #{e.message}")
      raise # Re-raise to trigger job retry
    end

    # Persist error events from Redis to database
    def persist_errors
      batch_size = Findbug.config.persist_batch_size
      total_persisted = 0

      loop do
        # Pop a batch from Redis
        events = Findbug::Storage::RedisBuffer.pop_errors(batch_size)
        break if events.empty?

        # Process the batch
        self.class.persist_errors_batch(events)
        total_persisted += events.size

        # Safety limit to prevent infinite loops
        break if total_persisted >= MAX_EVENTS_PER_RUN

        # Small sleep to avoid hammering the database
        sleep(0.01)
      end

      if total_persisted.positive?
        Findbug.logger.info("[Findbug] Persisted #{total_persisted} error events")
      end
    end

    # Persist performance events from Redis to database
    def persist_performance
      batch_size = Findbug.config.persist_batch_size
      total_persisted = 0

      loop do
        events = Findbug::Storage::RedisBuffer.pop_performance(batch_size)
        break if events.empty?

        self.class.persist_performance_batch(events)
        total_persisted += events.size

        break if total_persisted >= MAX_EVENTS_PER_RUN

        sleep(0.01)
      end

      if total_persisted.positive?
        Findbug.logger.info("[Findbug] Persisted #{total_persisted} performance events")
      end
    end

    class << self
      # Persist a batch of error events
      #
      # @param events [Array<Hash>] error event data
      #
      def persist_errors_batch(events)
        events.each do |event_data|
          # Scrub sensitive data before persisting
          scrubbed = Findbug::Processing::DataScrubber.scrub(event_data)

          # Upsert to database
          Findbug::ErrorEvent.upsert_from_event(scrubbed)
        rescue StandardError => e
          Findbug.logger.error(
            "[Findbug] Failed to persist error event: #{e.message}"
          )
          # Continue with other events
        end
      end

      # Persist a batch of performance events
      #
      # @param events [Array<Hash>] performance event data
      #
      def persist_performance_batch(events)
        events.each do |event_data|
          scrubbed = Findbug::Processing::DataScrubber.scrub(event_data)
          Findbug::PerformanceEvent.create_from_event(scrubbed)
        rescue StandardError => e
          Findbug.logger.error(
            "[Findbug] Failed to persist performance event: #{e.message}"
          )
        end
      end
    end
  end
end
