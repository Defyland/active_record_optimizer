# frozen_string_literal: true

namespace :active_record do
  desc 'Analyze Active Record models, schema, query patterns, and migrations'
  task :optimize, %i[fail_on format config runtime_report explain_runtime] => :environment do |_task, args|
    fail_on = ActiveRecordOptimizer::TaskOptions.normalized_fail_on(args, ARGV, ENV)
    format = ActiveRecordOptimizer::TaskOptions.normalized_format(args, ARGV, ENV)
    config_path = ActiveRecordOptimizer::TaskOptions.config_path(args, ARGV, ENV)
    overrides = ActiveRecordOptimizer::TaskOptions.configuration_overrides(args, ARGV, ENV)
    configuration = ActiveRecordOptimizer.effective_configuration(root: Rails.root, config_path: config_path, overrides: overrides)
    output_format = format || configuration.output_format
    report = ActiveRecordOptimizer.optimize(
      root: Rails.root,
      format: output_format,
      config_path: config_path,
      configuration: configuration,
      overrides: overrides
    )
    if fail_on && output_format != 'json'
      puts
      puts "Fail-on threshold: #{fail_on}"
    end
    exit(report.exit_status(fail_on))
  end
end

module ActiveRecordOptimizer
  module TaskOptions
    def self.normalized_fail_on(args, argv, env)
      Report.normalize_severity(env['FAIL_ON'] || args[:fail_on] || argv_value(argv, '--fail-on'))
    rescue ArgumentError => e
      abort e.message
    end

    def self.normalized_format(args, argv, env)
      value = env['FORMAT'] || args[:format] || argv_value(argv, '--format')
      return unless value

      Report.new([]).render(value)
      value
    rescue ArgumentError => e
      abort e.message
    end

    def self.config_path(args, argv, env)
      env['CONFIG'] || args[:config] || argv_value(argv, '--config')
    end

    def self.configuration_overrides(args, argv, env)
      explain_runtime = boolean_value(env['EXPLAIN_RUNTIME'] || args[:explain_runtime] || argv_flag?(argv, '--explain-runtime'))
      runtime_report = env['RUNTIME_REPORT'] || args[:runtime_report] || argv_value(argv, '--runtime-report')
      overrides = {}
      overrides[:runtime_query_report_path] = runtime_report if runtime_report
      overrides[:explain_runtime_queries] = explain_runtime unless explain_runtime.nil?

      overrides
    end

    def self.argv_value(argv, flag)
      index = argv.index(flag)
      return unless index

      argv[index + 1]
    end

    def self.argv_flag?(argv, flag)
      true if argv.include?(flag)
    end

    def self.boolean_value(value)
      case value
      when true, 1, '1', 'true', 'TRUE', 'yes', 'YES', 'on', 'ON'
        true
      when false, 0, '0', 'false', 'FALSE', 'no', 'NO', 'off', 'OFF'
        false
      end
    end
  end
end
