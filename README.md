# Findbug

Self-hosted error tracking and performance monitoring for Rails applications. Think Sentry, but with all data stored locally using Redis and your database.

## Features

- **Error Tracking** - Capture exceptions with full context, stack traces, and breadcrumbs
- **Performance Monitoring** - Track request timing, SQL queries, and N+1 detection
- **Self-Hosted** - All data stays on your infrastructure (Redis + Database)
- **Zero Performance Impact** - Async writes via Redis buffer, never blocks your requests
- **Built-in Dashboard** - Mountable web UI at `/findbug` (like Sidekiq)
- **Multi-channel Alerts** - Email, Slack, Discord, and webhooks
- **Rails 7+ Native** - Uses modern Rails patterns (Hotwire, ActiveJob)

## Why Findbug?

| Feature | Sentry | Findbug |
|---------|--------|---------|
| Data Location | Their servers | Your infrastructure |
| Monthly Cost | $26+ / team | Free |
| Privacy/Compliance | Requires DPA | Full control |
| Network Dependency | Required | None |
| Offline Support | No | Yes |

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

### 1. Configure Redis

Findbug uses Redis as a high-speed buffer. Configure in `config/initializers/findbug.rb`:

```ruby
Findbug.configure do |config|
  config.redis_url = ENV.fetch("FINDBUG_REDIS_URL", "redis://localhost:6379/1")
end
```

### 2. Enable the Dashboard

Set credentials via environment variables:

```bash
export FINDBUG_USERNAME=admin
export FINDBUG_PASSWORD=your-secure-password
```

Access the dashboard at: `http://localhost:3000/findbug`

### 3. Set Up Background Jobs

Findbug requires periodic jobs to persist data from Redis to your database:

**With Sidekiq + sidekiq-scheduler:**

```yaml
# config/sidekiq.yml
:schedule:
  findbug_persist:
    cron: '*/30 * * * * *'  # Every 30 seconds
    class: Findbug::Jobs::PersistJob

  findbug_cleanup:
    cron: '0 3 * * *'       # Daily at 3 AM
    class: Findbug::Jobs::CleanupJob
```

**With Solid Queue (Rails 8):**

```ruby
# app/jobs/findbug_scheduler_job.rb
class FindbugSchedulerJob < ApplicationJob
  def perform
    Findbug::Jobs::PersistJob.perform_now
    self.class.set(wait: 30.seconds).perform_later
  end
end
```

## Configuration

Full configuration options:

```ruby
Findbug.configure do |config|
  # Core
  config.enabled = !Rails.env.test?
  config.redis_url = "redis://localhost:6379/1"
  config.redis_pool_size = 5

  # Error Capture
  config.sample_rate = 1.0  # Capture 100% of errors
  config.ignored_exceptions = [ActiveRecord::RecordNotFound]
  config.ignored_paths = [/^\/health/, /^\/assets/]

  # Performance
  config.performance_enabled = true
  config.performance_sample_rate = 0.1  # Sample 10% of requests
  config.slow_request_threshold_ms = 0
  config.slow_query_threshold_ms = 100

  # Security
  config.scrub_fields = %w[password api_key credit_card ssn]
  config.scrub_headers = true

  # Storage
  config.retention_days = 30

  # Dashboard
  config.web_username = ENV["FINDBUG_USERNAME"]
  config.web_password = ENV["FINDBUG_PASSWORD"]
  config.web_path = "/findbug"

  # Alerts
  config.alerts do |alerts|
    alerts.throttle_period = 5.minutes

    alerts.slack(
      enabled: true,
      webhook_url: ENV["SLACK_WEBHOOK_URL"]
    )

    alerts.email(
      enabled: true,
      recipients: ["team@example.com"]
    )
  end
end
```

## Usage

### Automatic Error Capture

Findbug automatically captures:
- Unhandled exceptions in controllers
- Errors reported via `Rails.error.handle`
- Background job failures

### Manual Error Capture

```ruby
# Capture an exception
begin
  risky_operation
rescue => e
  Findbug.capture_exception(e, user_id: current_user.id)
  # Handle gracefully...
end

# Capture a message
Findbug.capture_message("User exceeded rate limit", :warning, user_id: 123)
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

Automatic tracking for:
- HTTP request timing
- SQL query counting and N+1 detection
- View rendering time

Manual tracking:

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
│  Middleware ──► Exception Capture ──► Redis Buffer (async)      │
│                                              │                   │
│  Performance ──► Instrumentation ──► Redis Buffer (async)       │
│                                              │                   │
│                                              ▼                   │
│                                    ┌─────────────────┐          │
│                                    │  PersistJob     │          │
│                                    │  (every 30s)    │          │
│                                    └────────┬────────┘          │
│                                              │                   │
│                                              ▼                   │
│  Dashboard ◄────────────── Database (PostgreSQL/MySQL)          │
│  (/findbug)                                                      │
└─────────────────────────────────────────────────────────────────┘
```

**Performance guarantees:**
- Error capture: ~1-2ms (async Redis write)
- Never blocks your request
- Circuit breaker protects against Redis failures
- Separate connection pool (won't affect your app's Redis)

## Rake Tasks

```bash
# Show status and configuration
rake findbug:status

# Test error capture
rake findbug:test

# Manually flush buffer to database
rake findbug:flush

# Run cleanup (remove old records)
rake findbug:cleanup

# Clear Redis buffers
rake findbug:clear_buffers
```

## Development

```bash
git clone https://github.com/soumitdas/findbug.git
cd findbug
bin/setup
rake spec
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/soumitdas/findbug.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
