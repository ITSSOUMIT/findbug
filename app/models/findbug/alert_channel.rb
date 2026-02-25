# frozen_string_literal: true

require_relative "../../../lib/findbug/alerts/channels/base"
require_relative "../../../lib/findbug/alerts/channels/email"
require_relative "../../../lib/findbug/alerts/channels/slack"
require_relative "../../../lib/findbug/alerts/channels/discord"
require_relative "../../../lib/findbug/alerts/channels/webhook"

module Findbug
  # AlertChannel stores alert channel configurations in the database.
  #
  # DATABASE SCHEMA
  # ===============
  #
  # This model expects a table created by the install generator:
  #
  #   create_table :findbug_alert_channels do |t|
  #     t.string :channel_type, null: false
  #     t.string :name, null: false
  #     t.boolean :enabled, default: false
  #     t.text :config_data
  #     t.timestamps
  #   end
  #
  # WHY DB INSTEAD OF INITIALIZER?
  # ==============================
  #
  # Storing alert config in the database lets users create, edit, and
  # manage alert channels from the dashboard UI without code changes
  # or redeployment.
  #
  # WHY TEXT + SERIALIZE INSTEAD OF JSONB?
  # ======================================
  #
  # ActiveRecord::Encryption works on text columns. We serialize the
  # config hash as JSON and encrypt the entire blob at rest, so webhook
  # URLs and tokens are never stored in plain text.
  #
  class AlertChannel < ActiveRecord::Base
    self.table_name = "findbug_alert_channels"

    # Channel types
    CHANNEL_TYPES = %w[email slack discord webhook].freeze

    # Check if Rails encryption is configured
    def self.encryption_available?
      return false unless defined?(ActiveRecord::Encryption)

      ActiveRecord::Encryption.config.primary_key.present?
    rescue StandardError
      false
    end

    # Serialize config as JSON
    serialize :config_data, coder: JSON

    # Encrypt config at rest if Rails encryption is configured
    encrypts :config_data if encryption_available?

    # Validations
    validates :name, presence: true
    validates :channel_type, presence: true, inclusion: { in: CHANNEL_TYPES }
    validate :validate_required_config

    # Scopes
    scope :enabled, -> { where(enabled: true) }
    scope :by_type, ->(type) { where(channel_type: type) }

    # Convenience accessor for config
    def config
      config_data || {}
    end

    def config=(value)
      self.config_data = value
    end

    # Returns the channel class for sending alerts
    #
    # Maps channel_type to the corresponding Alerts::Channels class.
    #
    def channel_class
      case channel_type
      when "email"   then Findbug::Alerts::Channels::Email
      when "slack"   then Findbug::Alerts::Channels::Slack
      when "discord" then Findbug::Alerts::Channels::Discord
      when "webhook" then Findbug::Alerts::Channels::Webhook
      end
    end

    # Human-readable channel type
    def display_type
      channel_type&.titleize
    end

    # Returns config with sensitive values masked for display
    #
    # Shows scheme + host for URLs, masks everything else.
    # Email recipients are shown in full (not sensitive).
    #
    def masked_config
      masked = {}

      case channel_type
      when "email"
        masked["Recipients"] = Array(config["recipients"]).join(", ").presence || "None"
        masked["From"] = config["from"] || "findbug@localhost"
      when "slack"
        masked["Webhook URL"] = mask_url(config["webhook_url"])
        masked["Channel"] = config["channel"] || "Default"
        masked["Username"] = config["username"] || "Findbug"
      when "discord"
        masked["Webhook URL"] = mask_url(config["webhook_url"])
        masked["Username"] = config["username"] || "Findbug"
      when "webhook"
        masked["URL"] = mask_url(config["url"])
        masked["Method"] = (config["method"] || "POST").upcase
        headers_count = (config["headers"] || {}).size
        masked["Custom Headers"] = "#{headers_count} configured" if headers_count > 0
      end

      masked
    end

    private

    # Mask a URL for safe display
    #
    # Shows scheme + host but masks the path (which typically contains
    # secret tokens in webhook URLs).
    #
    def mask_url(url)
      return "Not configured" if url.blank?

      uri = URI.parse(url)
      path = uri.path.to_s
      masked_path = path.length > 8 ? "#{path[0..7]}********" : "********"
      "#{uri.scheme}://#{uri.host}#{masked_path}"
    rescue URI::InvalidURIError
      "#{url[0..15]}********"
    end

    # Validate that required config fields are present for each channel type
    def validate_required_config
      return if config.blank? && !enabled?

      case channel_type
      when "email"
        if enabled? && Array(config["recipients"]).compact_blank.empty?
          errors.add(:base, "Email channel requires at least one recipient")
        end
      when "slack"
        if enabled? && config["webhook_url"].blank?
          errors.add(:base, "Slack channel requires a webhook URL")
        end
      when "discord"
        if enabled? && config["webhook_url"].blank?
          errors.add(:base, "Discord channel requires a webhook URL")
        end
      when "webhook"
        if enabled? && config["url"].blank?
          errors.add(:base, "Webhook channel requires a URL")
        end
      end
    end
  end
end
