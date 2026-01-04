# frozen_string_literal: true

require_relative "lib/findbug/version"

Gem::Specification.new do |spec|
  spec.name = "findbug"
  spec.version = Findbug::VERSION
  spec.authors = ["Soumit Das"]
  spec.email = ["its.soumit.das@gmail.com"]

  spec.summary = "Self-hosted error tracking and performance monitoring for Rails"
  spec.description = "Findbug is a Sentry-like error tracking and performance monitoring gem " \
                     "that stores data locally using Redis and your database. Features include " \
                     "exception capture, performance instrumentation, alerting, and a built-in dashboard."
  spec.homepage = "https://github.com/ITSSOUMIT/findbug"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  # Rails 7.0+ required - using pessimistic version constraint to allow 7.x and 8.x
  spec.add_dependency "railties", ">= 7.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.0", "< 9.0"
  spec.add_dependency "activerecord", ">= 7.0", "< 9.0"
  spec.add_dependency "activejob", ">= 7.0", "< 9.0"

  # Redis for fast in-memory buffer storage
  spec.add_dependency "redis", ">= 4.0", "< 6.0"

  # Connection pool for efficient Redis connection management
  spec.add_dependency "connection_pool", "~> 2.2"

  # Hotwire for the dashboard UI
  spec.add_dependency "turbo-rails", ">= 1.0", "< 3.0"
  spec.add_dependency "stimulus-rails", ">= 1.0", "< 3.0"
end
