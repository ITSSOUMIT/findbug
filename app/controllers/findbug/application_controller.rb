# frozen_string_literal: true

module Findbug
  # ApplicationController is the base controller for all Findbug dashboard controllers.
  #
  # AUTHENTICATION
  # ==============
  #
  # We use HTTP Basic Auth for simplicity (same as Sidekiq).
  #
  # Why Basic Auth?
  # - Simple to set up (just username/password in config)
  # - Works with any deployment (no OAuth setup needed)
  # - Stateless (no session management)
  # - Secure enough for internal tools (over HTTPS)
  #
  # If you need more sophisticated auth (SSO, OAuth, role-based):
  # - Override `authenticate!` in your app
  # - Or use a Rack middleware before the engine
  #
  class ApplicationController < ActionController::Base
    # Protect from forgery with exception
    protect_from_forgery with: :exception

    # Authenticate before all actions
    before_action :authenticate!
    before_action :set_findbug_view_path

    # Set layout
    layout "findbug/application"

    # Helper methods
    helper_method :findbug_path

    private

    # HTTP Basic Authentication
    #
    # WHY BASIC AUTH?
    # ---------------
    # 1. Zero setup for users (no OAuth, no devise)
    # 2. Works everywhere (curl, browser, CI)
    # 3. Secure over HTTPS
    # 4. Same pattern as Sidekiq (users know it)
    #
    def authenticate!
      return true unless Findbug.config.web_enabled?

      authenticate_or_request_with_http_basic("Findbug") do |username, password|
        # Use secure comparison to prevent timing attacks
        secure_compare(username, Findbug.config.web_username) &&
          secure_compare(password, Findbug.config.web_password)
      end
    end

    # Secure string comparison (constant-time)
    #
    # WHY CONSTANT-TIME?
    # ------------------
    # Normal string comparison stops at the first different character.
    # An attacker could measure response times to guess characters one by one.
    # Constant-time comparison always takes the same time regardless of input.
    #
    def secure_compare(a, b)
      return false if a.nil? || b.nil?

      ActiveSupport::SecurityUtils.secure_compare(a.to_s, b.to_s)
    end

    # Helper to get the engine's mount path
    def findbug_path
      Findbug.config.web_path
    end

    # Add the gem's view path so templates can be found
    # This runs before each request to ensure the path is set
    def set_findbug_view_path
      return unless defined?(FINDBUG_GEM_ROOT)

      views_path = File.join(FINDBUG_GEM_ROOT, "app", "views")
      prepend_view_path(views_path) unless view_paths.include?(views_path)
    end

    # Handle ActiveRecord errors gracefully
    rescue_from ActiveRecord::RecordNotFound do |e|
      flash_error "Record not found"
      redirect_to findbug.root_path
    end

    # Safe flash helpers that work with API-only Rails apps
    def flash_success(message)
      flash[:success] = message if flash_available?
    end

    def flash_error(message)
      flash[:error] = message if flash_available?
    end

    def flash_available?
      respond_to?(:flash) && flash.respond_to?(:[]=)
    rescue NoMethodError
      false
    end
  end
end
