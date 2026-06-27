# frozen_string_literal: true

require 'fileutils'
require 'rubygems/package'
require 'rubygems/user_interaction'
require 'tmpdir'
require_relative 'package_audit/host_app_smoke'
require_relative 'package_audit/smoke'

module ActiveRecordOptimizer
  module PackageAudit
    PUBLIC_CONTRACT_FILES = %w[
      docs/contract-versioning.md
      docs/json-report-schema-v1.json
      docs/runtime-query-snapshot-schema-v1.json
      docs/runtime-query-snapshot-schema-v2.json
    ].freeze
    PUBLIC_DOCS = %w[README.md docs/contract-versioning.md].freeze
    ABSOLUTE_LOCAL_LINK_PATTERN = %r{\(/Users/}

    module_function

    def verify!(root:)
      with_built_package(root: root) do |gem_path|
        verify_built_package_artifacts!(gem_path)
        Dir.mktmpdir do |directory|
          host_app_gem_path = File.join(directory, File.basename(gem_path))
          FileUtils.cp(gem_path, host_app_gem_path)
          Smoke.verify!(gem_path: gem_path)
          HostAppSmoke.verify!(gem_path: host_app_gem_path)
        end
      end
    end

    def verify_postgresql!(root:, connection_config:)
      with_built_package(root: root) do |gem_path|
        verify_built_package_artifacts!(gem_path)
        Dir.mktmpdir do |directory|
          host_app_gem_path = File.join(directory, File.basename(gem_path))
          FileUtils.cp(gem_path, host_app_gem_path)
          Smoke.verify!(gem_path: gem_path)
          HostAppSmoke.verify_postgresql!(gem_path: host_app_gem_path, connection_config: connection_config)
        end
      end
    end

    def with_built_package(root:)
      Dir.mktmpdir('active_record_optimizer-package') do |directory|
        yield build_package(root: root, build_directory: directory)
      end
    end

    def build_package(root:, build_directory:)
      spec_path = File.join(root, 'active_record_optimizer.gemspec')
      spec = Gem::Specification.load(spec_path)
      raise ActiveRecordOptimizer::Error, "Could not load gemspec at #{spec_path}." unless spec

      isolated_gem_path = File.join(build_directory, "#{spec.full_name}.gem")
      Dir.chdir(root) do
        Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
          Gem::Package.build(spec, false, false, isolated_gem_path)
        end
      end
      isolated_gem_path
    end

    def package_contents(gem_path)
      Gem::Package.new(gem_path).contents
    end

    def packaged_public_docs(gem_path)
      Dir.mktmpdir do |directory|
        Gem::Package.new(gem_path).extract_files(directory)
        yield PUBLIC_DOCS.to_h { |path| [path, File.read(File.join(directory, path))] }
      end
    end

    def verify_built_package_artifacts!(gem_path)
      contents = package_contents(gem_path)
      verify_packaged_contract_files!(contents)
      verify_public_docs!(gem_path)
    end

    def verify_packaged_contract_files!(contents)
      missing = PUBLIC_CONTRACT_FILES - contents
      return if missing.empty?

      raise ActiveRecordOptimizer::Error, "Built gem is missing public contract files: #{missing.join(', ')}."
    end

    def verify_public_docs!(gem_path)
      packaged_public_docs(gem_path) do |docs|
        offending_paths = docs.filter_map do |path, contents|
          path if contents.match?(ABSOLUTE_LOCAL_LINK_PATTERN)
        end

        next if offending_paths.empty?

        raise ActiveRecordOptimizer::Error,
              "Built gem contains absolute local links in public docs: #{offending_paths.join(', ')}."
      end
    end
  end
end
