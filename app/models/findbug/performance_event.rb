# frozen_string_literal: true

module Findbug
  # PerformanceEvent stores captured performance data in the database.
  #
  # DATABASE SCHEMA
  # ===============
  #
  #   create_table :findbug_performance_events do |t|
  #     t.string :transaction_name, null: false
  #     t.string :transaction_type, default: 'request'
  #     t.string :request_method
  #     t.string :request_path
  #     t.string :format
  #     t.integer :status
  #     t.float :duration_ms, null: false
  #     t.float :db_time_ms, default: 0
  #     t.float :view_time_ms, default: 0
  #     t.integer :query_count, default: 0
  #     t.jsonb :slow_queries, default: []
  #     t.jsonb :n_plus_one_queries, default: []
  #     t.boolean :has_n_plus_one, default: false
  #     t.integer :view_count, default: 0
  #     t.jsonb :context, default: {}
  #     t.string :environment
  #     t.string :release_version
  #     t.datetime :captured_at
  #     t.timestamps
  #   end
  #
  # AGGREGATION STRATEGY
  # ====================
  #
  # Unlike errors (which we group by fingerprint), we store every
  # performance event individually. This allows:
  #
  # - Percentile calculations (p50, p95, p99)
  # - Trend analysis over time
  # - Individual slow request investigation
  #
  # For dashboards, we aggregate on read using SQL GROUP BY.
  #
  class PerformanceEvent < ActiveRecord::Base
    self.table_name = "findbug_performance_events"

    # Transaction types
    TYPE_REQUEST = "request"
    TYPE_CUSTOM = "custom"
    TYPE_JOB = "job"

    # Validations
    validates :transaction_name, presence: true
    validates :duration_ms, presence: true, numericality: { greater_than_or_equal_to: 0 }

    # Scopes
    scope :requests, -> { where(transaction_type: TYPE_REQUEST) }
    scope :custom, -> { where(transaction_type: TYPE_CUSTOM) }
    scope :jobs, -> { where(transaction_type: TYPE_JOB) }
    scope :slow, -> { where("duration_ms >= ?", Findbug.config.slow_request_threshold_ms) }
    scope :with_n_plus_one, -> { where(has_n_plus_one: true) }
    scope :recent, -> { order(captured_at: :desc) }

    # Time-based scopes
    scope :last_hour, -> { where("captured_at >= ?", 1.hour.ago) }
    scope :last_24_hours, -> { where("captured_at >= ?", 24.hours.ago) }
    scope :last_7_days, -> { where("captured_at >= ?", 7.days.ago) }

    # Create a performance event from Redis data
    #
    # @param event_data [Hash] the performance event data
    # @return [PerformanceEvent] the created event
    #
    def self.create_from_event(event_data)
      create!(
        transaction_name: event_data[:transaction_name],
        transaction_type: event_data[:transaction_type] || TYPE_REQUEST,
        request_method: event_data[:request_method],
        request_path: event_data[:request_path],
        format: event_data[:format],
        status: event_data[:status],
        duration_ms: event_data[:duration_ms],
        db_time_ms: event_data[:db_time_ms] || 0,
        view_time_ms: event_data[:view_time_ms] || 0,
        query_count: event_data[:query_count] || 0,
        slow_queries: event_data[:slow_queries] || [],
        n_plus_one_queries: event_data[:n_plus_one_queries] || [],
        has_n_plus_one: event_data[:has_n_plus_one] || false,
        view_count: event_data[:view_count] || 0,
        context: event_data[:context] || {},
        environment: event_data[:environment],
        release_version: event_data[:release],
        captured_at: parse_captured_at(event_data[:captured_at])
      )
    end

    # Aggregate stats for a transaction
    #
    # @param transaction_name [String] the transaction to aggregate
    # @param since [Time] start time for aggregation
    # @return [Hash] aggregated statistics
    #
    def self.aggregate_for(transaction_name, since: 24.hours.ago)
      events = where(transaction_name: transaction_name)
               .where("captured_at >= ?", since)

      return nil if events.empty?

      durations = events.pluck(:duration_ms).sort

      {
        transaction_name: transaction_name,
        count: events.count,
        avg_duration_ms: durations.sum / durations.size.to_f,
        min_duration_ms: durations.first,
        max_duration_ms: durations.last,
        p50_duration_ms: percentile(durations, 50),
        p95_duration_ms: percentile(durations, 95),
        p99_duration_ms: percentile(durations, 99),
        avg_query_count: events.average(:query_count).to_f.round(1),
        n_plus_one_count: events.where(has_n_plus_one: true).count
      }
    end

    # Get slowest transactions
    #
    # @param since [Time] start time
    # @param limit [Integer] max results
    # @return [Array<Hash>] slowest transactions with stats
    #
    def self.slowest_transactions(since: 24.hours.ago, limit: 10)
      where("captured_at >= ?", since)
        .group(:transaction_name)
        .select(
          "transaction_name",
          "AVG(duration_ms) as avg_duration",
          "MAX(duration_ms) as max_duration",
          "COUNT(*) as request_count"
        )
        .order("avg_duration DESC")
        .limit(limit)
        .map do |row|
          {
            transaction_name: row.transaction_name,
            avg_duration_ms: row.avg_duration.round(2),
            max_duration_ms: row.max_duration.round(2),
            count: row.request_count
          }
        end
    end

    # Get transactions with most N+1 issues
    #
    # @param since [Time] start time
    # @param limit [Integer] max results
    # @return [Array<Hash>] transactions with N+1 stats
    #
    def self.n_plus_one_hotspots(since: 24.hours.ago, limit: 10)
      with_n_plus_one
        .where("captured_at >= ?", since)
        .group(:transaction_name)
        .select(
          "transaction_name",
          "COUNT(*) as occurrence_count",
          "AVG(query_count) as avg_queries"
        )
        .order("occurrence_count DESC")
        .limit(limit)
        .map do |row|
          {
            transaction_name: row.transaction_name,
            n_plus_one_count: row.occurrence_count,
            avg_queries: row.avg_queries.round(1)
          }
        end
    end

    # Get throughput over time (requests per minute)
    #
    # @param since [Time] start time
    # @param interval [String] grouping interval ('minute', 'hour', 'day')
    # @return [Array<Hash>] time series data
    #
    def self.throughput_over_time(since: 24.hours.ago, interval: "hour")
      # This uses database-specific date truncation
      # Works with PostgreSQL; adjust for other databases
      time_column = case interval
                    when "minute" then "date_trunc('minute', captured_at)"
                    when "hour" then "date_trunc('hour', captured_at)"
                    when "day" then "date_trunc('day', captured_at)"
                    else "date_trunc('hour', captured_at)"
                    end

      where("captured_at >= ?", since)
        .group(Arel.sql(time_column))
        .select(
          Arel.sql("#{time_column} as time_bucket"),
          "COUNT(*) as request_count",
          "AVG(duration_ms) as avg_duration"
        )
        .order(Arel.sql(time_column))
        .map do |row|
          {
            time: row.time_bucket,
            count: row.request_count,
            avg_duration_ms: row.avg_duration.round(2)
          }
        end
    end

    private

    def self.percentile(sorted_array, percentile)
      return 0 if sorted_array.empty?

      k = (percentile / 100.0) * (sorted_array.length - 1)
      f = k.floor
      c = k.ceil

      if f == c
        sorted_array[f]
      else
        sorted_array[f] + (k - f) * (sorted_array[c] - sorted_array[f])
      end
    end

    def self.parse_captured_at(value)
      case value
      when Time, DateTime
        value
      when String
        Time.parse(value)
      else
        Time.current
      end
    end
  end
end
