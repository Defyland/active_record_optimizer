# frozen_string_literal: true

module ActiveRecordOptimizer
  class TableNameResolver
    UNKNOWN_SCHEMA_RANK = 1_000_000

    def initialize(schema_table_names:, model_table_names:, connection: ActiveRecord::Base.connection)
      @connection = connection
      @known_table_names = (schema_table_names + model_table_names).map(&:to_s).uniq
      @search_path_schemas = load_search_path_schemas
    end

    def canonicalize(name)
      table_name = name.to_s
      return table_name if table_name.empty?
      return table_name if qualified?(table_name)

      candidates = known_table_names.select { |candidate| base_table_name(candidate) == table_name }
      resolve_unqualified(table_name, candidates)
    end

    def canonicalize_query_usage(usage)
      canonical_table = canonicalize(usage.table)
      canonical_plan_relation_name = canonicalize(usage.plan_relation_name)

      return usage unless canonical_table != usage.table || canonical_plan_relation_name != usage.plan_relation_name

      build_query_usage(usage, canonical_table, canonical_plan_relation_name)
    end

    private

    attr_reader :connection, :known_table_names, :search_path_schemas

    def build_query_usage(usage, canonical_table, canonical_plan_relation_name)
      return build_runtime_query_usage(usage, canonical_table, canonical_plan_relation_name) if usage.origin == 'runtime'

      build_source_query_usage(usage, canonical_table)
    end

    def resolve_unqualified(base_name, candidates)
      return base_name if candidates.empty?
      return candidates.first if candidates.one?

      resolved = search_path_candidates(candidates)
      resolved || base_name
    end

    def search_path_candidates(candidates)
      ordered_candidates = candidates
                           .map { |candidate| [candidate, schema_rank(candidate)] }
                           .reject { |_candidate, rank| rank == UNKNOWN_SCHEMA_RANK }
                           .sort_by(&:last)
      return nil if ordered_candidates.empty?

      ordered_candidates.first.first
    end

    def schema_rank(candidate)
      schema_name = split_table_identifier(candidate).first
      return UNKNOWN_SCHEMA_RANK unless schema_name

      search_path_schemas.index(schema_name) || UNKNOWN_SCHEMA_RANK
    end

    def load_search_path_schemas
      return [] unless connection.adapter_name.to_s.downcase == 'postgresql'

      connection.select_values('SELECT unnest(current_schemas(false))')
    rescue ActiveRecord::StatementInvalid
      []
    end

    def split_table_identifier(table_name)
      parts = table_name.to_s.split('.', 2)
      return [nil, table_name] if parts.size == 1

      parts
    end

    def base_table_name(table_name)
      split_table_identifier(table_name).last
    end

    def qualified?(table_name)
      table_name.to_s.include?('.')
    end

    def base_attributes(usage, canonical_table)
      {
        table: canonical_table,
        column: usage.column,
        operation: usage.operation,
        source: usage.source,
        where_columns: usage.where_columns
      }
    end

    def build_runtime_query_usage(usage, canonical_table, canonical_plan_relation_name)
      QueryUsage.runtime(
        **base_attributes(usage, canonical_table),
        count: usage.count,
        total_duration_ms: usage.total_duration_ms,
        explain_source: usage.explain_source,
        plan_summary: usage.plan_summary,
        plan_root_node_type: usage.plan_root_node_type,
        plan_relation_node_type: usage.plan_relation_node_type,
        plan_relation_name: canonical_plan_relation_name,
        plan_rows: usage.plan_rows
      )
    end

    def build_source_query_usage(usage, canonical_table)
      QueryUsage.source(
        **base_attributes(usage, canonical_table),
        path: usage.path,
        line: usage.line
      )
    end
  end
end
