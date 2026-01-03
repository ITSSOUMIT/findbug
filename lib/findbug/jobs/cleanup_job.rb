# frozen_string_literal: true

require "active_job"

module Findbug
  module Jobs
    # CleanupJob removes old data based on retention policy.
    #
    # WHY CLEANUP?
    # ============
    #
    # Without cleanup, your database would grow forever:
    # - 1000 errors/day × 30 days = 30,000 records
    # - 10000 perf events/day × 30 days = 300,000 records
    #
    # Cleanup enforces retention policy:
    # - Default: 30 days
    # - Configurable via config.retention_days
    #
    # WHAT GETS CLEANED
    # =================
    #
    # 1. Error events older than retention_days
    #    - Except: unresolved errors (you probably want to fix these!)
    #
    # 2. Performance events older than retention_days
    #    - All performance data is cleaned (it's meant for trends, not forever)
    #
    # 3. Resolved/ignored errors older than retention_days
    #
    # SCHEDULING
    # ==========
    #
    # Run this daily (not too often, not too rare):
    #
    #   findbug_cleanup:
    #     cron: "0 3 * * *"  # 3 AM daily
    #     class: Findbug::Jobs::CleanupJob
    #
    class CleanupJob < ActiveJob::Base
      queue_as { Findbug.config.queue_name }

      # Delete in batches to avoid long-running transactions
      BATCH_SIZE = 1000

      def perform
        return unless Findbug.enabled?

        cleanup_errors
        cleanup_performance

        Findbug.logger.info("[Findbug] Cleanup completed")
      rescue StandardError => e
        Findbug.logger.error("[Findbug] CleanupJob failed: #{e.message}")
        raise
      end

      private

      def cleanup_errors
        cutoff_date = retention_days.days.ago

        # Delete resolved and ignored errors older than retention
        deleted_count = delete_in_batches(
          ErrorEvent.where(status: [ErrorEvent::STATUS_RESOLVED, ErrorEvent::STATUS_IGNORED])
                    .where("last_seen_at < ?", cutoff_date)
        )

        # Optionally delete very old unresolved errors (e.g., 3x retention)
        # This prevents truly ancient errors from accumulating
        very_old_cutoff = (retention_days * 3).days.ago
        old_unresolved_count = delete_in_batches(
          ErrorEvent.unresolved.where("last_seen_at < ?", very_old_cutoff)
        )

        total = deleted_count + old_unresolved_count
        if total.positive?
          Findbug.logger.info("[Findbug] Cleaned up #{total} error events")
        end
      end

      def cleanup_performance
        cutoff_date = retention_days.days.ago

        # Delete all performance events older than retention
        deleted_count = delete_in_batches(
          PerformanceEvent.where("captured_at < ?", cutoff_date)
        )

        if deleted_count.positive?
          Findbug.logger.info("[Findbug] Cleaned up #{deleted_count} performance events")
        end
      end

      # Delete records in batches to avoid long transactions
      #
      # WHY BATCHING?
      # =============
      #
      # Deleting 100,000 records in one query:
      # 1. Locks the table for a long time
      # 2. Can cause deadlocks with other queries
      # 3. Uses lots of memory for transaction log
      # 4. Might timeout
      #
      # Batching (1000 at a time):
      # 1. Short locks between batches
      # 2. Other queries can interleave
      # 3. Steady memory usage
      # 4. Can be interrupted and resumed
      #
      def delete_in_batches(scope)
        total_deleted = 0

        loop do
          # Get IDs of records to delete
          ids = scope.limit(BATCH_SIZE).pluck(:id)
          break if ids.empty?

          # Delete this batch
          deleted = scope.where(id: ids).delete_all
          total_deleted += deleted

          # Give other queries a chance
          sleep(0.01)
        end

        total_deleted
      end

      def retention_days
        Findbug.config.retention_days
      end
    end
  end
end
