# frozen_string_literal: true

require "active_support/notifications"

module Findbug
  module Performance
    # Instrumentation subscribes to Rails' ActiveSupport::Notifications.
    #
    # WHAT IS ActiveSupport::Notifications?
    # =====================================
    #
    # Rails has a built-in pub/sub system for internal events. Every time
    # something interesting happens, Rails publishes a notification:
    #
    #   - sql.active_record → Database queries
    #   - process_action.action_controller → HTTP requests
    #   - render_template.action_view → View rendering
    #   - cache_read.active_support → Cache operations
    #
    # Any code can subscribe to these events:
    #
    #   ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
    #     puts "Query took #{event.duration}ms"
    #   end
    #
    # This is how Rails' request logs, performance gems, and APM tools work.
    # We subscribe to capture timing data for our dashboard.
    #
    # WHY NOT MIDDLEWARE FOR PERFORMANCE?
    # ====================================
    #
    # Middleware only sees the request start and end. It can't see:
    # - Individual SQL queries
    # - Which view took how long
    # - Cache hits/misses
    #
    # Notifications give us granular visibility into the request lifecycle.
    #
    class Instrumentation
      SUBSCRIPTIONS = [
        "process_action.action_controller",
        "sql.active_record",
        "render_template.action_view",
        "render_partial.action_view",
        "cache_read.active_support",
        "cache_write.active_support"
      ].freeze

      class << self
        # Set up all instrumentation subscriptions
        #
        # Called once during Rails initialization (via Railtie).
        #
        def setup!
          return if @setup_complete
          return unless Findbug.config.performance_enabled

          subscribe_to_requests
          subscribe_to_queries
          subscribe_to_views
          subscribe_to_cache

          @setup_complete = true
          Findbug.logger.debug("[Findbug] Performance instrumentation enabled")
        end

        # Tear down subscriptions (for testing)
        def teardown!
          @subscriptions&.each do |subscriber|
            ActiveSupport::Notifications.unsubscribe(subscriber)
          end
          @subscriptions = []
          @setup_complete = false
        end

        private

        def subscriptions
          @subscriptions ||= []
        end

        # Subscribe to HTTP request completion
        #
        # This is the main event - it fires when a request finishes.
        # We use it to aggregate all the data collected during the request.
        #
        def subscribe_to_requests
          subscriber = ActiveSupport::Notifications.subscribe(
            "process_action.action_controller"
          ) do |event|
            handle_request_complete(event)
          end

          subscriptions << subscriber
        end

        # Subscribe to SQL queries
        #
        # This fires for EVERY database query. We collect them all,
        # then analyze for slow queries and N+1 patterns.
        #
        def subscribe_to_queries
          subscriber = ActiveSupport::Notifications.subscribe(
            "sql.active_record"
          ) do |event|
            handle_sql_query(event)
          end

          subscriptions << subscriber
        end

        # Subscribe to view rendering
        def subscribe_to_views
          %w[render_template render_partial].each do |event_name|
            subscriber = ActiveSupport::Notifications.subscribe(
              "#{event_name}.action_view"
            ) do |event|
              handle_view_render(event)
            end

            subscriptions << subscriber
          end
        end

        # Subscribe to cache operations
        def subscribe_to_cache
          %w[cache_read cache_write].each do |event_name|
            subscriber = ActiveSupport::Notifications.subscribe(
              "#{event_name}.active_support"
            ) do |event|
              handle_cache_operation(event)
            end

            subscriptions << subscriber
          end
        end

        # Handle request completion
        #
        # This is where we assemble all the data and decide whether to capture.
        #
        def handle_request_complete(event)
          return unless should_sample?

          # Get collected data from thread-local storage
          request_data = current_request_data

          # Build the performance event
          perf_event = build_performance_event(event, request_data)

          # Check against thresholds
          return unless meets_threshold?(perf_event)

          # Push to Redis (async)
          Storage::RedisBuffer.push_performance(perf_event)
        rescue StandardError => e
          Findbug.logger.debug("[Findbug] Performance capture failed: #{e.message}")
        ensure
          clear_request_data
        end

        # Handle individual SQL query
        def handle_sql_query(event)
          # Skip schema queries (they're not real app queries)
          return if event.payload[:name] == "SCHEMA"
          return if event.payload[:sql]&.start_with?("SHOW ")

          # Store in thread-local array
          queries = current_request_data[:queries] ||= []

          queries << {
            sql: truncate_sql(event.payload[:sql]),
            name: event.payload[:name],
            duration_ms: event.duration,
            cached: event.payload[:cached] || false
          }
        end

        # Handle view render
        def handle_view_render(event)
          views = current_request_data[:views] ||= []

          views << {
            identifier: event.payload[:identifier]&.sub(Rails.root.to_s + "/", ""),
            duration_ms: event.duration,
            layout: event.payload[:layout]
          }
        end

        # Handle cache operation
        def handle_cache_operation(event)
          cache_ops = current_request_data[:cache] ||= []

          cache_ops << {
            operation: event.name.split(".").first, # cache_read or cache_write
            key: truncate_cache_key(event.payload[:key]),
            hit: event.payload[:hit],
            duration_ms: event.duration
          }
        end

        # Build the final performance event
        def build_performance_event(event, request_data)
          payload = event.payload
          queries = request_data[:queries] || []
          views = request_data[:views] || []

          # Calculate aggregates
          db_time = queries.sum { |q| q[:duration_ms] }
          view_time = views.sum { |v| v[:duration_ms] }

          # Detect N+1 queries
          n_plus_one = detect_n_plus_one(queries)

          # Find slow queries
          slow_queries = queries.select do |q|
            q[:duration_ms] >= Findbug.config.slow_query_threshold_ms
          end

          {
            transaction_name: "#{payload[:controller]}##{payload[:action]}",
            request_method: payload[:method],
            request_path: payload[:path],
            format: payload[:format],
            status: payload[:status],

            duration_ms: event.duration,
            db_time_ms: db_time,
            view_time_ms: view_time,

            query_count: queries.size,
            slow_queries: slow_queries.first(10), # Limit stored slow queries
            has_n_plus_one: n_plus_one.any?,
            n_plus_one_queries: n_plus_one.first(5),

            view_count: views.size,

            context: Capture::Context.to_h,
            captured_at: Time.now.utc.iso8601(3),
            environment: Findbug.config.environment,
            release: Findbug.config.release
          }
        end

        # Detect N+1 query patterns
        #
        # WHAT IS N+1?
        # ============
        #
        # The N+1 problem occurs when you:
        # 1. Load a collection (1 query)
        # 2. For each item, run another query (N queries)
        #
        # Example:
        #   posts = Post.all              # 1 query
        #   posts.each do |post|
        #     puts post.author.name       # N queries!
        #   end
        #
        # We detect this by finding similar queries executed multiple times.
        #
        def detect_n_plus_one(queries)
          return [] if queries.size < 3

          # Normalize queries (remove specific IDs)
          normalized = queries.map do |q|
            {
              pattern: normalize_sql_pattern(q[:sql]),
              original: q[:sql],
              duration_ms: q[:duration_ms]
            }
          end

          # Group by pattern and find duplicates
          grouped = normalized.group_by { |q| q[:pattern] }

          grouped.select { |_, group| group.size >= 3 }.map do |pattern, group|
            {
              pattern: pattern,
              count: group.size,
              total_duration_ms: group.sum { |q| q[:duration_ms] },
              example: group.first[:original]
            }
          end
        end

        # Normalize SQL for pattern matching
        def normalize_sql_pattern(sql)
          return "" unless sql

          sql.gsub(/\d+/, "?")
             .gsub(/'[^']*'/, "?")
             .gsub(/"[^"]*"/, "?")
             .gsub(/\s+/, " ")
             .strip
        end

        # Truncate SQL to reasonable length
        def truncate_sql(sql)
          return nil unless sql

          sql.length > 1000 ? "#{sql[0..997]}..." : sql
        end

        # Truncate cache keys
        def truncate_cache_key(key)
          return nil unless key

          key_s = key.to_s
          key_s.length > 200 ? "#{key_s[0..197]}..." : key_s
        end

        # Check if we should sample this request
        def should_sample?
          Findbug.config.should_capture_performance?
        end

        # Check if request meets threshold for capture
        def meets_threshold?(event)
          return true if Findbug.config.slow_request_threshold_ms.zero?

          event[:duration_ms] >= Findbug.config.slow_request_threshold_ms
        end

        # Thread-local storage for request data
        def current_request_data
          Thread.current[:findbug_performance_data] ||= {}
        end

        def clear_request_data
          Thread.current[:findbug_performance_data] = nil
        end
      end
    end
  end
end
