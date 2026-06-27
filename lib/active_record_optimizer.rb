# frozen_string_literal: true

require_relative 'active_record_optimizer/version'
require_relative 'active_record_optimizer/configuration_coercions'
require_relative 'active_record_optimizer/configuration'
require_relative 'active_record_optimizer/config_loader'
require_relative 'active_record_optimizer/finding'
require_relative 'active_record_optimizer/query_usage'
require_relative 'active_record_optimizer/table_name_resolver'
require_relative 'active_record_optimizer/schema_scanner'
require_relative 'active_record_optimizer/model_scanner'
require_relative 'active_record_optimizer/prism_helpers'
require_relative 'active_record_optimizer/source_scanner'
require_relative 'active_record_optimizer/migration_scanner'
require_relative 'active_record_optimizer/query_collector'
require_relative 'active_record_optimizer/runtime_query_payload_validator'
require_relative 'active_record_optimizer/runtime_query_loader'
require_relative 'active_record_optimizer/query_plan_analyzer'
require_relative 'active_record_optimizer/rules'
require_relative 'active_record_optimizer/report'
require_relative 'active_record_optimizer/runner'

require 'json'

require_relative 'active_record_optimizer/railtie' if defined?(Rails::Railtie)

module ActiveRecordOptimizer
  class Error < StandardError; end

  class << self
    def generator_metadata
      {
        name: 'active_record_optimizer',
        version: VERSION
      }
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def effective_configuration(root: nil, config_path: nil, overrides: {})
      resolved_root = root || (Rails.root if defined?(Rails.root))
      configuration
        .copy
        .apply(ConfigLoader.new(root: resolved_root).load(path: config_path))
        .apply(overrides.transform_keys(&:to_s))
    end

    def optimize(**options)
      root = options[:root]
      output = options.fetch(:output, $stdout)
      format = options[:format]
      config_path = options[:config_path]
      supplied_configuration = options[:configuration]
      overrides = options.fetch(:overrides, {})
      resolved_root = root || (Rails.root if defined?(Rails.root))
      resolved_configuration = supplied_configuration || effective_configuration(
        root: resolved_root,
        config_path: config_path,
        overrides: overrides
      )
      report = Runner.new(root: resolved_root, configuration: resolved_configuration).call
      output.puts(report.render(format || resolved_configuration.output_format))
      report
    end

    def capture_runtime_queries(path: nil, literalize_binds: false, &block)
      snapshot = QueryCollector.capture(literalize_binds: literalize_binds) do |collector|
        block.call(collector)
      end
      snapshot.write(path) if path
      snapshot
    end
  end
end
