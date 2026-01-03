# frozen_string_literal: true

# Findbug Rake Tasks
#
# These tasks help with maintenance and debugging.
# Run `rake -T findbug` to see all available tasks.
#

namespace :findbug do
  desc "Show Findbug configuration and status"
  task status: :environment do
    config = Findbug.config

    puts "\n=== Findbug Status ==="
    puts ""
    puts "Enabled:            #{Findbug.enabled? ? 'Yes' : 'No'}"
    puts "Environment:        #{config.environment}"
    puts "Release:            #{config.release || '(not set)'}"
    puts ""

    puts "--- Error Capture ---"
    puts "Sample Rate:        #{(config.sample_rate * 100).round(1)}%"
    puts "Ignored Exceptions: #{config.ignored_exceptions.map(&:name).join(', ').presence || '(none)'}"
    puts ""

    puts "--- Performance ---"
    puts "Performance Enabled:  #{config.performance_enabled ? 'Yes' : 'No'}"
    puts "Performance Sample:   #{(config.performance_sample_rate * 100).round(1)}%"
    puts "Slow Request Threshold: #{config.slow_request_threshold_ms}ms"
    puts "Slow Query Threshold:   #{config.slow_query_threshold_ms}ms"
    puts ""

    puts "--- Storage ---"
    puts "Redis URL:          #{config.redis_url.gsub(/:[^@]+@/, ':***@')}" # Hide password
    puts "Redis Pool Size:    #{config.redis_pool_size}"
    puts "Retention Days:     #{config.retention_days}"
    puts ""

    puts "--- Dashboard ---"
    puts "Dashboard Enabled:  #{config.web_enabled? ? 'Yes' : 'No'}"
    puts "Dashboard Path:     #{config.web_path}" if config.web_enabled?
    puts ""

    puts "--- Alerts ---"
    if config.alerts.any_enabled?
      config.alerts.enabled_channels.each do |name, _|
        puts "  #{name}: enabled"
      end
    else
      puts "(no alerts configured)"
    end

    puts ""

    # Show Redis buffer stats if available
    if Findbug.enabled?
      puts "--- Buffer Status ---"
      begin
        stats = Findbug::Storage::RedisBuffer.stats
        puts "Error Queue Length:       #{stats[:error_queue_length]}"
        puts "Performance Queue Length: #{stats[:performance_queue_length]}"
        puts "Circuit Breaker State:    #{stats[:circuit_breaker_state]}"
        puts "Circuit Breaker Failures: #{stats[:circuit_breaker_failures]}"
      rescue StandardError => e
        puts "Could not fetch buffer stats: #{e.message}"
      end
    end

    puts "\n"
  end

  desc "Clear all Findbug data from Redis buffers"
  task clear_buffers: :environment do
    puts "Clearing Findbug Redis buffers..."
    Findbug::Storage::RedisBuffer.clear!
    puts "Done!"
  end

  desc "Flush Redis buffers to database immediately"
  task flush: :environment do
    puts "Flushing Findbug buffers to database..."

    require_relative "../jobs/persist_job"

    error_count = 0
    perf_count = 0

    loop do
      events = Findbug::Storage::RedisBuffer.pop_errors(100)
      break if events.empty?

      Findbug::Jobs::PersistJob.persist_errors(events)
      error_count += events.size
    end

    loop do
      events = Findbug::Storage::RedisBuffer.pop_performance(100)
      break if events.empty?

      Findbug::Jobs::PersistJob.persist_performance(events)
      perf_count += events.size
    end

    puts "Flushed #{error_count} error events and #{perf_count} performance events."
  end

  desc "Run cleanup to remove old records"
  task cleanup: :environment do
    puts "Running Findbug cleanup..."

    require_relative "../jobs/cleanup_job"
    Findbug::Jobs::CleanupJob.perform_now

    puts "Done!"
  end

  desc "Test error capture by raising a test exception"
  task test: :environment do
    puts "Testing Findbug error capture..."

    # Capture a test exception
    begin
      raise "Findbug Test Exception - #{Time.now}"
    rescue StandardError => e
      Findbug.capture_exception(e, test: true)
      puts "Test exception captured!"
    end

    # Wait for async write
    sleep 0.5

    # Check if it made it to Redis
    stats = Findbug::Storage::RedisBuffer.stats
    puts "Error queue length: #{stats[:error_queue_length]}"

    if stats[:error_queue_length].positive?
      puts "\nTest passed! Exception was captured."
    else
      puts "\nTest may have failed. Check configuration."
    end
  end

  namespace :db do
    desc "Show database record counts"
    task stats: :environment do
      puts "\n=== Findbug Database Stats ==="

      if defined?(Findbug::ErrorEvent)
        total_errors = Findbug::ErrorEvent.count
        unresolved = Findbug::ErrorEvent.where(status: "unresolved").count
        puts "Total Errors:      #{total_errors}"
        puts "Unresolved:        #{unresolved}"
      else
        puts "ErrorEvent model not loaded"
      end

      if defined?(Findbug::PerformanceEvent)
        total_perf = Findbug::PerformanceEvent.count
        puts "Performance Events: #{total_perf}"
      else
        puts "PerformanceEvent model not loaded"
      end

      puts ""
    end
  end
end
