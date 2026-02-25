# frozen_string_literal: true

require "ostruct"

module Findbug
  # AlertsController manages alert channel configuration via the dashboard.
  #
  # Users can create, edit, enable/disable, delete, and test alert channels
  # directly from the UI instead of editing the Rails initializer.
  #
  class AlertsController < ApplicationController
    before_action :set_alert_channel, only: [:edit, :update, :destroy, :toggle, :test]

    # GET /findbug/alerts
    #
    # List all configured alert channels.
    #
    def index
      @channels = Findbug::AlertChannel.order(created_at: :asc)
      @enabled_count = @channels.count(&:enabled?)

      render template: "findbug/alerts/index", layout: "findbug/application"
    end

    # GET /findbug/alerts/new
    #
    # Form to create a new alert channel.
    #
    def new
      @channel = Findbug::AlertChannel.new
      render template: "findbug/alerts/new", layout: "findbug/application"
    end

    # POST /findbug/alerts
    #
    # Save a new alert channel.
    #
    def create
      @channel = Findbug::AlertChannel.new(channel_params)
      @channel.config = build_config_from_params

      if @channel.save
        flash_success "#{@channel.display_type} alert channel created"
        redirect_to findbug.alerts_path
      else
        flash_error @channel.errors.full_messages.join(", ")
        render template: "findbug/alerts/new", layout: "findbug/application", status: :unprocessable_entity
      end
    end

    # GET /findbug/alerts/:id/edit
    #
    # Form to edit an existing alert channel.
    #
    def edit
      render template: "findbug/alerts/edit", layout: "findbug/application"
    end

    # PATCH /findbug/alerts/:id
    #
    # Update an existing alert channel.
    #
    def update
      @channel.assign_attributes(channel_params)
      @channel.config = build_config_from_params

      if @channel.save
        flash_success "#{@channel.display_type} alert channel updated"
        redirect_to findbug.alerts_path
      else
        flash_error @channel.errors.full_messages.join(", ")
        render template: "findbug/alerts/edit", layout: "findbug/application", status: :unprocessable_entity
      end
    end

    # DELETE /findbug/alerts/:id
    #
    # Delete an alert channel.
    #
    def destroy
      name = @channel.name
      @channel.destroy
      flash_success "Alert channel \"#{name}\" deleted"
      redirect_to findbug.alerts_path
    end

    # POST /findbug/alerts/:id/toggle
    #
    # Toggle enable/disable for an alert channel.
    #
    def toggle
      @channel.enabled = !@channel.enabled?

      if @channel.save
        status = @channel.enabled? ? "enabled" : "disabled"
        flash_success "#{@channel.name} #{status}"
      else
        flash_error @channel.errors.full_messages.join(", ")
      end

      redirect_to findbug.alerts_path
    end

    # POST /findbug/alerts/:id/test
    #
    # Send a test alert to this channel.
    #
    # Creates a synthetic error event (not persisted to DB) and sends it
    # directly to the channel, bypassing throttling.
    #
    def test
      unless @channel.enabled?
        flash_error "Cannot test a disabled channel. Enable it first."
        redirect_to findbug.alerts_path and return
      end

      error_event = build_test_error_event
      channel_instance = @channel.channel_class.new(@channel.config.symbolize_keys)

      begin
        channel_instance.send_alert(error_event)
        flash_success "Test alert sent to #{@channel.name} successfully!"
      rescue StandardError => e
        flash_error "Failed to send test alert: #{e.message}"
      end

      redirect_to findbug.alerts_path
    end

    private

    def set_alert_channel
      @channel = Findbug::AlertChannel.find(params[:id])
    end

    def channel_params
      params.require(:alert_channel).permit(:name, :channel_type, :enabled)
    end

    # Build the config hash from channel-type-specific form params
    #
    # Each channel type has different fields. We extract them from
    # params[:config] and build a clean hash.
    #
    def build_config_from_params
      config_params = params[:config] || {}
      channel_type = params.dig(:alert_channel, :channel_type) || @channel&.channel_type

      case channel_type
      when "email"
        recipients = (config_params[:recipients] || "").split(/[\n,]/).map(&:strip).compact_blank
        {
          "recipients" => recipients,
          "from" => config_params[:from].presence
        }.compact
      when "slack"
        {
          "webhook_url" => config_params[:webhook_url],
          "channel" => config_params[:channel].presence,
          "username" => config_params[:username].presence,
          "icon_emoji" => config_params[:icon_emoji].presence
        }.compact
      when "discord"
        {
          "webhook_url" => config_params[:webhook_url],
          "username" => config_params[:username].presence,
          "avatar_url" => config_params[:avatar_url].presence
        }.compact
      when "webhook"
        headers = parse_headers(config_params[:headers])
        {
          "url" => config_params[:url],
          "method" => config_params[:method].presence || "POST",
          "headers" => headers.presence
        }.compact
      else
        {}
      end
    end

    # Parse headers from textarea format ("Key: Value" per line) into a hash
    def parse_headers(raw)
      return {} if raw.blank?

      raw.split("\n").each_with_object({}) do |line, hash|
        key, value = line.split(":", 2).map(&:strip)
        hash[key] = value if key.present? && value.present?
      end
    end

    # Build a synthetic error event for testing alerts
    #
    # Uses OpenStruct to duck-type ErrorEvent without touching the database.
    # Includes all attributes that channel implementations access.
    #
    def build_test_error_event
      now = Time.current

      OpenStruct.new(
        id: 0,
        fingerprint: "findbug-test-alert-#{now.to_i}",
        exception_class: "Findbug::TestAlert",
        message: "This is a test alert from the Findbug dashboard. If you see this, your alert channel is working correctly!",
        severity: "error",
        status: "unresolved",
        handled: false,
        occurrence_count: 1,
        first_seen_at: now,
        last_seen_at: now,
        environment: Findbug.config.environment || "production",
        release_version: Findbug::VERSION,
        backtrace_lines: [
          "app/controllers/findbug/alerts_controller.rb:42:in `test'",
          "lib/findbug/alerts/dispatcher.rb:57:in `send_alerts'",
          "lib/findbug/alerts/channels/base.rb:34:in `send_alert'"
        ],
        context: {},
        user: nil,
        request: { "method" => "POST", "path" => "/findbug/alerts/test" },
        tags: { "source" => "test_alert" }
      )
    end
  end
end
