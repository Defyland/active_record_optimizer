# frozen_string_literal: true

require 'test_helper'

module AssociationRulesTestSupport
  private

  def context_for_dependent_destroy(estimated_row_count:)
    reflection = ActiveRecordOptimizer::ModelScanner::Reflection.new(
      name: 'payments',
      macro: 'has_many',
      options: { 'dependent' => :destroy },
      foreign_key: 'user_id',
      foreign_type: nil,
      table_name: 'payments',
      klass_name: 'Payment',
      polymorphic: false,
      inverse_name: nil,
      association_primary_key: 'id'
    )

    model = ActiveRecordOptimizer::ModelScanner::Model.new(
      klass: nil,
      name: 'User',
      table_name: 'users',
      reflections: [reflection],
      default_scopes: [],
      defined_enums: {},
      source_location: nil
    )

    table = ActiveRecordOptimizer::SchemaScanner::Table.new(
      name: 'payments',
      primary_key: 'id',
      columns: {},
      indexes: [],
      foreign_keys: [],
      estimated_row_count: estimated_row_count
    )

    schema = ActiveRecordOptimizer::SchemaScanner::Schema.new(tables: { 'payments' => table })
    configuration = ActiveRecordOptimizer::Configuration.new

    ActiveRecordOptimizer::Runner::Context.new(
      schema: schema,
      models: [model],
      query_usages: [],
      migration_changes: [],
      configuration: configuration
    )
  end

  def scanned_association_context
    ActiveRecordOptimizer::Runner::Context.new(
      schema: ActiveRecordOptimizer::SchemaScanner.new.call,
      models: ActiveRecordOptimizer::ModelScanner.new.call,
      query_usages: [],
      migration_changes: [],
      configuration: ActiveRecordOptimizer::Configuration.new
    )
  end
end

class AssociationLifecycleRulesTest < ActiveRecordOptimizerTest
  include AssociationRulesTestSupport

  def test_dependent_destroy_requires_large_child_table_evidence
    context = context_for_dependent_destroy(estimated_row_count: 500)

    findings = ActiveRecordOptimizer::Rules::AssociationRules.new.call(context)

    refute_includes findings.map(&:code), 'broad_dependent_destroy'
  end

  def test_dependent_destroy_reports_when_child_table_estimate_is_large
    context = context_for_dependent_destroy(estimated_row_count: 50_000)

    findings = ActiveRecordOptimizer::Rules::AssociationRules.new.call(context)
    finding = findings.find { |entry| entry.code == 'broad_dependent_destroy' }

    refute_nil finding
    assert_includes finding.evidence, 'estimated rows=50000'
  end

  def test_missing_inverse_of_is_not_reported_when_rails_can_infer_inverse
    create_schema(index_payment_user: true, foreign_key: true)

    TestModels.const_set(:User, Class.new(ActiveRecord::Base) do
      self.table_name = 'users'
      has_many :payments, dependent: :destroy, class_name: 'TestModels::Payment'
    end)

    TestModels.const_set(:Payment, Class.new(ActiveRecord::Base) do
      self.table_name = 'payments'
      belongs_to :user, class_name: 'TestModels::User'
    end)

    findings = ActiveRecordOptimizer::Rules::AssociationRules.new.call(scanned_association_context)

    refute_includes findings.map(&:code), 'missing_inverse_of'
  end

  def test_missing_inverse_of_is_reported_when_rails_cannot_infer_inverse
    create_schema(index_payment_user: true, foreign_key: true)

    TestModels.const_set(:User, Class.new(ActiveRecord::Base) do
      self.table_name = 'users'
      has_many :paid_payments, -> { where(status: 1) },
               autosave: true,
               class_name: 'TestModels::Payment',
               foreign_key: 'user_id'
    end)

    TestModels.const_set(:Payment, Class.new(ActiveRecord::Base) do
      self.table_name = 'payments'
      belongs_to :user, class_name: 'TestModels::User'
    end)

    findings = ActiveRecordOptimizer::Rules::AssociationRules.new.call(scanned_association_context)

    assert_includes findings.map(&:code), 'missing_inverse_of'
  end
end

class AssociationForeignKeyRulesTest < ActiveRecordOptimizerTest
  include AssociationRulesTestSupport

  def test_missing_foreign_key_recommendation_includes_column_for_custom_foreign_key
    ActiveRecord::Schema.define do
      create_table :users, force: true do |table|
        table.string :name
      end

      create_table :payments, force: true do |table|
        table.integer :payer_id
      end
    end

    TestModels.const_set(:User, Class.new(ActiveRecord::Base) do
      self.table_name = 'users'
    end)

    TestModels.const_set(:Payment, Class.new(ActiveRecord::Base) do
      self.table_name = 'payments'
      belongs_to :payer, class_name: 'TestModels::User', foreign_key: 'payer_id'
    end)

    findings = ActiveRecordOptimizer::Rules::AssociationRules.new.call(scanned_association_context)
    finding = findings.find { |entry| entry.code == 'missing_foreign_key_constraint' }

    refute_nil finding
    assert_equal 'add_foreign_key :payments, :users, column: :payer_id', finding.recommendation
  end

  def test_missing_foreign_key_recommendation_includes_primary_key_for_custom_association_key
    ActiveRecord::Schema.define do
      create_table :accounts, primary_key: :uuid, id: :string, force: true do |table|
        table.string :name
      end

      create_table :payments, force: true do |table|
        table.string :account_uuid
      end
    end

    TestModels.const_set(:Account, Class.new(ActiveRecord::Base) do
      self.table_name = 'accounts'
      self.primary_key = 'uuid'
    end)

    TestModels.const_set(:Payment, Class.new(ActiveRecord::Base) do
      self.table_name = 'payments'
      belongs_to :account, class_name: 'TestModels::Account', foreign_key: 'account_uuid', primary_key: 'uuid'
    end)

    findings = ActiveRecordOptimizer::Rules::AssociationRules.new.call(scanned_association_context)
    finding = findings.find { |entry| entry.code == 'missing_foreign_key_constraint' }

    refute_nil finding
    assert_equal 'add_foreign_key :payments, :accounts, column: :account_uuid, primary_key: :uuid', finding.recommendation
  end

  def test_wrong_target_primary_key_does_not_satisfy_missing_foreign_key_rule
    ActiveRecord::Schema.define do
      create_table :accounts, force: true do |table|
        table.string :uuid
      end

      create_table :payments, force: true do |table|
        table.integer :account_id
      end

      add_foreign_key :payments, :accounts, column: :account_id
    end

    TestModels.const_set(:Account, Class.new(ActiveRecord::Base) do
      self.table_name = 'accounts'
      self.primary_key = 'uuid'
    end)

    TestModels.const_set(:Payment, Class.new(ActiveRecord::Base) do
      self.table_name = 'payments'
      belongs_to :account, class_name: 'TestModels::Account', foreign_key: 'account_id', primary_key: 'uuid'
    end)

    findings = ActiveRecordOptimizer::Rules::AssociationRules.new.call(scanned_association_context)

    assert_includes findings.map(&:code), 'missing_foreign_key_constraint'
  end
end
