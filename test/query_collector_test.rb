# frozen_string_literal: true

require 'test_helper'

FakeCollectorConnection = Struct.new(:quoted_values) do
  def quote(value)
    quoted_values << value
    return 'NULL' if value.nil?
    return value.to_s if value.is_a?(Numeric)

    "'#{value}'"
  end
end

module QueryCollectorTestSupport
  private

  def find_usage(usages, operation:, column:, table: nil)
    usages.find do |usage|
      usage.operation == operation &&
        usage.column == column &&
        (table.nil? || usage.table == table)
    end
  end

  def create_self_join_schema
    ActiveRecord::Schema.define do
      create_table :payments, force: true do |table|
        table.integer :parent_payment_id
        table.integer :status
        table.timestamps
      end
    end
  end

  def define_self_join_models
    TestModels.const_set(:Payment, Class.new(ActiveRecord::Base) do
      self.table_name = 'payments'
      belongs_to :parent_payment, class_name: 'TestModels::Payment', optional: true
    end)
  end
end

class QueryCollectorSqlParserTest < ActiveRecordOptimizerTest
  include QueryCollectorTestSupport

  def test_sql_literalizer_replaces_postgresql_placeholders
    connection = FakeCollectorConnection.new([])
    literalizer = ActiveRecordOptimizer::QueryCollector::SqlLiteralizer.new(connection: connection)

    sql = literalizer.call(
      sql: 'SELECT * FROM payments WHERE status = $1 AND reference = $2',
      binds: [1, 'paid']
    )

    assert_equal "SELECT * FROM payments WHERE status = 1 AND reference = 'paid'", sql
    assert_equal ['paid', 1], connection.quoted_values
  end

  def test_sql_parser_captures_jsonb_containment_as_jsonb_usage
    usages = ActiveRecordOptimizer::QueryCollector::SqlParser.new.call(
      sql: "SELECT \"payments\".* FROM \"payments\" WHERE metadata @> '{\"status\":\"paid\"}'",
      duration_ms: 12.0
    )

    jsonb_usage = find_usage(usages, operation: 'jsonb_where', column: 'metadata')

    refute_nil jsonb_usage
    refute find_usage(usages, operation: 'where', column: 'metadata')
  end

  def test_sql_parser_maps_aliased_base_table_columns_back_to_the_real_table
    usages = ActiveRecordOptimizer::QueryCollector::SqlParser.new.call(
      sql: 'SELECT "ap".* FROM "payments" "ap" ' \
           'WHERE "ap"."status" = 1 ORDER BY "ap"."created_at" DESC',
      duration_ms: 12.0
    )

    where_usage = find_usage(usages, operation: 'where', table: 'payments', column: 'status')
    order_usage = find_usage(usages, operation: 'order', table: 'payments', column: 'created_at')

    refute_nil where_usage
    refute_nil order_usage
    assert_equal ['status'], order_usage.where_columns
  end

  def test_sql_parser_captures_join_alias_columns_against_the_joined_table
    usages = ActiveRecordOptimizer::QueryCollector::SqlParser.new.call(
      sql: 'SELECT "payments".* FROM "payments" ' \
           'INNER JOIN "users" "payer" ON "payer"."id" = "payments"."payer_id" ' \
           'WHERE "payer"."status" = 1',
      duration_ms: 12.0
    )

    where_usage = find_usage(usages, operation: 'where', table: 'users', column: 'status')

    refute_nil where_usage
  end

  def test_sql_parser_captures_jsonb_usage_through_a_table_alias
    usages = ActiveRecordOptimizer::QueryCollector::SqlParser.new.call(
      sql: 'SELECT "ap".* FROM "payments" "ap" ' \
           'WHERE "ap"."metadata" @> \'{"status":"paid"}\'',
      duration_ms: 12.0
    )

    jsonb_usage = find_usage(usages, operation: 'jsonb_where', table: 'payments', column: 'metadata')

    refute_nil jsonb_usage
  end

  def test_sql_parser_maps_schema_qualified_table_references_back_to_the_base_table
    usages = ActiveRecordOptimizer::QueryCollector::SqlParser.new.call(
      sql: 'SELECT "payments".* FROM "analytics"."payments" ' \
           'WHERE "payments"."status" = 1 ORDER BY "payments"."created_at" DESC',
      duration_ms: 12.0
    )

    where_usage = find_usage(usages, operation: 'where', table: 'analytics.payments', column: 'status')
    order_usage = find_usage(usages, operation: 'order', table: 'analytics.payments', column: 'created_at')

    refute_nil where_usage
    refute_nil order_usage
    assert_equal ['status'], order_usage.where_columns
  end

  def test_sql_parser_captures_fully_qualified_jsonb_usage
    usages = ActiveRecordOptimizer::QueryCollector::SqlParser.new.call(
      sql: 'SELECT "analytics"."payments".* FROM "analytics"."payments" ' \
           'WHERE "analytics"."payments"."metadata" @> \'{"status":"paid"}\'',
      duration_ms: 12.0
    )

    jsonb_usage = find_usage(usages, operation: 'jsonb_where', table: 'analytics.payments', column: 'metadata')

    refute_nil jsonb_usage
  end
end

class QueryCollectorCaptureTest < ActiveRecordOptimizerTest
  include QueryCollectorTestSupport

  def test_capture_aggregates_runtime_query_usages
    create_schema(index_payment_user: true)
    define_payment_models

    snapshot = ActiveRecordOptimizer::QueryCollector.capture do
      TestModels::Payment.where(status: 1).order(created_at: :desc).load
      TestModels::Payment.where(status: 1).order(created_at: :desc).load
    end

    where_usage = find_usage(snapshot.query_usages, operation: 'where', column: 'status')
    order_usage = find_usage(snapshot.query_usages, operation: 'order', column: 'created_at')

    assert_runtime_usage(where_usage, count: 2, where_columns: [])
    assert_runtime_usage(order_usage, count: 2, where_columns: ['status'])
    assert_snapshot_metadata(snapshot, literalized_binds: false)
    assert_match(/SELECT/i, where_usage.source)
  end

  def test_capture_runtime_queries_writes_snapshot_when_path_is_given
    create_schema(index_payment_user: true)
    define_payment_models
    directory = Dir.mktmpdir
    path = File.join(directory, 'runtime_report.json')

    snapshot = ActiveRecordOptimizer.capture_runtime_queries(path: path) do
      TestModels::Payment.where(status: 1).load
    end

    assert File.exist?(path)
    assert_equal 1, snapshot.query_usages.size
    assert_nil snapshot.query_usages.first.explain_source
    assert_snapshot_metadata(snapshot, literalized_binds: false)
  ensure
    FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
  end

  def test_capture_runtime_queries_can_persist_explainable_sql_when_opted_in
    create_schema(index_payment_user: true)
    define_payment_models
    directory = Dir.mktmpdir
    path = File.join(directory, 'runtime_report.json')

    snapshot = ActiveRecordOptimizer.capture_runtime_queries(path: path, literalize_binds: true) do
      TestModels::Payment.where(status: 1).load
    end

    refute_nil snapshot.query_usages.first.explain_source
    assert_snapshot_metadata(snapshot, literalized_binds: true)
  ensure
    FileUtils.remove_entry(directory) if directory && Dir.exist?(directory)
  end

  def test_capture_keeps_where_columns_scoped_to_the_ordered_alias_in_self_join_queries
    create_self_join_schema
    define_self_join_models

    snapshot = ActiveRecordOptimizer::QueryCollector.capture do
      TestModels::Payment.joins(:parent_payment)
                         .where(parent_payment: { status: 1 })
                         .order(created_at: :desc)
                         .load
    end

    order_usage = find_usage(snapshot.query_usages, operation: 'order', table: 'payments', column: 'created_at')

    refute_nil order_usage
    assert_equal [], order_usage.where_columns
    assert_match(/INNER JOIN "payments" AS "parent_payment"/, order_usage.source)
  end

  private

  def assert_runtime_usage(usage, count:, where_columns:)
    assert_equal 'runtime', usage.origin
    assert_equal count, usage.count
    assert_equal where_columns, usage.where_columns
  end

  def assert_snapshot_metadata(snapshot, literalized_binds:)
    assert_equal ActiveRecordOptimizer::QueryCollector::Snapshot::JSON_SCHEMA_VERSION, snapshot.metadata[:schema_version]
    assert_equal literalized_binds, snapshot.metadata.dig(:capture, :literalized_binds)
  end
end
