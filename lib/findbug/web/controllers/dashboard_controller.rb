# frozen_string_literal: true

module Findbug
  module Web
    # DashboardController handles the main dashboard view.
    #
    class DashboardController < ApplicationController
      # GET /findbug
      #
      # Main dashboard with overview of errors and performance.
      #
      def index
        @stats = calculate_stats
        @recent_errors = Findbug::ErrorEvent.unresolved.recent.limit(10)
        @slowest_endpoints = Findbug::PerformanceEvent.slowest_transactions(since: 24.hours.ago, limit: 5)
        @error_trend = calculate_error_trend

        render template: "findbug/dashboard/index", layout: "findbug/application"
      end

      # GET /findbug/health
      #
      # Health check endpoint for monitoring.
      # Returns JSON with system status.
      #
      def health
        status = {
          status: "ok",
          version: Findbug::VERSION,
          redis: check_redis_health,
          database: check_database_health,
          buffer: Storage::RedisBuffer.stats
        }

        render json: status
      end

      # GET /findbug/stats
      #
      # JSON stats endpoint for AJAX updates.
      # Used by Turbo to refresh dashboard stats without full page reload.
      #
      def stats
        render json: calculate_stats
      end

      private

      def calculate_stats
        now = Time.current
        {
          errors: {
            total: Findbug::ErrorEvent.count,
            unresolved: Findbug::ErrorEvent.unresolved.count,
            last_24h: Findbug::ErrorEvent.where("created_at >= ?", 24.hours.ago).count,
            last_7d: Findbug::ErrorEvent.where("created_at >= ?", 7.days.ago).count
          },
          performance: {
            total: Findbug::PerformanceEvent.count,
            last_24h: Findbug::PerformanceEvent.where("captured_at >= ?", 24.hours.ago).count,
            avg_duration: Findbug::PerformanceEvent.where("captured_at >= ?", 24.hours.ago)
                                          .average(:duration_ms)&.round(2) || 0,
            n_plus_one_count: Findbug::PerformanceEvent.with_n_plus_one
                                              .where("captured_at >= ?", 24.hours.ago)
                                              .count
          },
          buffer: Findbug::Storage::RedisBuffer.stats,
          timestamp: now.iso8601
        }
      end

      def calculate_error_trend
        # Get hourly error counts for the last 24 hours
        Findbug::ErrorEvent.where("last_seen_at >= ?", 24.hours.ago)
                  .group_by_hour(:last_seen_at)
                  .count
      rescue NoMethodError
        # groupdate gem not installed, return simple count
        {}
      end

      def check_redis_health
        Findbug::Storage::ConnectionPool.healthy? ? "ok" : "error"
      rescue StandardError
        "error"
      end

      def check_database_health
        Findbug::ErrorEvent.connection.active? ? "ok" : "error"
      rescue StandardError
        "error"
      end
    end
  end
end
