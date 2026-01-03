# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Findbug
  module Alerts
    module Channels
      # Discord sends alerts via Discord webhooks.
      #
      # CONFIGURATION
      # =============
      #
      #   config.alerts do |alerts|
      #     alerts.discord(
      #       enabled: true,
      #       webhook_url: ENV["DISCORD_WEBHOOK_URL"],
      #       username: "Findbug",  # optional
      #       avatar_url: "https://..." # optional
      #     )
      #   end
      #
      # SETTING UP DISCORD WEBHOOK
      # ==========================
      #
      # 1. Go to your Discord server settings
      # 2. Navigate to Integrations > Webhooks
      # 3. Create a new webhook
      # 4. Copy the webhook URL
      #
      # Discord webhooks are similar to Slack but use a different payload format.
      #
      class Discord < Base
        def send_alert(error_event)
          webhook_url = config[:webhook_url]
          return if webhook_url.blank?

          payload = build_payload(error_event)
          post_to_webhook(webhook_url, payload)
        end

        private

        def build_payload(error_event)
          {
            username: config[:username] || "Findbug",
            avatar_url: config[:avatar_url],
            embeds: [build_embed(error_event)]
          }.compact
        end

        def build_embed(error_event)
          embed = {
            title: error_event.exception_class.truncate(256),
            description: error_event.message.to_s.truncate(2048),
            color: severity_color_decimal(error_event.severity),
            url: error_url(error_event),
            fields: build_fields(error_event),
            footer: {
              text: "Findbug | #{error_event.environment}"
            },
            timestamp: error_event.last_seen_at.iso8601
          }

          embed.compact
        end

        def build_fields(error_event)
          fields = []

          fields << {
            name: "Severity",
            value: error_event.severity.upcase,
            inline: true
          }

          fields << {
            name: "Occurrences",
            value: error_event.occurrence_count.to_s,
            inline: true
          }

          if error_event.release_version
            fields << {
              name: "Release",
              value: error_event.release_version.to_s.truncate(100),
              inline: true
            }
          end

          # Add backtrace (limited to Discord field limits)
          if error_event.backtrace_lines.any?
            backtrace = error_event.backtrace_lines.first(5).join("\n")
            fields << {
              name: "Backtrace",
              value: "```\n#{backtrace.truncate(1000)}\n```",
              inline: false
            }
          end

          # Add user info
          if error_event.user
            user_info = [
              error_event.user["email"],
              error_event.user["id"] ? "ID: #{error_event.user['id']}" : nil
            ].compact.join("\n")

            fields << {
              name: "User",
              value: user_info,
              inline: false
            } if user_info.present?
          end

          fields
        end

        # Discord uses decimal color values
        def severity_color_decimal(severity)
          case severity
          when "error" then 14_423_100   # #dc3545 in decimal
          when "warning" then 16_761_095 # #ffc107
          when "info" then 1_548_984     # #17a2b8
          else 7_107_965                 # #6c757d
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

          # Discord returns 204 No Content on success
          unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPNoContent)
            Findbug.logger.error(
              "[Findbug] Discord webhook failed: #{response.code} #{response.body}"
            )
          end
        rescue StandardError => e
          Findbug.logger.error("[Findbug] Discord alert failed: #{e.message}")
        end
      end
    end
  end
end
