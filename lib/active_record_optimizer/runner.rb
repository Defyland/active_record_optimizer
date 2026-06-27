# frozen_string_literal: true

require 'active_record'
require 'pathname'

module ActiveRecordOptimizer
  class Runner
    Context = Data.define(:schema, :models, :query_usages, :migration_changes, :configuration)

    def initialize(root: nil, configuration: nil, config_path: nil)
      @root = root || rails_root
      @configuration = load_configuration(configuration, config_path)
    end

    def call
      context = Context.new(
        schema: schema,
        models: models,
        query_usages: query_usages,
        migration_changes: migration_changes,
        configuration: configuration
      )

      findings = Rules.all.flat_map { |rule| rule.call(context) }
      Report.new(configuration.filter_findings(findings), metadata: report_metadata)
    end

    private

    attr_reader :root, :configuration

    def schema
      @schema ||= SchemaScanner.new(
        ignored_tables: configuration.ignored_tables,
        extra_tables: models.map(&:table_name)
      ).call
    end

    def models
      @models ||= ModelScanner.new(root: root).call
    end

    def query_usages
      @query_usages ||= canonicalize_query_usages(source_query_usages + runtime_query_usages)
    end

    def migration_changes
      return [] unless root

      @migration_changes ||= MigrationScanner.new(root: root).call
    end

    def rails_root
      Rails.root if defined?(Rails.root)
    end

    def source_query_usages
      return [] unless root

      SourceScanner.new(root: root).call(models: models)
    end

    def runtime_query_usages
      ensure_runtime_report_configured! if configuration.explain_runtime_queries
      return [] unless configuration.runtime_query_report_path

      runtime_snapshot = RuntimeQueryLoader.new(path: resolved_runtime_query_report_path).load_result
      loaded_usages = runtime_snapshot.query_usages
      return loaded_usages unless configuration.explain_runtime_queries

      ensure_runtime_snapshot_explainable!(runtime_snapshot)
      QueryPlanAnalyzer.new(connection: ActiveRecord::Base.connection).annotate(loaded_usages)
    end

    def resolved_runtime_query_report_path
      runtime_path = configuration.runtime_query_report_path
      return runtime_path if Pathname(runtime_path).absolute?
      return runtime_path unless root

      File.join(root.to_s, runtime_path)
    end

    def ensure_runtime_snapshot_explainable!(runtime_snapshot)
      return if runtime_snapshot.query_usages.any? { |usage| explainable_runtime_usage?(usage) }

      raise ActiveRecordOptimizer::Error,
            "Runtime query report at #{resolved_runtime_query_report_path} does not contain explainable SQL for " \
            '--explain-runtime. Re-capture with literalize_binds: true or run without --explain-runtime.'
    end

    def ensure_runtime_report_configured!
      return if configuration.runtime_query_report_path

      raise ActiveRecordOptimizer::Error,
            'explain_runtime_queries requires runtime_query_report_path. ' \
            'Provide --runtime-report or set runtime_query_report_path in configuration.'
    end

    def explainable_runtime_usage?(usage)
      QueryPlanAnalyzer.explainable_sql?(usage.explain_source || usage.source)
    end

    def load_configuration(base_configuration, config_path)
      configuration = (base_configuration || Configuration.new).copy
      configuration.apply(ConfigLoader.new(root: root).load(path: config_path))
    end

    def report_metadata
      {
        schema_version: Report::JSON_SCHEMA_VERSION,
        generator: {
          name: 'active_record_optimizer',
          version: ActiveRecordOptimizer::VERSION
        }
      }
    end

    def canonicalize_query_usages(usages)
      usages.map { |usage| table_name_resolver.canonicalize_query_usage(usage) }
    end

    def table_name_resolver
      @table_name_resolver ||= TableNameResolver.new(
        connection: ActiveRecord::Base.connection,
        schema_table_names: schema.tables.keys,
        model_table_names: models.map(&:table_name)
      )
    end
  end
end
