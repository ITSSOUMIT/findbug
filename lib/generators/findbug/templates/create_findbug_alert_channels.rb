# frozen_string_literal: true

class CreateFindbugAlertChannels < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :findbug_alert_channels do |t|
      # Channel identification
      t.string :channel_type, null: false  # email, slack, discord, webhook
      t.string :name, null: false          # user-friendly label

      # Status
      t.boolean :enabled, default: false

      # Configuration (JSON-serialized, encrypted at rest)
      # Using text instead of jsonb so Rails encryption can work on it
      t.text :config_data

      t.timestamps
    end

    # Indexes for common queries
    add_index :findbug_alert_channels, :channel_type
    add_index :findbug_alert_channels, :enabled
  end
end
