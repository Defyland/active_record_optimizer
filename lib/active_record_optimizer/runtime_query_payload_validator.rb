# frozen_string_literal: true

module ActiveRecordOptimizer
  class RuntimeQueryPayloadValidator
    JSON_SCHEMA_VERSION = ActiveRecordOptimizer::QueryCollector::Snapshot::JSON_SCHEMA_VERSION
    SUPPORTED_SCHEMA_VERSIONS = [1, JSON_SCHEMA_VERSION].uniq.freeze

    REQUIRED_QUERY_USAGE_STRING_FIELDS = %w[table column operation source].freeze
    NULLABLE_QUERY_USAGE_STRING_FIELDS = %w[
      explain_source
      plan_summary
      plan_root_node_type
      plan_relation_node_type
      plan_relation_name
    ].freeze

    def initialize(path:)
      @path = path
    end

    def validate!(payload)
      invalid!('must be a JSON object with a query_usages array') unless payload.is_a?(Hash) && payload['query_usages'].is_a?(Array)

      schema_version = validate_metadata!(payload['metadata'])
      validate_queries!(payload['queries'], schema_version)
      validate_query_usages!(payload['query_usages'], schema_version)
      schema_version
    end

    private

    attr_reader :path

    def validate_metadata!(metadata)
      return nil if metadata.nil?

      invalid!('has invalid metadata: expected an object') unless metadata.is_a?(Hash)

      schema_version = metadata['schema_version']
      unless SUPPORTED_SCHEMA_VERSIONS.include?(schema_version)
        invalid!(
          "uses unsupported schema version #{schema_version.inspect}. " \
          "Supported versions: #{SUPPORTED_SCHEMA_VERSIONS.join(', ')}"
        )
      end

      validate_versioned_metadata!(metadata) if versioned_schema?(schema_version)
      schema_version
    end

    def validate_versioned_metadata!(metadata)
      generator = metadata['generator']
      unless generator.is_a?(Hash) && generator['name'].is_a?(String) && generator['version'].is_a?(String)
        invalid!('has invalid metadata.generator: expected name and version strings')
      end

      invalid!(generator_name_message(generator)) unless generator['name'] == 'active_record_optimizer'

      capture = metadata['capture']
      return if capture.is_a?(Hash) && boolean_value?(capture['literalized_binds'])

      invalid!('has invalid metadata.capture.literalized_binds: expected true or false')
    end

    def generator_name_message(generator)
      "has invalid metadata.generator.name #{generator['name'].inspect}. Expected \"active_record_optimizer\""
    end

    def validate_queries!(queries, schema_version)
      return unless versioned_schema?(schema_version)

      invalid!('has invalid queries: expected an array') unless queries.is_a?(Array)

      queries.each_with_index do |query, index|
        validate_query!(query, index, schema_version)
      end
    end

    def validate_query!(query, index, schema_version)
      invalid!("has invalid queries[#{index}]") unless valid_query_shape?(query)
      return unless current_schema_version?(schema_version)

      invalid_query!(index, 'duration_ms', 'expected a number greater than or equal to 0') if query['duration_ms'].negative?
    end

    def valid_query_shape?(query)
      query.is_a?(Hash) &&
        query['sql'].is_a?(String) &&
        nullable_string?(query['name']) &&
        numeric_value?(query['duration_ms']) &&
        nullable_string?(query['explain_sql'])
    end

    def validate_query_usages!(usages, schema_version)
      usages.each_with_index do |usage, index|
        validate_query_usage!(usage, index, schema_version)
      end
    end

    def validate_query_usage!(usage, index, schema_version)
      invalid!("has invalid query_usages[#{index}]: expected an object") unless usage.is_a?(Hash)

      validate_required_query_usage_fields!(usage, index)
      validate_nullable_query_usage_fields!(usage, index)
      validate_numeric_query_usage_fields!(usage, index)
      validate_where_columns!(usage['where_columns'], index)
      validate_origin!(usage['origin'], index, schema_version)
      validate_versioned_runtime_usage_shape!(usage, index) if versioned_schema?(schema_version)
      validate_current_runtime_usage_semantics!(usage, index) if current_schema_version?(schema_version)
    end

    def validate_required_query_usage_fields!(usage, index)
      REQUIRED_QUERY_USAGE_STRING_FIELDS.each do |key|
        invalid_usage!(index, key, 'expected a string') unless usage[key].is_a?(String)
      end

      invalid_usage!(index, 'count', 'expected an integer') unless usage['count'].is_a?(Integer)
    end

    def validate_nullable_query_usage_fields!(usage, index)
      NULLABLE_QUERY_USAGE_STRING_FIELDS.each do |key|
        invalid_usage!(index, key, 'expected a string or null') unless nullable_string?(usage[key])
      end
    end

    def validate_numeric_query_usage_fields!(usage, index)
      invalid_usage!(index, 'total_duration_ms', 'expected a number or null') unless nullable_numeric?(usage['total_duration_ms'])
      return if usage['plan_rows'].nil? || usage['plan_rows'].is_a?(Integer)

      invalid_usage!(index, 'plan_rows', 'expected an integer or null')
    end

    def validate_current_runtime_usage_semantics!(usage, index)
      invalid_usage!(index, 'count', 'expected an integer greater than or equal to 1') if usage['count'] < 1

      if usage['total_duration_ms']&.negative?
        invalid_usage!(index, 'total_duration_ms', 'expected a number greater than or equal to 0 or null')
      end

      return unless usage['plan_rows']&.negative?

      invalid_usage!(index, 'plan_rows', 'expected an integer greater than or equal to 0 or null')
    end

    def validate_where_columns!(value, index)
      return if value.nil?
      return if value.is_a?(Array) && value.all?(String)

      invalid_usage!(index, 'where_columns', 'expected an array of strings')
    end

    def validate_origin!(value, index, schema_version)
      return if value == 'runtime'
      return if value.nil? && schema_version.nil?

      invalid_usage!(index, 'origin', 'expected "runtime"')
    end

    def validate_versioned_runtime_usage_shape!(usage, index)
      invalid_usage!(index, 'path', 'expected null') unless usage.key?('path') && usage['path'].nil?
      invalid_usage!(index, 'line', 'expected null') unless usage.key?('line') && usage['line'].nil?
    end

    def invalid_query!(index, key, message)
      invalid!("has invalid queries[#{index}].#{key}: #{message}")
    end

    def invalid_usage!(index, key, message)
      invalid!("has invalid query_usages[#{index}].#{key}: #{message}")
    end

    def invalid!(message)
      raise ActiveRecordOptimizer::Error, "Runtime query report at #{path} #{message}."
    end

    def nullable_string?(value)
      value.nil? || value.is_a?(String)
    end

    def nullable_numeric?(value)
      value.nil? || numeric_value?(value)
    end

    def numeric_value?(value)
      value.is_a?(Numeric)
    end

    def boolean_value?(value)
      [true, false].include?(value)
    end

    def current_schema_version?(schema_version)
      schema_version == JSON_SCHEMA_VERSION
    end

    def versioned_schema?(schema_version)
      SUPPORTED_SCHEMA_VERSIONS.include?(schema_version)
    end
  end
end
