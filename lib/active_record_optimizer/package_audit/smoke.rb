# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'pathname'
require 'rubygems/installer'
require 'rubygems/user_interaction'
require 'shellwords'
require 'tmpdir'

module ActiveRecordOptimizer
  module PackageAudit
    # rubocop:disable Metrics/ModuleLength
    module Smoke
      module_function

      def verify!(gem_path:)
        Dir.mktmpdir do |directory|
          gem_home = File.join(directory, 'gems')
          FileUtils.mkdir_p(gem_home)
          installed_spec = install_built_gem!(gem_path, gem_home)
          run_command!(
            smoke_env(gem_home, installed_spec),
            [Gem.ruby, '-e', smoke_script],
            failure_message: 'Failed to require built gem from isolated GEM_HOME.',
            chdir: directory
          )
        end
      end

      def install_built_gem!(gem_path, gem_home)
        Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
          Gem::Installer.at(gem_path, install_dir: gem_home, ignore_dependencies: true, wrappers: false).install
        end
      rescue Gem::InstallError, Gem::Package::FormatError => e
        raise ActiveRecordOptimizer::Error, "Failed to install built gem into isolated GEM_HOME: #{e.message}"
      end

      def smoke_env(gem_home, installed_spec)
        sanitized_env.merge(
          'EXPECTED_CONTRACT_FILES' => PackageAudit::PUBLIC_CONTRACT_FILES.join(File::PATH_SEPARATOR),
          'EXPECTED_VERSION' => ActiveRecordOptimizer::VERSION,
          'GEM_HOME' => gem_home,
          'GEM_PATH' => ([gem_home] + base_gem_paths).uniq.join(File::PATH_SEPARATOR),
          'INSTALLED_GEM_PATH' => installed_spec.full_gem_path,
          'INSTALLED_GEM_REALPATH' => File.realpath(installed_spec.full_gem_path),
          'INSTALLED_SPEC_PATH' => installed_spec.loaded_from,
          'REAL_GEM_HOME' => File.realpath(gem_home)
        )
      end

      def smoke_script
        <<~RUBY
          expected_version = ENV.fetch('EXPECTED_VERSION')
          spec = Gem::Specification.load(ENV.fetch('INSTALLED_SPEC_PATH'))
          abort('installed gem spec could not be loaded') unless spec
          real_installed_gem_path = File.realpath(spec.full_gem_path)
          abort('installed gem path mismatch') unless real_installed_gem_path == ENV.fetch('INSTALLED_GEM_REALPATH')

          if Object.const_defined?(:ActiveRecordOptimizer)
            Object.send(:remove_const, :ActiveRecordOptimizer)
          end

          $LOADED_FEATURES.reject! do |feature|
            feature.include?('/active_record_optimizer/') && !feature.start_with?(spec.full_gem_path)
          end
          spec.full_require_paths.reverse_each { |path| $LOAD_PATH.unshift(path) }
          require 'active_record_optimizer'

          expected_files = ENV.fetch('EXPECTED_CONTRACT_FILES').split(File::PATH_SEPARATOR)
          missing_files = expected_files.reject { |path| File.exist?(File.join(spec.full_gem_path, path)) }
          abort("missing installed contract files: \#{missing_files.join(', ')}") unless missing_files.empty?
          abort('loaded gem version mismatch') unless ActiveRecordOptimizer::VERSION == expected_version
          abort('loaded gem path is not isolated GEM_HOME') unless real_installed_gem_path.start_with?(ENV.fetch('REAL_GEM_HOME'))
          loaded_entry = $LOADED_FEATURES.find { |feature| feature.end_with?('/active_record_optimizer.rb') }
          loaded_entry_realpath = File.realpath(loaded_entry) if loaded_entry
          abort('top-level require did not resolve to installed gem') unless loaded_entry_realpath&.start_with?(real_installed_gem_path)

          report = ActiveRecordOptimizer::Report.new([])
          abort('smoke require failed to render JSON') unless report.render('json').include?('"schema_version"')
        RUBY
      end

      def run_command!(env, command, failure_message:, chdir:, allowed_exit_codes: [0])
        stdout, stderr, status = Open3.capture3(execution_env(env, chdir), *command, chdir: chdir)
        return stdout if allowed_exit_codes.include?(status.exitstatus)

        message = [
          failure_message,
          "Command: #{command.shelljoin}",
          "stdout:\n#{stdout}",
          "stderr:\n#{stderr}"
        ].join("\n\n")
        raise ActiveRecordOptimizer::Error, message
      end

      def sanitized_env
        ENV.to_h.reject do |key, _value|
          bundler_environment_key?(key)
        end
      end

      def base_gem_paths
        ([bundler_bundle_path] + Gem.path + [Gem.user_dir] + Gem.default_path).compact.uniq
      end

      def bundler_bundle_path
        return unless defined?(Bundler) && Bundler.respond_to?(:bundle_path)

        Bundler.bundle_path.to_s
      rescue Bundler::BundlerError
        nil
      end

      def bundler_configured_path
        return expanded_bundler_path(ENV.fetch('BUNDLE_PATH')) if ENV['BUNDLE_PATH']
        return unless defined?(Bundler) && Bundler.respond_to?(:settings)

        path = Bundler.settings[:path]
        expanded_bundler_path(path.to_s) unless path.to_s.empty?
      rescue Bundler::BundlerError
        nil
      end

      def expanded_bundler_path(path)
        return path if Pathname(path).absolute?
        return File.expand_path(path, Bundler.root) if defined?(Bundler) && Bundler.respond_to?(:root)

        File.expand_path(path)
      end

      def execution_env(env, chdir)
        bundler_unbundled_env.merge(unset_bundler_environment).merge(env).merge('PWD' => chdir)
      end

      def bundler_unbundled_env
        return Bundler.unbundled_env if defined?(Bundler) && Bundler.respond_to?(:unbundled_env)

        ENV.to_h
      end

      def bundler_environment_key?(key)
        key.start_with?('BUNDLE_', 'BUNDLER_') || %w[RUBYLIB RUBYOPT].include?(key)
      end

      def unset_bundler_environment
        ENV.keys.select { |key| bundler_environment_key?(key) }.to_h { |key| [key, nil] }
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
