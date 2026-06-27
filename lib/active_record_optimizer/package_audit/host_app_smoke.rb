# frozen_string_literal: true

require 'json'
require 'rubygems/package'

module ActiveRecordOptimizer
  module PackageAudit
    # rubocop:disable Metrics/ModuleLength
    module HostAppSmoke
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

      module_function

      def verify!(gem_path:)
        Dir.mktmpdir do |directory|
          app_root = File.join(directory, 'host_app')
          gem_home = File.join(directory, 'gems')
          FileUtils.mkdir_p(gem_home)
          env = host_app_env

          installed_spec = Smoke.install_built_gem!(gem_path, gem_home)
          create_host_app!(directory, app_root, env)
          bundler_gem_path = unpack_built_gem_for_bundler!(app_root, gem_path, installed_spec)
          write_host_app_files!(app_root, bundler_gem_path: bundler_gem_path)
          bundle_env = host_app_bundle_env(app_root, gem_home)
          run_bundle!(app_root, bundle_env, 'install', '--local')
          verify_loaded_gem!(app_root, bundle_env, expected_version: installed_spec.version, expected_gem_path: bundler_gem_path)
          run_bundle!(app_root, bundle_env, 'exec', 'bin/rails', 'db:migrate')
          run_bundle!(app_root, bundle_env, 'exec', 'bin/rails', 'runner', 'tmp/runtime_capture.rb')
          verify_runtime_snapshot!(app_root, installed_gem_path: installed_spec.full_gem_path, literalized_binds: false)
          verify_optimizer_command!(app_root, bundle_env)
        end
      end

      def verify_postgresql!(gem_path:, connection_config:)
        Dir.mktmpdir do |directory|
          app_root = File.join(directory, 'host_app')
          gem_home = File.join(directory, 'gems')
          FileUtils.mkdir_p(gem_home)
          env = host_app_env

          installed_spec = Smoke.install_built_gem!(gem_path, gem_home)
          create_host_app!(directory, app_root, env)
          bundler_gem_path = unpack_built_gem_for_bundler!(app_root, gem_path, installed_spec)
          write_postgresql_host_app_files!(app_root, bundler_gem_path: bundler_gem_path, connection_config: connection_config)
          bundle_env = host_app_bundle_env(app_root, gem_home)
          run_bundle!(app_root, bundle_env, 'install', '--local')
          verify_loaded_gem!(app_root, bundle_env, expected_version: installed_spec.version, expected_gem_path: bundler_gem_path)
          run_bundle!(app_root, bundle_env, 'exec', 'bin/rails', 'db:migrate')
          run_bundle!(app_root, bundle_env, 'exec', 'bin/rails', 'runner', 'tmp/runtime_capture.rb')
          verify_runtime_snapshot!(app_root, installed_gem_path: installed_spec.full_gem_path, literalized_binds: true)
          verify_postgresql_optimizer_command!(app_root, bundle_env)
        end
      end

      def host_app_env
        Smoke.sanitized_env.merge(
          'RAILS_ENV' => 'development'
        )
      end

      def host_app_bundle_env(app_root, gem_home)
        env = host_app_env.merge(
          'BUNDLE_APP_CONFIG' => File.join(app_root, '.bundle'),
          'BUNDLE_GEMFILE' => File.join(app_root, 'Gemfile'),
          'GEM_HOME' => gem_home,
          'GEM_PATH' => ([gem_home] + Smoke.base_gem_paths).uniq.join(File::PATH_SEPARATOR)
        )
        env['BUNDLE_PATH'] = Smoke.bundler_configured_path if Smoke.bundler_configured_path
        env
      end

      def create_host_app!(directory, app_root, env)
        Smoke.run_command!(
          env,
          [Gem.ruby, Gem.bin_path('railties', 'rails'), 'new', app_root, *GENERATOR_OPTIONS],
          failure_message: 'Failed to generate disposable Rails host app for built gem smoke verification.',
          chdir: directory
        )
      end

      def write_host_app_files!(app_root, bundler_gem_path:)
        write_gemfile!(app_root, bundler_gem_path)
        write_project_config!(app_root)
        write_models!(app_root)
        write_migration!(app_root)
        write_runtime_capture_script!(app_root)
      end

      def write_gemfile!(app_root, bundler_gem_path)
        remove_lockfile!(app_root)
        write_file(
          app_root,
          'Gemfile',
          <<~RUBY
            source "https://rubygems.org"

            gem "rails", "~> 8.1.3"
            gem "sqlite3", ">= 2.1"
            #{packaged_gem_declaration(bundler_gem_path)}
          RUBY
        )
      end

      def write_project_config!(app_root)
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

      def write_postgresql_host_app_files!(app_root, bundler_gem_path:, connection_config:)
        write_postgresql_gemfile!(app_root, bundler_gem_path)
        write_postgresql_database_config!(app_root, connection_config)
        write_postgresql_project_config!(app_root)
        write_postgresql_models!(app_root)
        write_postgresql_migration!(app_root)
        write_postgresql_runtime_capture_script!(app_root)
      end

      def write_models!(app_root)
        write_file(
          app_root,
          'app/models/user.rb',
          <<~RUBY
            class User < ApplicationRecord
              has_many :payments
            end
          RUBY
        )

        write_file(
          app_root,
          'app/models/payment.rb',
          <<~RUBY
            class Payment < ApplicationRecord
              belongs_to :user
            end
          RUBY
        )
      end

      def write_postgresql_gemfile!(app_root, bundler_gem_path)
        remove_lockfile!(app_root)
        write_file(
          app_root,
          'Gemfile',
          <<~RUBY
            source "https://rubygems.org"

            gem "rails", "~> 8.1.3"
            gem "pg"
            #{packaged_gem_declaration(bundler_gem_path)}
          RUBY
        )
      end

      def write_postgresql_database_config!(app_root, connection_config)
        normalized_config = connection_config.transform_keys(&:to_s)
        lines = {
          'adapter' => 'postgresql',
          'database' => normalized_config.fetch('database'),
          'host' => normalized_config['host'],
          'port' => normalized_config['port'],
          'username' => normalized_config['username'],
          'password' => normalized_config['password'],
          'pool' => 5
        }.compact

        database_yaml = [
          'default: &default',
          *lines.map { |key, value| "  #{key}: #{value.inspect}" },
          '',
          'development:',
          '  <<: *default'
        ].join("\n")

        write_file(app_root, 'config/database.yml', "#{database_yaml}\n")
      end

      def write_postgresql_project_config!(app_root)
        write_file(
          app_root,
          '.active_record_optimizer.yml',
          <<~YAML
            output_format: json
            planner_row_threshold: 1
          YAML
        )
      end

      def write_postgresql_models!(app_root)
        write_file(
          app_root,
          'app/models/user.rb',
          <<~RUBY
            class User < ApplicationRecord
              has_many :payments
            end
          RUBY
        )

        write_file(
          app_root,
          'app/models/payment.rb',
          <<~RUBY
            class Payment < ApplicationRecord
              belongs_to :user
            end
          RUBY
        )
      end

      def write_postgresql_migration!(app_root)
        write_file(
          app_root,
          'db/migrate/20260613000001_create_users_and_payments.rb',
          <<~RUBY
            class CreateUsersAndPayments < ActiveRecord::Migration[8.1]
              def change
                create_table :users do |t|
                  t.string :name
                  t.timestamps
                end

                create_table :payments do |t|
                  t.references :user, null: false, foreign_key: true, index: true
                  t.jsonb :metadata, null: false, default: {}
                  t.timestamps
                end
              end
            end
          RUBY
        )
      end

      def write_postgresql_runtime_capture_script!(app_root)
        write_file(
          app_root,
          'tmp/runtime_capture.rb',
          <<~RUBY
            user = User.create!(name: "optimizer")

            20.times do |index|
              Payment.create!(
                user: user,
                metadata: { status: index.even? ? "paid" : "pending" }
              )
            end

            ActiveRecord::Base.connection.execute("ANALYZE payments")

            ActiveRecordOptimizer.capture_runtime_queries(
              path: Rails.root.join("tmp/active_record_optimizer.runtime.json"),
              literalize_binds: true
            ) do
              2.times { Payment.where("metadata ->> 'status' = ?", "paid").load }
            end
          RUBY
        )
      end

      def write_migration!(app_root)
        write_file(
          app_root,
          'db/migrate/20260613000000_create_users_and_payments.rb',
          <<~RUBY
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
        )
      end

      def write_runtime_capture_script!(app_root)
        write_file(
          app_root,
          'tmp/runtime_capture.rb',
          <<~RUBY
            user = User.create!(name: "optimizer")
            Payment.create!(user_id: user.id, status: 1)

            ActiveRecordOptimizer.capture_runtime_queries(
              path: Rails.root.join("tmp/active_record_optimizer.runtime.json")
            ) do
              2.times { Payment.where(status: 1).load }
            end
          RUBY
        )
      end

      def verify_loaded_gem!(app_root, env, expected_version:, expected_gem_path:)
        Smoke.run_command!(
          env.merge(
            'EXPECTED_GEM_PATH' => File.realpath(expected_gem_path),
            'EXPECTED_GEM_VERSION' => expected_version.to_s
          ),
          bundle_command('exec', 'ruby', '-e', loaded_gem_script),
          failure_message: 'Bundler did not resolve active_record_optimizer from the built gem installation.',
          chdir: app_root
        )
      end

      def verify_optimizer_command!(app_root, env)
        stdout = Smoke.run_command!(
          env,
          bundle_command('exec', 'bin/rails', 'active_record:optimize', '--fail-on', 'high'),
          failure_message: 'Disposable Rails host app failed to execute active_record:optimize from the built gem.',
          chdir: app_root,
          allowed_exit_codes: [1]
        )

        payload = JSON.parse(stdout)
        finding_codes = payload.fetch('findings').map { |finding| finding.fetch('code') }

        return if payload.dig('metadata', 'schema_version') == Report::JSON_SCHEMA_VERSION &&
                  finding_codes == ['missing_foreign_key_constraint'] &&
                  payload.fetch('counts') == { 'high' => 1 }

        raise ActiveRecordOptimizer::Error,
              'Disposable Rails host app returned unexpected JSON from active_record:optimize.'
      rescue JSON::ParserError => e
        raise ActiveRecordOptimizer::Error,
              "Disposable Rails host app did not emit valid JSON from active_record:optimize: #{e.message}"
      end

      def verify_postgresql_optimizer_command!(app_root, env)
        stdout = Smoke.run_command!(
          env,
          postgresql_optimizer_command,
          failure_message: 'Disposable PostgreSQL Rails host app failed to execute active_record:optimize from the built gem.',
          chdir: app_root,
          allowed_exit_codes: [1]
        )

        payload = JSON.parse(stdout)
        return if postgresql_optimizer_payload_valid?(payload)

        raise ActiveRecordOptimizer::Error,
              'Disposable PostgreSQL Rails host app returned unexpected JSON from active_record:optimize.'
      rescue JSON::ParserError => e
        raise ActiveRecordOptimizer::Error,
              "Disposable PostgreSQL Rails host app did not emit valid JSON from active_record:optimize: #{e.message}"
      end

      def verify_runtime_snapshot!(app_root, installed_gem_path:, literalized_binds:)
        snapshot_path = File.join(app_root, 'tmp/active_record_optimizer.runtime.json')
        payload = JSON.parse(File.read(snapshot_path))
        validate_runtime_snapshot_schema!(payload, installed_gem_path)
        result = RuntimeQueryLoader.new(path: snapshot_path).load_result

        return if payload.dig('metadata', 'schema_version') == QueryCollector::Snapshot::JSON_SCHEMA_VERSION &&
                  payload.dig('metadata', 'capture', 'literalized_binds') == literalized_binds &&
                  result.query_usages.any?

        raise ActiveRecordOptimizer::Error,
              'Disposable Rails host app returned unexpected runtime snapshot JSON from capture_runtime_queries.'
      rescue Errno::ENOENT
        raise ActiveRecordOptimizer::Error,
              'Disposable Rails host app did not write the expected runtime snapshot artifact.'
      rescue JSON::ParserError => e
        raise ActiveRecordOptimizer::Error,
              "Disposable Rails host app did not emit valid JSON from capture_runtime_queries: #{e.message}"
      end

      def validate_runtime_snapshot_schema!(payload, installed_gem_path)
        errors = runtime_snapshot_schema(installed_gem_path).validate(payload).to_a
        return if errors.empty?

        raise ActiveRecordOptimizer::Error,
              "Disposable Rails host app emitted runtime snapshot JSON that violates the packaged schema: #{errors.inspect}"
      end

      def runtime_snapshot_schema(installed_gem_path)
        require_json_schemer!

        schema_path = File.join(installed_gem_path, runtime_snapshot_schema_relative_path)
        unless File.exist?(schema_path)
          raise ActiveRecordOptimizer::Error,
                "Installed built gem is missing #{runtime_snapshot_schema_relative_path} required for runtime snapshot validation."
        end

        @runtime_snapshot_schema_cache ||= {}
        @runtime_snapshot_schema_cache[schema_path] ||= JSONSchemer.schema(JSON.parse(File.read(schema_path)))
      end

      def require_json_schemer!
        return if defined?(JSONSchemer)

        require 'json_schemer'
      rescue LoadError
        raise ActiveRecordOptimizer::Error,
              'Package audit runtime snapshot validation requires the json_schemer gem in the verification environment.'
      end

      def runtime_snapshot_schema_relative_path
        "docs/runtime-query-snapshot-schema-v#{QueryCollector::Snapshot::JSON_SCHEMA_VERSION}.json"
      end

      def postgresql_optimizer_command
        bundle_command(
          'exec',
          'bin/rails',
          'active_record:optimize',
          '--runtime-report',
          'tmp/active_record_optimizer.runtime.json',
          '--explain-runtime',
          '--fail-on',
          'high'
        )
      end

      def postgresql_optimizer_payload_valid?(payload)
        finding = payload.fetch('findings').find { |entry| entry.fetch('code') == 'jsonb_query_without_index' }

        payload.dig('metadata', 'schema_version') == Report::JSON_SCHEMA_VERSION &&
          payload.fetch('counts') == { 'high' => 1 } &&
          finding &&
          finding.dig('details', 'planner_confirmed') == true
      end

      def bundle_command(*arguments)
        [Gem.ruby, Gem.bin_path('bundler', 'bundle'), *arguments]
      end

      def run_bundle!(app_root, env, *arguments)
        Smoke.run_command!(
          env,
          bundle_command(*arguments),
          failure_message: "Disposable Rails host app failed to run `bundle #{arguments.join(' ')}`.",
          chdir: app_root
        )
      end

      def write_file(app_root, relative_path, contents)
        path = File.join(app_root, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
      end

      def remove_lockfile!(app_root)
        FileUtils.rm_f(File.join(app_root, 'Gemfile.lock'))
      end

      def unpack_built_gem_for_bundler!(app_root, gem_path, installed_spec)
        bundler_gem_path = File.join(app_root, 'vendor/gems/active_record_optimizer')
        FileUtils.rm_rf(bundler_gem_path)
        FileUtils.mkdir_p(bundler_gem_path)
        Gem::Package.new(gem_path).extract_files(bundler_gem_path)
        File.write(File.join(bundler_gem_path, 'active_record_optimizer.gemspec'), installed_spec.to_ruby)
        bundler_gem_path
      end

      def packaged_gem_declaration(bundler_gem_path)
        %(gem "active_record_optimizer", path: #{bundler_gem_path.inspect})
      end

      def loaded_gem_script
        <<~RUBY
          spec = Gem.loaded_specs.fetch('active_record_optimizer')
          real_path = File.realpath(spec.full_gem_path)
          abort('loaded gem version mismatch') unless spec.version.to_s == ENV.fetch('EXPECTED_GEM_VERSION')
          abort('loaded gem path does not match unpacked built gem') unless real_path == ENV.fetch('EXPECTED_GEM_PATH')
        RUBY
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
