# frozen_string_literal: true

module Findbug
  # ErrorsController handles error listing and detail views.
  #
  class ErrorsController < ApplicationController
    before_action :set_error, only: [:show, :resolve, :ignore, :reopen]

    # GET /findbug/errors
    #
    # List all errors with filtering.
    #
    def index
      @errors = Findbug::ErrorEvent.all

      # Apply filters
      @errors = apply_filters(@errors)

      # Pagination
      @page = (params[:page] || 1).to_i
      @per_page = 25
      @total_count = @errors.count
      @errors = @errors.offset((@page - 1) * @per_page).limit(@per_page)

      render template: "findbug/errors/index", layout: "findbug/application"
    end

    # GET /findbug/errors/:id
    #
    # Show error details.
    #
    def show
      @similar_errors = Findbug::ErrorEvent.where(exception_class: @error.exception_class)
                                  .where.not(id: @error.id)
                                  .recent
                                  .limit(5)

      render template: "findbug/errors/show", layout: "findbug/application"
    end

    # POST /findbug/errors/:id/resolve
    #
    # Mark error as resolved.
    #
    def resolve
      @error.resolve!
      flash_success "Error marked as resolved"
      redirect_back(fallback_location: findbug.errors_path)
    end

    # POST /findbug/errors/:id/ignore
    #
    # Mark error as ignored.
    #
    def ignore
      @error.ignore!
      flash_success "Error marked as ignored"
      redirect_back(fallback_location: findbug.errors_path)
    end

    # POST /findbug/errors/:id/reopen
    #
    # Reopen a resolved/ignored error.
    #
    def reopen
      @error.reopen!
      flash_success "Error reopened"
      redirect_back(fallback_location: findbug.errors_path)
    end

    private

    def set_error
      @error = Findbug::ErrorEvent.find(params[:id])
    end

    def apply_filters(scope)
      # Status filter
      # Note: empty string means "All Statuses" was selected
      if params[:status].present?
        scope = scope.where(status: params[:status])
      elsif !params.key?(:status)
        # Default to unresolved only on initial page load (no filter submitted)
        scope = scope.unresolved
      end
      # If params[:status] is "" (All Statuses), don't filter by status

      # Severity filter
      if params[:severity].present?
        scope = scope.where(severity: params[:severity])
      end

      # Search filter
      if params[:search].present?
        search = "%#{params[:search]}%"
        scope = scope.where(
          "exception_class ILIKE :search OR message ILIKE :search",
          search: search
        )
      end

      # Date range filter
      if params[:since].present?
        since = parse_since(params[:since])
        scope = scope.where("last_seen_at >= ?", since)
      end

      # Sort
      case params[:sort]
      when "oldest"
        scope.order(last_seen_at: :asc)
      when "occurrences"
        scope.order(occurrence_count: :desc)
      else
        scope.recent # Default: most recent
      end
    end

    def parse_since(value)
      case value
      when "1h" then 1.hour.ago
      when "24h" then 24.hours.ago
      when "7d" then 7.days.ago
      when "30d" then 30.days.ago
      else 24.hours.ago
      end
    end
  end
end
