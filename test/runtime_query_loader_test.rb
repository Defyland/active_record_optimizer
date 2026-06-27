# frozen_string_literal: true

require 'test_helper'

module RuntimeQueryLoaderTestSupport
  private

  def runtime_snapshot_payload(schema_version: ActiveRecordOptimizer::QueryCollector::Snapshot::JSON_SCHEMA_VERSION,
                               **overrides)
    {
      metadata: {
        schema_version: schema_version,
        generator: {
          name: 'active_record_optimizer',
          version: ActiveRecordOptimizer::VERSION
        },
        capture: {
          literalized_binds: false
        }
      },
      queries: [],
      query_usages: [runtime_usage_payload]
    }.merge(overrides)
  end

  def runtime_usage_payload(overrides = {})
    {
      table: 'payments',
      column: 'status',
      operation: 'where',
      source: 'SELECT "payments".* FROM "payments" WHERE "payments"."status" = 1',
      origin: 'runtime',
      count: 2,
      total_duration_ms: 4.2,
      path: nil,
      line: nil,
      explain_source: nil,
      plan_summary: nil,
      plan_root_node_type: nil,
      plan_relation_node_type: nil,
      plan_relation_name: nil,
      plan_rows: nil,
      where_columns: []
    }.merge(overrides)
  end
end

class RuntimeQueryLoaderRoundTripTest < ActiveRecordOptimizerTest
  include RuntimeQueryLoaderTestSupport

  def test_snapshot_write_and_runtime_loader_round_trip
    create_schema(index_payment_user: true)
    define_payment_models
    directory = Dir.mktmpdir
    path = File.join(directory, 'runtime_report.json')

    snapshot = ActiveRecordOptimizer::QueryCollector.capture do
      TestModels::Payment.where(status: 1).load
    end
    snapshot.write(path)

    payload = JSON.parse(File.read(path))
    usages = ActiveRecordOptimizer::RuntimeQueryLoader.new(path: path).load

    assert_runtime_snapshot_payload(payload, literalized_binds: false)
    assert_runtime_usage(usages.first, column: 'status', where_columns: [])
    assert_valid_against_schema(payload, 'runtime-query-snapshot-schema-v2.json')
  ensure
    FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
  end

  def test_runtime_query_loader_accepts_supported_v1_snapshot
    directory = Dir.mktmpdir
    path = File.join(directory, 'runtime_report.json')
    payload = runtime_snapshot_payload(schema_version: 1)
    File.write(path, JSON.pretty_generate(payload))

    usages = ActiveRecordOptimizer::RuntimeQueryLoader.new(path: path).load

    assert_runtime_usage(usages.first, column: 'status', where_columns: [])
  ensure
    FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
  end

  def test_runtime_query_loader_accepts_legacy_snapshot_without_metadata
    directory = Dir.mktmpdir
    path = File.join(directory, 'runtime_report.json')
    File.write(
      path,
      JSON.pretty_generate(
        query_usages: [
          {
            table: 'payments',
            column: 'status',
            operation: 'where',
            source: 'SELECT "payments".* FROM "payments" WHERE "payments"."status" = 1',
            origin: 'runtime',
            count: 2,
            total_duration_ms: 4.2
          }
        ]
      )
    )

    usages = ActiveRecordOptimizer::RuntimeQueryLoader.new(path: path).load

    assert_runtime_usage(usages.first, column: 'status', where_columns: [])
  ensure
    FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
  end

  def test_runtime_query_loader_raises_clear_error_for_invalid_json
    directory = Dir.mktmpdir
    path = File.join(directory, 'runtime_report.json')
    File.write(path, '{invalid json')

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::RuntimeQueryLoader.new(path: path).load
    end

    assert_includes error.message, 'is not valid JSON'
  ensure
    FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
  end

  def test_runtime_query_loader_raises_clear_error_for_missing_file
    path = File.join(Dir.mktmpdir, 'missing-runtime-report.json')

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::RuntimeQueryLoader.new(path: path).load
    end

    assert_includes error.message, 'not found'
  end

  def test_runtime_query_loader_raises_clear_error_for_unsupported_schema_version
    directory = Dir.mktmpdir
    path = File.join(directory, 'runtime_report.json')
    File.write(
      path,
      JSON.pretty_generate(
        metadata: { schema_version: 99 },
        queries: [],
        query_usages: []
      )
    )

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::RuntimeQueryLoader.new(path: path).load
    end

    assert_includes error.message, 'unsupported schema version'
    assert_includes error.message, ActiveRecordOptimizer::RuntimeQueryLoader::SUPPORTED_SCHEMA_VERSIONS.join(', ')
  ensure
    FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
  end

  def test_runtime_snapshot_schema_artifact_matches_snapshot_version
    schema = JSON.parse(File.read(File.expand_path('../docs/runtime-query-snapshot-schema-v2.json', __dir__)))

    assert_equal ActiveRecordOptimizer::QueryCollector::Snapshot::JSON_SCHEMA_VERSION,
                 schema.dig('properties', 'metadata', 'properties', 'schema_version', 'const')
  end

  private

  def assert_runtime_snapshot_payload(payload, literalized_binds:)
    assert_equal ActiveRecordOptimizer::QueryCollector::Snapshot::JSON_SCHEMA_VERSION,
                 payload.dig('metadata', 'schema_version')
    assert_equal 'active_record_optimizer', payload.dig('metadata', 'generator', 'name')
    assert_equal literalized_binds, payload.dig('metadata', 'capture', 'literalized_binds')
  end

  def assert_runtime_usage(usage, column:, where_columns:)
    assert_equal 'runtime', usage.origin
    assert_equal column, usage.column
    assert_nil usage.explain_source
    assert_nil usage.plan_summary
    assert_equal where_columns, usage.where_columns
  end
end

class RuntimeQueryLoaderValidationTest < ActiveRecordOptimizerTest
  include RuntimeQueryLoaderTestSupport

  def test_runtime_query_loader_load_result_exposes_metadata
    directory = Dir.mktmpdir
    path = File.join(directory, 'runtime_report.json')
    payload = runtime_snapshot_payload
    File.write(path, JSON.pretty_generate(payload))

    result = ActiveRecordOptimizer::RuntimeQueryLoader.new(path: path).load_result

    assert_equal ActiveRecordOptimizer::QueryCollector::Snapshot::JSON_SCHEMA_VERSION, result.metadata['schema_version']
    assert_equal 'active_record_optimizer', result.metadata.dig('generator', 'name')
    assert_equal 1, result.query_usages.size
  ensure
    FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
  end

  def test_runtime_query_loader_rejects_wrong_generator_name
    directory = Dir.mktmpdir
    path = File.join(directory, 'runtime_report.json')
    payload = runtime_snapshot_payload(
      metadata: runtime_snapshot_payload[:metadata].merge(
        generator: { name: 'other_tool', version: '1.0.0' }
      )
    )
    File.write(path, JSON.pretty_generate(payload))

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::RuntimeQueryLoader.new(path: path).load
    end

    assert_includes error.message, 'metadata.generator.name'
  ensure
    FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
  end

  def test_runtime_query_loader_rejects_non_runtime_usage_origin
    directory = Dir.mktmpdir
    path = File.join(directory, 'runtime_report.json')
    payload = runtime_snapshot_payload(query_usages: [runtime_usage_payload(origin: 'source')])
    File.write(path, JSON.pretty_generate(payload))

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::RuntimeQueryLoader.new(path: path).load
    end

    assert_includes error.message, 'query_usages[0].origin'
  ensure
    FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
  end

  def test_runtime_query_loader_rejects_non_array_where_columns
    directory = Dir.mktmpdir
    path = File.join(directory, 'runtime_report.json')
    payload = runtime_snapshot_payload(query_usages: [runtime_usage_payload(where_columns: 'status')])
    File.write(path, JSON.pretty_generate(payload))

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::RuntimeQueryLoader.new(path: path).load
    end

    assert_includes error.message, 'query_usages[0].where_columns'
  ensure
    FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
  end

  def test_runtime_query_loader_rejects_invalid_v2_numeric_semantics
    cases = [
      [
        'queries[0].duration_ms',
        runtime_snapshot_payload(
          queries: [{ sql: 'SELECT 1', name: nil, duration_ms: -0.1, explain_sql: nil }]
        )
      ],
      [
        'query_usages[0].count',
        runtime_snapshot_payload(query_usages: [runtime_usage_payload(count: 0)])
      ],
      [
        'query_usages[0].total_duration_ms',
        runtime_snapshot_payload(query_usages: [runtime_usage_payload(total_duration_ms: -1.0)])
      ],
      [
        'query_usages[0].plan_rows',
        runtime_snapshot_payload(query_usages: [runtime_usage_payload(plan_rows: -1)])
      ]
    ]

    cases.each do |field_path, payload|
      directory = Dir.mktmpdir
      path = File.join(directory, 'runtime_report.json')
      File.write(path, JSON.pretty_generate(payload))

      error = assert_raises(ActiveRecordOptimizer::Error) do
        ActiveRecordOptimizer::RuntimeQueryLoader.new(path: path).load
      end

      assert_includes error.message, field_path
    ensure
      FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
    end
  end
end
