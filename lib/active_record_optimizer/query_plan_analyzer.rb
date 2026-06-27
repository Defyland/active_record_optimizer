# frozen_string_literal: true

require 'json'

module ActiveRecordOptimizer
  class QueryPlanAnalyzer
    SUPPORTED_ROOT_KEYWORDS = %w[SELECT WITH].freeze

    def self.explainable_sql?(sql)
      statement = sql.to_s.strip
      return false if statement.empty?
      return false if statement.match?(/\$\d+/) || statement.include?('?')

      SUPPORTED_ROOT_KEYWORDS.include?(statement.split(/\s+/, 2).first.to_s.upcase)
    end

    def initialize(connection: ActiveRecord::Base.connection)
      @connection = connection
      @plan_summaries = {}
    end

    def annotate(query_usages)
      return query_usages unless postgresql?

      query_usages.map { |usage| annotated_usage(usage) }
    end

    private

    attr_reader :connection, :plan_summaries

    def postgresql?
      connection.adapter_name.to_s.downcase == 'postgresql'
    end

    def plan_data_for(sql)
      statement = sql.to_s.strip
      return nil if statement.empty?
      return nil unless explainable?(statement)
      return plan_summaries[statement] if plan_summaries.key?(statement)

      plan_summaries[statement] = explain_summary(statement)
    end

    def explainable?(statement)
      self.class.explainable_sql?(statement)
    end

    def explain_source_for(usage)
      usage.explain_source || usage.source
    end

    def explain_summary(statement)
      payload = connection.exec_query("EXPLAIN (FORMAT JSON) #{statement}")
      raw_plan = payload.rows.dig(0, 0)
      plan = parsed_plan(raw_plan)
      return nil unless plan

      relation_node = first_relation_node(plan)
      {
        summary: format_summary(plan, relation_node),
        root_node_type: plan['Node Type'],
        relation_node_type: relation_node&.dig('Node Type'),
        relation_name: relation_node&.dig('Relation Name'),
        plan_rows: plan['Plan Rows']
      }
    rescue ActiveRecord::StatementInvalid, JSON::ParserError
      nil
    end

    def parsed_plan(raw_plan)
      parsed = JSON.parse(raw_plan.to_s)
      parsed.first&.fetch('Plan', nil)
    end

    def annotated_usage(usage)
      return usage unless usage.origin == 'runtime'

      plan_data = plan_data_for(explain_source_for(usage))
      return usage unless plan_data

      QueryUsage.runtime(
        table: usage.table,
        column: usage.column,
        operation: usage.operation,
        source: usage.source,
        count: usage.count,
        total_duration_ms: usage.total_duration_ms,
        explain_source: usage.explain_source,
        plan_summary: plan_data.fetch(:summary),
        plan_root_node_type: plan_data[:root_node_type],
        plan_relation_node_type: plan_data[:relation_node_type],
        plan_relation_name: plan_data[:relation_name],
        plan_rows: plan_data[:plan_rows],
        where_columns: usage.where_columns
      )
    end

    def format_summary(plan, relation_node)
      segments = [node_label(plan)]
      segments << "over #{node_label(relation_node)}" if relation_node && relation_node != plan
      segments << "rows=#{plan['Plan Rows']}" if plan['Plan Rows']
      segments << "cost=#{cost_range(plan)}" if cost_range(plan)
      "postgresql plan: #{segments.join(' ')}"
    end

    def node_label(plan)
      parts = [plan['Node Type']]
      parts << "using #{plan['Index Name']}" if plan['Index Name']
      parts << "on #{plan['Relation Name']}" if plan['Relation Name']
      parts.join(' ')
    end

    def first_relation_node(plan)
      return plan if plan['Relation Name']

      Array(plan['Plans']).each do |child|
        found = first_relation_node(child)
        return found if found
      end

      nil
    end

    def cost_range(plan)
      return unless plan.key?('Startup Cost') && plan.key?('Total Cost')

      format('%<startup>.2f..%<total>.2f', startup: plan['Startup Cost'], total: plan['Total Cost'])
    end
  end
end
