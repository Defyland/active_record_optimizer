# frozen_string_literal: true

require 'active_support/notifications'
require 'json'

module ActiveRecordOptimizer
  class QueryCollector
    Query = Data.define(:sql, :name, :duration_ms, :explain_sql) do
      def to_h
        {
          sql: sql,
          name: name,
          duration_ms: duration_ms,
          explain_sql: explain_sql
        }
      end
    end

    class Snapshot
      JSON_SCHEMA_VERSION = 2

      attr_reader :metadata, :queries, :query_usages

      def initialize(queries:, query_usages:, metadata: nil)
        @queries = queries
        @query_usages = query_usages
        @metadata = metadata || default_metadata
      end

      def to_h
        {
          metadata: metadata,
          queries: queries.map(&:to_h),
          query_usages: query_usages.map(&:to_h)
        }
      end

      def to_json(*)
        JSON.pretty_generate(to_h)
      end

      def write(path)
        File.write(path, to_json)
      end

      private

      def default_metadata
        {
          schema_version: JSON_SCHEMA_VERSION,
          generator: ActiveRecordOptimizer.generator_metadata,
          capture: {
            literalized_binds: queries.any?(&:explain_sql)
          }
        }
      end
    end

    class SqlParser
      TABLE_REFERENCE_PATTERN =
        /\b(?:FROM|JOIN|UPDATE)\s+(?:"?([a-zA-Z_][\w$]*)"?\.)?"?([a-zA-Z_][\w$]*)"?(?:\s+(?:AS\s+)?"?([a-zA-Z_][\w$]*)"?)?/i
      WHERE_BOUNDARY_PATTERN = /\bWHERE\b(.+?)(?:\bGROUP\b|\bORDER\b|\bLIMIT\b|\bOFFSET\b|\bFOR\b|\z)/im
      ORDER_BOUNDARY_PATTERN = /\bORDER\s+BY\b(.+?)(?:\bLIMIT\b|\bOFFSET\b|\bFOR\b|\z)/im
      QUALIFIED_COLUMN_PATTERN =
        /(?:"?([a-zA-Z_][\w$]*)"?\.)?"?([a-zA-Z_][\w$]*)"?\."?([a-zA-Z_][\w$]*)"?/
      QUALIFIED_JSONB_EXTRACTION_PATTERN =
        /(?:"?([a-zA-Z_][\w$]*)"?\.)?"?([a-zA-Z_][\w$]*)"?\."?([a-zA-Z_][\w$]*)"?\s*(->>|->)\s*'([^']+)'/
      QUALIFIED_JSONB_CONTAINMENT_PATTERN =
        /(?:"?([a-zA-Z_][\w$]*)"?\.)?"?([a-zA-Z_][\w$]*)"?\."?([a-zA-Z_][\w$]*)"?\s*@>/
      UNQUALIFIED_JSONB_EXTRACTION_PATTERN = /"?([a-zA-Z_][\w$]*)"?\s*(->>|->)\s*'([^']+)'/
      UNQUALIFIED_JSONB_CONTAINMENT_PATTERN = /"?([a-zA-Z_][\w$]*)"?\s*@>/
      CLAUSE_TOKENS = %w[WHERE INNER LEFT RIGHT FULL CROSS JOIN ON GROUP ORDER LIMIT OFFSET FOR SET RETURNING USING].freeze

      def call(sql:, duration_ms:)
        table_aliases = table_aliases(sql)
        return [] if table_aliases.empty?

        where_columns_by_qualifier = where_columns_by_qualifier(sql, table_aliases)

        where_usages(sql, duration_ms, table_aliases) +
          order_usages(sql, duration_ms, table_aliases, where_columns_by_qualifier)
      end

      private

      def table_aliases(sql)
        sql.scan(TABLE_REFERENCE_PATTERN).each_with_object({}) do |(schema_name, table_name, alias_candidate), aliases|
          canonical_table_name = qualified_table_name(schema_name, table_name)
          aliases[table_name] ||= canonical_table_name
          aliases[canonical_table_name] ||= canonical_table_name

          alias_name = normalize_alias(alias_candidate)
          aliases[alias_name] = canonical_table_name if alias_name
        end
      end

      def normalize_alias(alias_candidate)
        return if alias_candidate.nil?

        alias_name = alias_candidate.delete('"')
        return if CLAUSE_TOKENS.include?(alias_name.upcase)

        alias_name
      end

      def where_usages(sql, duration_ms, table_aliases)
        fragment = sql[WHERE_BOUNDARY_PATTERN, 1]
        return [] unless fragment

        jsonb_observations = jsonb_usages(fragment, sql, duration_ms, table_aliases)
        jsonb_columns = jsonb_observations.map { |usage| [usage.table, usage.column] }.uniq

        column_usages(fragment, sql, duration_ms, 'where', table_aliases)
          .reject { |usage| jsonb_columns.include?([usage.table, usage.column]) } +
          jsonb_observations
      end

      def order_usages(sql, duration_ms, table_aliases, where_columns_by_qualifier)
        fragment = sql[ORDER_BOUNDARY_PATTERN, 1]
        return [] unless fragment

        qualified_column_references(fragment, table_aliases).map do |qualifier, table, column|
          runtime_usage(
            sql: sql,
            duration_ms: duration_ms,
            table: table,
            column: column,
            operation: 'order',
            where_columns: where_columns_by_qualifier.fetch(qualifier, [])
          )
        end
      end

      def column_usages(fragment, sql, duration_ms, operation, table_aliases)
        qualified_columns(fragment, table_aliases).map do |table, column|
          runtime_usage(
            sql: sql,
            duration_ms: duration_ms,
            table: table,
            column: column,
            operation: operation
          )
        end
      end

      def jsonb_usages(fragment, sql, duration_ms, table_aliases)
        jsonb_columns(fragment, table_aliases).map do |table, column|
          runtime_usage(
            sql: sql,
            duration_ms: duration_ms,
            table: table,
            column: column,
            operation: 'jsonb_where'
          )
        end
      end

      def jsonb_columns(fragment, table_aliases)
        (qualified_extraction_columns(fragment, table_aliases) +
          qualified_containment_columns(fragment, table_aliases) +
          unqualified_jsonb_columns(fragment, table_aliases)).uniq
      end

      def qualified_extraction_columns(fragment, table_aliases)
        fragment.scan(QUALIFIED_JSONB_EXTRACTION_PATTERN).filter_map do |schema_name, qualifier, column, *_rest|
          table_name = table_name_for_qualifier(table_aliases, schema_name, qualifier)
          [table_name, column] if table_name
        end
      end

      def qualified_containment_columns(fragment, table_aliases)
        fragment.scan(QUALIFIED_JSONB_CONTAINMENT_PATTERN).filter_map do |schema_name, qualifier, column|
          table_name = table_name_for_qualifier(table_aliases, schema_name, qualifier)
          [table_name, column] if table_name
        end
      end

      def unqualified_jsonb_columns(fragment, table_aliases)
        tables = table_aliases.values.uniq
        return [] unless tables.one?

        table_name = tables.first

        (fragment.scan(UNQUALIFIED_JSONB_EXTRACTION_PATTERN).map(&:first) +
          fragment.scan(UNQUALIFIED_JSONB_CONTAINMENT_PATTERN).flatten)
          .uniq
          .map { |column| [table_name, column] }
      end

      def qualified_columns(fragment, table_aliases)
        qualified_column_references(fragment, table_aliases).map { |_qualifier, table, column| [table, column] }.uniq
      end

      def runtime_usage(sql:, duration_ms:, where_columns: [], **attributes)
        QueryUsage.runtime(
          table: attributes.fetch(:table),
          column: attributes.fetch(:column),
          operation: attributes.fetch(:operation),
          source: sql,
          count: 1,
          total_duration_ms: duration_ms,
          where_columns: where_columns
        )
      end

      def where_columns_by_qualifier(sql, table_aliases)
        fragment = sql[WHERE_BOUNDARY_PATTERN, 1]
        return {} unless fragment

        qualified_column_references(fragment, table_aliases)
          .group_by(&:first)
          .transform_values { |references| references.map { |_qualifier, _table, column| column }.uniq }
      end

      def qualified_column_references(fragment, table_aliases)
        fragment.scan(QUALIFIED_COLUMN_PATTERN).filter_map do |schema_name, qualifier, column|
          table_name = table_name_for_qualifier(table_aliases, schema_name, qualifier)
          [qualifier_key(schema_name, qualifier), table_name, column] if table_name
        end.uniq
      end

      def table_name_for_qualifier(table_aliases, schema_name, qualifier)
        table_aliases[qualifier_key(schema_name, qualifier)] || table_aliases[qualifier]
      end

      def qualifier_key(schema_name, qualifier)
        return qualifier unless schema_name

        qualified_table_name(schema_name, qualifier)
      end

      def qualified_table_name(schema_name, table_name)
        return table_name unless schema_name

        "#{schema_name}.#{table_name}"
      end
    end

    class SqlLiteralizer
      def initialize(connection: ActiveRecord::Base.connection)
        @connection = connection
      end

      def call(sql:, binds:)
        statement = sql.to_s
        values = Array(binds)
        return statement if statement.empty? || values.empty?

        if statement.match?(/\$\d+/)
          replace_numbered_placeholders(statement, values)
        elsif statement.include?('?')
          replace_question_mark_placeholders(statement, values)
        else
          statement
        end
      rescue StandardError
        statement
      end

      private

      attr_reader :connection

      def replace_numbered_placeholders(statement, values)
        values.each_with_index.reverse_each.reduce(statement) do |sql, (value, index)|
          sql.gsub("$#{index + 1}", quoted(value))
        end
      end

      def replace_question_mark_placeholders(statement, values)
        bind_index = 0

        statement.gsub('?') do
          value = values.fetch(bind_index, nil)
          bind_index += 1
          quoted(value)
        end
      end

      def quoted(value)
        connection.quote(value)
      end
    end

    attr_reader :queries

    def self.capture(literalize_binds: false)
      collector = new(literalize_binds: literalize_binds)
      collector.start
      yield collector
      collector.snapshot
    ensure
      collector&.stop
    end

    def initialize(sql_parser: SqlParser.new, sql_literalizer: SqlLiteralizer.new, literalize_binds: false)
      @queries = []
      @sql_parser = sql_parser
      @sql_literalizer = sql_literalizer
      @literalize_binds = literalize_binds
      @subscription = nil
      @usage_totals = Hash.new { |hash, key| hash[key] = { count: 0, total_duration_ms: 0.0, source: nil } }
    end

    def start
      return self if @subscription

      @subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, started, finished, _id, payload|
        next if payload[:name] == 'SCHEMA'

        duration_ms = ((finished - started) * 1000).round(2)
        record_query(payload, duration_ms)
      end

      self
    end

    def stop
      return self unless @subscription

      ActiveSupport::Notifications.unsubscribe(@subscription)
      @subscription = nil
      self
    end

    def snapshot
      Snapshot.new(
        queries: queries.dup,
        query_usages: aggregated_query_usages
      )
    end

    private

    attr_reader :literalize_binds, :sql_parser, :sql_literalizer, :usage_totals

    def record_query(payload, duration_ms)
      raw_sql = payload[:sql].to_s
      explain_sql = explain_sql(raw_sql, payload[:type_casted_binds])
      queries << Query.new(sql: raw_sql, name: payload[:name], duration_ms: duration_ms, explain_sql: explain_sql)

      sql_parser.call(sql: raw_sql, duration_ms: duration_ms).each do |usage|
        accumulate_usage(usage, explain_sql)
      end
    end

    def aggregated_query_usages
      usage_totals.map do |(table, column, operation, _where_columns), bucket|
        QueryUsage.runtime(
          table: table,
          column: column,
          operation: operation,
          source: bucket[:source],
          count: bucket[:count],
          total_duration_ms: bucket[:total_duration_ms].round(2),
          explain_source: bucket[:explain_source],
          where_columns: bucket[:where_columns]
        )
      end
    end

    def explain_sql(raw_sql, binds)
      return unless literalize_binds

      sql_literalizer.call(sql: raw_sql, binds: binds)
    end

    def accumulate_usage(usage, explain_sql)
      bucket = usage_totals[usage_bucket_key(usage)]
      bucket[:count] += usage.count
      bucket[:total_duration_ms] += usage.total_duration_ms.to_f
      bucket[:source] ||= usage.source
      bucket[:explain_source] ||= explain_sql
      bucket[:where_columns] ||= usage.where_columns
    end

    def usage_bucket_key(usage)
      [usage.table, usage.column, usage.operation, usage.where_columns]
    end
  end
end
