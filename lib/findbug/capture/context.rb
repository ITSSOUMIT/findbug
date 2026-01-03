# frozen_string_literal: true

module Findbug
  module Capture
    # Context stores request-scoped data that gets attached to errors.
    #
    # THREAD-LOCAL STORAGE
    # ====================
    #
    # In a multi-threaded server like Puma, multiple requests run concurrently.
    # Each request needs its OWN context - we can't share a global variable
    # or Request A's user would appear on Request B's errors!
    #
    # Solution: Thread.current[:key] - a hash specific to each thread.
    #
    #   Thread 1 (Request A):
    #     Context.set_user(id: 1)
    #     # Thread.current[:findbug_context] = { user: { id: 1 } }
    #
    #   Thread 2 (Request B):
    #     Context.set_user(id: 2)
    #     # Thread.current[:findbug_context] = { user: { id: 2 } }
    #
    #   Thread 1: Context.current[:user] → { id: 1 }  ✓ Correct!
    #   Thread 2: Context.current[:user] → { id: 2 }  ✓ Correct!
    #
    # WHAT GETS STORED?
    # =================
    #
    # 1. User - who was affected
    # 2. Tags - short key-value pairs for filtering
    # 3. Extra - arbitrary data about the request
    # 4. Breadcrumbs - trail of events before the error
    # 5. Request - HTTP request details (auto-captured)
    #
    class Context
      THREAD_KEY = :findbug_context
      MAX_BREADCRUMBS = 50

      class << self
        # Get the current context hash
        #
        # @return [Hash] the current thread's context
        #
        def current
          Thread.current[THREAD_KEY] ||= default_context
        end

        # Clear the context (call between requests)
        #
        # This MUST be called after each request to prevent context leaking.
        # The Railtie sets this up via after_action.
        #
        def clear!
          Thread.current[THREAD_KEY] = nil
        end

        # Set user information
        #
        # @param user_data [Hash] user attributes (id, email, username, etc.)
        #
        # @example
        #   Context.set_user(id: 123, email: "user@example.com")
        #
        def set_user(user_data)
          current[:user] = scrub_user_data(user_data)
        end

        # Get current user
        #
        # @return [Hash, nil] the current user data
        #
        def user
          current[:user]
        end

        # Add a tag
        #
        # Tags are short key-value pairs optimized for filtering.
        # Unlike extra data, tags are indexed and searchable.
        #
        # @param key [String, Symbol] tag name
        # @param value [String, Numeric, Boolean] tag value
        #
        # @example
        #   Context.add_tag(:environment, "production")
        #   Context.add_tag(:plan, "enterprise")
        #
        def add_tag(key, value)
          current[:tags][key.to_sym] = value
        end

        # Get all tags
        #
        # @return [Hash] current tags
        #
        def tags
          current[:tags]
        end

        # Merge extra data into context
        #
        # Extra data is arbitrary key-value pairs that provide more detail.
        # Use this for non-indexed, detailed information.
        #
        # @param data [Hash] data to merge
        #
        # @example
        #   Context.merge(order_id: 456, cart_size: 3)
        #
        def merge(data)
          current[:extra].merge!(data)
        end

        # Get extra data
        #
        # @return [Hash] current extra data
        #
        def extra
          current[:extra]
        end

        # Add a breadcrumb
        #
        # Breadcrumbs are a chronological trail of events leading to an error.
        # Think of them like a log, but attached to the error.
        #
        # @param breadcrumb [Hash] breadcrumb data
        # @option breadcrumb [String] :message what happened
        # @option breadcrumb [String] :category grouping category
        # @option breadcrumb [Hash] :data additional data
        # @option breadcrumb [String] :timestamp when it happened
        #
        # @example
        #   Context.add_breadcrumb(
        #     message: "User clicked checkout",
        #     category: "ui",
        #     data: { button: "checkout_btn" }
        #   )
        #
        def add_breadcrumb(breadcrumb)
          crumbs = current[:breadcrumbs]

          # Add timestamp if not provided
          breadcrumb[:timestamp] ||= Time.now.utc.iso8601(3)

          crumbs << breadcrumb

          # Keep only the most recent breadcrumbs
          # This prevents memory issues from long-running requests
          crumbs.shift while crumbs.size > MAX_BREADCRUMBS
        end

        # Get all breadcrumbs
        #
        # @return [Array<Hash>] breadcrumbs in chronological order
        #
        def breadcrumbs
          current[:breadcrumbs]
        end

        # Set request data (auto-populated by middleware)
        #
        # @param request_data [Hash] HTTP request information
        #
        def set_request(request_data)
          current[:request] = request_data
        end

        # Get request data
        #
        # @return [Hash] HTTP request information
        #
        def request
          current[:request]
        end

        # Get the complete context for capturing
        #
        # This returns all context data in a format ready for storage.
        #
        # @return [Hash] complete context
        #
        def to_h
          ctx = current.dup
          ctx.compact! # Remove nil values

          # Convert breadcrumbs to array (it's already an array, but be explicit)
          ctx[:breadcrumbs] = ctx[:breadcrumbs].dup if ctx[:breadcrumbs]

          ctx
        end

        # Create context from a Rack request
        #
        # This extracts useful information from the HTTP request.
        # Called automatically by the middleware.
        #
        # @param rack_request [Rack::Request] the Rack request object
        # @return [Hash] extracted request data
        #
        def from_rack_request(rack_request)
          {
            method: rack_request.request_method,
            url: rack_request.url,
            path: rack_request.path,
            query_string: scrub_query_string(rack_request.query_string),
            headers: scrub_headers(extract_headers(rack_request)),
            ip: rack_request.ip,
            user_agent: rack_request.user_agent,
            content_type: rack_request.content_type,
            content_length: rack_request.content_length,
            request_id: rack_request.env["action_dispatch.request_id"]
          }
        end

        private

        def default_context
          {
            user: nil,
            tags: {},
            extra: {},
            breadcrumbs: [],
            request: nil
          }
        end

        # Scrub sensitive data from user info
        def scrub_user_data(user_data)
          return nil unless user_data

          scrubbed = user_data.dup

          # Never store password-related fields
          Findbug.config.scrub_fields.each do |field|
            scrubbed.delete(field.to_sym)
            scrubbed.delete(field.to_s)
          end

          scrubbed
        end

        # Extract headers from Rack request
        def extract_headers(rack_request)
          headers = {}

          rack_request.each_header do |key, value|
            # HTTP headers in Rack are prefixed with HTTP_
            next unless key.start_with?("HTTP_")

            # Convert HTTP_X_FORWARDED_FOR to X-Forwarded-For
            header_name = key.sub(/^HTTP_/, "").split("_").map(&:capitalize).join("-")
            headers[header_name] = value
          end

          # Add Content-Type and Content-Length (not prefixed with HTTP_)
          headers["Content-Type"] = rack_request.content_type if rack_request.content_type
          headers["Content-Length"] = rack_request.content_length.to_s if rack_request.content_length

          headers
        end

        # Scrub sensitive headers
        def scrub_headers(headers)
          return {} unless Findbug.config.scrub_headers

          sensitive_headers = %w[
            Authorization
            Cookie
            X-Api-Key
            X-Auth-Token
            X-Access-Token
          ] + Findbug.config.scrub_header_names

          headers.transform_values.with_index do |value, _|
            key = headers.keys[headers.values.index(value)]
            if sensitive_headers.any? { |h| key.casecmp?(h) }
              "[FILTERED]"
            else
              value
            end
          end
        end

        # Scrub sensitive query parameters
        def scrub_query_string(query_string)
          return nil if query_string.nil? || query_string.empty?

          params = Rack::Utils.parse_query(query_string)

          Findbug.config.scrub_fields.each do |field|
            params[field] = "[FILTERED]" if params.key?(field)
          end

          Rack::Utils.build_query(params)
        end
      end
    end
  end
end
