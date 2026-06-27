# frozen_string_literal: true

require 'test_helper'

module SourceScannerTestSupport
  private

  def select_usages(usages, column:, operation:)
    usages.select do |usage|
      usage.table == 'payments' && usage.column == column && usage.operation == operation
    end
  end

  def noise_path?(usages)
    usages.any? { |usage| usage.path.end_with?('noise.rb') }
  end
end

class SourceScannerBasicTest < ActiveRecordOptimizerTest
  include SourceScannerTestSupport

  def test_scans_model_and_service_queries_without_counting_comments_or_strings
    create_schema(index_payment_user: true)
    define_payment_models
    root = root_with_model_source
    models = ActiveRecordOptimizer::ModelScanner.new(root: root).call

    usages = ActiveRecordOptimizer::SourceScanner.new(root: root).call(models: models)
    status_where_usages = select_usages(usages, column: 'status', operation: 'where')
    created_at_order_usages = select_usages(usages, column: 'created_at', operation: 'order')

    assert_equal 3, status_where_usages.size
    assert_equal 2, created_at_order_usages.size
    assert_equal [%w[status], %w[status]], created_at_order_usages.map(&:where_columns)
    refute(noise_path?(status_where_usages))
    refute(noise_path?(created_at_order_usages))
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_scans_relation_queries_through_local_variables_and_keeps_where_context
    create_schema(index_payment_user: true)
    define_payment_models
    root = root_with_model_source
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
    models = ActiveRecordOptimizer::ModelScanner.new(root: root).call

    usages = ActiveRecordOptimizer::SourceScanner.new(root: root).call(models: models)
    order_usage = usages.find do |usage|
      usage.path.end_with?('local_variable_report.rb') &&
        usage.operation == 'order' &&
        usage.column == 'created_at'
    end

    refute_nil order_usage
    assert_equal 'payments', order_usage.table
    assert_equal ['status'], order_usage.where_columns
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_scans_reorder_queries_through_local_variables_and_keeps_where_context
    create_schema(index_payment_user: true)
    define_payment_models
    root = root_with_model_source
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
    models = ActiveRecordOptimizer::ModelScanner.new(root: root).call

    usages = ActiveRecordOptimizer::SourceScanner.new(root: root).call(models: models)
    order_usage = usages.find do |usage|
      usage.path.end_with?('reorder_report.rb') &&
        usage.operation == 'order' &&
        usage.column == 'created_at'
    end

    refute_nil order_usage
    assert_equal 'payments', order_usage.table
    assert_equal ['status'], order_usage.where_columns
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end
end

class SourceScannerNamedScopeAndClassMethodTest < ActiveRecordOptimizerTest
  def test_scans_named_scope_queries_with_scope_where_context
    create_schema(index_payment_user: true)
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
    models = ActiveRecordOptimizer::ModelScanner.new(root: root).call

    usages = ActiveRecordOptimizer::SourceScanner.new(root: root).call(models: models)
    order_usage = usages.find do |usage|
      usage.path.end_with?('named_scope_report.rb') &&
        usage.operation == 'order' &&
        usage.column == 'created_at'
    end

    refute_nil order_usage
    assert_equal 'payments', order_usage.table
    assert_equal ['status'], order_usage.where_columns
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_scans_model_class_method_queries_with_where_context
    create_schema(index_payment_user: true)
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
    models = ActiveRecordOptimizer::ModelScanner.new(root: root).call

    usages = ActiveRecordOptimizer::SourceScanner.new(root: root).call(models: models)
    order_usage = usages.find do |usage|
      usage.path.end_with?('class_method_report.rb') &&
        usage.operation == 'order' &&
        usage.column == 'created_at'
    end

    refute_nil order_usage
    assert_equal 'payments', order_usage.table
    assert_equal ['status'], order_usage.where_columns
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_scans_parameterized_model_class_method_queries_with_where_context
    create_schema(index_payment_user: true)
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
    models = ActiveRecordOptimizer::ModelScanner.new(root: root).call

    usages = ActiveRecordOptimizer::SourceScanner.new(root: root).call(models: models)
    order_usage = usages.find do |usage|
      usage.path.end_with?('parameterized_class_method_report.rb') &&
        usage.operation == 'order' &&
        usage.column == 'created_at'
    end

    refute_nil order_usage
    assert_equal 'payments', order_usage.table
    assert_equal ['status'], order_usage.where_columns
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end
end

class SourceScannerDelegationAndSingletonTest < ActiveRecordOptimizerTest
  def test_scans_delegating_model_class_method_queries_when_target_helper_is_defined_later
    create_schema(index_payment_user: true)
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
    models = ActiveRecordOptimizer::ModelScanner.new(root: root).call

    usages = ActiveRecordOptimizer::SourceScanner.new(root: root).call(models: models)
    order_usage = usages.find do |usage|
      usage.path.end_with?('delegating_class_method_report.rb') &&
        usage.operation == 'order' &&
        usage.column == 'created_at'
    end

    refute_nil order_usage
    assert_equal 'payments', order_usage.table
    assert_equal ['status'], order_usage.where_columns
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_scans_singleton_class_relation_helpers_with_where_context
    create_schema(index_payment_user: true)
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
    models = ActiveRecordOptimizer::ModelScanner.new(root: root).call

    usages = ActiveRecordOptimizer::SourceScanner.new(root: root).call(models: models)
    order_usage = usages.find do |usage|
      usage.path.end_with?('singleton_class_report.rb') &&
        usage.operation == 'order' &&
        usage.column == 'created_at'
    end

    refute_nil order_usage
    assert_equal 'payments', order_usage.table
    assert_equal ['status'], order_usage.where_columns
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end
end
