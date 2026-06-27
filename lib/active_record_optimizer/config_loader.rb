# frozen_string_literal: true

require 'pathname'
require 'yaml'

module ActiveRecordOptimizer
  class ConfigLoader
    DEFAULT_PATHS = [
      '.active_record_optimizer.yml',
      'config/active_record_optimizer.yml'
    ].freeze

    def initialize(root:)
      @root = root
    end

    def load(path: nil)
      config_path = resolve_path(path)
      return {} unless config_path

      raw_config = YAML.safe_load_file(config_path, permitted_classes: [], aliases: false)
      return {} unless raw_config

      unless raw_config.is_a?(Hash)
        raise ActiveRecordOptimizer::Error,
              "Configuration file #{config_path} must contain a top-level mapping."
      end

      raw_config
    rescue Errno::ENOENT
      raise ActiveRecordOptimizer::Error, "Configuration file not found: #{config_path}."
    rescue Psych::Exception => e
      raise ActiveRecordOptimizer::Error, "Failed to parse configuration file #{config_path}: #{e.message}"
    end

    private

    attr_reader :root

    def resolve_path(path)
      if path
        config_path = explicit_config_candidates(path.to_s).find { |candidate| File.exist?(candidate) }
        unless config_path
          raise ActiveRecordOptimizer::Error,
                "Configuration file not found: #{explicit_config_candidates(path.to_s).first}."
        end

        return config_path
      end

      DEFAULT_PATHS.map { |candidate| File.join(root.to_s, candidate) }.find { |candidate| File.exist?(candidate) }
    end

    def explicit_config_candidates(path)
      return [path] if Pathname(path).absolute? || !root

      [File.join(root.to_s, path), path].uniq
    end
  end
end
