# frozen_string_literal: true

module Findbug
  module Processing
    # DataScrubber removes sensitive data from captured events.
    #
    # WHY SCRUBBING IS CRITICAL
    # =========================
    #
    # Error data often contains sensitive information:
    # - User passwords (in form params)
    # - API keys (in headers)
    # - Credit card numbers (in payment flows)
    # - Personal data (in user context)
    #
    # Even though Findbug is self-hosted, you don't want this data:
    # 1. Stored in your database
    # 2. Visible in the dashboard
    # 3. In logs or backups
    # 4. Accessible to developers who shouldn't see it
    #
    # SCRUBBING STRATEGY
    # ==================
    #
    # We replace sensitive values with "[FILTERED]" rather than removing them.
    # This way you can see that the field existed (helpful for debugging)
    # without exposing the actual value.
    #
    # WHAT WE SCRUB
    # =============
    #
    # 1. Known field names (password, api_key, etc.)
    # 2. Credit card patterns (16 digits)
    # 3. SSN patterns (XXX-XX-XXXX)
    # 4. Sensitive headers (Authorization, Cookie)
    # 5. Custom fields from configuration
    #
    class DataScrubber
      FILTERED = "[FILTERED]"

      # Credit card patterns (Visa, MasterCard, Amex, etc.)
      CREDIT_CARD_PATTERN = /\b(?:\d{4}[-\s]?){3}\d{4}\b/

      # SSN pattern
      SSN_PATTERN = /\b\d{3}[-\s]?\d{2}[-\s]?\d{4}\b/

      # Bearer token in text
      BEARER_TOKEN_PATTERN = /Bearer\s+[A-Za-z0-9\-_.~+\/]+=*/i

      # API key-like patterns (long alphanumeric strings)
      API_KEY_PATTERN = /\b[A-Za-z0-9]{32,}\b/

      class << self
        # Scrub an entire event hash
        #
        # @param event [Hash] the event data to scrub
        # @return [Hash] scrubbed event data
        #
        def scrub(event)
          deep_scrub(event)
        end

        # Scrub a string value for patterns
        #
        # @param value [String] the string to scrub
        # @return [String] scrubbed string
        #
        def scrub_string(value)
          return value unless value.is_a?(String)

          value = value.dup

          # Scrub credit card numbers
          value.gsub!(CREDIT_CARD_PATTERN, FILTERED)

          # Scrub SSN
          value.gsub!(SSN_PATTERN, FILTERED)

          # Scrub Bearer tokens
          value.gsub!(BEARER_TOKEN_PATTERN, "Bearer #{FILTERED}")

          # Scrub potential API keys (but not in backtraces)
          # Only scrub in certain contexts to avoid false positives
          # value.gsub!(API_KEY_PATTERN, FILTERED)

          value
        end

        private

        def deep_scrub(obj, path = [])
          case obj
          when Hash
            # Preserve original key type (symbol or string)
            obj.each_with_object({}) do |(key, value), result|
              result[key] = if sensitive_key?(key)
                              FILTERED
                            else
                              deep_scrub(value, path + [key])
                            end
            end
          when Array
            obj.map.with_index { |item, i| deep_scrub(item, path + [i]) }
          when String
            scrub_string(obj)
          else
            obj
          end
        end

        def sensitive_key?(key)
          key_s = key.to_s.downcase

          # Check against configured scrub fields
          scrub_fields.any? do |field|
            key_s.include?(field.downcase)
          end
        end

        def scrub_fields
          @scrub_fields ||= build_scrub_fields
        end

        def build_scrub_fields
          default_fields = %w[
            password
            passwd
            secret
            token
            api_key
            apikey
            access_key
            accesskey
            private_key
            privatekey
            credit_card
            creditcard
            card_number
            cardnumber
            cvv
            cvc
            ssn
            social_security
            authorization
            auth
            bearer
            cookie
            session
            csrf
          ]

          # Merge with user-configured fields
          (default_fields + Findbug.config.scrub_fields.map(&:to_s)).uniq
        end

        # Reset cached fields (for testing or config changes)
        def reset!
          @scrub_fields = nil
        end
      end
    end
  end
end
