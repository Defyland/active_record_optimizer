# frozen_string_literal: true

require 'test_helper'

class ReportTest < Minitest::Test
  def test_json_schema_artifact_matches_report_version
    schema = JSON.parse(File.read(File.expand_path('../docs/json-report-schema-v1.json', __dir__)))

    assert_equal(
      ActiveRecordOptimizer::Report::JSON_SCHEMA_VERSION,
      schema.dig('properties', 'metadata', 'properties', 'schema_version', 'const')
    )
  end

  def test_no_findings_text_and_exit_status
    report = ActiveRecordOptimizer::Report.new([])

    assert_equal 'ActiveRecordOptimizer: no findings.', report.to_text
    assert_equal 0, report.exit_status('high')
  end

  def test_fail_on_threshold
    report = ActiveRecordOptimizer::Report.new(
      [
        ActiveRecordOptimizer::Finding.new(
          severity: 'medium',
          code: 'example',
          title: 'Example',
          model: nil,
          table: 'payments',
          column: nil,
          problem: 'Problem',
          recommendation: 'Recommendation',
          evidence: 'Evidence',
          details: nil
        )
      ]
    )

    assert_equal 0, report.exit_status('high')
    assert_equal 1, report.exit_status('medium')
  end

  def test_invalid_fail_on_threshold_raises_clear_error
    report = ActiveRecordOptimizer::Report.new([])

    error = assert_raises(ArgumentError) { report.exit_status('critical') }

    assert_equal 'Unknown severity "critical". Use one of: high, medium, low.', error.message
  end

  def test_render_json_output
    report = ActiveRecordOptimizer::Report.new(
      [
        ActiveRecordOptimizer::Finding.new(
          severity: 'high',
          code: 'missing_foreign_key_constraint',
          title: 'Missing foreign key constraint',
          model: 'Payment',
          table: 'payments',
          column: 'user_id',
          problem: 'Problem',
          recommendation: 'Recommendation',
          evidence: 'Evidence',
          details: { planner_confirmed: true }
        )
      ]
    )

    payload = JSON.parse(report.render('json'))

    assert_equal ActiveRecordOptimizer::Report::JSON_SCHEMA_VERSION, payload['metadata']['schema_version']
    assert_equal 'active_record_optimizer', payload['metadata']['generator']['name']
    assert_equal 1, payload['counts']['high']
    assert_equal 'missing_foreign_key_constraint', payload['findings'].first['code']
    assert_equal true, payload['findings'].first['details']['planner_confirmed']
    assert_valid_against_schema(payload, 'json-report-schema-v1.json')
  end
end
