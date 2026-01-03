# frozen_string_literal: true

require "redis"
require "connection_pool"

module Findbug
  module Storage
    # ConnectionPool manages Redis connections for Findbug.
    #
    # WHY A SEPARATE POOL?
    # ====================
    #
    # Your Rails app likely already uses Redis for:
    # - Sidekiq (job queue)
    # - Caching (Rails.cache)
    # - Action Cable (websockets)
    #
    # If Findbug shared these connections, we could:
    # 1. Starve your app of connections during high error rates
    # 2. Cause Sidekiq jobs to timeout waiting for connections
    # 3. Create unpredictable latency spikes
    #
    # By maintaining our OWN pool, Findbug is isolated.
    # If our pool is exhausted, only Findbug suffers - your app keeps running.
    #
    # HOW CONNECTION POOLING WORKS
    # ============================
    #
    #   Without pooling:
    #   Thread 1 → create connection → use → close
    #   Thread 2 → create connection → use → close  (expensive!)
    #   Thread 3 → create connection → use → close
    #
    #   With pooling:
    #   Thread 1 → borrow connection → use → return to pool
    #   Thread 2 → borrow connection → use → return to pool
    #   Thread 3 → borrow connection → use → return to pool
    #                   ↓
    #            [Pool of 5 connections]
    #
    # The `connection_pool` gem handles:
    # - Creating connections lazily (only when needed)
    # - Returning connections automatically (via block)
    # - Waiting for available connections (with timeout)
    # - Thread-safety (multiple threads can't corrupt state)
    #
    class ConnectionPool
      class << self
        # Get a connection from the pool and execute a block
        #
        # @yield [Redis] a Redis connection
        # @return [Object] the return value of the block
        #
        # @example
        #   ConnectionPool.with do |redis|
        #     redis.lpush("findbug:errors", data.to_json)
        #   end
        #
        # WHY A BLOCK?
        # ------------
        # The block pattern ensures connections are ALWAYS returned to the pool.
        # Even if an exception occurs, the connection goes back.
        # This prevents connection leaks.
        #
        def with(&block)
          pool.with(&block)
        end

        # Get the raw pool (for advanced usage)
        #
        # @return [::ConnectionPool] the underlying connection pool
        #
        def pool
          @pool ||= create_pool
        end

        # Shutdown the pool (for cleanup/testing)
        #
        # This closes all connections and resets the pool.
        # Call this when shutting down your app or between tests.
        #
        def shutdown!
          @pool&.shutdown { |redis| redis.close }
          @pool = nil
        end

        # Check if a connection can be established
        #
        # @return [Boolean] true if Redis is reachable
        #
        # This is used by the circuit breaker to test if Redis is back up.
        #
        def healthy?
          with { |redis| redis.ping == "PONG" }
        rescue StandardError
          false
        end

        private

        def create_pool
          config = Findbug.config

          ::ConnectionPool.new(
            size: config.redis_pool_size,
            timeout: config.redis_pool_timeout
          ) do
            create_redis_connection(config.redis_url)
          end
        end

        def create_redis_connection(url)
          # Parse the URL and create a Redis connection
          #
          # WHY NOT JUST `Redis.new(url: url)`?
          # -----------------------------------
          # We add some defensive options:
          # - connect_timeout: Don't hang if Redis is unreachable
          # - read_timeout: Don't hang if Redis is slow
          # - write_timeout: Don't hang on slow writes
          # - reconnect_attempts: Retry on temporary failures
          #
          Redis.new(
            url: url,
            connect_timeout: 1.0,   # 1 second to establish connection
            read_timeout: 1.0,      # 1 second to read response
            write_timeout: 1.0,     # 1 second to write command
            reconnect_attempts: 1   # Retry once on connection failure
          )
        end
      end
    end
  end
end
