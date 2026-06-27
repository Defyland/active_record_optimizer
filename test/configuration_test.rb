# frozen_string_literal: true

require 'test_helper'

class ConfigurationTest < Minitest::Test
  def test_apply_rejects_unknown_configuration_keys
    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::Configuration.new.apply('mystery_toggle' => true)
    end

    assert_includes error.message, 'Unknown configuration keys: mystery_toggle'
  end

  def test_apply_rejects_invalid_integer_values
    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::Configuration.new.apply('where_occurrence_threshold' => 'often')
    end

    assert_equal 'Invalid integer for where_occurrence_threshold: "often".', error.message
  end

  def test_apply_rejects_non_positive_threshold_values
    %w[dependent_destroy_row_threshold planner_row_threshold where_occurrence_threshold].each do |key|
      [0, -1].each do |value|
        error = assert_raises(ActiveRecordOptimizer::Error) do
          ActiveRecordOptimizer::Configuration.new.apply(key => value)
        end

        assert_equal "Invalid integer for #{key}: #{value}. Expected an integer greater than or equal to 1.",
                     error.message
      end
    end
  end

  def test_apply_rejects_invalid_boolean_values
    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::Configuration.new.apply('explain_runtime_queries' => 'sometimes')
    end

    assert_equal 'Invalid boolean for explain_runtime_queries: "sometimes".', error.message
  end

  def test_apply_rejects_invalid_output_format
    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::Configuration.new.apply('output_format' => 'yaml')
    end

    assert_equal 'Invalid value for output_format: "yaml". Use one of: json, text.', error.message
  end

  def test_apply_rejects_invalid_ignored_findings_rule_shape
    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::Configuration.new.apply(
        'ignored_findings' => [{ 'code' => 'missing_foreign_key_constraint', 'owner' => 'payments' }]
      )
    end

    assert_equal 'Invalid ignored_findings[0]: unknown keys owner.', error.message
  end

  def test_apply_accepts_valid_ignored_findings_rule
    configuration = ActiveRecordOptimizer::Configuration.new.apply(
      'ignored_findings' => [{ 'code' => 'missing_foreign_key_constraint', 'table' => 'payments' }]
    )

    assert_equal [{ code: 'missing_foreign_key_constraint', table: 'payments' }], configuration.ignored_findings
  end
end
