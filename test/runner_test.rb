# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class RunnerFindingsTest < ActiveRecordOptimizerTest
  def test_reports_missing_belongs_to_index_and_foreign_key
    create_schema
    define_payment_models

    report = ActiveRecordOptimizer::Runner.new(root: Dir.mktmpdir).call
    codes = report.findings.map(&:code)

    assert_includes codes, 'missing_belongs_to_index'
    assert_includes codes, 'missing_foreign_key_constraint'
    assert_equal 1, report.exit_status('high')
  end

  def test_does_not_report_missing_belongs_to_index_when_index_exists
    create_schema(index_payment_user: true)
    define_payment_models

    report = ActiveRecordOptimizer::Runner.new(root: Dir.mktmpdir).call
    codes = report.findings.map(&:code)

    refute_includes codes, 'missing_belongs_to_index'
    assert_includes codes, 'missing_foreign_key_constraint'
  end

  def test_reports_foreign_key_without_child_index
    create_schema(foreign_key: true)
    define_payment_models

    report = ActiveRecordOptimizer::Runner.new(root: Dir.mktmpdir).call
    codes = report.findings.map(&:code)

    assert_includes codes, 'foreign_key_without_index'
  end

  def test_prefers_specific_enum_where_finding_over_generic_recurring_where_finding
    create_schema(index_payment_user: true)
    define_payment_models
    root = root_with_model_source

    report = ActiveRecordOptimizer::Runner.new(root: root).call
    codes = report.findings.map(&:code)

    assert_includes codes, 'enum_where_without_index'
    refute_includes codes, 'recurring_where_without_index'
    assert_includes codes, 'order_without_index'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_reports_reference_migration_without_current_foreign_key
    create_schema(index_payment_user: true)
    ActiveRecord::Base.connection.add_column(:payments, :account_id, :integer)
    define_payment_models
    root = root_with_model_source
    write_migration(root)

    report = ActiveRecordOptimizer::Runner.new(root: root).call
    codes = report.findings.map(&:code)

    assert_includes codes, 'migration_reference_without_foreign_key'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_reports_order_findings_for_local_relation_variables_in_source_scans
    create_schema(index_payment_user: true)
    ActiveRecord::Base.connection.add_index(:payments, :status)
    define_payment_models
    root = Dir.mktmpdir
    create_source_root(root)
    write_source_file(
      root,
      'app/services/local_variable_report.rb',
      <<~RUBY
        class LocalVariableReport
          def call
            payments = TestModels::Payment.where(status: :paid)
            payments.order(created_at: :desc)
          end
        end
      RUBY
    )

    report = ActiveRecordOptimizer::Runner.new(root: root).call

    assert_includes report.findings.map(&:code), 'order_without_index'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_reports_order_findings_for_reorder_calls_in_source_scans
    create_schema(index_payment_user: true)
    ActiveRecord::Base.connection.add_index(:payments, :status)
    define_payment_models
    root = Dir.mktmpdir
    create_source_root(root)
    write_source_file(
      root,
      'app/services/reorder_report.rb',
      <<~RUBY
        class ReorderReport
          def call
            payments = TestModels::Payment.where(status: :paid)
            payments.reorder(created_at: :desc)
          end
        end
      RUBY
    )

    report = ActiveRecordOptimizer::Runner.new(root: root).call

    assert_includes report.findings.map(&:code), 'order_without_index'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_does_not_report_polymorphic_reference_migration_as_missing_foreign_key
    ActiveRecord::Schema.define do
      create_table :activity_events, force: true do |table|
        table.integer :subject_id
        table.string :subject_type
        table.timestamps
      end
    end
    root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(root, 'db/migrate'))
    write_polymorphic_reference_migration(root)

    report = ActiveRecordOptimizer::Runner.new(root: root).call

    refute_includes report.findings.map(&:code), 'migration_reference_without_foreign_key'
  ensure
    ActiveRecord::Base.connection.drop_table(:activity_events, if_exists: true)
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end
end

class RunnerSourceRelationContextTest < ActiveRecordOptimizerTest
  def test_named_scope_where_context_prevents_false_order_finding_for_supported_composite_index
    create_schema(index_payment_user: true)
    ActiveRecord::Base.connection.add_index(:payments, %i[status created_at])
    define_payment_models
    root = root_with_model_source
    write_source_file(
      root,
      'app/services/named_scope_report.rb',
      <<~RUBY
        class NamedScopeReport
          def call
            TestModels::Payment.paid_only.order(created_at: :desc)
          end
        end
      RUBY
    )

    report = ActiveRecordOptimizer::Runner.new(root: root).call

    refute_includes report.findings.map(&:code), 'order_without_index'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_model_class_method_where_context_prevents_false_order_finding_for_supported_composite_index
    create_schema(index_payment_user: true)
    ActiveRecord::Base.connection.add_index(:payments, %i[status created_at])
    define_payment_models
    root = Dir.mktmpdir
    create_source_root(root)
    write_source_file(
      root,
      'app/models/test_models/payment.rb',
      <<~RUBY
        class TestModels::Payment < ActiveRecord::Base
          def self.paid_only_via_class_method
            where(status: :paid)
          end
        end
      RUBY
    )
    write_source_file(
      root,
      'app/services/class_method_report.rb',
      <<~RUBY
        class ClassMethodReport
          def call
            TestModels::Payment.paid_only_via_class_method.order(created_at: :desc)
          end
        end
      RUBY
    )

    report = ActiveRecordOptimizer::Runner.new(root: root).call

    refute_includes report.findings.map(&:code), 'order_without_index'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_parameterized_model_class_method_where_context_prevents_false_order_finding
    create_schema(index_payment_user: true)
    ActiveRecord::Base.connection.add_index(:payments, %i[status created_at])
    define_payment_models
    root = Dir.mktmpdir
    create_source_root(root)
    write_source_file(
      root,
      'app/models/test_models/payment.rb',
      <<~RUBY
        class TestModels::Payment < ActiveRecord::Base
          def self.for_status(status)
            where(status: status)
          end
        end
      RUBY
    )
    write_source_file(
      root,
      'app/services/parameterized_class_method_report.rb',
      <<~RUBY
        class ParameterizedClassMethodReport
          def call
            TestModels::Payment.for_status(:paid).order(created_at: :desc)
          end
        end
      RUBY
    )

    report = ActiveRecordOptimizer::Runner.new(root: root).call

    refute_includes report.findings.map(&:code), 'order_without_index'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end
end

class RunnerDelegationAndSingletonRelationContextTest < ActiveRecordOptimizerTest
  def test_delegating_model_class_method_where_context_prevents_false_order_finding
    create_schema(index_payment_user: true)
    ActiveRecord::Base.connection.add_index(:payments, %i[status created_at])
    define_payment_models
    root = Dir.mktmpdir
    create_source_root(root)
    write_source_file(
      root,
      'app/models/test_models/payment.rb',
      <<~RUBY
        class TestModels::Payment < ActiveRecord::Base
          def self.paid_only_via_delegation
            for_status(:paid)
          end

          def self.for_status(status)
            where(status: status)
          end
        end
      RUBY
    )
    write_source_file(
      root,
      'app/services/delegating_class_method_report.rb',
      <<~RUBY
        class DelegatingClassMethodReport
          def call
            TestModels::Payment.paid_only_via_delegation.order(created_at: :desc)
          end
        end
      RUBY
    )

    report = ActiveRecordOptimizer::Runner.new(root: root).call

    refute_includes report.findings.map(&:code), 'order_without_index'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_singleton_class_relation_helper_where_context_prevents_false_order_finding
    create_schema(index_payment_user: true)
    ActiveRecord::Base.connection.add_index(:payments, %i[status created_at])
    define_payment_models
    root = Dir.mktmpdir
    create_source_root(root)
    write_source_file(
      root,
      'app/models/test_models/payment.rb',
      <<~RUBY
        class TestModels::Payment < ActiveRecord::Base
          class << self
            def paid_only_via_singleton_class
              where(status: :paid)
            end
          end
        end
      RUBY
    )
    write_source_file(
      root,
      'app/services/singleton_class_report.rb',
      <<~RUBY
        class SingletonClassReport
          def call
            TestModels::Payment.paid_only_via_singleton_class.order(created_at: :desc)
          end
        end
      RUBY
    )

    report = ActiveRecordOptimizer::Runner.new(root: root).call

    refute_includes report.findings.map(&:code), 'order_without_index'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end
end

class RunnerConfigurationTest < ActiveRecordOptimizerTest
  def test_filters_findings_from_project_config
    create_schema
    define_payment_models
    root = Dir.mktmpdir
    File.write(
      File.join(root, '.active_record_optimizer.yml'),
      <<~YAML
        ignored_findings:
          - code: missing_belongs_to_index
            table: payments
      YAML
    )

    report = ActiveRecordOptimizer::Runner.new(root: root).call
    codes = report.findings.map(&:code)

    refute_includes codes, 'missing_belongs_to_index'
    assert_includes codes, 'missing_foreign_key_constraint'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_optimize_respects_json_output_format_from_config
    create_schema
    define_payment_models
    root = Dir.mktmpdir
    output = StringIO.new
    File.write(File.join(root, '.active_record_optimizer.yml'), "output_format: json\n")

    report = ActiveRecordOptimizer.optimize(root: root, output: output)
    payload = JSON.parse(output.string)

    assert_equal report.findings.size, payload['findings'].size
    assert_equal 'missing_belongs_to_index', payload['findings'].first['code']
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_invalid_project_config_fails_fast
    create_schema(index_payment_user: true)
    define_payment_models
    root = Dir.mktmpdir
    File.write(
      File.join(root, '.active_record_optimizer.yml'),
      <<~YAML
        output: json
      YAML
    )

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::Runner.new(root: root).call
    end

    assert_includes error.message, 'Unknown configuration keys: output'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_invalid_project_threshold_config_fails_fast
    create_schema(index_payment_user: true)
    define_payment_models
    root = Dir.mktmpdir
    File.write(
      File.join(root, '.active_record_optimizer.yml'),
      <<~YAML
        planner_row_threshold: 0
      YAML
    )

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::Runner.new(root: root).call
    end

    assert_includes error.message, 'Invalid integer for planner_row_threshold: 0.'
    assert_includes error.message, 'greater than or equal to 1'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end
end

class RunnerRuntimeReportTest < ActiveRecordOptimizerTest
  def test_runtime_query_report_uses_specific_enum_finding_without_generic_duplicate
    create_schema(index_payment_user: true)
    define_payment_models
    root = Dir.mktmpdir
    runtime_path = File.join(root, 'tmp/runtime_report.json')
    FileUtils.mkdir_p(File.dirname(runtime_path))
    File.write(
      File.join(root, '.active_record_optimizer.yml'),
      <<~YAML
        where_occurrence_threshold: 2
        runtime_query_report_path: tmp/runtime_report.json
      YAML
    )

    snapshot = ActiveRecordOptimizer::QueryCollector.capture do
      TestModels::Payment.where(status: 1).load
      TestModels::Payment.where(status: 1).load
    end
    snapshot.write(runtime_path)

    report = ActiveRecordOptimizer::Runner.new(root: root).call

    assert_includes report.findings.map(&:code), 'enum_where_without_index'
    refute_includes report.findings.map(&:code), 'recurring_where_without_index'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_runtime_query_report_keeps_order_finding_for_self_join_filters_on_another_alias
    ActiveRecord::Schema.define do
      create_table :payments, force: true do |table|
        table.integer :parent_payment_id
        table.integer :status
        table.timestamps
      end
    end

    TestModels.const_set(:Payment, Class.new(ActiveRecord::Base) do
      self.table_name = 'payments'
      belongs_to :parent_payment, class_name: 'TestModels::Payment', optional: true
    end)

    root = Dir.mktmpdir
    runtime_path = File.join(root, 'tmp/runtime_report.json')
    FileUtils.mkdir_p(File.dirname(runtime_path))
    File.write(
      File.join(root, '.active_record_optimizer.yml'),
      <<~YAML
        runtime_query_report_path: tmp/runtime_report.json
      YAML
    )

    snapshot = ActiveRecordOptimizer::QueryCollector.capture do
      TestModels::Payment.joins(:parent_payment)
                         .where(parent_payment: { status: 1 })
                         .order(created_at: :desc)
                         .load
    end
    snapshot.write(runtime_path)

    report = ActiveRecordOptimizer::Runner.new(root: root).call

    assert_includes report.findings.map(&:code), 'order_without_index'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_explain_runtime_requires_explainable_sql_in_runtime_report
    create_schema(index_payment_user: true)
    define_payment_models
    root = Dir.mktmpdir
    runtime_path = File.join(root, 'tmp/runtime_report.json')
    FileUtils.mkdir_p(File.dirname(runtime_path))
    File.write(
      File.join(root, '.active_record_optimizer.yml'),
      <<~YAML
        explain_runtime_queries: true
        runtime_query_report_path: tmp/runtime_report.json
      YAML
    )

    snapshot = ActiveRecordOptimizer::QueryCollector.capture do
      TestModels::Payment.where(status: 1).load
      TestModels::Payment.where(status: 1).load
    end
    snapshot.write(runtime_path)

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::Runner.new(root: root).call
    end

    assert_includes error.message, 'does not contain explainable SQL'
    assert_includes error.message, 'literalize_binds: true'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_explain_runtime_requires_runtime_query_report_path
    create_schema(index_payment_user: true)
    define_payment_models
    root = Dir.mktmpdir
    File.write(
      File.join(root, '.active_record_optimizer.yml'),
      <<~YAML
        explain_runtime_queries: true
      YAML
    )

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::Runner.new(root: root).call
    end

    assert_includes error.message, 'requires runtime_query_report_path'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_missing_runtime_query_report_path_raises_clear_error
    create_schema(index_payment_user: true)
    define_payment_models
    root = Dir.mktmpdir
    File.write(
      File.join(root, '.active_record_optimizer.yml'),
      <<~YAML
        runtime_query_report_path: tmp/missing-runtime-report.json
      YAML
    )

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::Runner.new(root: root).call
    end

    assert_includes error.message, 'Runtime query report not found'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end
end
