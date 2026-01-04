# frozen_string_literal: true

require "rails/engine"

# Calculate the gem root path once at load time
# __dir__ is lib/findbug, so we go up two levels to get the gem root
FINDBUG_GEM_ROOT = File.expand_path("../..", __dir__)

# Require controllers (needed for routing)
require_relative "../../app/controllers/findbug/application_controller"
require_relative "../../app/controllers/findbug/dashboard_controller"
require_relative "../../app/controllers/findbug/errors_controller"
require_relative "../../app/controllers/findbug/performance_controller"

module Findbug
  # Engine is the main Rails integration point for Findbug.
  #
  # WHAT IS A RAILS ENGINE?
  # =======================
  #
  # An engine is like a mini Rails app that can be mounted inside another app.
  # It has its own:
  # - Controllers
  # - Models
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
  #   mount Findbug::Engine => "/my-findbug"
  #
  # ISOLATION
  # =========
  #
  # We use `isolate_namespace` to prevent our routes/helpers from conflicting
  # with the host app. All our routes are prefixed with `findbug_`.
  #
  class Engine < ::Rails::Engine
    # Isolate our namespace to avoid conflicts with host app
    isolate_namespace Findbug

    # Engine name for route helpers (findbug.errors_path, etc.)
    engine_name "findbug"

    # Set the root path for the engine to the gem's root directory
    # This tells Rails where to find app/controllers, app/models, app/views, etc.
    def self.root
      @root ||= Pathname.new(FINDBUG_GEM_ROOT)
    end

    # Configure the engine
    config.findbug = ActiveSupport::OrderedOptions.new

    # Add our view paths to ActionController
    initializer "findbug.add_view_paths" do |app|
      views_path = File.join(FINDBUG_GEM_ROOT, "app", "views")
      ActiveSupport.on_load(:action_controller) do
        prepend_view_path views_path
      end
    end

    # NOTE: We intentionally do NOT add session/flash middleware here.
    # Adding middleware to API-mode apps would change their behavior
    # (e.g., showing HTML error pages instead of JSON).
    # The layout handles missing flash gracefully with a rescue block.
  end
end

# Define routes for the engine
Findbug::Engine.routes.draw do
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
