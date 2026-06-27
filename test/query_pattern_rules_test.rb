# frozen_string_literal: true

require 'test_helper'

module QueryPatternRulesTestSupport
  private

  def finding_for(context, code)
    ActiveRecordOptimizer::Rules::QueryPatternRules.new.call(context).find { |entry| entry.code == code }
  end

  def context_for_runtime_usage(attributes = {})
    planner = attributes.fetch(:planner, {})
    configuration = ActiveRecordOptimizer::Configuration.new
    configuration.planner_row_threshold = 1000
    configuration.where_occurrence_threshold = 2

    ActiveRecordOptimizer::Runner::Context.new(
      schema: ActiveRecordOptimizer::SchemaScanner::Schema.new(
        tables: { 'payments' => payments_table(indexes: attributes.fetch(:indexes, [])) }
      ),
      models: [payment_model],
      query_usages: [runtime_usage(attributes, planner)],
      migration_changes: [],
      configuration: configuration
    )
  end

  def payments_table(indexes: [])
    ActiveRecordOptimizer::SchemaScanner::Table.new(
      name: 'payments',
      primary_key: 'id',
      columns: {
        'id' => column('id', :integer, 'integer', nullable: false),
        'account_id' => column('account_id', :integer, 'integer'),
        'metadata' => column('metadata', :jsonb, 'jsonb'),
        'status' => column('status', :integer, 'integer'),
        'created_at' => column('created_at', :datetime, 'datetime')
      },
      indexes: indexes,
      foreign_keys: [],
      estimated_row_count: nil
    )
  end

  def payment_model
    ActiveRecordOptimizer::ModelScanner::Model.new(
      klass: nil,
      name: 'Payment',
      table_name: 'payments',
      reflections: [],
      default_scopes: [],
      defined_enums: { 'status' => { 'pending' => '0', 'paid' => '1' } },
      source_location: nil
    )
  end

  def runtime_usage(attributes, planner)
    ActiveRecordOptimizer::QueryUsage.runtime(
      table: 'payments',
      column: attributes.fetch(:column, 'status'),
      operation: attributes.fetch(:operation),
      source: attributes.fetch(:source, 'SELECT "payments".* FROM "payments" WHERE "payments"."status" = 1'),
      count: 3,
      total_duration_ms: 12.0,
      plan_summary: 'postgresql plan: Seq Scan on payments rows=50000 cost=0.00..100.00',
      plan_root_node_type: planner[:plan_root_node_type],
      plan_relation_node_type: planner[:plan_relation_node_type],
      plan_relation_name: planner[:plan_relation_name],
      plan_rows: attributes.fetch(:plan_rows, 50_000),
      where_columns: attributes.fetch(:where_columns, [])
    )
  end

  def column(name, type, sql_type, nullable: true)
    ActiveRecordOptimizer::SchemaScanner::Column.new(name: name, type: type, sql_type: sql_type, null: nullable)
  end
end

class QueryPatternRulesTest < Minitest::Test
  include QueryPatternRulesTestSupport

  def test_seq_scan_promotes_recurring_where_finding_to_high
    context = context_for_runtime_usage(
      operation: 'where',
      column: 'account_id',
      source: 'SELECT "payments".* FROM "payments" WHERE "payments"."account_id" = 7',
      planner: { plan_relation_node_type: 'Seq Scan', plan_relation_name: 'payments' }
    )

    finding = finding_for(context, 'recurring_where_without_index')

    refute_nil finding
    assert_equal 'high', finding.severity
    assert_equal 'Seq Scan', finding.details[:plan_relation_node_type]
  end

  def test_sort_promotes_order_finding_to_high
    context = context_for_runtime_usage(
      operation: 'order',
      column: 'created_at',
      where_columns: ['status'],
      planner: {
        plan_root_node_type: 'Sort',
        plan_relation_node_type: 'Seq Scan',
        plan_relation_name: 'payments'
      }
    )

    finding = finding_for(context, 'order_without_index')

    refute_nil finding
    assert_equal 'high', finding.severity
    assert_equal 'Sort', finding.details[:plan_root_node_type]
  end

  def test_composite_index_on_where_plus_order_suppresses_order_finding
    context = context_for_runtime_usage(
      operation: 'order',
      column: 'created_at',
      source: 'SELECT "payments".* FROM "payments" ' \
              'WHERE "payments"."status" = 1 AND "payments"."account_id" = 7 ' \
              'ORDER BY "payments"."created_at" DESC',
      where_columns: %w[status account_id],
      indexes: [
        ActiveRecordOptimizer::SchemaScanner::Index.new(
          name: 'index_payments_on_account_status_created_at',
          columns: %w[account_id status created_at],
          unique: false,
          using: nil,
          orders: nil,
          opclasses: nil,
          where: nil
        )
      ]
    )

    finding = finding_for(context, 'order_without_index')

    assert_nil finding
  end

  def test_primary_key_where_does_not_report_missing_index
    context = context_for_runtime_usage(
      operation: 'where',
      column: 'id',
      source: 'SELECT "payments".* FROM "payments" WHERE "payments"."id" = 42'
    )

    finding = finding_for(context, 'recurring_where_without_index')

    assert_nil finding
  end

  def test_primary_key_order_does_not_report_missing_index
    context = context_for_runtime_usage(
      operation: 'order',
      column: 'id',
      source: 'SELECT "payments".* FROM "payments" ORDER BY "payments"."id" DESC'
    )

    finding = finding_for(context, 'order_without_index')

    assert_nil finding
  end

  def test_enum_where_uses_specific_finding_without_duplicate_generic_finding
    context = context_for_runtime_usage(
      operation: 'where',
      column: 'status',
      source: 'SELECT "payments".* FROM "payments" WHERE "payments"."status" = 1'
    )

    findings = ActiveRecordOptimizer::Rules::QueryPatternRules.new.call(context)

    assert_includes findings.map(&:code), 'enum_where_without_index'
    refute_includes findings.map(&:code), 'recurring_where_without_index'
  end

  def test_btree_index_on_jsonb_column_does_not_suppress_expression_query_finding
    context = context_for_runtime_usage(
      operation: 'jsonb_where',
      column: 'metadata',
      source: "SELECT \"payments\".* FROM \"payments\" WHERE metadata ->> 'status' = 'paid'",
      indexes: [
        ActiveRecordOptimizer::SchemaScanner::Index.new(
          name: 'index_payments_on_metadata',
          columns: ['metadata'],
          unique: false,
          using: :btree,
          orders: nil,
          opclasses: nil,
          where: nil
        )
      ]
    )

    finding = finding_for(context, 'jsonb_query_without_index')

    refute_nil finding
  end

  def test_whole_column_gin_index_suppresses_jsonb_containment_finding
    context = context_for_runtime_usage(
      operation: 'jsonb_where',
      column: 'metadata',
      source: "SELECT \"payments\".* FROM \"payments\" WHERE metadata @> '{\"status\":\"paid\"}'",
      indexes: [
        ActiveRecordOptimizer::SchemaScanner::Index.new(
          name: 'index_payments_on_metadata_gin',
          columns: ['metadata'],
          unique: false,
          using: :gin,
          orders: nil,
          opclasses: nil,
          where: nil
        )
      ]
    )

    finding = finding_for(context, 'jsonb_query_without_index')

    assert_nil finding
  end
end
