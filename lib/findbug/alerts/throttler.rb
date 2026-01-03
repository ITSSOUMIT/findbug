# frozen_string_literal: true

module Findbug
  module Alerts
    # Throttler prevents alert spam by limiting how often we alert for the same error.
    #
    # THE PROBLEM
    # ===========
    #
    # Without throttling:
    # - 1000 users hit the same bug
    # - 1000 Slack messages
    # - Your team mutes the channel
    # - You miss the NEXT important error
    #
    # With throttling:
    # - First occurrence: Alert sent
    # - Next 999 in 5 minutes: Throttled
    # - 5 minutes later, if still happening: Another alert
    #
    # IMPLEMENTATION
    # ==============
    #
    # We use Redis to store "last alerted at" timestamps:
    #
    #   Key: findbug:alert:throttle:{fingerprint}
    #   Value: ISO8601 timestamp
    #   TTL: throttle_period
    #
    # If the key exists and isn't expired, we're throttled.
    # Simple and fast.
    #
    class Throttler
      THROTTLE_KEY_PREFIX = "findbug:alert:throttle:"

      class << self
        # Check if an alert is currently throttled
        #
        # @param fingerprint [String] error fingerprint
        # @return [Boolean] true if throttled
        #
        def throttled?(fingerprint)
          key = throttle_key(fingerprint)

          Storage::ConnectionPool.with do |redis|
            redis.exists?(key)
          end
        rescue StandardError => e
          Findbug.logger.debug("[Findbug] Throttle check failed: #{e.message}")
          false # If we can't check, allow the alert
        end

        # Record that we sent an alert (starts throttle period)
        #
        # @param fingerprint [String] error fingerprint
        #
        def record(fingerprint)
          key = throttle_key(fingerprint)
          ttl = throttle_period

          Storage::ConnectionPool.with do |redis|
            redis.setex(key, ttl, Time.now.utc.iso8601)
          end
        rescue StandardError => e
          Findbug.logger.debug("[Findbug] Throttle record failed: #{e.message}")
        end

        # Clear throttle for a specific error (e.g., when error is resolved)
        #
        # @param fingerprint [String] error fingerprint
        #
        def clear(fingerprint)
          key = throttle_key(fingerprint)

          Storage::ConnectionPool.with do |redis|
            redis.del(key)
          end
        rescue StandardError
          # Ignore errors during cleanup
        end

        # Get remaining throttle time
        #
        # @param fingerprint [String] error fingerprint
        # @return [Integer, nil] seconds remaining, or nil if not throttled
        #
        def remaining_seconds(fingerprint)
          key = throttle_key(fingerprint)

          Storage::ConnectionPool.with do |redis|
            ttl = redis.ttl(key)
            ttl.positive? ? ttl : nil
          end
        rescue StandardError
          nil
        end

        private

        def throttle_key(fingerprint)
          "#{THROTTLE_KEY_PREFIX}#{fingerprint}"
        end

        def throttle_period
          Findbug.config.alerts.throttle_period
        end
      end
    end
  end
end
