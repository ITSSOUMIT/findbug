# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Findbug
  module Generators
    # InstallGenerator sets up Findbug in a Rails application.
    #
    # Usage:
    #   rails generate findbug:install
    #
    # This will:
    #   1. Create the initializer (config/initializers/findbug.rb)
    #   2. Create database migrations
    #   3. Display next steps
    #
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Install Findbug: creates initializer and migrations"

      class_option :skip_migrations,
                   type: :boolean,
                   default: false,
                   desc: "Skip creating migrations"

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def create_initializer
        template "initializer.rb", "config/initializers/findbug.rb"
        say_status :create, "config/initializers/findbug.rb", :green
      end

      def create_migrations
        return if options[:skip_migrations]

        migration_template(
          "create_findbug_error_events.rb",
          "db/migrate/create_findbug_error_events.rb"
        )

        migration_template(
          "create_findbug_performance_events.rb",
          "db/migrate/create_findbug_performance_events.rb"
        )

        say_status :create, "db/migrate/create_findbug_error_events.rb", :green
        say_status :create, "db/migrate/create_findbug_performance_events.rb", :green
      end

      def display_post_install
        readme "POST_INSTALL" if behavior == :invoke
      end

      private

      def migration_version
        "[#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}]"
      end
    end
  end
end
