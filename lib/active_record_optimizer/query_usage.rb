# frozen_string_literal: true

module ActiveRecordOptimizer
  QueryUsage = Data.define(
    :table,
    :column,
    :operation,
    :source,
    :origin,
    :count,
    :total_duration_ms,
    :path,
    :line,
    :explain_source,
    :plan_summary,
    :plan_root_node_type,
    :plan_relation_node_type,
    :plan_relation_name,
    :plan_rows,
    :where_columns
  ) do
    def self.source(**attributes)
      new(
        table: attributes.fetch(:table),
        column: attributes.fetch(:column),
        operation: attributes.fetch(:operation),
        source: attributes.fetch(:source),
        origin: 'source',
        count: 1,
        total_duration_ms: nil,
        path: attributes.fetch(:path),
        line: attributes.fetch(:line),
        explain_source: nil,
        plan_summary: nil,
        plan_root_node_type: nil,
        plan_relation_node_type: nil,
        plan_relation_name: nil,
        plan_rows: nil,
        where_columns: attributes.fetch(:where_columns, [])
      )
    end

    def self.runtime(**attributes)
      new(
        table: attributes.fetch(:table),
        column: attributes.fetch(:column),
        operation: attributes.fetch(:operation),
        source: attributes.fetch(:source),
        origin: 'runtime',
        count: attributes.fetch(:count),
        total_duration_ms: attributes.fetch(:total_duration_ms),
        path: nil,
        line: nil,
        explain_source: attributes.fetch(:explain_source, nil),
        plan_summary: attributes.fetch(:plan_summary, nil),
        plan_root_node_type: attributes.fetch(:plan_root_node_type, nil),
        plan_relation_node_type: attributes.fetch(:plan_relation_node_type, nil),
        plan_relation_name: attributes.fetch(:plan_relation_name, nil),
        plan_rows: attributes.fetch(:plan_rows, nil),
        where_columns: attributes.fetch(:where_columns, [])
      )
    end

    def to_h
      {
        table: table,
        column: column,
        operation: operation,
        source: source,
        origin: origin,
        count: count,
        total_duration_ms: total_duration_ms,
        path: path,
        line: line,
        explain_source: explain_source,
        plan_summary: plan_summary,
        plan_root_node_type: plan_root_node_type,
        plan_relation_node_type: plan_relation_node_type,
        plan_relation_name: plan_relation_name,
        plan_rows: plan_rows,
        where_columns: where_columns
      }
    end
  end
end
