# frozen_string_literal: true

module HostAppGeneratorSupport
  GENERATOR_OPTIONS = %w[
    --minimal
    --no-rc
    --skip-asset-pipeline
    --skip-bundle
    --skip-git
    --skip-ci
    --skip-docker
    --skip-bootsnap
    --skip-devcontainer
    --skip-solid
    --skip-thruster
    --skip-kamal
    --skip-rubocop
    --skip-brakeman
    --skip-bundler-audit
  ].freeze

  private

  def with_host_app
    Dir.mktmpdir do |directory|
      app_root = File.join(directory, 'host_app')
      run_command!(project_root, rails_new_command(app_root))
      yield app_root
    end
  end

  def replace_gemfile(app_root)
    write_file(
      app_root,
      'Gemfile',
      <<~RUBY
        source "https://rubygems.org"

        gem "rails", "~> 8.1.3"
        gem "sqlite3", ">= 2.1"
        gem "active_record_optimizer", path: #{project_root.inspect}
      RUBY
    )
  end

  def rails_new_command(app_root)
    [Gem.ruby, Gem.bin_path('railties', 'rails'), 'new', app_root, *GENERATOR_OPTIONS]
  end

  def project_root
    File.expand_path('../..', __dir__)
  end
end

module HostAppFixtureSupport
  private

  def write_host_app_files(app_root)
    write_host_app_config(app_root)
    write_host_app_models(app_root)
    write_host_app_migration(app_root)
  end

  def write_host_app_config(app_root)
    write_file(
      app_root,
      '.active_record_optimizer.yml',
      <<~YAML
        output_format: json
        ignored_findings:
          - code: missing_belongs_to_index
            table: payments
      YAML
    )
  end

  def write_host_app_models(app_root)
    write_file(app_root, 'app/models/user.rb', <<~RUBY)
      class User < ApplicationRecord
        has_many :payments
      end
    RUBY

    write_file(app_root, 'app/models/payment.rb', <<~RUBY)
      class Payment < ApplicationRecord
        belongs_to :user
      end
    RUBY
  end

  def write_host_app_migration(app_root)
    write_file(app_root, 'db/migrate/20260613000000_create_users_and_payments.rb', <<~RUBY)
      class CreateUsersAndPayments < ActiveRecord::Migration[8.1]
        def change
          create_table :users do |t|
            t.string :name
            t.timestamps
          end

          create_table :payments do |t|
            t.integer :user_id
            t.integer :status
            t.timestamps
          end
        end
      end
    RUBY
  end

  def write_runtime_capture_script(app_root)
    write_file(app_root, 'tmp/runtime_capture.rb', <<~RUBY)
      user = User.create!(name: "optimizer")
      Payment.create!(user_id: user.id, status: 1)

      ActiveRecordOptimizer.capture_runtime_queries(
        path: Rails.root.join("tmp/active_record_optimizer.runtime.json")
      ) do
        2.times { Payment.where(status: 1).load }
      end
    RUBY
  end

  def write_file(app_root, relative_path, contents)
    path = File.join(app_root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end
end

module HostAppCommandSupport
  private

  # rubocop:disable Style/ArgumentsForwarding
  def bundle_command(*arguments)
    [Gem.ruby, Gem.bin_path('bundler', 'bundle'), *arguments]
  end

  def run_bundle_command!(chdir, *arguments)
    run_command!(chdir, bundle_command(*arguments))
  end
  # rubocop:enable Style/ArgumentsForwarding

  def run_command!(chdir, command)
    stdout, stderr, status = capture_command(chdir, command)
    return stdout if status.success?

    flunk([
      "Command failed: #{command.shelljoin}",
      "stdout:\n#{stdout}",
      "stderr:\n#{stderr}"
    ].join("\n\n"))
  end

  def capture_command(chdir, command)
    Open3.capture3(execution_env(chdir), *command, chdir: chdir)
  end

  def execution_env(chdir)
    bundler_unbundled_env.merge(sanitized_env).merge('PWD' => chdir)
  end

  def sanitized_env
    ENV.to_h.reject do |key, _value|
      key.start_with?('BUNDLE_', 'BUNDLER_') || %w[RUBYLIB RUBYOPT].include?(key)
    end
  end

  def bundler_unbundled_env
    return Bundler.unbundled_env if defined?(Bundler) && Bundler.respond_to?(:unbundled_env)

    ENV.to_h
  end
end
