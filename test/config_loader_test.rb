# frozen_string_literal: true

require 'test_helper'

class ConfigLoaderTest < Minitest::Test
  def test_loads_default_project_config
    root = Dir.mktmpdir
    File.write(
      File.join(root, '.active_record_optimizer.yml'),
      <<~YAML
        dependent_destroy_row_threshold: 2000
        explain_runtime_queries: true
        planner_row_threshold: 5000
        where_occurrence_threshold: 4
        output_format: json
        ignored_tables:
          - internal_events
      YAML
    )

    config = ActiveRecordOptimizer::ConfigLoader.new(root: root).load

    assert_equal 2000, config['dependent_destroy_row_threshold']
    assert_equal 4, config['where_occurrence_threshold']
    assert_equal true, config['explain_runtime_queries']
    assert_equal 5000, config['planner_row_threshold']
    assert_equal 'json', config['output_format']
    assert_equal ['internal_events'], config['ignored_tables']
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_explicit_missing_config_path_raises_clear_error
    root = Dir.mktmpdir

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::ConfigLoader.new(root: root).load(path: File.join(root, 'missing.yml'))
    end

    assert_equal "Configuration file not found: #{File.join(root, 'missing.yml')}.", error.message
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_explicit_relative_config_path_resolves_from_root
    root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(root, 'config'))
    File.write(
      File.join(root, 'config/active_record_optimizer.yml'),
      <<~YAML
        where_occurrence_threshold: 5
      YAML
    )

    config = Dir.mktmpdir do |other_directory|
      Dir.chdir(other_directory) do
        ActiveRecordOptimizer::ConfigLoader.new(root: root).load(path: 'config/active_record_optimizer.yml')
      end
    end

    assert_equal 5, config['where_occurrence_threshold']
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_invalid_yaml_raises_clear_error
    root = Dir.mktmpdir
    path = File.join(root, '.active_record_optimizer.yml')
    File.write(path, "ignored_tables:\n  - payments\n  :\n")

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::ConfigLoader.new(root: root).load
    end

    assert_includes error.message, "Failed to parse configuration file #{path}:"
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_non_hash_yaml_raises_clear_error
    root = Dir.mktmpdir
    path = File.join(root, '.active_record_optimizer.yml')
    File.write(path, "- not\n- a\n- mapping\n")

    error = assert_raises(ActiveRecordOptimizer::Error) do
      ActiveRecordOptimizer::ConfigLoader.new(root: root).load
    end

    assert_equal "Configuration file #{path} must contain a top-level mapping.", error.message
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end
end
