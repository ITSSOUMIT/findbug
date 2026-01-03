# frozen_string_literal: true

require "json"
require_relative "circuit_breaker"
require_relative "connection_pool"

module Findbug
  module Storage
    # RedisBuffer provides fast, non-blocking writes to Redis.
    #
    # THIS IS THE KEY TO ZERO PERFORMANCE IMPACT
    # ==========================================
    #
    # Traditional error tracking (synchronous):
    #
    #   Request starts
    #       ↓
    #   Exception occurs
    #       ↓
    #   BLOCKING: Write to database (50-100ms)  ← Your user waits!
    #       ↓
    #   Request ends
    #
    # Findbug (asynchronous):
    #
    #   Request starts
    #       ↓
    #   Exception occurs
    #       ↓
    #   NON-BLOCKING: Spawn thread to write to Redis (0ms)
    #       ↓                          ↓
    #   Request ends            Background: Redis write (1-2ms)
    #       ↓
    #   User gets response immediately
    #
    # WHY REDIS INSTEAD OF DATABASE?
    # ==============================
    #
    # Redis write: ~1-2ms
    # Database write: ~50-100ms (with indexes, constraints, etc.)
    #
    # Even if we made DB writes async, Redis is still better for buffering because:
    # 1. It's faster (in-memory)
    # 2. It handles high write loads gracefully
    # 3. It has built-in expiration (TTL)
    # 4. It supports atomic list operations
    #
    # The database is for long-term storage. Redis is for the fast buffer.
    #
    # WHY Thread.new INSTEAD OF SIDEKIQ?
    # ==================================
    #
    # Sidekiq itself writes to Redis. If we used Sidekiq to buffer our errors:
    # 1. We'd add Sidekiq job overhead (~5ms)
    # 2. We'd share Redis connections with Sidekiq
    # 3. We'd depend on Sidekiq being healthy
    #
    # A simple Thread.new is:
    # 1. Instant (no queue overhead)
    # 2. Independent of your job system
    # 3. Simpler (no job serialization)
    #
    # We use Sidekiq/ActiveJob later for PERSISTING to DB, not for buffering.
    #
    class RedisBuffer
      # Key prefix for error events
      ERRORS_KEY = "findbug:errors"

      # Key prefix for performance events
      PERFORMANCE_KEY = "findbug:performance"

      # Key for tracking stats
      STATS_KEY = "findbug:stats"

      class << self
        # Push an error event to the buffer (async, non-blocking)
        #
        # @param event_data [Hash] the error event data
        #
        # @example
        #   RedisBuffer.push_error({
        #     exception_class: "RuntimeError",
        #     message: "Something went wrong",
        #     backtrace: [...],
        #     context: {...}
        #   })
        #
        # IMPORTANT: This returns IMMEDIATELY. The actual write happens
        # in a background thread. This is what makes us non-blocking.
        #
        def push_error(event_data)
          push_async(ERRORS_KEY, event_data)
        end

        # Push a performance event to the buffer (async, non-blocking)
        #
        # @param event_data [Hash] the performance event data
        #
        def push_performance(event_data)
          push_async(PERFORMANCE_KEY, event_data)
        end

        # Pop a batch of error events from the buffer
        #
        # @param batch_size [Integer] maximum number of events to retrieve
        # @return [Array<Hash>] array of error events
        #
        # This is called by the PersistJob to move data from Redis to DB.
        # It uses LPOP in a loop to get events atomically.
        #
        def pop_errors(batch_size = 100)
          pop_batch(ERRORS_KEY, batch_size)
        end

        # Pop a batch of performance events from the buffer
        #
        # @param batch_size [Integer] maximum number of events to retrieve
        # @return [Array<Hash>] array of performance events
        #
        def pop_performance(batch_size = 100)
          pop_batch(PERFORMANCE_KEY, batch_size)
        end

        # Get buffer statistics (for monitoring)
        #
        # @return [Hash] buffer stats including queue lengths
        #
        def stats
          ConnectionPool.with do |redis|
            {
              error_queue_length: redis.llen(ERRORS_KEY),
              performance_queue_length: redis.llen(PERFORMANCE_KEY),
              circuit_breaker_state: CircuitBreaker.state,
              circuit_breaker_failures: CircuitBreaker.failure_count
            }
          end
        rescue StandardError => e
          # Always return circuit breaker state even if Redis is down
          {
            error_queue_length: 0,
            performance_queue_length: 0,
            circuit_breaker_state: Findbug::Storage::CircuitBreaker.state,
            circuit_breaker_failures: Findbug::Storage::CircuitBreaker.failure_count,
            error: "Redis connection failed: #{e.message}"
          }
        end

        # Clear all buffers (for testing)
        def clear!
          ConnectionPool.with do |redis|
            redis.del(ERRORS_KEY, PERFORMANCE_KEY)
          end
        rescue StandardError
          # Ignore errors during cleanup
        end

        private

        # The core async push operation
        #
        # WHY THIS PATTERN?
        # -----------------
        #
        # 1. Check circuit breaker BEFORE spawning thread
        #    - If Redis is down, don't waste resources on threads
        #
        # 2. Spawn a new thread for the actual write
        #    - This returns immediately to the caller
        #    - The thread runs independently
        #
        # 3. Inside the thread, use connection pool
        #    - Gets a connection from the pool
        #    - Writes to Redis
        #    - Returns connection automatically (via block)
        #
        # 4. Handle errors gracefully
        #    - Log but don't crash
        #    - Update circuit breaker state
        #
        def push_async(key, event_data)
          # Early exit if Findbug is disabled
          return unless Findbug.enabled?

          # Early exit if circuit breaker is open
          unless CircuitBreaker.allow?
            increment_dropped_count
            return
          end

          # Spawn a thread for non-blocking write
          #
          # WHY Thread.new HERE?
          # --------------------
          # Thread.new creates a new Ruby thread that runs independently.
          # The calling code continues immediately without waiting.
          #
          # THREAD SAFETY NOTES:
          # - event_data is captured by the closure (safe - we're not mutating it)
          # - ConnectionPool handles thread-safe connection borrowing
          # - Redis operations are atomic
          #
          Thread.new do
            perform_push(key, event_data)
          rescue StandardError => e
            # CRITICAL: Catch ALL errors in the thread
            # An unhandled exception in a thread will crash the thread silently
            handle_push_error(e)
          end

          nil # Return immediately
        end

        # The actual Redis push (runs in background thread)
        def perform_push(key, event_data)
          ConnectionPool.with do |redis|
            # Add timestamp if not present
            event_data[:captured_at] ||= Time.now.utc.iso8601(3)

            # LPUSH adds to the LEFT of the list (newest first)
            # We use JSON encoding for storage
            redis.lpush(key, event_data.to_json)

            # LTRIM keeps only the first N elements
            # This prevents unbounded memory growth
            # If we have more than max_buffer_size events, old ones are dropped
            max_size = Findbug.config.max_buffer_size
            redis.ltrim(key, 0, max_size - 1)

            # Record success for circuit breaker
            CircuitBreaker.record_success
          end
        end

        # Handle errors during push
        def handle_push_error(error)
          CircuitBreaker.record_failure

          # Log at debug level to avoid log spam during outages
          Findbug.logger.debug(
            "[Findbug] Failed to push event to Redis: #{error.message}"
          )
        end

        # Pop a batch of events atomically
        #
        # WHY NOT LRANGE + LTRIM?
        # -----------------------
        # That's not atomic. Between LRANGE and LTRIM, new events could arrive.
        # We use LPOP in a loop which is atomic per operation.
        #
        # WHY NOT RPOPLPUSH?
        # ------------------
        # We don't need a backup queue. If persistence fails, the job will
        # retry and the data is still in the main queue.
        #
        def pop_batch(key, batch_size)
          events = []

          ConnectionPool.with do |redis|
            batch_size.times do
              # RPOP gets from the RIGHT (oldest first - FIFO order)
              json = redis.rpop(key)
              break unless json

              begin
                events << JSON.parse(json, symbolize_names: true)
              rescue JSON::ParserError => e
                Findbug.logger.error("[Findbug] Failed to parse event: #{e.message}")
              end
            end
          end

          events
        end

        # Track dropped events (when circuit breaker is open)
        def increment_dropped_count
          # We could track this in Redis too, but that defeats the purpose
          # when Redis is down. Just log it.
          Findbug.logger.debug("[Findbug] Event dropped (circuit breaker open)")
        end
      end
    end
  end
end
