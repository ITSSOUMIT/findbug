# frozen_string_literal: true

module Findbug
  module Performance
    # Transaction provides manual performance tracking for custom operations.
    #
    # WHY MANUAL TRANSACTIONS?
    # ========================
    #
    # Automatic instrumentation catches HTTP requests, but what about:
    # - External API calls
    # - Background job processing
    # - Custom business logic
    # - Third-party service calls
    #
    # With transactions, you can track anything:
    #
    #   Findbug.track_performance("stripe_charge") do
    #     Stripe::Charge.create(...)
    #   end
    #
    #   Findbug.track_performance("pdf_generation") do
    #     generate_report_pdf(...)
    #   end
    #
    # NESTING
    # =======
    #
    # Transactions can be nested. Child transactions contribute to parent timing:
    #
    #   Findbug.track_performance("checkout") do
    #     Findbug.track_performance("payment") do
    #       process_payment
    #     end
    #     Findbug.track_performance("fulfillment") do
    #       create_shipment
    #     end
    #   end
    #
    # This creates a tree of timings you can analyze.
    #
    class Transaction
      class << self
        # Track a block's performance
        #
        # @param name [String] name for this transaction
        # @param tags [Hash] optional tags for filtering
        # @yield the block to track
        # @return [Object] the block's return value
        #
        def track(name, tags: {}, &block)
          return yield unless Findbug.enabled?
          return yield unless Findbug.config.performance_enabled

          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          begin
            # Execute the block
            result = yield

            # Calculate duration
            duration_ms = calculate_duration(start_time)

            # Record the transaction
            record_transaction(name, duration_ms, tags, success: true)

            result
          rescue StandardError => e
            # Calculate duration even on error
            duration_ms = calculate_duration(start_time)

            # Record as failed
            record_transaction(name, duration_ms, tags, success: false, error: e.class.name)

            raise
          end
        end

        # Start a transaction manually (for cases where block syntax doesn't work)
        #
        # @param name [String] transaction name
        # @return [TransactionSpan] a span object to finish later
        #
        # @example
        #   span = Findbug::Performance::Transaction.start("long_operation")
        #   # ... do work ...
        #   span.finish
        #
        def start(name, tags: {})
          TransactionSpan.new(name, tags)
        end

        private

        def calculate_duration(start_time)
          end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          ((end_time - start_time) * 1000).round(2)
        end

        def record_transaction(name, duration_ms, tags, success:, error: nil)
          # Only sample some transactions
          return unless Findbug.config.should_capture_performance?

          event = {
            transaction_name: name,
            transaction_type: "custom",
            duration_ms: duration_ms,
            success: success,
            error_class: error,
            tags: tags,
            context: Capture::Context.to_h,
            captured_at: Time.now.utc.iso8601(3),
            environment: Findbug.config.environment,
            release: Findbug.config.release
          }

          Storage::RedisBuffer.push_performance(event)
        rescue StandardError => e
          Findbug.logger.debug("[Findbug] Transaction recording failed: #{e.message}")
        end
      end
    end

    # TransactionSpan represents an in-progress transaction.
    #
    # Use this when block syntax isn't convenient:
    #
    #   span = Findbug::Performance::Transaction.start("my_operation")
    #   begin
    #     do_work
    #     span.finish
    #   rescue => e
    #     span.finish(error: e)
    #     raise
    #   end
    #
    class TransactionSpan
      attr_reader :name, :tags, :start_time

      def initialize(name, tags = {})
        @name = name
        @tags = tags
        @start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @finished = false
      end

      # Finish the transaction
      #
      # @param error [Exception, nil] optional error if the transaction failed
      #
      def finish(error: nil)
        return if @finished

        @finished = true
        duration_ms = calculate_duration

        event = {
          transaction_name: name,
          transaction_type: "custom",
          duration_ms: duration_ms,
          success: error.nil?,
          error_class: error&.class&.name,
          tags: tags,
          context: Capture::Context.to_h,
          captured_at: Time.now.utc.iso8601(3),
          environment: Findbug.config.environment,
          release: Findbug.config.release
        }

        Storage::RedisBuffer.push_performance(event)
      rescue StandardError => e
        Findbug.logger.debug("[Findbug] Span finish failed: #{e.message}")
      end

      # Check if already finished
      def finished?
        @finished
      end

      # Get current duration (for monitoring in-progress transactions)
      def current_duration_ms
        calculate_duration
      end

      private

      def calculate_duration
        end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ((end_time - start_time) * 1000).round(2)
      end
    end
  end
end
