# frozen_string_literal: true

class CreateFindbugPerformanceEvents < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :findbug_performance_events do |t|
      # Transaction identification
      t.string :transaction_name, null: false
      t.string :transaction_type, default: "request"

      # Request info
      t.string :request_method
      t.string :request_path
      t.string :format
      t.integer :status

      # Timing (all in milliseconds)
      t.float :duration_ms, null: false
      t.float :db_time_ms, default: 0
      t.float :view_time_ms, default: 0

      # Query tracking
      t.integer :query_count, default: 0
      t.jsonb :slow_queries, default: []
      t.jsonb :n_plus_one_queries, default: []
      t.boolean :has_n_plus_one, default: false
      t.integer :view_count, default: 0

      # Context
      t.jsonb :context, default: {}

      # Metadata
      t.string :environment
      t.string :release_version
      t.datetime :captured_at

      t.timestamps
    end

    # Indexes for common queries (using short names to stay under 63 char limit)
    add_index :findbug_performance_events, :transaction_name, name: "idx_fb_perf_txn_name"
    add_index :findbug_performance_events, :transaction_type, name: "idx_fb_perf_txn_type"
    add_index :findbug_performance_events, :captured_at, name: "idx_fb_perf_captured_at"
    add_index :findbug_performance_events, :duration_ms, name: "idx_fb_perf_duration"
    add_index :findbug_performance_events, :has_n_plus_one, name: "idx_fb_perf_n_plus_one"
    add_index :findbug_performance_events, [:transaction_name, :captured_at], name: "idx_fb_perf_txn_captured"
  end
end
