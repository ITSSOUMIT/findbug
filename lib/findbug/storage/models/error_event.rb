# frozen_string_literal: true

module Findbug
  # ErrorEvent stores captured exceptions in the database.
  #
  # DATABASE SCHEMA
  # ===============
  #
  # This model expects a table created by the install generator:
  #
  #   create_table :findbug_error_events do |t|
  #     t.string :fingerprint, null: false
  #     t.string :exception_class, null: false
  #     t.text :message
  #     t.text :backtrace
  #     t.jsonb :context, default: {}
  #     t.jsonb :request_data, default: {}
  #     t.string :environment
  #     t.string :release_version
  #     t.string :severity, default: 'error'
  #     t.string :source
  #     t.boolean :handled, default: false
  #     t.integer :occurrence_count, default: 1
  #     t.datetime :first_seen_at
  #     t.datetime :last_seen_at
  #     t.string :status, default: 'unresolved'
  #     t.timestamps
  #   end
  #
  # WHY JSONB FOR CONTEXT?
  # ======================
  #
  # Context is semi-structured - different errors have different context.
  # JSONB (in PostgreSQL) or JSON (in other DBs) lets us store any shape
  # of data without schema migrations.
  #
  # For querying, we create GIN indexes on commonly queried paths.
  #
  class ErrorEvent < ActiveRecord::Base
    self.table_name = "findbug_error_events"

    # Statuses
    STATUS_UNRESOLVED = "unresolved"
    STATUS_RESOLVED = "resolved"
    STATUS_IGNORED = "ignored"

    # Severities
    SEVERITY_ERROR = "error"
    SEVERITY_WARNING = "warning"
    SEVERITY_INFO = "info"

    # Validations
    validates :fingerprint, presence: true
    validates :exception_class, presence: true
    validates :status, inclusion: { in: [STATUS_UNRESOLVED, STATUS_RESOLVED, STATUS_IGNORED] }
    validates :severity, inclusion: { in: [SEVERITY_ERROR, SEVERITY_WARNING, SEVERITY_INFO] }

    # Scopes
    scope :unresolved, -> { where(status: STATUS_UNRESOLVED) }
    scope :resolved, -> { where(status: STATUS_RESOLVED) }
    scope :ignored, -> { where(status: STATUS_IGNORED) }
    scope :errors, -> { where(severity: SEVERITY_ERROR) }
    scope :warnings, -> { where(severity: SEVERITY_WARNING) }
    scope :recent, -> { order(last_seen_at: :desc) }
    scope :by_occurrence, -> { order(occurrence_count: :desc) }

    # Time-based scopes
    scope :last_24_hours, -> { where("last_seen_at >= ?", 24.hours.ago) }
    scope :last_7_days, -> { where("last_seen_at >= ?", 7.days.ago) }
    scope :last_30_days, -> { where("last_seen_at >= ?", 30.days.ago) }

    # Find or create an error event, incrementing count if exists
    #
    # @param event_data [Hash] the error event data from Redis
    # @return [ErrorEvent] the created or updated error event
    #
    # UPSERT PATTERN
    # ==============
    #
    # We use "upsert" logic: if an error with this fingerprint exists,
    # we update it (increment count, update last_seen_at). Otherwise,
    # we create a new record.
    #
    # This groups similar errors together instead of creating thousands
    # of duplicate records.
    #
    def self.upsert_from_event(event_data)
      fingerprint = event_data[:fingerprint]

      # Use database-level locking to prevent race conditions
      transaction do
        existing = find_by(fingerprint: fingerprint)

        if existing
          # Update existing error
          existing.occurrence_count += 1
          existing.last_seen_at = Time.current

          # Update context with latest (might have new info)
          existing.context = merge_contexts(existing.context, event_data[:context])

          # If it was resolved but happened again, reopen it
          if existing.status == STATUS_RESOLVED
            existing.status = STATUS_UNRESOLVED
          end

          existing.save!
          existing
        else
          # Create new error
          create!(
            fingerprint: fingerprint,
            exception_class: event_data[:exception_class],
            message: event_data[:message],
            backtrace: serialize_backtrace(event_data[:backtrace]),
            context: event_data[:context] || {},
            request_data: event_data[:context]&.dig(:request) || {},
            environment: event_data[:environment],
            release_version: event_data[:release],
            severity: event_data[:severity] || SEVERITY_ERROR,
            source: event_data[:source],
            handled: event_data[:handled] || false,
            occurrence_count: 1,
            first_seen_at: Time.current,
            last_seen_at: Time.current,
            status: STATUS_UNRESOLVED
          )
        end
      end
    end

    # Mark this error as resolved
    def resolve!
      update!(status: STATUS_RESOLVED)
    end

    # Mark this error as ignored
    def ignore!
      update!(status: STATUS_IGNORED)
    end

    # Reopen a resolved/ignored error
    def reopen!
      update!(status: STATUS_UNRESOLVED)
    end

    # Get parsed backtrace as array
    def backtrace_lines
      return [] unless backtrace

      backtrace.is_a?(Array) ? backtrace : JSON.parse(backtrace)
    rescue JSON::ParserError
      backtrace.to_s.split("\n")
    end

    # Get user info from context
    def user
      context&.dig("user") || context&.dig(:user)
    end

    # Get request info from context
    def request
      context&.dig("request") || context&.dig(:request)
    end

    # Get breadcrumbs from context
    def breadcrumbs
      context&.dig("breadcrumbs") || context&.dig(:breadcrumbs) || []
    end

    # Get tags from context
    def tags
      context&.dig("tags") || context&.dig(:tags) || {}
    end

    # Short summary for lists
    def summary
      "#{exception_class}: #{message&.truncate(100)}"
    end

    private

    def self.merge_contexts(old_context, new_context)
      return new_context if old_context.blank?
      return old_context if new_context.blank?

      # Deep merge, preferring new values
      old_context.deep_merge(new_context)
    end

    def self.serialize_backtrace(backtrace)
      return nil unless backtrace

      backtrace.is_a?(Array) ? backtrace.to_json : backtrace
    end
  end
end
