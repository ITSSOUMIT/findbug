# FindBug

[![Gem Version](https://badge.fury.io/rb/findbug.svg)](https://rubygems.org/gems/findbug)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![GitHub](https://img.shields.io/github/stars/ITSSOUMIT/findbug?style=social)](https://github.com/ITSSOUMIT/findbug)

**Self-hosted error tracking and performance monitoring for Rails applications.**

FindBug provides Sentry-like functionality with all data stored on your own infrastructure using Redis and your database. Zero external dependencies, full data ownership.

## Features

- **Error Tracking** - Capture exceptions with full context, stack traces, and request data
- **Performance Monitoring** - Track request timing, SQL queries, and automatic N+1 detection
- **Self-Hosted** - All data stays on your infrastructure (Redis + PostgreSQL/MySQL)
- **Zero Performance Impact** - Async writes via Redis buffer, never blocks your requests
- **Built-in Dashboard** - Beautiful web UI for viewing errors and performance metrics
- **Multi-channel Alerts** - Email, Slack, Discord, and custom webhooks
- **Works Out of the Box** - Built-in background persister, no job scheduler required
- **Rails 7+ Native** - Designed for modern Rails applications

## Why FindBug?

| Feature | Sentry/Bugsnag | FindBug |
|---------|----------------|---------|
| Data Location | Third-party servers | Your infrastructure |
| Monthly Cost | $26+ per seat | Free |
| Privacy/Compliance | Requires DPA | Full control |
| Network Dependency | Required | None |
| Setup Complexity | API keys, SDKs | One gem, one command |

## Requirements

- Ruby 3.1+
- Rails 7.0+
- Redis 4.0+
- PostgreSQL or MySQL

## Installation

Add to your Gemfile:

```ruby
gem 'findbug'
```

Run the installer:

```bash
bundle install
rails generate findbug:install
rails db:migrate
```

## Quick Start

### 1. Configure Redis (Optional)

FindBug uses Redis as a high-speed buffer. By default, it connects to `redis://localhost:6379/1`.

To use a different Redis URL, set the environment variable:

```bash
export FINDBUG_REDIS_URL=redis://localhost:6379/1
```

Or configure in `config/initializers/findbug.rb`:

```ruby
config.redis_url = ENV.fetch("FINDBUG_REDIS_URL", "redis://localhost:6379/1")
```

### 2. Enable the Dashboard

Set credentials via environment variables:

```bash
export FINDBUG_USERNAME=admin
export FINDBUG_PASSWORD=your-secure-password
```

Access the dashboard at: `http://localhost:3000/findbug`

### 3. That's It!

FindBug automatically:
- Captures unhandled exceptions
- Monitors request performance
- Persists data to your database (via built-in background thread)
- No additional job scheduler required

## Configuration

All configuration options in `config/initializers/findbug.rb`:

```ruby
Findbug.configure do |config|
  # ===================
  # Core Settings
  # ===================
  config.enabled = !Rails.env.test?
  config.redis_url = ENV.fetch("FINDBUG_REDIS_URL", "redis://localhost:6379/1")
  config.redis_pool_size = 5

  # ===================
  # Error Capture
  # ===================
  config.sample_rate = 1.0  # Capture 100% of errors
  config.ignored_exceptions = [
    ActiveRecord::RecordNotFound,
    ActionController::RoutingError
  ]
  config.ignored_paths = [/^\/health/, /^\/assets/]

  # ===================
  # Performance Monitoring
  # ===================
  config.performance_enabled = true
  config.performance_sample_rate = 0.1  # Sample 10% of requests
  config.slow_request_threshold_ms = 0
  config.slow_query_threshold_ms = 100

  # ===================
  # Data Security
  # ===================
  config.scrub_fields = %w[password api_key credit_card ssn token secret]
  config.scrub_headers = true

  # ===================
  # Storage & Retention
  # ===================
  config.retention_days = 30
  config.max_buffer_size = 10_000

  # ===================
  # Dashboard
  # ===================
  config.web_username = ENV["FINDBUG_USERNAME"]
  config.web_password = ENV["FINDBUG_PASSWORD"]
  config.web_path = "/findbug"

  # ===================
  # Alerts (Optional)
  # ===================
  config.alerts do |alerts|
    alerts.throttle_period = 5.minutes

    # Slack
    # alerts.slack(
    #   enabled: true,
    #   webhook_url: ENV["SLACK_WEBHOOK_URL"],
    #   channel: "#errors"
    # )

    # Email
    # alerts.email(
    #   enabled: true,
    #   recipients: ["team@example.com"]
    # )

    # Discord
    # alerts.discord(
    #   enabled: true,
    #   webhook_url: ENV["DISCORD_WEBHOOK_URL"]
    # )

    # Custom Webhook
    # alerts.webhook(
    #   enabled: true,
    #   url: "https://your-service.com/webhook",
    #   headers: { "Authorization" => "Bearer token" }
    # )
  end
end
```

## Usage

### Automatic Error Capture

FindBug automatically captures:
- Unhandled exceptions in controllers
- Errors reported via `Rails.error.handle` / `Rails.error.report`
- Any exception that bubbles up through the middleware stack

### Manual Error Capture

```ruby
# Capture an exception with context
begin
  risky_operation
rescue => e
  Findbug.capture_exception(e, user_id: current_user.id)
  # Handle gracefully...
end

# Capture a message (non-exception event)
Findbug.capture_message("Rate limit exceeded", :warning, user_id: 123)
```

### Adding Context

In your `ApplicationController`:

```ruby
class ApplicationController < ActionController::Base
  before_action :set_findbug_context

  private

  def set_findbug_context
    findbug_set_user(current_user)
    findbug_set_context(
      plan: current_user&.plan,
      organization_id: current_org&.id
    )
  end
end
```

### Breadcrumbs

Track events leading up to an error:

```ruby
findbug_breadcrumb("User clicked checkout", category: "ui")
findbug_breadcrumb("Payment API called", category: "http", data: { amount: 99.99 })
```

### Performance Tracking

Automatic tracking includes:
- HTTP request duration
- SQL query count and timing
- N+1 query detection
- View rendering time

Manual tracking for custom operations:

```ruby
Findbug.track_performance("external_api_call") do
  ExternalAPI.fetch_data
end
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Your Rails App                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Request ──► Middleware ──► Exception? ──► Redis Buffer        │
│                                               (async, ~1ms)     │
│                                                    │            │
│  Request ──► Instrumentation ──► Perf Data ──► Redis Buffer    │
│                                               (async, ~1ms)     │
│                                                    │            │
│                                                    ▼            │
│                                         ┌──────────────────┐   │
│                                         │ BackgroundThread │   │
│                                         │   (every 30s)    │   │
│                                         └────────┬─────────┘   │
│                                                  │              │
│                                                  ▼              │
│  Dashboard ◄──────────────────── Database (PostgreSQL/MySQL)   │
│  (/findbug)                                                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Performance Guarantees:**
- Error capture: ~1-2ms (async Redis write)
- Never blocks your HTTP requests
- Circuit breaker auto-disables if Redis is unavailable
- Dedicated connection pool (won't affect your app's Redis usage)

## Rake Tasks

```bash
# Show configuration and system status
rails findbug:status

# Test error capture
rails findbug:test

# Manually flush Redis buffer to database
rails findbug:flush

# Run retention cleanup
rails findbug:cleanup

# Clear Redis buffers (use with caution)
rails findbug:clear_buffers

# Show database statistics
rails findbug:db:stats
```

## Advanced: Using ActiveJob Instead of Built-in Thread

By default, FindBug uses a built-in background thread for persistence. If you prefer to use ActiveJob with your own job backend:

```ruby
# config/initializers/findbug.rb
config.auto_persist = false  # Disable built-in thread
```

Then schedule the jobs with your preferred scheduler:

```ruby
# With any scheduler (Sidekiq, GoodJob, Solid Queue, etc.)
Findbug::PersistJob.perform_later   # Run every 30 seconds
Findbug::CleanupJob.perform_later   # Run daily
```

## API Reference

### Error Capture

```ruby
Findbug.capture_exception(exception, context = {})
Findbug.capture_message(message, level = :info, context = {})
```

### Performance Tracking

```ruby
Findbug.track_performance(name) { ... }
```

### Controller Helpers

```ruby
findbug_set_user(user)
findbug_set_context(hash)
findbug_breadcrumb(message, category:, data: {})
```

### Configuration

```ruby
Findbug.config           # Access configuration
Findbug.enabled?         # Check if enabled
Findbug.reset!           # Reset configuration (for testing)
```

## Development

```bash
git clone https://github.com/ITSSOUMIT/findbug.git
cd findbug
bin/setup
bundle exec rspec
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ITSSOUMIT/findbug.

If you encounter any bugs, please open an issue or send an email to hey@soumit.in.

1. Fork it
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Create a Pull Request

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Credits

Built by [Soumit Das](https://github.com/ITSSOUMIT).
