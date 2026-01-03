# frozen_string_literal: true

require "rails/railtie"

module Findbug
  # Railtie hooks Findbug into the Rails boot process.
  #
  # WHAT IS A RAILTIE?
  # ==================
  #
  # When Rails boots, it looks for classes that inherit from Rails::Railtie
  # and calls their initializers in order. This is how gems integrate with Rails.
  #
  # Common things Railties do:
  # - Insert middleware into the stack
  # - Subscribe to ActiveSupport::Notifications
  # - Add rake tasks
  # - Configure the Rails app
  #
  # WHY USE A RAILTIE?
  # ==================
  #
  # Instead of making users add Findbug to 5 different places:
  #
  #   # application.rb
  #   config.middleware.use Findbug::Capture::Middleware
  #
  #   # initializer
  #   ActiveSupport::Notifications.subscribe(...)
  #
  #   # routes
  #   mount Findbug::Web::Engine => "/findbug"
  #
  # We do it all automatically in the Railtie. User just adds the gem
  # and creates a config file. Zero setup!
  #
  # THE INITIALIZATION ORDER
  # ========================
  #
  # Rails runs initializers in stages:
  #
  # 1. before_configuration - Before config is read
  # 2. before_initialize - Before Rails.initialize!
  # 3. to_prepare - Before each request (dev) or once (prod)
  # 4. after_initialize - After Rails is fully loaded
  #
  # We use after_initialize because we need:
  # - Rails.env to be set
  # - Database connections to exist
  # - All models to be loaded
  #
  class Railtie < Rails::Railtie
    # Register our middleware to catch exceptions
    #
    # MIDDLEWARE ORDER MATTERS!
    # -------------------------
    #
    # We insert AFTER ActionDispatch::ShowExceptions because:
    # 1. ShowExceptions converts exceptions to HTTP responses
    # 2. We want to capture the raw exception BEFORE that happens
    # 3. We also want to capture exceptions that ShowExceptions misses
    #
    # Stack (simplified):
    #   Rails::Rack::Logger
    #   ActionDispatch::RequestId
    #   ActionDispatch::ShowExceptions  ← Converts exceptions to 500 pages
    #   Findbug::Capture::Middleware    ← WE GO HERE (sees raw exceptions)
    #   ActionDispatch::Routing
    #   YourController#action
    #
    initializer "findbug.middleware" do
      require_relative "capture/middleware"

      Rails.application.config.middleware.use(Findbug::Capture::Middleware)
    end

    # Set up Rails error reporting integration (Rails 7+)
    #
    # Rails 7 introduced ErrorReporter for centralized error handling.
    # We subscribe to it so we capture ALL errors, even those handled
    # gracefully by the app.
    #
    initializer "findbug.error_reporter" do |app|
      require_relative "capture/exception_subscriber"

      app.config.after_initialize do
        if defined?(Rails.error) && Rails.error.respond_to?(:subscribe)
          Rails.error.subscribe(Findbug::Capture::ExceptionSubscriber.new)
        end
      end
    end

    # Set up performance instrumentation
    #
    # Rails uses ActiveSupport::Notifications for internal events:
    # - sql.active_record (database queries)
    # - process_action.action_controller (requests)
    # - render_template.action_view (view rendering)
    #
    # We subscribe to these to capture performance data.
    #
    initializer "findbug.instrumentation" do |app|
      app.config.after_initialize do
        next unless Findbug.config.performance_enabled

        require_relative "performance/instrumentation"
        Findbug::Performance::Instrumentation.setup!
      end
    end

    # Mount the web dashboard engine
    #
    # This adds routes for the /findbug dashboard.
    # We only mount if authentication is configured (security!).
    #
    initializer "findbug.routes" do |app|
      app.config.after_initialize do
        next unless Findbug.config.web_enabled?

        require_relative "web/engine"

        # Add routes programmatically
        # This is equivalent to `mount Findbug::Web::Engine => "/findbug"` in routes.rb
        # but automatic!
        app.routes.append do
          mount Findbug::Web::Engine => Findbug.config.web_path
        end
      end
    end

    # Set up default configuration values that depend on Rails
    #
    initializer "findbug.defaults" do |app|
      app.config.after_initialize do
        config = Findbug.config

        # Use Rails.env if environment not explicitly set
        config.environment ||= Rails.env

        # Disable in test environment by default
        if Rails.env.test? && config.enabled
          Findbug.logger.debug(
            "[Findbug] Running in test environment. Set `config.enabled = true` to enable."
          )
          # Note: We don't force disable here. User might want it enabled for integration tests.
        end

        # Try to auto-detect release from common sources
        config.release ||= detect_release
      end
    end

    # Add Findbug helpers to ActionController
    #
    # This adds methods like `findbug_context` that controllers can use
    # to add custom context to errors.
    #
    initializer "findbug.controller_methods" do
      ActiveSupport.on_load(:action_controller) do
        require_relative "rails/controller_methods"
        include Findbug::RailsExt::ControllerMethods
      end
    end

    # Start background persister
    #
    # This runs a thread that periodically moves events from Redis to the database.
    # Users don't need to set up Sidekiq or any job system - it works out of the box.
    #
    initializer "findbug.background_persister" do |app|
      app.config.after_initialize do
        next unless Findbug.enabled?
        next unless Findbug.config.auto_persist

        require_relative "background_persister"
        Findbug::BackgroundPersister.start!(
          interval: Findbug.config.persist_interval
        )
      end
    end

    # Register cleanup for application shutdown
    #
    # When the app shuts down (e.g., during deploys), we want to:
    # 1. Stop the background persister thread
    # 2. Flush any pending events
    # 3. Close Redis connections cleanly
    #
    initializer "findbug.shutdown" do |app|
      at_exit do
        Findbug::BackgroundPersister.stop! if defined?(Findbug::BackgroundPersister)
        Findbug::Storage::ConnectionPool.shutdown! if defined?(Findbug::Storage::ConnectionPool)
      end
    end

    # Add rake tasks
    rake_tasks do
      load File.expand_path("tasks/findbug.rake", __dir__)
    end

    private

    # Try to detect the release/version from environment
    def detect_release
      # Common environment variables for release tracking
      ENV["FINDBUG_RELEASE"] ||
        ENV["HEROKU_SLUG_COMMIT"] ||
        ENV["RENDER_GIT_COMMIT"] ||
        ENV["GIT_COMMIT"] ||
        ENV["SOURCE_VERSION"] ||
        git_sha
    end

    # Get current git SHA (if in a git repo)
    def git_sha
      sha = `git rev-parse --short HEAD 2>/dev/null`.strip
      sha.empty? ? nil : sha
    rescue StandardError
      nil
    end
  end
end
