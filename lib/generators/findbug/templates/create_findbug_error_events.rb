# frozen_string_literal: true

class CreateFindbugErrorEvents < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :findbug_error_events do |t|
      # Error identification
      t.string :fingerprint, null: false
      t.string :exception_class, null: false
      t.text :message
      t.text :backtrace

      # Context (stored as JSON for flexibility)
      t.jsonb :context, default: {}
      t.jsonb :request_data, default: {}

      # Metadata
      t.string :environment
      t.string :release_version
      t.string :severity, default: "error"
      t.string :source
      t.boolean :handled, default: false

      # Aggregation
      t.integer :occurrence_count, default: 1
      t.datetime :first_seen_at
      t.datetime :last_seen_at

      # Status tracking
      t.string :status, default: "unresolved"

      t.timestamps
    end

    # Indexes for common queries
    add_index :findbug_error_events, :fingerprint
    add_index :findbug_error_events, :exception_class
    add_index :findbug_error_events, :status
    add_index :findbug_error_events, :severity
    add_index :findbug_error_events, :last_seen_at
    add_index :findbug_error_events, :created_at
    add_index :findbug_error_events, [:status, :last_seen_at]
    add_index :findbug_error_events, [:exception_class, :created_at]
  end
end
