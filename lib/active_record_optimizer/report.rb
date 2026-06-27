# frozen_string_literal: true

module ActiveRecordOptimizer
  class Report
    FORMATS = %w[json text].freeze
    JSON_SCHEMA_VERSION = 1

    def self.normalize_severity(severity)
      return unless severity

      severity.to_s.downcase.tap do |value|
        next if ActiveRecordOptimizer::SEVERITY_RANK.key?(value)

        raise ArgumentError, "Unknown severity #{severity.inspect}. Use one of: high, medium, low."
      end
    end

    attr_reader :findings, :metadata

    def initialize(findings, metadata: nil)
      @findings = findings.sort_by { |finding| [-finding.rank, finding.code, finding.table.to_s, finding.column.to_s] }
      @metadata = metadata || default_metadata
    end

    def render(format = 'text')
      normalized_format = normalize_format(format)
      return JSON.pretty_generate(as_json) if normalized_format == 'json'

      to_text
    end

    def to_text
      return 'ActiveRecordOptimizer: no findings.' if findings.empty?

      findings.map { |finding| format_finding(finding) }.join("\n\n")
    end

    def as_json(*)
      {
        metadata: metadata,
        counts: counts_by_severity,
        findings: findings.map(&:to_h)
      }
    end

    def fail_on?(severity)
      threshold_name = normalize_severity(severity)
      return false unless threshold_name

      threshold = ActiveRecordOptimizer::SEVERITY_RANK.fetch(threshold_name)
      findings.any? { |finding| finding.rank >= threshold }
    end

    def exit_status(fail_on)
      fail_on?(fail_on) ? 1 : 0
    end

    private

    def normalize_format(format)
      return 'text' unless format

      format.to_s.downcase.tap do |value|
        next if FORMATS.include?(value)

        raise ArgumentError, "Unknown format #{format.inspect}. Use one of: #{FORMATS.join(', ')}."
      end
    end

    def normalize_severity(severity)
      self.class.normalize_severity(severity)
    end

    def default_metadata
      {
        schema_version: JSON_SCHEMA_VERSION,
        generator: ActiveRecordOptimizer.generator_metadata
      }
    end

    def counts_by_severity
      findings.each_with_object(Hash.new(0)) do |finding, counts|
        counts[finding.severity] += 1
      end
    end

    def format_finding(finding)
      lines = ["#{finding.severity.upcase}: #{finding.title}"]
      lines << section('Model', finding.model) if finding.model
      lines << section('Table', finding.table) if finding.table
      lines << section('Column', finding.column) if finding.column
      lines << section('Problem', finding.problem)
      lines << section('Recommendation', finding.recommendation)
      lines << section('Evidence', finding.evidence)
      lines.join("\n")
    end

    def section(title, value)
      "#{title}:\n  #{value.to_s.gsub("\n", "\n  ")}"
    end
  end
end
