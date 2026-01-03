# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Findbug
  module Alerts
    module Channels
      # Webhook sends alerts to a generic HTTP endpoint.
      #
      # CONFIGURATION
      # =============
      #
      #   config.alerts do |alerts|
      #     alerts.webhook(
      #       enabled: true,
      #       url: "https://your-service.com/findbug-webhook",
      #       headers: {
      #         "Authorization" => "Bearer #{ENV['WEBHOOK_TOKEN']}",
      #         "X-Custom-Header" => "value"
      #       },
      #       method: "POST"  # optional, defaults to POST
      #     )
      #   end
      #
      # PAYLOAD FORMAT
      # ==============
      #
      # The webhook receives a JSON payload with the full error event:
      #
      #   {
      #     "event_type": "error",
      #     "error": {
      #       "id": 123,
      #       "exception_class": "NoMethodError",
      #       "message": "undefined method...",
      #       "severity": "error",
      #       "occurrence_count": 5,
      #       "first_seen_at": "2024-01-01T00:00:00Z",
      #       "last_seen_at": "2024-01-01T01:00:00Z",
      #       "environment": "production",
      #       "release": "abc123",
      #       "backtrace": [...],
      #       "context": {...}
      #     }
      #   }
      #
      # USE CASES
      # =========
      #
      # - Custom alerting systems
      # - Integration with internal tools
      # - PagerDuty/OpsGenie (if no native integration)
      # - Log aggregation services
      # - Custom notification services
      #
      class Webhook < Base
        def send_alert(error_event)
          url = config[:url]
          return if url.blank?

          payload = build_payload(error_event)
          post_to_webhook(url, payload)
        end

        private

        def build_payload(error_event)
          {
            event_type: "error",
            timestamp: Time.now.utc.iso8601,
            findbug_version: Findbug::VERSION,
            error: {
              id: error_event.id,
              fingerprint: error_event.fingerprint,
              exception_class: error_event.exception_class,
              message: error_event.message,
              severity: error_event.severity,
              status: error_event.status,
              handled: error_event.handled,
              occurrence_count: error_event.occurrence_count,
              first_seen_at: error_event.first_seen_at&.iso8601,
              last_seen_at: error_event.last_seen_at&.iso8601,
              environment: error_event.environment,
              release: error_event.release_version,
              backtrace: error_event.backtrace_lines,
              context: error_event.context,
              user: error_event.user,
              request: error_event.request,
              tags: error_event.tags,
              url: error_url(error_event)
            }
          }
        end

        def post_to_webhook(url, payload)
          uri = URI.parse(url)

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 5
          http.read_timeout = 10

          method = config[:method]&.upcase || "POST"
          request = build_request(method, uri, payload)

          # Add custom headers
          (config[:headers] || {}).each do |key, value|
            request[key] = value
          end

          response = http.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            Findbug.logger.error(
              "[Findbug] Webhook failed: #{response.code} #{response.body.to_s.truncate(200)}"
            )
          end
        rescue StandardError => e
          Findbug.logger.error("[Findbug] Webhook alert failed: #{e.message}")
        end

        def build_request(method, uri, payload)
          case method
          when "POST"
            request = Net::HTTP::Post.new(uri.request_uri)
            request["Content-Type"] = "application/json"
            request.body = payload.to_json
            request
          when "PUT"
            request = Net::HTTP::Put.new(uri.request_uri)
            request["Content-Type"] = "application/json"
            request.body = payload.to_json
            request
          else
            raise ArgumentError, "Unsupported HTTP method: #{method}"
          end
        end
      end
    end
  end
end
