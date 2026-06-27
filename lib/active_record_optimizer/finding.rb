# frozen_string_literal: true

module ActiveRecordOptimizer
  SEVERITY_RANK = {
    'low' => 1,
    'medium' => 2,
    'high' => 3
  }.freeze

  Finding = Data.define(
    :severity,
    :code,
    :title,
    :model,
    :table,
    :column,
    :problem,
    :recommendation,
    :evidence,
    :details
  ) do
    def rank
      ActiveRecordOptimizer::SEVERITY_RANK.fetch(severity)
    end

    def to_h
      {
        severity: severity,
        code: code,
        title: title,
        model: model,
        table: table,
        column: column,
        problem: problem,
        recommendation: recommendation,
        evidence: evidence,
        details: details
      }
    end
  end
end
