# frozen_string_literal: true

# Findbug Configuration
#
# This file configures Findbug, your self-hosted error and performance monitoring.
# See https://github.com/ITSSOUMIT/findbug for full documentation.
#

Findbug.configure do |config|
  # ============================================================================
  # CORE SETTINGS
  # ============================================================================

  # Enable or disable Findbug (default: true)
  # Set to false in test environment to reduce noise
  config.enabled = !Rails.env.test?

  # Redis URL for the buffer
  # We recommend using a separate database (e.g., /1) from your main Redis
  config.redis_url = ENV.fetch("FINDBUG_REDIS_URL", "redis://localhost:6379/1")

  # Redis connection pool settings
  config.redis_pool_size = ENV.fetch("FINDBUG_REDIS_POOL_SIZE", 5).to_i

  # ============================================================================
  # ERROR CAPTURE
  # ============================================================================

  # Sample rate for error capture (0.0 to 1.0)
  # 1.0 = capture 100% of errors (recommended for most apps)
  # Lower this for extremely high-traffic apps
  config.sample_rate = 1.0

  # Exceptions to ignore (won't be captured)
  # Add exceptions that are "expected" in normal operation
  config.ignored_exceptions = [
    ActiveRecord::RecordNotFound,      # 404s
    ActionController::RoutingError,    # Invalid routes
    ActionController::UnknownFormat    # Format not supported
  ]

  # URL paths to ignore (regex patterns)
  # Useful for health checks, assets, etc.
  config.ignored_paths = [
    /^\/health/,
    /^\/assets/,
    /^\/packs/
  ]

  # ============================================================================
  # PERFORMANCE MONITORING
  # ============================================================================

  # Enable performance monitoring (default: true)
  config.performance_enabled = true

  # Sample rate for performance data (0.0 to 1.0)
  # Performance data is more voluminous, so sampling is common
  config.performance_sample_rate = 0.1  # 10% of requests

  # Only capture requests slower than this (in ms)
  # Set to 0 to capture all sampled requests
  config.slow_request_threshold_ms = 0

  # Threshold for flagging slow SQL queries (in ms)
  config.slow_query_threshold_ms = 100

  # ============================================================================
  # DATA SCRUBBING (Security)
  # ============================================================================

  # Field names to scrub (replaced with [FILTERED])
  # Add any custom sensitive fields your app uses
  config.scrub_fields = %w[
    password
    password_confirmation
    secret
    token
    api_key
    credit_card
    ssn
  ]

  # Scrub sensitive headers (default: true)
  config.scrub_headers = true

  # ============================================================================
  # STORAGE & RETENTION
  # ============================================================================

  # How many days to keep data (default: 30)
  config.retention_days = 30

  # Maximum events in Redis buffer before old ones are dropped
  config.max_buffer_size = 10_000

  # Queue name for Findbug background jobs
  config.queue_name = "findbug"

  # ============================================================================
  # WEB DASHBOARD
  # ============================================================================

  # Dashboard authentication (required for dashboard to be enabled)
  # We recommend using environment variables for security
  config.web_username = ENV["FINDBUG_USERNAME"]
  config.web_password = ENV["FINDBUG_PASSWORD"]

  # Dashboard URL path (default: "/findbug")
  config.web_path = "/findbug"

  # ============================================================================
  # ALERTS
  # ============================================================================

  config.alerts do |alerts|
    # Throttle period - don't alert for same error more than once in this period
    alerts.throttle_period = 5.minutes

    # Email alerts
    # alerts.email(
    #   enabled: true,
    #   recipients: ["dev-team@example.com"]
    # )

    # Slack alerts
    # alerts.slack(
    #   enabled: true,
    #   webhook_url: ENV["SLACK_WEBHOOK_URL"],
    #   channel: "#errors"  # optional
    # )

    # Discord alerts
    # alerts.discord(
    #   enabled: true,
    #   webhook_url: ENV["DISCORD_WEBHOOK_URL"]
    # )

    # Generic webhook
    # alerts.webhook(
    #   enabled: true,
    #   url: "https://your-service.com/findbug-webhook",
    #   headers: { "Authorization" => "Bearer #{ENV['WEBHOOK_TOKEN']}" }
    # )
  end

  # ============================================================================
  # MISC
  # ============================================================================

  # Release/version identifier (auto-detected from git or ENV)
  # Useful for tracking which deploy introduced a bug
  # config.release = ENV["GIT_COMMIT"]

  # Custom logger (defaults to Rails.logger)
  # config.logger = Rails.logger
end
