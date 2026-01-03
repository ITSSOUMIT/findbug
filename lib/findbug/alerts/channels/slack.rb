# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Findbug
  module Alerts
    module Channels
      # Slack sends alerts via Slack incoming webhooks.
      #
      # CONFIGURATION
      # =============
      #
      #   config.alerts do |alerts|
      #     alerts.slack(
      #       enabled: true,
      #       webhook_url: ENV["SLACK_WEBHOOK_URL"],
      #       channel: "#errors",  # optional, overrides webhook default
      #       username: "Findbug", # optional
      #       icon_emoji: ":bug:"  # optional
      #     )
      #   end
      #
      # SETTING UP SLACK WEBHOOK
      # ========================
      #
      # 1. Go to https://api.slack.com/apps
      # 2. Create a new app (or use existing)
      # 3. Add "Incoming Webhooks" feature
      # 4. Create a webhook for your channel
      # 5. Copy the webhook URL
      #
      class Slack < Base
        def send_alert(error_event)
          webhook_url = config[:webhook_url]
          return if webhook_url.blank?

          payload = build_payload(error_event)
          post_to_webhook(webhook_url, payload)
        end

        private

        def build_payload(error_event)
          {
            channel: config[:channel],
            username: config[:username] || "Findbug",
            icon_emoji: config[:icon_emoji] || ":bug:",
            attachments: [build_attachment(error_event)]
          }.compact
        end

        def build_attachment(error_event)
          {
            color: severity_color(error_event.severity),
            title: "#{error_event.exception_class}",
            title_link: error_url(error_event),
            text: error_event.message.to_s.truncate(500),
            fields: build_fields(error_event),
            footer: "Findbug | #{error_event.environment}",
            ts: error_event.last_seen_at.to_i
          }.compact
        end

        def build_fields(error_event)
          fields = []

          fields << {
            title: "Occurrences",
            value: error_event.occurrence_count.to_s,
            short: true
          }

          fields << {
            title: "Severity",
            value: error_event.severity.upcase,
            short: true
          }

          if error_event.release_version
            fields << {
              title: "Release",
              value: error_event.release_version.to_s.truncate(20),
              short: true
            }
          end

          # Add first backtrace line
          if error_event.backtrace_lines.any?
            fields << {
              title: "Location",
              value: "`#{error_event.backtrace_lines.first.truncate(80)}`",
              short: false
            }
          end

          # Add user info if present
          if error_event.user
            user_info = [
              error_event.user["email"],
              error_event.user["id"] ? "ID: #{error_event.user['id']}" : nil
            ].compact.join(" | ")

            fields << {
              title: "User",
              value: user_info,
              short: false
            } if user_info.present?
          end

          fields
        end

        def severity_color(severity)
          case severity
          when "error" then "#dc3545"   # Red
          when "warning" then "#ffc107" # Yellow
          when "info" then "#17a2b8"    # Blue
          else "#6c757d"                # Gray
          end
        end

        def post_to_webhook(webhook_url, payload)
          uri = URI.parse(webhook_url)

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 5
          http.read_timeout = 5

          request = Net::HTTP::Post.new(uri.path)
          request["Content-Type"] = "application/json"
          request.body = payload.to_json

          response = http.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            Findbug.logger.error(
              "[Findbug] Slack webhook failed: #{response.code} #{response.body}"
            )
          end
        rescue StandardError => e
          Findbug.logger.error("[Findbug] Slack alert failed: #{e.message}")
        end
      end
    end
  end
end
