# frozen_string_literal: true

module Findbug
  module Alerts
    module Channels
      # Email sends alert emails via ActionMailer.
      #
      # CONFIGURATION
      # =============
      #
      #   config.alerts do |alerts|
      #     alerts.email(
      #       enabled: true,
      #       recipients: ["dev-team@example.com", "oncall@example.com"],
      #       from: "findbug@example.com"  # optional
      #     )
      #   end
      #
      # REQUIREMENTS
      # ============
      #
      # ActionMailer must be configured in your Rails app.
      # The gem doesn't configure SMTP - it uses your app's mailer config.
      #
      class Email < Base
        def send_alert(error_event)
          recipients = config[:recipients]
          return if recipients.blank?

          # Use ActionMailer if available
          if defined?(ActionMailer::Base)
            FindbugMailer.error_alert(error_event, recipients).deliver_later
          else
            Findbug.logger.warn("[Findbug] ActionMailer not available for email alerts")
          end
        end
      end

      # Simple mailer for error alerts
      #
      # We define this inline because it's simple and self-contained.
      # Users can override by creating their own FindbugMailer.
      #
      class FindbugMailer < ActionMailer::Base
        default from: -> { Findbug.config.alerts.channel(:email)&.dig(:from) || "findbug@localhost" }

        def error_alert(error_event, recipients)
          @error = error_event
          @error_url = build_error_url(error_event)

          subject = "[#{Rails.env}] #{error_event.exception_class}: #{error_event.message.to_s.truncate(50)}"

          mail(
            to: recipients,
            subject: subject
          ) do |format|
            format.text { render plain: build_text_body(error_event) }
            format.html { render html: build_html_body(error_event).html_safe }
          end
        end

        private

        def build_text_body(error_event)
          <<~TEXT
            ERROR ALERT
            ===========

            Exception: #{error_event.exception_class}
            Message: #{error_event.message}
            Severity: #{error_event.severity.upcase}
            Environment: #{error_event.environment}

            Occurrences: #{error_event.occurrence_count}
            First seen: #{error_event.first_seen_at}
            Last seen: #{error_event.last_seen_at}

            #{@error_url ? "View in dashboard: #{@error_url}" : ""}

            BACKTRACE
            ---------
            #{error_event.backtrace_lines.first(10).join("\n")}

            CONTEXT
            -------
            #{format_context(error_event)}
          TEXT
        end

        def build_html_body(error_event)
          <<~HTML
            <!DOCTYPE html>
            <html>
            <head>
              <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
                .container { max-width: 600px; margin: 0 auto; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
                .header { background: #dc3545; color: white; padding: 20px; }
                .header h1 { margin: 0; font-size: 18px; }
                .content { padding: 20px; }
                .meta { color: #666; font-size: 14px; margin-bottom: 20px; }
                .section { margin-bottom: 20px; }
                .section h3 { margin: 0 0 10px 0; font-size: 14px; color: #333; border-bottom: 1px solid #eee; padding-bottom: 5px; }
                .backtrace { background: #f8f9fa; padding: 10px; font-family: monospace; font-size: 12px; overflow-x: auto; border-radius: 4px; }
                .btn { display: inline-block; padding: 10px 20px; background: #007bff; color: white; text-decoration: none; border-radius: 4px; }
                code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; font-size: 13px; }
              </style>
            </head>
            <body>
              <div class="container">
                <div class="header">
                  <h1>#{error_event.exception_class}</h1>
                </div>
                <div class="content">
                  <p><strong>#{h(error_event.message)}</strong></p>

                  <div class="meta">
                    <span>#{error_event.severity.upcase}</span> &bull;
                    <span>#{error_event.environment}</span> &bull;
                    <span>#{error_event.occurrence_count} occurrence(s)</span>
                  </div>

                  #{@error_url ? "<p><a href=\"#{@error_url}\" class=\"btn\">View in Dashboard</a></p>" : ""}

                  <div class="section">
                    <h3>Backtrace</h3>
                    <div class="backtrace">#{error_event.backtrace_lines.first(10).map { |l| h(l) }.join("<br>")}</div>
                  </div>

                  <div class="section">
                    <h3>Request Info</h3>
                    #{format_request_html(error_event)}
                  </div>
                </div>
              </div>
            </body>
            </html>
          HTML
        end

        def format_context(error_event)
          request = error_event.request
          return "No request context" unless request

          [
            "Method: #{request['method']}",
            "Path: #{request['path']}",
            "IP: #{request['ip']}",
            "User Agent: #{request['user_agent']}"
          ].join("\n")
        end

        def format_request_html(error_event)
          request = error_event.request
          return "<p>No request context</p>" unless request

          <<~HTML
            <p>
              <code>#{request['method']}</code> #{h(request['path'])}<br>
              IP: #{request['ip']}<br>
              User Agent: #{h(request['user_agent'].to_s.truncate(100))}
            </p>
          HTML
        end

        def build_error_url(error_event)
          base_url = ENV.fetch("FINDBUG_BASE_URL", nil)
          return nil unless base_url

          "#{base_url}#{Findbug.config.web_path}/errors/#{error_event.id}"
        end

        def h(text)
          ERB::Util.html_escape(text)
        end
      end
    end
  end
end
