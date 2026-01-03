# frozen_string_literal: true

module Findbug
  # BackgroundPersister runs a background thread that periodically moves
  # events from the Redis buffer to the database.
  #
  # WHY A BACKGROUND THREAD?
  # ========================
  #
  # We want Findbug to work "out of the box" without requiring users to:
  # 1. Set up Sidekiq/ActiveJob
  # 2. Configure recurring jobs
  # 3. Run separate worker processes
  #
  # A background thread achieves this by running inside the Rails process.
  #
  # THREAD SAFETY
  # =============
  #
  # - Uses Mutex for start/stop synchronization
  # - Only one persister thread runs at a time
  # - Safe to call start! multiple times (idempotent)
  #
  # GRACEFUL SHUTDOWN
  # =================
  #
  # The thread checks a @running flag and exits cleanly when stopped.
  # We also register an at_exit hook to ensure cleanup.
  #
  # LIMITATIONS
  # ===========
  #
  # - Only persists in the process where it's started
  # - In multi-process setups (Puma cluster), each process has its own thread
  # - For high-volume apps, users should use the ActiveJob approach instead
  #
  class BackgroundPersister
    DEFAULT_INTERVAL = 30 # seconds

    class << self
      def start!(interval: nil)
        return if @running

        @mutex ||= Mutex.new
        @mutex.synchronize do
          return if @running

          @interval = interval || Findbug.config.persist_interval || DEFAULT_INTERVAL
          @running = true
          @thread = Thread.new { run_loop }
          @thread.name = "findbug-persister"
          @thread.abort_on_exception = false

          Findbug.logger.info("[Findbug] Background persister started (interval: #{@interval}s)")
        end
      end

      def stop!
        return unless @running

        @mutex.synchronize do
          @running = false
          @thread&.wakeup rescue nil # Wake from sleep
          @thread&.join(5) # Wait up to 5 seconds
          @thread = nil
          Findbug.logger.info("[Findbug] Background persister stopped")
        end
      end

      def running?
        @running == true && @thread&.alive?
      end

      # Force an immediate persist (useful for testing)
      def persist_now!
        perform_persist
      end

      private

      def run_loop
        while @running
          sleep(@interval)
          next unless @running

          perform_persist
        end
      rescue StandardError => e
        Findbug.logger.error("[Findbug] Background persister crashed: #{e.message}")
        @running = false
      end

      def perform_persist
        return unless Findbug.enabled?

        # Persist errors
        persist_errors

        # Persist performance events
        persist_performance
      rescue StandardError => e
        Findbug.logger.error("[Findbug] Persist failed: #{e.message}")
      end

      def persist_errors
        events = Findbug::Storage::RedisBuffer.pop_errors(batch_size)
        return if events.empty?

        persisted = 0
        events.each do |event_data|
          begin
            Findbug::ErrorEvent.upsert_from_event(event_data)
            persisted += 1
          rescue StandardError => e
            Findbug.logger.error("[Findbug] Failed to persist error: #{e.message}")
          end
        end

        Findbug.logger.info("[Findbug] Persisted #{persisted}/#{events.size} errors") if persisted > 0
      end

      def persist_performance
        events = Findbug::Storage::RedisBuffer.pop_performance(batch_size)
        return if events.empty?

        persisted = 0
        events.each do |event_data|
          begin
            Findbug::PerformanceEvent.create_from_event(event_data)
            persisted += 1
          rescue StandardError => e
            Findbug.logger.error("[Findbug] Failed to persist performance event: #{e.message}")
          end
        end

        Findbug.logger.info("[Findbug] Persisted #{persisted}/#{events.size} performance events") if persisted > 0
      end

      def batch_size
        Findbug.config.persist_batch_size || 100
      end
    end
  end
end
