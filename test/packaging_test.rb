# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'json_schemer'
require 'pathname'
require 'tmpdir'
require 'test_helper'
require 'active_record_optimizer/package_audit'

class PackagingTest < Minitest::Test
  def test_built_gem_includes_published_contract_artifacts
    with_built_package do |gem_path|
      files = ActiveRecordOptimizer::PackageAudit.package_contents(gem_path)

      ActiveRecordOptimizer::PackageAudit::PUBLIC_CONTRACT_FILES.each do |path|
        assert_includes files, path
      end
    end
  end

  def test_built_gem_includes_public_study_docs
    with_built_package do |gem_path|
      files = ActiveRecordOptimizer::PackageAudit.package_contents(gem_path)

      ActiveRecordOptimizer::PackageAudit::PUBLIC_DOCS.each do |path|
        assert_includes files, path
      end
    end
  end

  def test_built_gem_does_not_include_package_audit_harness
    with_built_package do |gem_path|
      files = ActiveRecordOptimizer::PackageAudit.package_contents(gem_path)
      includes_package_audit = files.any? { |path| path.start_with?('lib/active_record_optimizer/package_audit') }

      assert_equal false, includes_package_audit
    end
  end

  def test_built_public_docs_do_not_embed_absolute_local_paths
    with_built_package do |gem_path|
      ActiveRecordOptimizer::PackageAudit.packaged_public_docs(gem_path) do |docs|
        docs.each_value do |contents|
          refute_match ActiveRecordOptimizer::PackageAudit::ABSOLUTE_LOCAL_LINK_PATTERN, contents
        end
      end
    end
  end

  def test_gemspec_public_metadata_points_to_public_github_repository
    spec = Gem::Specification.load(File.join(project_root, 'active_record_optimizer.gemspec'))

    assert_equal 'https://github.com/Defyland/active_record_optimizer#active-record-optimizer', spec.homepage
    assert_equal ['2706523+Defyland@users.noreply.github.com'], spec.email
    assert_equal 'https://github.com/Defyland/active_record_optimizer', spec.metadata.fetch('source_code_uri')
    assert_equal 'https://github.com/Defyland/active_record_optimizer#readme', spec.metadata.fetch('documentation_uri')
    assert_equal 'https://github.com/Defyland/active_record_optimizer/issues', spec.metadata.fetch('bug_tracker_uri')
  end

  def test_package_audit_verifies_built_gem
    ActiveRecordOptimizer::PackageAudit.verify!(root: project_root)
  end

  def test_package_smoke_keeps_current_bundle_path_available_to_host_apps
    skip 'Bundler bundle path is unavailable.' unless defined?(Bundler) && Bundler.respond_to?(:bundle_path)

    assert_includes ActiveRecordOptimizer::PackageAudit::Smoke.base_gem_paths.map { |path| File.expand_path(path) },
                    File.expand_path(Bundler.bundle_path.to_s)
  end

  def test_built_gem_runtime_snapshot_matches_packaged_schema_inside_host_app
    with_built_package do |gem_path|
      Dir.mktmpdir do |directory|
        app_root = File.join(directory, 'host_app')
        gem_home = File.join(directory, 'gems')
        FileUtils.mkdir_p(gem_home)

        env = ActiveRecordOptimizer::PackageAudit::HostAppSmoke.host_app_env
        installed_spec = ActiveRecordOptimizer::PackageAudit::Smoke.install_built_gem!(gem_path, gem_home)
        ActiveRecordOptimizer::PackageAudit::HostAppSmoke.create_host_app!(directory, app_root, env)
        bundler_gem_path = ActiveRecordOptimizer::PackageAudit::HostAppSmoke.unpack_built_gem_for_bundler!(
          app_root,
          gem_path,
          installed_spec
        )
        ActiveRecordOptimizer::PackageAudit::HostAppSmoke.write_host_app_files!(app_root, bundler_gem_path: bundler_gem_path)

        bundle_env = ActiveRecordOptimizer::PackageAudit::HostAppSmoke.host_app_bundle_env(app_root, gem_home)
        ActiveRecordOptimizer::PackageAudit::HostAppSmoke.run_bundle!(app_root, bundle_env, 'install', '--local')
        ActiveRecordOptimizer::PackageAudit::HostAppSmoke.verify_loaded_gem!(
          app_root,
          bundle_env,
          expected_version: installed_spec.version,
          expected_gem_path: bundler_gem_path
        )
        ActiveRecordOptimizer::PackageAudit::HostAppSmoke.run_bundle!(app_root, bundle_env, 'exec', 'bin/rails', 'db:migrate')
        ActiveRecordOptimizer::PackageAudit::HostAppSmoke.run_bundle!(
          app_root,
          bundle_env,
          'exec',
          'bin/rails',
          'runner',
          'tmp/runtime_capture.rb'
        )

        payload = JSON.parse(File.read(File.join(app_root, 'tmp/active_record_optimizer.runtime.json')))

        assert_equal ActiveRecordOptimizer::QueryCollector::Snapshot::JSON_SCHEMA_VERSION,
                     payload.dig('metadata', 'schema_version')
        assert_valid_against_packaged_schema(gem_path, payload, 'docs/runtime-query-snapshot-schema-v2.json')
      end
    end
  end

  def test_host_app_smoke_rejects_runtime_snapshot_that_violates_packaged_schema
    with_built_package do |gem_path|
      Dir.mktmpdir do |directory|
        app_root = File.join(directory, 'host_app')
        gem_home = File.join(directory, 'gems')
        snapshot_path = File.join(app_root, 'tmp/active_record_optimizer.runtime.json')

        FileUtils.mkdir_p(File.dirname(snapshot_path))
        FileUtils.mkdir_p(gem_home)

        installed_spec = ActiveRecordOptimizer::PackageAudit::Smoke.install_built_gem!(gem_path, gem_home)
        File.write(
          snapshot_path,
          JSON.pretty_generate(
            runtime_snapshot_payload.merge('unexpected_top_level' => true)
          )
        )

        assert_equal 1, ActiveRecordOptimizer::RuntimeQueryLoader.new(path: snapshot_path).load_result.query_usages.size

        error = assert_raises(ActiveRecordOptimizer::Error) do
          ActiveRecordOptimizer::PackageAudit::HostAppSmoke.verify_runtime_snapshot!(
            app_root,
            installed_gem_path: installed_spec.full_gem_path,
            literalized_binds: false
          )
        end

        assert_includes error.message, 'packaged schema'
        assert_includes error.message, 'unexpected_top_level'
      end
    end
  end

  def test_with_built_package_uses_isolated_artifact_path
    FileUtils.rm_f(root_built_package_path)

    with_built_package do |gem_path|
      refute_equal root_built_package_path, gem_path
      assert File.exist?(gem_path)
      refute File.exist?(root_built_package_path)
    end

    refute File.exist?(root_built_package_path)
  end

  private

  def project_root
    File.expand_path('..', __dir__)
  end

  def with_built_package(&)
    ActiveRecordOptimizer::PackageAudit.with_built_package(root: project_root, &)
  end

  def root_built_package_path
    spec = Gem::Specification.load(File.join(project_root, 'active_record_optimizer.gemspec'))
    File.join(project_root, "#{spec.full_name}.gem")
  end

  def assert_valid_against_packaged_schema(gem_path, payload, schema_relative_path)
    Dir.mktmpdir do |directory|
      Gem::Package.new(gem_path).extract_files(directory)
      schema_path = File.join(directory, schema_relative_path)
      errors = JSONSchemer.schema(Pathname(schema_path)).validate(payload).to_a

      assert_empty errors, "Expected payload to match packaged #{schema_relative_path}, got: #{errors.inspect}"
    end
  end

  def runtime_snapshot_payload
    {
      'metadata' => {
        'schema_version' => ActiveRecordOptimizer::QueryCollector::Snapshot::JSON_SCHEMA_VERSION,
        'generator' => {
          'name' => 'active_record_optimizer',
          'version' => ActiveRecordOptimizer::VERSION
        },
        'capture' => {
          'literalized_binds' => false
        }
      },
      'queries' => [],
      'query_usages' => [runtime_usage_payload]
    }
  end

  def runtime_usage_payload
    {
      'table' => 'payments',
      'column' => 'status',
      'operation' => 'where',
      'source' => 'SELECT "payments".* FROM "payments" WHERE "payments"."status" = 1',
      'origin' => 'runtime',
      'count' => 2,
      'total_duration_ms' => 4.2,
      'path' => nil,
      'line' => nil,
      'explain_source' => nil,
      'plan_summary' => nil,
      'plan_root_node_type' => nil,
      'plan_relation_node_type' => nil,
      'plan_relation_name' => nil,
      'plan_rows' => nil,
      'where_columns' => []
    }
  end
end
