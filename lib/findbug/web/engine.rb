# frozen_string_literal: true

require "rails/engine"

# Require models
require_relative "../storage/models/error_event"
require_relative "../storage/models/performance_event"

# Require storage
require_relative "../storage/redis_buffer"
require_relative "../storage/connection_pool"

# Require all controllers
require_relative "controllers/application_controller"
require_relative "controllers/dashboard_controller"
require_relative "controllers/errors_controller"
require_relative "controllers/performance_controller"

module Findbug
  module Web
    # Engine is a mountable Rails engine that provides the Findbug dashboard.
    #
    # WHAT IS A RAILS ENGINE?
    # =======================
    #
    # An engine is like a mini Rails app that can be mounted inside another app.
    # It has its own:
    # - Controllers
    # - Views
    # - Routes
    # - Assets
    #
    # But it shares the host app's:
    # - Database connection
    # - Session
    # - Application configuration
    #
    # This is how gems like Sidekiq, Resque, and Devise provide web UIs.
    #
    # MOUNTING THE ENGINE
    # ===================
    #
    # The Railtie automatically mounts this engine at config.web_path (default "/findbug").
    #
    # Users can also manually mount:
    #
    #   # config/routes.rb
    #   mount Findbug::Web::Engine => "/my-findbug"
    #
    # ISOLATION
    # =========
    #
    # We use `isolate_namespace` to prevent our routes/helpers from conflicting
    # with the host app. All our routes are prefixed with `findbug_`.
    #
    class Engine < ::Rails::Engine
      # Isolate our namespace to avoid conflicts
      isolate_namespace Findbug::Web

      # Set the root path for the engine to the gem's root
      # This tells Rails where to find app/views, app/assets, etc.
      def self.root
        @root ||= Pathname.new(File.expand_path("../../..", __dir__))
      end

      # Set the root path for the engine
      engine_name "findbug"

      # Configure the engine
      config.findbug = ActiveSupport::OrderedOptions.new

      # NOTE: We intentionally do NOT add session/flash middleware here.
      # Adding middleware to API-mode apps would change their behavior
      # (e.g., showing HTML error pages instead of JSON).
      # The layout handles missing flash gracefully with a rescue block.

      # Load routes
      initializer "findbug.routes" do |app|
        # Routes are defined inline below
      end

      # Set up middleware for basic auth
      initializer "findbug.authentication" do |app|
        # Authentication is handled in ApplicationController
      end
    end

    # Define routes for the engine
    Engine.routes.draw do
      # Dashboard (root)
      root to: "dashboard#index"

      # Errors
      resources :errors, only: [:index, :show] do
        member do
          post :resolve
          post :ignore
          post :reopen
        end
      end

      # Performance
      resources :performance, only: [:index, :show]

      # Health check (useful for monitoring)
      get "health", to: "dashboard#health"

      # Stats API (for AJAX updates)
      get "stats", to: "dashboard#stats"
    end
  end
end
