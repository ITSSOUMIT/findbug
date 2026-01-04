# frozen_string_literal: true

require_relative "findbug/version"
require_relative "findbug/configuration"

# Findbug - Self-hosted error tracking and performance monitoring for Rails
#
# ARCHITECTURE OVERVIEW
# =====================
#
# Findbug is designed with ONE critical goal: NEVER slow down your application.
#
# How we achieve this:
#
# 1. ASYNC WRITES
#    When an error occurs, we don't write to the database immediately.
#    Instead, we push to a Redis buffer in a background thread.
#    This takes ~1-2ms and doesn't block your request.
#
# 2. BACKGROUND PERSISTENCE
#    A periodic job (via ActiveJob or built-in thread) pulls events from Redis
#    and batch-inserts them to the database. This happens outside your
#    request cycle.
#
# 3. CIRCUIT BREAKER
#    If Redis is down, we don't keep retrying and slowing down your app.
#    The circuit breaker "opens" after 5 failures and stops attempting
#    writes for 30 seconds.
#
# 4. CONNECTION POOLING
#    We maintain our OWN Redis connection pool, separate from your app's
#    Redis/Sidekiq. This prevents connection contention.
#
# 5. SAMPLING
#    For high-traffic apps, you can sample errors (e.g., capture 50%)
#    to reduce overhead further.
#
# DATA FLOW
# =========
#
#   [Exception occurs]
#          |
#          v
#   [Middleware catches it]
#          |
#          v
#   [Scrub sensitive data]
#          |
#          v
#   [Push to Redis buffer] <-- Async, non-blocking (Thread.new)
#          |
#          v
#   [BackgroundPersister runs every 30s]
#          |
#          v
#   [Batch insert to Database]
#          |
#          v
#   [Dashboard displays data]
#
module Findbug
  # Base error class for Findbug-specific exceptions
  class Error < StandardError; end

  class << self
    # Access the configuration object
    #
    # @return [Configuration] the current configuration
    #
    # WHY A CLASS METHOD?
    # -------------------
    # We use `Findbug.config` instead of a global variable because:
    # 1. It's lazily initialized (created on first access)
    # 2. It's thread-safe (||= is atomic in MRI Ruby)
    # 3. It's mockable in tests
    # 4. It follows Ruby conventions (like Rails.config)
    #
    def config
      @config ||= Configuration.new
    end

    # Configure Findbug with a block
    #
    # @yield [Configuration] the configuration object
    #
    # @example
    #   Findbug.configure do |config|
    #     config.redis_url = "redis://localhost:6379/1"
    #     config.sample_rate = 0.5
    #
    #     config.alerts do |alerts|
    #       alerts.slack enabled: true, webhook_url: ENV["SLACK_WEBHOOK"]
    #     end
    #   end
    #
    def configure
      yield(config) if block_given?
      config.validate!
      config
    end

    # Reset configuration to defaults (useful for testing)
    #
    # WHY EXPOSE THIS?
    # ----------------
    # In tests, you often want to reset state between examples.
    # This makes Findbug test-friendly.
    #
    def reset!
      @config = nil
      @redis_pool = nil
      @logger = nil
    end

    # Get the logger instance
    #
    # Falls back to Rails.logger, then to a null logger
    #
    def logger
      @logger ||= config.logger || (defined?(Rails) && Rails.logger) || Logger.new(IO::NULL)
    end

    # Set a custom logger
    def logger=(new_logger)
      @logger = new_logger
    end

    # Check if Findbug is enabled
    #
    # This is a convenience method used throughout the codebase.
    # It checks both the enabled flag AND validates we're properly configured.
    #
    def enabled?
      config.enabled && config.redis_url.present?
    end

    # Capture an exception manually
    #
    # @param exception [Exception] the exception to capture
    # @param context [Hash] additional context to attach
    #
    # @example
    #   begin
    #     risky_operation
    #   rescue => e
    #     Findbug.capture_exception(e, user_id: current_user.id)
    #     raise # re-raise to let Rails handle it
    #   end
    #
    # WHY A MANUAL CAPTURE METHOD?
    # ----------------------------
    # Sometimes you want to capture an exception without crashing.
    # For example, in a rescue block where you handle the error
    # gracefully but still want to track it.
    #
    def capture_exception(exception, context = {})
      return unless enabled?
      return unless config.should_capture_exception?(exception)

      Capture::ExceptionHandler.capture(exception, context)
    rescue StandardError => e
      # CRITICAL: Never let Findbug crash your app
      logger.error("[Findbug] Failed to capture exception: #{e.message}")
    end

    # Capture a message (non-exception event)
    #
    # @param message [String] the message to capture
    # @param level [Symbol] severity level (:info, :warning, :error)
    # @param context [Hash] additional context
    #
    # @example
    #   Findbug.capture_message("User exceeded rate limit", :warning, user_id: 123)
    #
    def capture_message(message, level = :info, context = {})
      return unless enabled?

      Capture::MessageHandler.capture(message, level, context)
    rescue StandardError => e
      logger.error("[Findbug] Failed to capture message: #{e.message}")
    end

    # Wrap a block with performance tracking
    #
    # @param name [String] name for this operation
    # @yield the block to track
    #
    # @example
    #   Findbug.track_performance("external_api_call") do
    #     ExternalAPI.fetch_data
    #   end
    #
    def track_performance(name, &block)
      return yield unless enabled? && config.performance_enabled

      Performance::Transaction.track(name, &block)
    rescue StandardError => e
      logger.error("[Findbug] Performance tracking failed: #{e.message}")
      yield # Still execute the block even if tracking fails
    end
  end
end

# Load core library modules (these stay in lib/ as they're not Rails-autoloadable)
require_relative "findbug/storage/connection_pool"
require_relative "findbug/storage/circuit_breaker"
require_relative "findbug/storage/redis_buffer"
require_relative "findbug/processing/data_scrubber"
require_relative "findbug/capture/context"
require_relative "findbug/capture/exception_handler"
require_relative "findbug/capture/message_handler"
require_relative "findbug/capture/middleware"

# Load the Railtie if Rails is available
# This auto-configures Findbug when Rails boots
require_relative "findbug/railtie" if defined?(Rails::Railtie)
