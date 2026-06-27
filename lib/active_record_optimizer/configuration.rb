# frozen_string_literal: true

module ActiveRecordOptimizer
  class Configuration
    include ConfigurationCoercions

    attr_accessor :explain_runtime_queries, :ignored_findings, :ignored_tables, :output_format,
                  :runtime_query_report_path, :where_occurrence_threshold, :dependent_destroy_row_threshold,
                  :planner_row_threshold

    def initialize
      @dependent_destroy_row_threshold = 10_000
      @explain_runtime_queries = false
      @ignored_findings = []
      @where_occurrence_threshold = 2
      @planner_row_threshold = 10_000
      @output_format = 'text'
      @runtime_query_report_path = nil
      @ignored_tables = %w[
        ar_internal_metadata
        schema_migrations
      ]
    end

    def apply(options = {})
      normalized_options = normalize_options(options)

      @dependent_destroy_row_threshold = integer_option(normalized_options, 'dependent_destroy_row_threshold',
                                                        dependent_destroy_row_threshold, minimum: 1)
      @explain_runtime_queries = boolean_option(normalized_options, 'explain_runtime_queries', explain_runtime_queries)
      @planner_row_threshold = integer_option(normalized_options, 'planner_row_threshold', planner_row_threshold,
                                              minimum: 1)
      @where_occurrence_threshold = integer_option(normalized_options, 'where_occurrence_threshold',
                                                   where_occurrence_threshold, minimum: 1)
      @ignored_tables = string_array_option(normalized_options, 'ignored_tables', ignored_tables)
      @ignored_findings = finding_rules_option(normalized_options, 'ignored_findings', ignored_findings)
      @output_format = output_format_option(normalized_options, 'output_format', output_format)
      @runtime_query_report_path = nullable_string_option(normalized_options, 'runtime_query_report_path',
                                                          runtime_query_report_path)
      self
    end

    def copy
      self.class.new.apply(
        'dependent_destroy_row_threshold' => dependent_destroy_row_threshold,
        'explain_runtime_queries' => explain_runtime_queries,
        'ignored_findings' => ignored_findings.map(&:dup),
        'ignored_tables' => ignored_tables.dup,
        'output_format' => output_format,
        'planner_row_threshold' => planner_row_threshold,
        'runtime_query_report_path' => runtime_query_report_path,
        'where_occurrence_threshold' => where_occurrence_threshold
      )
    end

    def filter_findings(findings)
      findings.reject { |finding| ignored?(finding) }
    end

    private

    def ignored?(finding)
      ignored_findings.any? { |rule| matches_rule?(finding, rule) }
    end

    def matches_rule?(finding, rule)
      rule.all? do |key, value|
        actual_value = finding.public_send(key)
        actual_value.to_s == value.to_s
      end
    end
  end
end
