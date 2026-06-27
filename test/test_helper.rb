# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'active_record_optimizer'
require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

Dir[File.expand_path('support/**/*.rb', __dir__)].each { |file| require file }

Minitest::Test.include JsonSchemaAssertions

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Base.logger = nil

module TestModels
end

class ActiveRecordOptimizerTest < Minitest::Test
  def setup
    drop_test_tables
  end

  def teardown
    drop_test_tables
    remove_test_constants
  end

  private

  def create_schema(index_payment_user: false, foreign_key: false)
    ActiveRecord::Schema.define do
      create_table :users, force: true do |table|
        table.string :name
        table.timestamps
      end

      create_table :payments, force: true do |table|
        table.integer :user_id
        table.integer :status
        table.timestamps
      end

      add_index :payments, :user_id if index_payment_user
      add_foreign_key :payments, :users if foreign_key
    end
  end

  def define_payment_models
    TestModels.const_set(:User, Class.new(ActiveRecord::Base) do
      self.table_name = 'users'
      has_many :payments, class_name: 'TestModels::Payment'
    end)

    TestModels.const_set(:Payment, Class.new(ActiveRecord::Base) do
      self.table_name = 'payments'
      belongs_to :user, class_name: 'TestModels::User'
      enum :status, { pending: 0, paid: 1 }
    end)
  end

  def root_with_model_source
    Dir.mktmpdir.tap do |root|
      create_source_root(root)
      write_source_file(root, 'app/models/test_models/payment.rb', payment_model_source)
      write_source_file(root, 'app/services/payment_report.rb', payment_report_source)
      write_source_file(root, 'app/services/noise.rb', noise_source)
    end
  end

  def write_migration(root)
    File.write(
      File.join(root, 'db/migrate/20260101000000_add_account_to_payments.rb'),
      <<~RUBY
        class AddAccountToPayments < ActiveRecord::Migration[8.1]
          def change
            add_column :payments, :account_id, :integer
          end
        end
      RUBY
    )
  end

  def write_ast_migration(root)
    File.write(
      File.join(root, 'db/migrate/20260101000001_ast_paths.rb'),
      <<~RUBY
        class AstPaths < ActiveRecord::Migration[8.1]
          def change
            # add_reference :payments, :ignored
            add_column :payments, :account_id, :integer

            create_table :audit_entries do |t|
              t.references :user, foreign_key: true
              t.belongs_to :merchant
            end
          end
        end
      RUBY
    )
  end

  def write_foreign_key_hash_migration(root)
    File.write(
      File.join(root, 'db/migrate/20260101000002_foreign_key_hash.rb'),
      <<~RUBY
        class ForeignKeyHash < ActiveRecord::Migration[8.1]
          def change
            add_reference :payments, :account, foreign_key: { to_table: :accounts }

            create_table :refunds do |t|
              t.belongs_to :payment, foreign_key: { to_table: :payments }
            end
          end
        end
      RUBY
    )
  end

  def write_polymorphic_reference_migration(root)
    File.write(
      File.join(root, 'db/migrate/20260101000003_polymorphic_reference.rb'),
      <<~RUBY
        class PolymorphicReference < ActiveRecord::Migration[8.1]
          def change
            add_reference :activity_events, :subject, polymorphic: true

            create_table :notifications do |t|
              t.references :recipient, polymorphic: true
            end
          end
        end
      RUBY
    )
  end

  def create_source_root(root)
    %w[app/models/test_models app/services db/migrate].each do |directory|
      FileUtils.mkdir_p(File.join(root, directory))
    end
  end

  def write_source_file(root, relative_path, contents)
    File.write(File.join(root, relative_path), contents)
  end

  def payment_model_source
    <<~RUBY
      class TestModels::Payment < ActiveRecord::Base
        scope :paid_only, -> { where(status: :paid) }
        scope :recent_paid, -> { where(status: :paid).order(created_at: :desc) }
      end
    RUBY
  end

  def payment_report_source
    <<~RUBY
      class PaymentReport
        def call
          TestModels::Payment.where(status: :paid).order(created_at: :desc)
        end
      end
    RUBY
  end

  def noise_source
    <<~RUBY
      class Noise
        COMMENT = "order(created_at: :desc)"

        def call
          # TestModels::Payment.where(status: :paid)
          "where(status: :paid)"
        end
      end
    RUBY
  end

  def drop_test_tables
    %i[payments users accounts].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  def remove_test_constants
    %i[Payment User Account].each do |constant|
      TestModels.send(:remove_const, constant) if TestModels.const_defined?(constant, false)
    end
  end
end
