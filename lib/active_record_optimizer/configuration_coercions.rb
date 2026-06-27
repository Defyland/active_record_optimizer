# frozen_string_literal: true

module ActiveRecordOptimizer
  # rubocop:disable Metrics/ModuleLength
  module ConfigurationCoercions
    BOOLEAN_TRUE_VALUES = [true, 1, '1', 'true', 'TRUE', 'yes', 'YES', 'on', 'ON'].freeze
    BOOLEAN_FALSE_VALUES = [false, nil, 0, '0', 'false', 'FALSE', 'no', 'NO', 'off', 'OFF'].freeze
    FINDING_RULE_KEYS = %w[code column model severity table].freeze
    OUTPUT_FORMATS = %w[json text].freeze
    VALID_KEYS = %w[dependent_destroy_row_threshold explain_runtime_queries ignored_findings ignored_tables output_format
                    planner_row_threshold runtime_query_report_path where_occurrence_threshold].freeze

    private

    def normalize_options(options)
      return {} unless options

      unless options.is_a?(Hash)
        raise ActiveRecordOptimizer::Error,
              "Configuration options must be a Hash, got #{options.class}."
      end

      normalized = options.transform_keys(&:to_s)
      unknown_keys = normalized.keys - VALID_KEYS
      return normalized if unknown_keys.empty?

      raise ActiveRecordOptimizer::Error,
            "Unknown configuration keys: #{unknown_keys.sort.join(', ')}. Supported keys: #{VALID_KEYS.join(', ')}."
    end

    def integer_option(options, key, fallback, minimum: nil)
      return fallback unless options.key?(key)

      value = Integer(options[key])
      return value unless minimum && value < minimum

      raise ActiveRecordOptimizer::Error,
            "Invalid integer for #{key}: #{options[key].inspect}. " \
            "Expected an integer greater than or equal to #{minimum}."
    rescue ArgumentError, TypeError
      raise ActiveRecordOptimizer::Error,
            "Invalid integer for #{key}: #{options[key].inspect}."
    end

    def string_array_option(options, key, fallback)
      return fallback unless options.key?(key)

      value = options[key]
      return [value] if value.is_a?(String)

      unless value.is_a?(Array) && value.all?(String)
        raise ActiveRecordOptimizer::Error,
              "Invalid value for #{key}: expected a string or array of strings."
      end

      value
    end

    def finding_rules_option(options, key, fallback)
      return fallback unless options.key?(key)

      value = options[key]
      unless value.is_a?(Array)
        raise ActiveRecordOptimizer::Error,
              "Invalid value for #{key}: expected an array of rule hashes."
      end

      value.each_with_index.map { |rule, index| normalize_finding_rule(rule, key, index) }
    end

    def normalize_finding_rule(rule, key, index)
      unless rule.is_a?(Hash)
        raise ActiveRecordOptimizer::Error,
              "Invalid #{key}[#{index}]: expected a rule hash."
      end

      normalized_rule = rule.transform_keys(&:to_s)
      validate_finding_rule_keys!(normalized_rule, key, index)
      validate_finding_rule_values!(normalized_rule, key, index)

      normalized_rule.transform_values(&:to_s).transform_keys(&:to_sym)
    end

    def validate_finding_rule_keys!(normalized_rule, key, index)
      unknown_keys = normalized_rule.keys - FINDING_RULE_KEYS
      return if unknown_keys.empty? && !normalized_rule.empty?

      if normalized_rule.empty?
        raise ActiveRecordOptimizer::Error,
              "Invalid #{key}[#{index}]: rule must include at least one of #{FINDING_RULE_KEYS.join(', ')}."
      end

      raise ActiveRecordOptimizer::Error,
            "Invalid #{key}[#{index}]: unknown keys #{unknown_keys.sort.join(', ')}."
    end

    def validate_finding_rule_values!(normalized_rule, key, index)
      return if normalized_rule.values.all? { |entry| entry.is_a?(String) || entry.is_a?(Symbol) }

      raise ActiveRecordOptimizer::Error,
            "Invalid #{key}[#{index}]: rule values must be strings or symbols."
    end

    def output_format_option(options, key, fallback)
      return fallback unless options.key?(key)

      value = options[key]
      unless value.is_a?(String) || value.is_a?(Symbol)
        raise ActiveRecordOptimizer::Error,
              "Invalid value for #{key}: expected a string."
      end

      normalized_value = value.to_s.downcase
      return normalized_value if OUTPUT_FORMATS.include?(normalized_value)

      raise ActiveRecordOptimizer::Error,
            "Invalid value for #{key}: #{value.inspect}. Use one of: #{OUTPUT_FORMATS.join(', ')}."
    end

    def boolean_option(options, key, fallback)
      return fallback unless options.key?(key)

      case options[key]
      when *BOOLEAN_TRUE_VALUES
        true
      when *BOOLEAN_FALSE_VALUES
        false
      else
        raise ActiveRecordOptimizer::Error,
              "Invalid boolean for #{key}: #{options[key].inspect}."
      end
    end

    def nullable_string_option(options, key, fallback)
      return fallback unless options.key?(key)

      value = options[key]
      return nil if value.nil?
      return value if value.is_a?(String)

      raise ActiveRecordOptimizer::Error,
            "Invalid value for #{key}: expected a string or nil."
    end
  end
  # rubocop:enable Metrics/ModuleLength
end
