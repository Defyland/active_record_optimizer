# frozen_string_literal: true

require 'pathname'

module ActiveRecordOptimizer
  module Rules
    class MigrationRules
      def call(context)
        context.migration_changes.filter_map do |change|
          table = context.schema.tables[change.table]
          next unless table
          next unless table.columns.key?(change.column)
          next if table.foreign_keys.any? { |foreign_key| foreign_key.columns == [change.column] }

          Finding.new(
            severity: 'high',
            code: 'migration_reference_without_foreign_key',
            title: 'Migration added reference column without foreign key',
            model: nil,
            table: change.table,
            column: change.column,
            problem: 'A migration added a reference-like column, and the current schema still has no matching foreign key constraint.',
            recommendation: 'Add foreign_key: true to the migration pattern for new tables, or add_foreign_key for existing tables.',
            evidence: "#{relative_path(change.path)}:#{change.line} #{change.source}",
            details: nil
          )
        end
      end

      private

      def relative_path(path)
        return path unless defined?(Rails.root) && Rails.root

        Pathname(path).relative_path_from(Rails.root).to_s
      rescue ArgumentError
        path
      end
    end
  end
end
