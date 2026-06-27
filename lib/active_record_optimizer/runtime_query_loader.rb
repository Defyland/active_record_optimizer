# frozen_string_literal: true

require 'json'

module ActiveRecordOptimizer
  class RuntimeQueryLoader
    JSON_SCHEMA_VERSION = RuntimeQueryPayloadValidator::JSON_SCHEMA_VERSION
    SUPPORTED_SCHEMA_VERSIONS = RuntimeQueryPayloadValidator::SUPPORTED_SCHEMA_VERSIONS
    Result = Data.define(:metadata, :query_usages)

    def initialize(path:)
      @path = path
    end

    def load
      load_result.query_usages
    end

    def load_result
      payload = load_payload
      schema_version = RuntimeQueryPayloadValidator.new(path: path).validate!(payload)
      query_usages = payload.fetch('query_usages').map { |usage| build_query_usage(usage, schema_version) }

      Result.new(metadata: payload['metadata'], query_usages: query_usages)
    end

    private

    attr_reader :path

    def load_payload
      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      raise ActiveRecordOptimizer::Error, "Runtime query report not found at #{path}."
    rescue JSON::ParserError
      raise ActiveRecordOptimizer::Error, "Runtime query report at #{path} is not valid JSON."
    end

    def normalized_usage(usage, schema_version)
      normalized = usage.dup
      normalized['where_columns'] ||= []
      return normalized unless schema_version.nil? && !normalized.key?('origin')

      normalized['origin'] = 'runtime'
      normalized
    end

    def build_query_usage(usage, schema_version)
      usage = normalized_usage(usage, schema_version)

      QueryUsage.runtime(
        table: usage.fetch('table'),
        column: usage.fetch('column'),
        operation: usage.fetch('operation'),
        source: usage.fetch('source'),
        count: usage.fetch('count'),
        total_duration_ms: usage.fetch('total_duration_ms'),
        explain_source: usage['explain_source'],
        plan_summary: usage['plan_summary'],
        plan_root_node_type: usage['plan_root_node_type'],
        plan_relation_node_type: usage['plan_relation_node_type'],
        plan_relation_name: usage['plan_relation_name'],
        plan_rows: usage['plan_rows'],
        where_columns: Array(usage['where_columns']).map(&:to_s)
      )
    end
  end
end
