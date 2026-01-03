# frozen_string_literal: true

module Findbug
  # Configuration holds all settings for Findbug.
  #
  # WHY THIS PATTERN?
  # -----------------
  # This is the standard Ruby gem configuration pattern. Users call:
  #
  #   Findbug.configure do |config|
  #     config.redis_url = "redis://localhost:6379/1"
  #     config.enabled = Rails.env.production?
  #   end
  #
  # Benefits:
  # 1. All settings in one place (easy to find/audit)
  # 2. Sensible defaults (works without configuration)
  # 3. Type checking and validation at startup (fail fast)
  # 4. Isolated from global state (each setting is an instance variable)
  #
  class Configuration
    # ----- Core Settings -----

    # Whether Findbug is enabled. Disable in test environments to avoid noise.
    # Default: true (enabled)
    attr_accessor :enabled

    # Redis connection URL. We use a SEPARATE Redis connection from your app
    # to avoid any interference with your caching/Sidekiq.
    # Default: redis://localhost:6379/1 (note: database 1, not 0)
    attr_accessor :redis_url

    # Size of the Redis connection pool. More connections = more concurrent writes.
    # Rule of thumb: match your Puma/Unicorn worker count.
    # Default: 5
    attr_accessor :redis_pool_size

    # Timeout for getting a connection from the pool (in seconds).
    # If all connections are busy, we wait this long before giving up.
    # Default: 1 second (fast fail to avoid blocking your app)
    attr_accessor :redis_pool_timeout

    # ----- Error Capture Settings -----

    # Sample rate for error capture (0.0 to 1.0).
    # 1.0 = capture 100% of errors
    # 0.5 = capture 50% of errors (randomly sampled)
    # Useful for extremely high-traffic apps where you don't need every error.
    # Default: 1.0 (capture everything)
    attr_accessor :sample_rate

    # Exception classes to ignore. These won't be captured at all.
    # Common ignores: ActiveRecord::RecordNotFound (404s), ActionController::RoutingError
    # Default: empty array
    attr_accessor :ignored_exceptions

    # Paths to ignore (regex patterns). Useful for health checks, assets, etc.
    # Example: [/^\/health/, /^\/assets/]
    # Default: empty array
    attr_accessor :ignored_paths

    # ----- Performance Monitoring Settings -----

    # Whether to enable performance monitoring (request timing, SQL queries).
    # Default: true
    attr_accessor :performance_enabled

    # Sample rate for performance monitoring (0.0 to 1.0).
    # Performance data is more voluminous than errors, so you might want to sample.
    # Default: 0.1 (10% of requests)
    attr_accessor :performance_sample_rate

    # Threshold in ms. Only record requests slower than this.
    # Helps reduce noise from fast requests.
    # Default: 0 (record all sampled requests)
    attr_accessor :slow_request_threshold_ms

    # Threshold in ms for flagging slow SQL queries.
    # Default: 100ms
    attr_accessor :slow_query_threshold_ms

    # ----- Data Scrubbing (Security) -----

    # Field names to scrub from captured data. These will be replaced with [FILTERED].
    # CRITICAL for PII/security compliance.
    # Default: common sensitive fields
    attr_accessor :scrub_fields

    # Whether to scrub request headers.
    # Default: true (scrubs Authorization, Cookie, etc.)
    attr_accessor :scrub_headers

    # Additional headers to scrub (beyond defaults).
    # Default: empty array
    attr_accessor :scrub_header_names

    # ----- Storage & Retention -----

    # How many days to keep error/performance data in the database.
    # Older records are automatically deleted by the cleanup job.
    # Default: 30 days
    attr_accessor :retention_days

    # Maximum buffer size in Redis (number of events).
    # Prevents Redis memory from growing unbounded if DB persistence falls behind.
    # Default: 10000 events
    attr_accessor :max_buffer_size

    # Redis key TTL for buffered events (in seconds).
    # Events older than this are automatically expired by Redis.
    # Default: 86400 (24 hours)
    attr_accessor :buffer_ttl

    # ----- Background Jobs -----

    # Queue name for Findbug's background jobs.
    # Default: "findbug"
    attr_accessor :queue_name

    # Batch size for persistence job (how many events to move from Redis to DB at once).
    # Larger = more efficient, but uses more memory.
    # Default: 100
    attr_accessor :persist_batch_size

    # Interval (in seconds) for the background persister thread.
    # This is how often events are moved from Redis to the database.
    # Default: 30 seconds
    attr_accessor :persist_interval

    # Whether to use the built-in background persister thread.
    # Set to false if you want to use ActiveJob/Sidekiq instead.
    # Default: true
    attr_accessor :auto_persist

    # ----- Web Dashboard -----

    # Username for basic auth on the dashboard.
    # Default: nil (dashboard disabled if not set)
    attr_accessor :web_username

    # Password for basic auth on the dashboard.
    # Default: nil (dashboard disabled if not set)
    attr_accessor :web_password

    # Path prefix for the dashboard. The dashboard will be mounted at this path.
    # Default: "/findbug"
    attr_accessor :web_path

    # ----- Alert Settings -----

    # Alert configuration object (set via block)
    attr_reader :alerts

    # ----- Misc -----

    # Release/version identifier (e.g., git SHA, semantic version).
    # Useful for tracking which deploy introduced a bug.
    # Default: nil (auto-detected from ENV['FINDBUG_RELEASE'] or Git)
    attr_accessor :release

    # Environment name override.
    # Default: Rails.env
    attr_accessor :environment

    # Custom logger. If nil, uses Rails.logger.
    # Default: nil
    attr_accessor :logger

    def initialize
      # Set sensible defaults
      @enabled = true

      # Redis defaults - note we use database 1 to avoid conflicts
      @redis_url = ENV.fetch("FINDBUG_REDIS_URL", "redis://localhost:6379/1")
      @redis_pool_size = ENV.fetch("FINDBUG_REDIS_POOL_SIZE", 5).to_i
      @redis_pool_timeout = 1

      # Error capture defaults
      @sample_rate = 1.0
      @ignored_exceptions = []
      @ignored_paths = []

      # Performance defaults
      @performance_enabled = true
      @performance_sample_rate = 0.1
      @slow_request_threshold_ms = 0
      @slow_query_threshold_ms = 100

      # Security defaults - these are CRITICAL
      @scrub_fields = %w[
        password password_confirmation
        secret secret_key secret_token
        api_key api_secret
        access_token refresh_token
        credit_card card_number cvv
        ssn social_security
        private_key
      ]
      @scrub_headers = true
      @scrub_header_names = []

      # Storage defaults
      @retention_days = 30
      @max_buffer_size = 10_000
      @buffer_ttl = 86_400 # 24 hours

      # Job defaults
      @queue_name = "findbug"
      @persist_batch_size = 100
      @persist_interval = 30
      @auto_persist = true

      # Web defaults
      @web_username = ENV["FINDBUG_USERNAME"]
      @web_password = ENV["FINDBUG_PASSWORD"]
      @web_path = "/findbug"

      # Alerts - initialized empty, configured via block
      @alerts = AlertConfiguration.new

      # Misc
      @release = ENV["FINDBUG_RELEASE"]
      @environment = nil # Will use Rails.env if not set
      @logger = nil # Will use Rails.logger if not set
    end

    # DSL for configuring alerts
    #
    # Example:
    #   config.alerts do |alerts|
    #     alerts.email enabled: true, recipients: ["team@example.com"]
    #     alerts.slack enabled: true, webhook_url: ENV["SLACK_WEBHOOK"]
    #   end
    #
    def alerts
      if block_given?
        yield @alerts
      else
        @alerts
      end
    end

    # Validate configuration at startup
    # Raises ConfigurationError if something is wrong
    def validate!
      validate_sample_rates!
      validate_redis!
      validate_web_auth!
    end

    # Check if the dashboard should be enabled
    def web_enabled?
      web_username.present? && web_password.present?
    end

    # Check if we should capture this exception class
    def should_capture_exception?(exception)
      return false unless enabled
      return false if ignored_exceptions.any? { |klass| exception.is_a?(klass) }

      # Apply sampling
      rand <= sample_rate
    end

    # Check if we should capture this request path
    def should_capture_path?(path)
      return false unless enabled
      return false if ignored_paths.any? { |pattern| path.match?(pattern) }

      true
    end

    # Check if we should capture performance for this request
    def should_capture_performance?
      return false unless enabled
      return false unless performance_enabled

      # Apply sampling
      rand <= performance_sample_rate
    end

    private

    def validate_sample_rates!
      unless sample_rate.between?(0.0, 1.0)
        raise ConfigurationError, "sample_rate must be between 0.0 and 1.0"
      end

      unless performance_sample_rate.between?(0.0, 1.0)
        raise ConfigurationError, "performance_sample_rate must be between 0.0 and 1.0"
      end
    end

    def validate_redis!
      return unless enabled

      unless redis_url.present?
        raise ConfigurationError, "redis_url is required when Findbug is enabled"
      end
    end

    def validate_web_auth!
      # If one is set, both must be set
      if (web_username.present? && web_password.blank?) ||
         (web_username.blank? && web_password.present?)
        raise ConfigurationError, "Both web_username and web_password must be set for dashboard authentication"
      end
    end
  end

  # Nested class for alert configuration
  #
  # WHY A SEPARATE CLASS?
  # Alerts have their own sub-configuration (multiple channels, each with settings).
  # Nesting keeps the main Configuration cleaner.
  #
  class AlertConfiguration
    attr_accessor :throttle_period

    def initialize
      @channels = {}
      @throttle_period = 300 # 5 minutes default
    end

    # Configure email alerts
    def email(enabled:, recipients: [], **options)
      @channels[:email] = {
        enabled: enabled,
        recipients: Array(recipients),
        **options
      }
    end

    # Configure Slack alerts
    def slack(enabled:, webhook_url: nil, channel: nil, **options)
      @channels[:slack] = {
        enabled: enabled,
        webhook_url: webhook_url,
        channel: channel,
        **options
      }
    end

    # Configure Discord alerts
    def discord(enabled:, webhook_url: nil, **options)
      @channels[:discord] = {
        enabled: enabled,
        webhook_url: webhook_url,
        **options
      }
    end

    # Configure generic webhook alerts
    def webhook(enabled:, url: nil, headers: {}, **options)
      @channels[:webhook] = {
        enabled: enabled,
        url: url,
        headers: headers,
        **options
      }
    end

    # Get configuration for a specific channel
    def channel(name)
      @channels[name.to_sym]
    end

    # Get all enabled channels
    def enabled_channels
      @channels.select { |_, config| config[:enabled] }
    end

    # Check if any alerts are configured
    def any_enabled?
      enabled_channels.any?
    end
  end

  # Custom error for configuration issues
  class ConfigurationError < StandardError; end
end
