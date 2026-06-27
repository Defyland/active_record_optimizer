# frozen_string_literal: true

require 'test_helper'

module PostgresModels
end

module PostgreSQLIntegrationTestSupport
  private

  def create_postgresql_schema(add_expression_index: false, add_whole_column_btree_index: false,
                               add_whole_column_gin_index: false)
    ActiveRecord::Schema.define do
      create_table :users, force: true do |table|
        table.string :name
        table.timestamps
      end

      create_table :payments, force: true do |table|
        table.references :user, null: false, foreign_key: true
        table.jsonb :metadata, null: false, default: {}
        table.timestamps
      end
    end

    if add_expression_index
      ActiveRecord::Base.connection.execute <<~SQL
        CREATE INDEX index_payments_on_metadata_status_expr
        ON payments ((metadata ->> 'status'))
      SQL
    end

    create_whole_column_jsonb_index(:btree) if add_whole_column_btree_index
    create_whole_column_jsonb_index(:gin) if add_whole_column_gin_index
  end

  def create_schema_qualified_postgresql_schema
    ActiveRecord::Base.connection.execute('CREATE SCHEMA analytics')

    ActiveRecord::Schema.define do
      create_table 'analytics.payments', force: true do |table|
        table.integer :status
        table.jsonb :metadata, null: false, default: {}
        table.timestamps
      end
    end
  end

  def define_postgres_models
    PostgresModels.const_set(:User, Class.new(ActiveRecord::Base) do
      self.table_name = 'users'
      has_many :payments, class_name: 'PostgresModels::Payment'
    end)

    PostgresModels.const_set(:Payment, Class.new(ActiveRecord::Base) do
      self.table_name = 'payments'
      belongs_to :user, class_name: 'PostgresModels::User'
    end)
  end

  def define_schema_qualified_postgres_models
    PostgresModels.const_set(:QualifiedPayment, Class.new(ActiveRecord::Base) do
      self.table_name = 'analytics.payments'
    end)
  end

  def root_with_postgres_sources(payment_source = nil)
    Dir.mktmpdir.tap do |root|
      FileUtils.mkdir_p(File.join(root, 'app/models/postgres_models'))
      File.write(
        File.join(root, 'app/models/postgres_models/payment.rb'),
        payment_source || <<~RUBY
          class PostgresModels::Payment < ActiveRecord::Base
            scope :by_status, ->(value) { where("metadata ->> 'status' = ?", value) }
          end
        RUBY
      )
    end
  end

  def root_with_schema_qualified_postgres_sources(payment_source = nil)
    Dir.mktmpdir.tap do |root|
      FileUtils.mkdir_p(File.join(root, 'app/models/postgres_models'))
      File.write(
        File.join(root, 'app/models/postgres_models/qualified_payment.rb'),
        payment_source || <<~RUBY
          class PostgresModels::QualifiedPayment < ActiveRecord::Base
            self.table_name = "analytics.payments"

            scope :by_status, ->(value) { where("metadata ->> 'status' = ?", value) }
          end
        RUBY
      )
    end
  end

  def create_whole_column_jsonb_index(kind)
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE INDEX index_payments_on_metadata_#{kind}
      ON payments USING #{kind} (metadata)
    SQL
  end

  def remove_postgres_constants
    %i[Payment QualifiedPayment User].each do |constant|
      PostgresModels.send(:remove_const, constant) if PostgresModels.const_defined?(constant, false)
    end
  end
end

class PostgreSQLIntegrationTestCase < Minitest::Test
  include PostgreSQLSupport
  include PostgreSQLIntegrationTestSupport

  def teardown
    remove_postgres_constants
  end
end

class PostgreSQLSchemaIntegrationTest < PostgreSQLIntegrationTestCase
  def test_schema_qualified_model_source_query_is_reported
    with_postgresql_database do
      create_schema_qualified_postgresql_schema
      define_schema_qualified_postgres_models
      root = root_with_schema_qualified_postgres_sources

      report = ActiveRecordOptimizer::Runner.new(root: root).call

      assert_includes report.findings.map(&:code), 'jsonb_query_without_index'
      assert_includes report.findings.map(&:table), 'analytics.payments'
    ensure
      FileUtils.remove_entry(root) if root && Dir.exist?(root)
    end
  end

  def test_jsonb_expression_index_prevents_false_positive
    with_postgresql_database do
      create_postgresql_schema(add_expression_index: true)
      define_postgres_models
      root = root_with_postgres_sources

      report = ActiveRecordOptimizer::Runner.new(root: root).call

      refute_includes report.findings.map(&:code), 'jsonb_query_without_index'
    ensure
      FileUtils.remove_entry(root) if root && Dir.exist?(root)
    end
  end

  def test_jsonb_query_without_index_is_reported_on_postgresql
    with_postgresql_database do
      create_postgresql_schema
      define_postgres_models
      root = root_with_postgres_sources

      report = ActiveRecordOptimizer::Runner.new(root: root).call

      assert_includes report.findings.map(&:code), 'jsonb_query_without_index'
    ensure
      FileUtils.remove_entry(root) if root && Dir.exist?(root)
    end
  end

  def test_btree_index_on_jsonb_column_does_not_hide_expression_query_problem
    with_postgresql_database do
      create_postgresql_schema(add_whole_column_btree_index: true)
      define_postgres_models
      root = root_with_postgres_sources(
        <<~RUBY
          class PostgresModels::Payment < ActiveRecord::Base
            scope :by_status, ->(value) { where("metadata ->> 'status' = ?", value) }
          end
        RUBY
      )

      report = ActiveRecordOptimizer::Runner.new(root: root).call

      assert_includes report.findings.map(&:code), 'jsonb_query_without_index'
    ensure
      FileUtils.remove_entry(root) if root && Dir.exist?(root)
    end
  end

  def test_whole_column_gin_index_supports_jsonb_containment_query
    with_postgresql_database do
      create_postgresql_schema(add_whole_column_gin_index: true)
      define_postgres_models
      root = root_with_postgres_sources(
        <<~RUBY
          class PostgresModels::Payment < ActiveRecord::Base
            scope :with_status_payload, ->(value) { where("metadata @> ?", { status: value }.to_json) }
          end
        RUBY
      )

      report = ActiveRecordOptimizer::Runner.new(root: root).call

      refute_includes report.findings.map(&:code), 'jsonb_query_without_index'
    ensure
      FileUtils.remove_entry(root) if root && Dir.exist?(root)
    end
  end

  def test_schema_scanner_reads_postgresql_row_estimates
    with_postgresql_database do
      create_postgresql_schema
      define_postgres_models
      user = PostgresModels::User.create!(name: 'u1')
      20.times { PostgresModels::Payment.create!(user: user, metadata: { status: 'paid' }) }
      ActiveRecord::Base.connection.execute('ANALYZE payments')

      schema = ActiveRecordOptimizer::SchemaScanner.new.call

      assert_operator schema.tables.fetch('payments').estimated_row_count, :>=, 1
    end
  end
end

class PostgreSQLRuntimeReportIntegrationTest < PostgreSQLIntegrationTestCase
  def test_runtime_report_detects_schema_qualified_runtime_findings
    with_postgresql_database do
      create_schema_qualified_postgresql_schema
      define_schema_qualified_postgres_models
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
        2.times { PostgresModels::QualifiedPayment.where(status: 1).order(created_at: :desc).load }
      end
      snapshot.write(runtime_path)

      report = ActiveRecordOptimizer::Runner.new(root: root).call
      findings = report.findings.select { |finding| finding.table == 'analytics.payments' }

      assert_includes findings.map(&:code), 'recurring_where_without_index'
      assert_includes findings.map(&:code), 'order_without_index'
    ensure
      FileUtils.remove_entry(root) if root && Dir.exist?(root)
    end
  end

  def test_runtime_report_canonicalizes_unqualified_sql_via_search_path_for_schema_qualified_model
    with_postgresql_database do
      create_schema_qualified_postgresql_schema
      define_schema_qualified_postgres_models
      ActiveRecord::Base.connection.execute('SET search_path TO analytics, public')
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
        2.times do
          ActiveRecord::Base.connection.exec_query(
            'SELECT "payments".* FROM "payments" ' \
            'WHERE "payments"."status" = 1 ORDER BY "payments"."created_at" DESC'
          )
        end
      end
      snapshot.write(runtime_path)

      report = ActiveRecordOptimizer::Runner.new(root: root).call
      findings = report.findings.select { |finding| finding.table == 'analytics.payments' }

      assert_includes findings.map(&:code), 'recurring_where_without_index'
      assert_includes findings.map(&:code), 'order_without_index'
    ensure
      FileUtils.remove_entry(root) if root && Dir.exist?(root)
    end
  end

  def test_runtime_report_detects_jsonb_containment_without_index
    with_postgresql_database do
      create_postgresql_schema
      define_postgres_models
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
        2.times { PostgresModels::Payment.where('metadata @> ?', { status: 'paid' }.to_json).load }
      end
      snapshot.write(runtime_path)

      report = ActiveRecordOptimizer::Runner.new(root: root).call

      assert_includes report.findings.map(&:code), 'jsonb_query_without_index'
    ensure
      FileUtils.remove_entry(root) if root && Dir.exist?(root)
    end
  end
end

class PostgreSQLRuntimeExplainIntegrationTest < PostgreSQLIntegrationTestCase
  def test_explain_runtime_requires_runtime_report_path
    with_postgresql_database do
      create_postgresql_schema
      define_postgres_models
      root = Dir.mktmpdir
      File.write(
        File.join(root, '.active_record_optimizer.yml'),
        <<~YAML
          explain_runtime_queries: true
          planner_row_threshold: 1
        YAML
      )

      error = assert_raises(ActiveRecordOptimizer::Error) do
        ActiveRecordOptimizer::Runner.new(root: root).call
      end

      assert_includes error.message, 'requires runtime_query_report_path'
    ensure
      FileUtils.remove_entry(root) if root && Dir.exist?(root)
    end
  end

  def test_explain_runtime_fails_fast_without_explainable_sql
    with_postgresql_database do
      create_postgresql_schema
      define_postgres_models
      root = Dir.mktmpdir
      runtime_path = File.join(root, 'tmp/runtime_report.json')
      FileUtils.mkdir_p(File.dirname(runtime_path))
      File.write(
        File.join(root, '.active_record_optimizer.yml'),
        <<~YAML
          explain_runtime_queries: true
          planner_row_threshold: 1
          runtime_query_report_path: tmp/runtime_report.json
        YAML
      )

      snapshot = ActiveRecordOptimizer::QueryCollector.capture do
        2.times { PostgresModels::Payment.where("metadata ->> 'status' = ?", 'paid').load }
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
  end

  def test_literalized_runtime_report_can_append_postgresql_explain_evidence
    with_postgresql_database do
      create_postgresql_schema
      define_postgres_models
      root = Dir.mktmpdir
      runtime_path = File.join(root, 'tmp/runtime_report.json')
      FileUtils.mkdir_p(File.dirname(runtime_path))
      File.write(
        File.join(root, '.active_record_optimizer.yml'),
        <<~YAML
          explain_runtime_queries: true
          planner_row_threshold: 1
          runtime_query_report_path: tmp/runtime_report.json
        YAML
      )

      snapshot = ActiveRecordOptimizer::QueryCollector.capture(literalize_binds: true) do
        2.times { PostgresModels::Payment.where("metadata ->> 'status' = ?", 'paid').load }
      end
      snapshot.write(runtime_path)

      report = ActiveRecordOptimizer::Runner.new(root: root).call
      finding = report.findings.find { |entry| entry.code == 'jsonb_query_without_index' }

      refute_nil finding
      assert_equal 'high', finding.severity
      assert_includes finding.evidence, 'postgresql plan:'
      assert_includes finding.evidence, 'Seq Scan'
    ensure
      FileUtils.remove_entry(root) if root && Dir.exist?(root)
    end
  end
end
