# frozen_string_literal: true

module Findbug
  # PerformanceController handles performance metrics views.
  #
  class PerformanceController < ApplicationController
    # GET /findbug/performance
    #
    # Performance overview with slowest endpoints.
    #
    def index
      @since = parse_since(params[:since] || "24h")

      @slowest = Findbug::PerformanceEvent.slowest_transactions(since: @since, limit: 20)
      @n_plus_one = Findbug::PerformanceEvent.n_plus_one_hotspots(since: @since, limit: 10)
      @throughput = Findbug::PerformanceEvent.throughput_over_time(since: @since)
      @stats = calculate_stats(@since)

      render template: "findbug/performance/index", layout: "findbug/application"
    end

    # GET /findbug/performance/:id
    #
    # Show details for a specific transaction type.
    #
    def show
      @transaction_name = params[:id]
      @since = parse_since(params[:since] || "24h")

      # Get events for this transaction
      @events = Findbug::PerformanceEvent.where(transaction_name: @transaction_name)
                                .where("captured_at >= ?", @since)
                                .recent
                                .limit(100)

      # Calculate aggregates
      @stats = Findbug::PerformanceEvent.aggregate_for(@transaction_name, since: @since)

      # Get slowest individual requests
      @slowest_requests = @events.order(duration_ms: :desc).limit(10)

      # Get requests with N+1 issues
      @n_plus_one_requests = @events.where(has_n_plus_one: true).limit(10)

      render template: "findbug/performance/show", layout: "findbug/application"
    end

    private

    def calculate_stats(since)
      events = Findbug::PerformanceEvent.where("captured_at >= ?", since)

      {
        total_requests: events.count,
        avg_duration: events.average(:duration_ms)&.round(2) || 0,
        max_duration: events.maximum(:duration_ms)&.round(2) || 0,
        avg_queries: events.average(:query_count)&.round(1) || 0,
        n_plus_one_percentage: calculate_n_plus_one_percentage(events)
      }
    end

    def calculate_n_plus_one_percentage(events)
      total = events.count
      return 0 if total.zero?

      n_plus_one = events.where(has_n_plus_one: true).count
      ((n_plus_one.to_f / total) * 100).round(1)
    end

    def parse_since(value)
      case value
      when "1h" then 1.hour.ago
      when "24h" then 24.hours.ago
      when "7d" then 7.days.ago
      when "30d" then 30.days.ago
      else 24.hours.ago
      end
    end
  end
end
