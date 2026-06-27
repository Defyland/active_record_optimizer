# frozen_string_literal: true

require 'active_support/core_ext/string/inflections'

module ActiveRecordOptimizer
  module Rules
    module AssociationRuleSupport
      private

      def dependent_destroy_findings(context, model)
        dependent_destroy_reflections(model).filter_map do |reflection|
          child_table = context.schema.tables[reflection.table_name]
          next unless dangerous_dependent_destroy?(context, child_table)

          dependent_destroy_finding(context, model, reflection, child_table)
        end
      end

      def dependent_destroy_finding(context, model, reflection, child_table)
        Finding.new(
          severity: 'medium',
          code: 'broad_dependent_destroy',
          title: 'Potentially broad dependent destroy',
          model: model.name,
          table: model.table_name,
          column: nil,
          problem: 'Destroying a parent can instantiate and destroy every child record one by one on a large child table.',
          recommendation: 'Verify expected cardinality; prefer database cascades, async deletion, ' \
                          'or batched cleanup when the relation can grow large.',
          evidence: "#{model.name} has_many :#{reflection.name}, dependent: :destroy; " \
                    "#{reflection.table_name} estimated rows=#{child_table.estimated_row_count}",
          details: dependent_destroy_details(context, child_table)
        )
      end

      def dependent_destroy_details(context, child_table)
        {
          estimated_row_count: child_table.estimated_row_count,
          row_threshold: context.configuration.dependent_destroy_row_threshold,
          evidence_source: 'postgresql_catalog'
        }
      end

      def dependent_destroy_reflections(model)
        model.reflections.select { |reflection| reflection.macro == 'has_many' && reflection.options['dependent'] == :destroy }
      end

      def dangerous_dependent_destroy?(context, child_table)
        child_table&.estimated_row_count &&
          child_table.estimated_row_count >= context.configuration.dependent_destroy_row_threshold
      end

      def index_starts_with?(table, columns)
        table.indexes.any? { |index| index.columns.first(columns.size) == columns }
      end

      def foreign_key_exists?(table, reflection)
        table.foreign_keys.any? do |foreign_key|
          foreign_key.columns == [reflection.foreign_key] &&
            foreign_key.to_table == reflection.table_name &&
            foreign_key.primary_key.to_s == expected_primary_key_for(reflection)
        end
      end

      def expected_primary_key_for(reflection)
        value = reflection.association_primary_key.to_s
        value.empty? ? 'id' : value
      end

      def foreign_key_recommendation(model, reflection)
        parts = ["add_foreign_key :#{model.table_name}, :#{reflection.table_name}"]
        options = []

        options << "column: :#{reflection.foreign_key}" unless reflection.foreign_key == default_foreign_key_for(reflection.table_name)
        options << "primary_key: :#{reflection.association_primary_key}" unless expected_primary_key_for(reflection) == 'id'

        [parts.join, options.join(', ')].reject(&:empty?).join(', ')
      end

      def default_foreign_key_for(table_name)
        "#{table_name.to_s.singularize}_id"
      end
    end

    class AssociationRules
      include AssociationRuleSupport

      def call(context)
        context.models.flat_map do |model|
          belongs_to_findings(context, model) +
            polymorphic_findings(context, model) +
            dependent_destroy_findings(context, model) +
            default_scope_findings(model) +
            inverse_of_findings(model)
        end
      end

      private

      def belongs_to_findings(context, model)
        belongs_to_reflections(model).flat_map do |reflection|
          table = context.schema.tables[model.table_name]
          next [] unless table&.columns&.key?(reflection.foreign_key)

          belongs_to_findings_for(model, table, reflection)
        end
      end

      def belongs_to_reflections(model)
        model.reflections.select { |reflection| reflection.macro == 'belongs_to' && !reflection.polymorphic }
      end

      def belongs_to_findings_for(model, table, reflection)
        [
          missing_belongs_to_index_finding(model, table, reflection),
          missing_foreign_key_constraint_finding(model, table, reflection)
        ].compact
      end

      def missing_belongs_to_index_finding(model, table, reflection)
        return if index_starts_with?(table, [reflection.foreign_key])

        Finding.new(
          severity: 'high',
          code: 'missing_belongs_to_index',
          title: 'Missing belongs_to index',
          model: model.name,
          table: model.table_name,
          column: reflection.foreign_key,
          problem: "The association uses #{model.table_name}.#{reflection.foreign_key}, but the child table has no compatible index.",
          recommendation: "add_index :#{model.table_name}, :#{reflection.foreign_key}",
          evidence: "#{model.name} belongs_to :#{reflection.name}",
          details: nil
        )
      end

      def missing_foreign_key_constraint_finding(model, table, reflection)
        return if foreign_key_exists?(table, reflection)

        Finding.new(
          severity: 'high',
          code: 'missing_foreign_key_constraint',
          title: 'Missing foreign key constraint',
          model: model.name,
          table: model.table_name,
          column: reflection.foreign_key,
          problem: 'Active Record association exists, but database integrity is not enforced.',
          recommendation: foreign_key_recommendation(model, reflection),
          evidence: "#{model.name} belongs_to :#{reflection.name}",
          details: nil
        )
      end

      def polymorphic_findings(context, model)
        polymorphic_reflections(model).filter_map do |reflection|
          table = context.schema.tables[model.table_name]
          next unless table
          next unless table.columns.key?(reflection.foreign_key) && table.columns.key?(reflection.foreign_type)
          next if index_starts_with?(table, [reflection.foreign_type, reflection.foreign_key]) ||
                  index_starts_with?(table, [reflection.foreign_key, reflection.foreign_type])

          Finding.new(
            severity: 'high',
            code: 'missing_polymorphic_composite_index',
            title: 'Missing polymorphic composite index',
            model: model.name,
            table: model.table_name,
            column: "#{reflection.foreign_type}, #{reflection.foreign_key}",
            problem: 'Polymorphic lookups need both type and id, but no composite index covers both columns.',
            recommendation: "add_index :#{model.table_name}, [:#{reflection.foreign_type}, :#{reflection.foreign_key}]",
            evidence: "#{model.name} belongs_to :#{reflection.name}, polymorphic: true",
            details: nil
          )
        end
      end

      def polymorphic_reflections(model)
        model.reflections.select { |reflection| reflection.macro == 'belongs_to' && reflection.polymorphic }
      end

      def default_scope_findings(model)
        return [] if model.default_scopes.empty?

        [
          Finding.new(
            severity: 'medium',
            code: 'default_scope',
            title: 'Default scope changes every query',
            model: model.name,
            table: model.table_name,
            column: nil,
            problem: 'default_scope alters all relation composition and can hide filters, ordering, or tenant/time assumptions.',
            recommendation: 'Replace with an explicit named scope unless every query on the model must always carry this condition.',
            evidence: "#{model.name} has #{model.default_scopes.size} default_scope definition(s)",
            details: nil
          )
        ]
      end

      def inverse_of_findings(model)
        model.reflections.select { |reflection| inverse_of_matters?(reflection) }.filter_map do |reflection|
          next if reflection.options.key?('inverse_of') || reflection.inverse_name

          Finding.new(
            severity: 'medium',
            code: 'missing_inverse_of',
            title: 'Missing inverse_of where identity consistency matters',
            model: model.name,
            table: model.table_name,
            column: nil,
            problem: 'The relation uses autosave or dependent destroy, but the inverse association is not explicit.',
            recommendation: 'Add inverse_of when the inverse is unambiguous, or document why Rails cannot infer it safely.',
            evidence: "#{model.name} has_many :#{reflection.name} with #{reflection.options.slice('autosave',
                                                                                                  'dependent')}",
            details: nil
          )
        end
      end

      def inverse_of_matters?(reflection)
        reflection.macro == 'has_many' &&
          (reflection.options['autosave'] == true || reflection.options['dependent'] == :destroy)
      end
    end
  end
end
