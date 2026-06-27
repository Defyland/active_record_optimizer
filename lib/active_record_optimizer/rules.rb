# frozen_string_literal: true

require_relative 'rules/association_rules'
require_relative 'rules/schema_rules'
require_relative 'rules/query_pattern_rules'
require_relative 'rules/migration_rules'

module ActiveRecordOptimizer
  module Rules
    def self.all
      [
        AssociationRules.new,
        SchemaRules.new,
        QueryPatternRules.new,
        MigrationRules.new
      ]
    end
  end
end
