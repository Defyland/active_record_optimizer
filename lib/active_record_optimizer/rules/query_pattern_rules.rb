# frozen_string_literal: true

require 'pathname'

module ActiveRecordOptimizer
  module Rules
    module QueryPatternRuleSupport
      private

      def planner_confirmed_seq_scan?(context, usages, table_name)
        usages.any? do |usage|
          usage.origin == 'runtime' &&
            usage.plan_relation_node_type == 'Seq Scan' &&
            usage.plan_relation_name == table_name &&
            plan_rows_at_or_above_threshold?(context, usage)
        end
      end

      def planner_confirmed_sort?(context, usages)
        usages.any? do |usage|
          usage.origin == 'runtime' &&
            usage.plan_root_node_type == 'Sort' &&
            plan_rows_at_or_above_threshold?(context, usage)
        end
      end

      def plan_rows_at_or_above_threshold?(context, usage)
        usage.plan_rows.to_i >= context.configuration.planner_row_threshold
      end

      def usage_evidence(usages)
        usages.first(3).map { |usage| format_usage(usage) }.join("\n")
      end

      def format_usage(usage)
        return source_usage_evidence(usage) if usage.origin == 'source'

        runtime_usage_evidence(usage)
      end

      def source_usage_evidence(usage)
        "#{relative_path(usage.path)}:#{usage.line} #{usage.source}"
      end

      def runtime_usage_evidence(usage)
        duration = usage.total_duration_ms ? " #{usage.total_duration_ms.round(2)}ms total" : ''
        plan_summary = usage.plan_summary ? "\nplan: #{usage.plan_summary}" : ''
        "runtime x#{usage.count}#{duration}: #{usage.source}#{plan_summary}"
      end

      def relative_path(path)
        return path unless defined?(Rails.root) && Rails.root

        Pathname(path).relative_path_from(Rails.root).to_s
      rescue ArgumentError
        path
      end

      def order_usage_supported?(table, usage)
        return true if leading_index_supported?(table, [usage.column])

        where_columns = Array(usage.where_columns)
        return false if where_columns.empty?

        table.indexes.any? { |index| composite_order_index_supports_usage?(index, usage.column, where_columns) }
      end

      def composite_order_index_supports_usage?(index, order_column, where_columns)
        order_position = index.columns.index(order_column)
        return false unless order_position
        return false if order_position.zero?

        leading_columns = index.columns.first(order_position)
        leading_columns.all? { |column| where_columns.include?(column) }
      end

      def leading_index_supported?(table, columns)
        primary_key_supports_columns?(table, columns) || index_starts_with?(table, columns)
      end

      def primary_key_supports_columns?(table, columns)
        columns == [table.primary_key]
      end

      def index_starts_with?(table, columns)
        table.indexes.any? { |index| index.columns.first(columns.size) == columns }
      end

      def grouped_usages(context, operation)
        context.query_usages
               .select { |usage| usage.operation == operation }
               .group_by { |usage| [usage.table, usage.column] }
      end

      def enum_columns(context)
        context.models.flat_map do |model|
          model.defined_enums.keys.map { |column| [model, column] }
        end
      end

      def enum_column_for_table?(context, table_name, column)
        context.models.any? do |model|
          model.table_name == table_name && model.defined_enums.key?(column)
        end
      end

      def model_for(context, table_name)
        context.models.find { |model| model.table_name == table_name }
      end

      def usage_count(usages)
        usages.sum(&:count)
      end
    end

    class QueryPatternRules
      include QueryPatternRuleSupport

      def call(context)
        recurring_where_findings(context) +
          enum_where_findings(context) +
          jsonb_findings(context) +
          order_findings(context)
      end

      private

      def recurring_where_findings(context)
        grouped_usages(context, 'where').filter_map do |(table_name, column), usages|
          table = context.schema.tables[table_name]
          next unless recurring_where_finding_needed?(context, table, table_name, column, usages)

          Finding.new(
            severity: planner_confirmed_seq_scan?(context, usages, table_name) ? 'high' : 'medium',
            code: 'recurring_where_without_index',
            title: 'Recurring where column without index',
            model: model_for(context, table_name)&.name,
            table: table_name,
            column: column,
            problem: 'Observed query patterns repeatedly filter on this column, but the schema has no compatible leading index.',
            recommendation: "Add an index if this query path is hot and selectivity is useful: add_index :#{table_name}, :#{column}",
            evidence: usage_evidence(usages),
            details: planner_details(context, usages)
          )
        end
      end

      def recurring_where_finding_needed?(context, table, table_name, column, usages)
        table &&
          !enum_column_for_table?(context, table_name, column) &&
          usage_count(usages) >= context.configuration.where_occurrence_threshold &&
          !leading_index_supported?(table, [column])
      end

      def enum_where_findings(context)
        enum_columns(context).filter_map do |model, column|
          usages = enum_where_usages(context, model, column)
          table = context.schema.tables[model.table_name]
          next if indexed_or_unused?(table, column, usages)

          Finding.new(
            severity: planner_confirmed_seq_scan?(context, usages, model.table_name) ? 'high' : 'medium',
            code: 'enum_where_without_index',
            title: 'Enum/status query without index',
            model: model.name,
            table: model.table_name,
            column: column,
            problem: 'The model defines an enum and observed queries filter by it, but the column has no compatible index.',
            recommendation: "Add an index when enum filters are selective: add_index :#{model.table_name}, :#{column}",
            evidence: usage_evidence(usages),
            details: planner_details(context, usages)
          )
        end
      end

      def enum_where_usages(context, model, column)
        context.query_usages.select do |usage|
          usage.operation == 'where' && usage.table == model.table_name && usage.column == column
        end
      end

      def indexed_or_unused?(table, column, usages)
        usages.empty? || !table || leading_index_supported?(table, [column])
      end

      def jsonb_findings(context)
        grouped_usages(context, 'jsonb_where').filter_map do |(table_name, column), usages|
          table = context.schema.tables[table_name]
          next unless table
          next if jsonb_index_matches?(table, column, usages)

          Finding.new(
            severity: planner_confirmed_seq_scan?(context, usages, table_name) ? 'high' : 'medium',
            code: 'jsonb_query_without_index',
            title: 'JSONB query without matching index',
            model: model_for(context, table_name)&.name,
            table: table_name,
            column: column,
            problem: 'Observed queries hit a JSONB column, but the schema has no matching whole-column or expression index evidence.',
            recommendation: 'Add an expression or GIN index that matches the actual JSONB operator and key path.',
            evidence: usage_evidence(usages),
            details: planner_details(context, usages)
          )
        end
      end

      def order_findings(context)
        grouped_usages(context, 'order').filter_map do |(table_name, column), usages|
          table = context.schema.tables[table_name]
          next unless table

          unsupported_usages = usages.reject { |usage| order_usage_supported?(table, usage) }
          next if unsupported_usages.empty?

          Finding.new(
            severity: planner_confirmed_sort?(context, unsupported_usages) ? 'high' : 'medium',
            code: 'order_without_index',
            title: 'Order column without compatible index',
            model: model_for(context, table_name)&.name,
            table: table_name,
            column: column,
            problem: 'Observed queries order by this column, but the schema has no compatible leading index.',
            recommendation: 'Add an index matching the WHERE + ORDER BY shape if this order is used on large result sets.',
            evidence: usage_evidence(unsupported_usages),
            details: planner_details(context, unsupported_usages)
          )
        end
      end

      def planner_details(context, usages)
        planner_usage = usages.find { |usage| usage.origin == 'runtime' && usage.plan_summary }
        return nil unless planner_usage

        {
          planner_confirmed: true,
          planner_row_threshold: context.configuration.planner_row_threshold,
          plan_root_node_type: planner_usage.plan_root_node_type,
          plan_relation_node_type: planner_usage.plan_relation_node_type,
          plan_relation_name: planner_usage.plan_relation_name,
          plan_rows: planner_usage.plan_rows
        }
      end

      def jsonb_index_matches?(table, column, usages)
        usages.all? do |usage|
          table.indexes.any? { |index| jsonb_index_supports_usage?(index, column, usage) }
        end
      end

      def jsonb_index_supports_usage?(index, column, usage)
        whole_column_jsonb_index_supports_usage?(index, column, usage) ||
          expression_index_matches_usage?(index, column, usage)
      end

      def whole_column_jsonb_index_supports_usage?(index, column, usage)
        index.columns.include?(column) &&
          gin_or_gist_index?(index) &&
          jsonb_containment_usage?(usage.source, column)
      end

      def expression_index_matches_usage?(index, column, usage)
        fragments = jsonb_source_fragments(usage.source, column)
        return false if fragments.empty?

        normalized_columns = index.columns.map { |indexed_column| normalize_jsonb_expression(indexed_column) }
        fragments.any? { |fragment| normalized_columns.any? { |indexed_column| indexed_column.include?(fragment) } }
      end

      def jsonb_source_fragments(source, column)
        source.scan(/#{Regexp.escape(column)}\s*(->>|->)\s*'([^']+)'/).map do |operator, key|
          normalize_jsonb_expression("#{column}#{operator}'#{key}'")
        end
      end

      def gin_or_gist_index?(index)
        %w[gin gist].include?(index.using.to_s.downcase)
      end

      def jsonb_containment_usage?(source, column)
        source.match?(/\b#{Regexp.escape(column)}\b\s*@>/)
      end

      def normalize_jsonb_expression(expression)
        expression.to_s.gsub('::text', '').gsub(/\s+/, '').delete('()')
      end
    end
  end
end
