# frozen_string_literal: true

require 'pg'
require 'securerandom'

module PostgreSQLSupport
  SQLITE_CONFIG = { adapter: 'sqlite3', database: ':memory:' }.freeze

  def with_postgresql_database
    skip 'PostgreSQL integration disabled' unless postgres_integration_enabled?

    database_name = "active_record_optimizer_#{Process.pid}_#{SecureRandom.hex(4)}"
    admin_connection = PG.connect(postgres_admin_pg_config)
    admin_connection.exec("CREATE DATABASE #{PG::Connection.quote_ident(database_name)}")

    config = postgres_connection_config(database_name)
    ActiveRecord::Base.establish_connection(config)

    yield config
  ensure
    ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
    drop_postgresql_database(admin_connection, database_name) if admin_connection && database_name
    admin_connection&.close
    ActiveRecord::Base.establish_connection(SQLITE_CONFIG)
  end

  private

  def postgres_integration_enabled?
    ENV['ARO_POSTGRES_INTEGRATION'] == '1'
  end

  def postgres_connection_config(database_name)
    {
      adapter: 'postgresql',
      database: database_name,
      host: ENV.fetch('ARO_POSTGRES_HOST', nil),
      port: ENV.fetch('ARO_POSTGRES_PORT', nil),
      username: ENV.fetch('ARO_POSTGRES_USER', nil),
      password: ENV.fetch('ARO_POSTGRES_PASSWORD', nil)
    }.compact
  end

  def postgres_admin_config
    postgres_connection_config(ENV.fetch('ARO_POSTGRES_ADMIN_DB', 'postgres'))
  end

  def postgres_admin_pg_config
    postgres_admin_config
      .except(:adapter)
      .transform_keys { |key| key == :database ? :dbname : key }
  end

  def drop_postgresql_database(connection, database_name)
    quoted_name = connection.escape_string(database_name)
    connection.exec(<<~SQL)
      SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE datname = '#{quoted_name}' AND pid <> pg_backend_pid()
    SQL
    connection.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(database_name)}")
  rescue PG::Error
    nil
  end
end
