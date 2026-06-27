# frozen_string_literal: true

require 'active_record_optimizer/package_audit'
require 'test_helper'

class PackagePostgreSQLSmokeTest < Minitest::Test
  include PostgreSQLSupport

  def test_built_gem_host_app_rehearsal_runs_on_postgresql
    with_postgresql_database do |connection_config|
      ActiveRecordOptimizer::PackageAudit.verify_postgresql!(
        root: project_root,
        connection_config: connection_config
      )
    end
  end

  private

  def project_root
    File.expand_path('..', __dir__)
  end
end
