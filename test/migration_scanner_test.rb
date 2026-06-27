# frozen_string_literal: true

require 'test_helper'

class MigrationScannerTest < ActiveRecordOptimizerTest
  def test_finds_real_reference_changes_without_comment_false_positives
    root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(root, 'db/migrate'))
    write_ast_migration(root)

    changes = ActiveRecordOptimizer::MigrationScanner.new(root: root).call

    columns = changes.map(&:column)

    assert_includes columns, 'account_id'
    assert_includes columns, 'merchant_id'
    refute_includes columns, 'ignored_id'
    refute_includes columns, 'user_id'
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_ignores_reference_migrations_that_enable_foreign_key_via_hash_options
    root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(root, 'db/migrate'))
    write_foreign_key_hash_migration(root)

    changes = ActiveRecordOptimizer::MigrationScanner.new(root: root).call

    assert_empty changes
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  def test_ignores_polymorphic_reference_migrations
    root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(root, 'db/migrate'))
    write_polymorphic_reference_migration(root)

    changes = ActiveRecordOptimizer::MigrationScanner.new(root: root).call

    assert_empty changes
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end
end
