# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Findbug
  module Generators
    # UpgradeGenerator creates any missing migrations for existing Findbug installations.
    #
    # Usage:
    #   rails generate findbug:upgrade
    #
    # This is safe to run multiple times — it only creates migrations that don't
    # already exist. Use this when upgrading Findbug to a new version that adds
    # new database tables.
    #
    class UpgradeGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Upgrade Findbug: creates any missing migrations"

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def create_missing_migrations
        create_migration_if_missing(
          "create_findbug_alert_channels.rb",
          "db/migrate/create_findbug_alert_channels.rb"
        )
      end

      def display_next_steps
        return unless behavior == :invoke

        say ""
        say "=================================================================", :green
        say "  Findbug upgrade complete!", :green
        say "=================================================================", :green
        say ""
        say "Next steps:"
        say ""
        say "  1. Run migrations:  rails db:migrate"
        say ""
        say "  2. Configure alerts via the dashboard:"
        say "     http://localhost:3000/findbug/alerts"
        say ""
        say "  3. (Multi-tenant apps) Add to apartment.rb excluded_models:"
        say "     Findbug::AlertChannel"
        say ""
      end

      private

      def migration_version
        "[#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}]"
      end

      # Only create a migration if no migration with the same class name exists
      def create_migration_if_missing(template_name, destination)
        migration_name = template_name.sub(/\.rb$/, "")

        if migration_exists?(migration_name)
          say_status :skip, destination, :yellow
        else
          migration_template(template_name, destination)
          say_status :create, destination, :green
        end
      end

      # Check if a migration file already exists in db/migrate/
      def migration_exists?(migration_name)
        Dir.glob("db/migrate/[0-9]*_#{migration_name}.rb").any?
      end
    end
  end
end
