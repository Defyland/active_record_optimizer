# frozen_string_literal: true

require 'json'
require 'open3'
require 'test_helper'

class HostAppIntegrationTest < Minitest::Test
  include HostAppCommandSupport
  include HostAppFixtureSupport
  include HostAppGeneratorSupport

  def test_bin_rails_command_runs_inside_generated_host_app_with_project_config
    with_host_app do |app_root|
      replace_gemfile(app_root)
      write_host_app_files(app_root)

      run_bundle_command!(app_root, 'install')
      run_bundle_command!(app_root, 'exec', 'bin/rails', 'db:migrate')

      stdout, stderr, status = capture_command(
        app_root,
        bundle_command('exec', 'bin/rails', 'active_record:optimize', '--fail-on', 'high')
      )

      assert_equal 1, status.exitstatus
      assert_empty stderr

      payload = JSON.parse(stdout)
      finding_codes = payload.fetch('findings').map { |finding| finding.fetch('code') }

      assert_equal 1, payload.dig('metadata', 'schema_version')
      assert_equal ['missing_foreign_key_constraint'], finding_codes
      assert_equal({ 'high' => 1 }, payload.fetch('counts'))
    end
  end

  def test_runtime_query_capture_writes_current_snapshot_contract_inside_generated_host_app
    with_host_app do |app_root|
      replace_gemfile(app_root)
      write_host_app_files(app_root)
      write_runtime_capture_script(app_root)

      run_bundle_command!(app_root, 'install')
      run_bundle_command!(app_root, 'exec', 'bin/rails', 'db:migrate')
      run_bundle_command!(app_root, 'exec', 'bin/rails', 'runner', 'tmp/runtime_capture.rb')

      payload = JSON.parse(File.read(File.join(app_root, 'tmp/active_record_optimizer.runtime.json')))
      load_result = ActiveRecordOptimizer::RuntimeQueryLoader
                    .new(path: File.join(app_root, 'tmp/active_record_optimizer.runtime.json'))
                    .load_result

      assert_equal ActiveRecordOptimizer::QueryCollector::Snapshot::JSON_SCHEMA_VERSION,
                   payload.dig('metadata', 'schema_version')
      assert_equal false, payload.dig('metadata', 'capture', 'literalized_binds')
      assert_operator load_result.query_usages.size, :>=, 1
      assert_valid_against_schema(payload, 'runtime-query-snapshot-schema-v2.json')
    end
  end
end
