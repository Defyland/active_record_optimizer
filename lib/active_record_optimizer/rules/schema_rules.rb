# frozen_string_literal: true

module ActiveRecordOptimizer
  module Rules
    class SchemaRules
      def call(context)
        context.schema.tables.values.flat_map do |table|
          foreign_key_index_findings(table) +
            primary_key_findings(table) +
            timestamp_findings(table)
        end
      end

      private

      def foreign_key_index_findings(table)
        table.foreign_keys.filter_map do |foreign_key|
          next if index_starts_with?(table, foreign_key.columns)

          Finding.new(
            severity: 'high',
            code: 'foreign_key_without_index',
            title: 'Foreign key constraint without child index',
            model: nil,
            table: table.name,
            column: foreign_key.columns.join(', '),
            problem: 'The database enforces the foreign key, but deletes/updates on the parent can scan the child table.',
            recommendation: "add_index :#{table.name}, #{array_literal(foreign_key.columns)}",
            evidence: "#{table.name}.#{foreign_key.columns.join(', ')} references #{foreign_key.to_table}",
            details: nil
          )
        end
      end

      def primary_key_findings(table)
        return [] if table.primary_key

        [
          Finding.new(
            severity: 'high',
            code: 'table_without_primary_key',
            title: 'Table without primary key',
            model: nil,
            table: table.name,
            column: nil,
            problem: 'Active Record works best with a stable primary key; missing keys limit updates, associations, and deletes.',
            recommendation: 'Add a primary key unless this is an intentional join table with explicit constraints.',
            evidence: "#{table.name} has no primary key in the database schema",
            details: nil
          )
        ]
      end

      def timestamp_findings(table)
        return [] if table.columns.key?('created_at') && table.columns.key?('updated_at')

        [
          Finding.new(
            severity: 'low',
            code: 'table_without_timestamps',
            title: 'Table without standard timestamps',
            model: nil,
            table: table.name,
            column: nil,
            problem: 'Tables without timestamps are harder to audit and investigate during performance or data incidents.',
            recommendation: 'Add created_at and updated_at unless this table is intentionally append-only, external, or ephemeral.',
            evidence: "#{table.name} is missing created_at and/or updated_at",
            details: nil
          )
        ]
      end

      def index_starts_with?(table, columns)
        table.indexes.any? { |index| index.columns.first(columns.size) == columns }
      end

      def array_literal(columns)
        return ":#{columns.first}" if columns.size == 1

        "[#{columns.map { |column| ":#{column}" }.join(', ')}]"
      end
    end
  end
end
