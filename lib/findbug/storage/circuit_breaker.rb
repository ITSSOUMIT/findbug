# frozen_string_literal: true

require "monitor"

module Findbug
  module Storage
    # CircuitBreaker prevents cascading failures when Redis is down.
    #
    # THE PROBLEM IT SOLVES
    # =====================
    #
    # Imagine Redis goes down during peak traffic:
    #
    #   Without circuit breaker:
    #   - 1000 requests/second
    #   - Each tries to write to Redis
    #   - Each waits 1 second for timeout
    #   - Your app becomes unusable
    #
    #   With circuit breaker:
    #   - After 5 failures, circuit "opens"
    #   - Next 1000 requests skip Redis immediately
    #   - Your app stays fast
    #   - After 30 seconds, we try again
    #
    # THE THREE STATES
    # ================
    #
    #   ┌─────────────────────────────────────────────────────────┐
    #   │                                                         │
    #   │   ┌──────────┐    failures >= 5    ┌──────────┐        │
    #   │   │  CLOSED  │ ─────────────────── │   OPEN   │        │
    #   │   │ (normal) │                     │ (tripped)│        │
    #   │   └──────────┘                     └──────────┘        │
    #   │        ▲                                 │             │
    #   │        │ success                         │ 30 seconds  │
    #   │        │                                 ▼             │
    #   │        │                          ┌───────────┐        │
    #   │        └───────────────────────── │ HALF-OPEN │        │
    #   │                                   │ (testing) │        │
    #   │                                   └───────────┘        │
    #   │                                         │              │
    #   │                                         │ failure      │
    #   │                                         ▼              │
    #   │                                   ┌──────────┐         │
    #   │                                   │   OPEN   │         │
    #   │                                   └──────────┘         │
    #   └─────────────────────────────────────────────────────────┘
    #
    # THREAD SAFETY
    # =============
    #
    # This class uses Monitor (a reentrant mutex) to ensure thread safety.
    # Multiple threads can check/update the circuit state without races.
    #
    class CircuitBreaker
      # How many failures before we trip the circuit
      FAILURE_THRESHOLD = 5

      # How long to wait before trying again (in seconds)
      RECOVERY_TIME = 30

      class << self
        # Check if requests are allowed through
        #
        # @return [Boolean] true if we should attempt the operation
        #
        # @example
        #   if CircuitBreaker.allow?
        #     # try Redis operation
        #   else
        #     # skip and log
        #   end
        #
        def allow?
          synchronize do
            case state
            when :closed
              # Normal operation - allow all requests
              true
            when :open
              if recovery_period_elapsed?
                # Time to test if Redis is back
                transition_to(:half_open)
                true
              else
                # Still in cooldown - reject immediately
                false
              end
            when :half_open
              # We're testing - allow this one request through
              true
            end
          end
        end

        # Record a successful operation
        #
        # Call this after a successful Redis operation.
        # This resets the failure count and closes the circuit.
        #
        def record_success
          synchronize do
            @failures = 0
            transition_to(:closed)
          end
        end

        # Record a failed operation
        #
        # Call this when a Redis operation fails.
        # After enough failures, the circuit opens.
        #
        def record_failure
          synchronize do
            @failures = (@failures || 0) + 1

            if state == :half_open
              # Failed during testing - back to open
              transition_to(:open)
            elsif @failures >= FAILURE_THRESHOLD
              # Too many failures - trip the circuit
              transition_to(:open)
              log_circuit_opened
            end
          end
        end

        # Get current state (for monitoring/debugging)
        #
        # @return [Symbol] :closed, :open, or :half_open
        #
        def state
          @state || :closed
        end

        # Get current failure count (for monitoring)
        #
        # @return [Integer] number of consecutive failures
        #
        def failure_count
          @failures || 0
        end

        # Reset the circuit breaker (for testing)
        def reset!
          synchronize do
            @state = :closed
            @failures = 0
            @opened_at = nil
          end
        end

        # Execute a block with circuit breaker protection
        #
        # @yield the operation to protect
        # @return [Object, nil] the block's return value, or nil if rejected
        #
        # @example
        #   result = CircuitBreaker.execute do
        #     redis.lpush("key", "value")
        #   end
        #
        # This is a convenience method that combines allow?/record_success/record_failure.
        #
        def execute
          return nil unless allow?

          begin
            result = yield
            record_success
            result
          rescue StandardError => e
            record_failure
            raise e
          end
        end

        private

        def synchronize(&block)
          @monitor ||= Monitor.new
          @monitor.synchronize(&block)
        end

        def transition_to(new_state)
          old_state = @state
          @state = new_state

          if new_state == :open
            @opened_at = Time.now
          end

          log_state_change(old_state, new_state) if old_state != new_state
        end

        def recovery_period_elapsed?
          return true unless @opened_at

          Time.now - @opened_at >= RECOVERY_TIME
        end

        def log_circuit_opened
          Findbug.logger.warn(
            "[Findbug] Circuit breaker opened after #{FAILURE_THRESHOLD} failures. " \
            "Redis operations will be skipped for #{RECOVERY_TIME} seconds."
          )
        end

        def log_state_change(old_state, new_state)
          return if old_state.nil? # Initial state

          case new_state
          when :closed
            Findbug.logger.info("[Findbug] Circuit breaker closed. Redis operations resumed.")
          when :half_open
            Findbug.logger.info("[Findbug] Circuit breaker half-open. Testing Redis connection...")
          end
        end
      end
    end
  end
end
