# frozen_string_literal: true

require 'rails/command/base'
require 'active_record_optimizer'

module Rails
  module Command
    class ActiveRecordCommand < Base
      desc 'optimize', 'Analyze Active Record models, schema, query patterns, and migrations'
      method_option :config, type: :string, banner: 'PATH', desc: 'Load configuration from a specific YAML file'
      method_option :explain_runtime, type: :boolean, default: nil,
                                      desc: 'Run PostgreSQL EXPLAIN (FORMAT JSON) for captured runtime queries'
      method_option :fail_on, type: :string, banner: 'SEVERITY', desc: 'Exit 1 when findings exist at or above severity'
      method_option :format, type: :string, banner: 'FORMAT', desc: 'Output format: text or json'
      method_option :runtime_report, type: :string, banner: 'PATH',
                                     desc: 'Merge a captured runtime query report JSON file into the analysis'

      def optimize
        boot_application!
        fail_on = normalized_fail_on
        format = normalized_format
        configuration = ActiveRecordOptimizer.effective_configuration(
          root: Rails.root,
          config_path: options[:config],
          overrides: configuration_overrides
        )
        output_format = format || configuration.output_format

        report = ActiveRecordOptimizer.optimize(
          root: Rails.root,
          format: output_format,
          config_path: options[:config],
          configuration: configuration,
          overrides: configuration_overrides
        )
        say("Fail-on threshold: #{fail_on}") if fail_on && output_format != 'json'
        exit(report.exit_status(fail_on))
      end

      private

      def normalized_fail_on
        ActiveRecordOptimizer::Report.normalize_severity(options[:fail_on])
      rescue ArgumentError => e
        say_error(e.message)
        exit(1)
      end

      def normalized_format
        return unless options[:format]

        ActiveRecordOptimizer::Report.new([]).render(options[:format])
        options[:format]
      rescue ArgumentError => e
        say_error(e.message)
        exit(1)
      end

      def configuration_overrides
        overrides = {}
        overrides[:runtime_query_report_path] = options[:runtime_report] if options[:runtime_report]
        overrides[:explain_runtime_queries] = options[:explain_runtime] unless options[:explain_runtime].nil?

        overrides
      end
    end
  end
end
