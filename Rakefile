# frozen_string_literal: true

require 'bundler/gem_tasks'
require_relative 'lib/active_record_optimizer'
require_relative 'lib/active_record_optimizer/package_audit'
require 'rake/testtask'

Rake::TestTask.new(:test) do |task|
  task.libs << 'test'
  task.test_files = FileList['test/**/*_test.rb'].exclude(
    'test/postgresql_integration_test.rb',
    'test/package_postgresql_smoke_test.rb'
  )
end

desc 'Run the PostgreSQL integration test suite'
Rake::TestTask.new('test:postgres') do |task|
  task.libs << 'test'
  task.test_files = FileList[
    'test/postgresql_integration_test.rb',
    'test/package_postgresql_smoke_test.rb'
  ]
end

desc 'Run RuboCop'
task :lint do
  sh 'bundle exec rubocop --format simple'
end

desc 'Run bundler-audit'
task :audit do
  sh 'bundle exec bundle-audit check --update'
end

namespace :package do
  desc 'Build the gem and verify packaged public contract artifacts'
  task :verify do
    ActiveRecordOptimizer::PackageAudit.verify!(root: __dir__)
  end
end

desc 'Run the default production-readiness checks'
task verify: %i[test lint audit package:verify]

desc 'Run the PostgreSQL integration checks'
task verify_postgres: ['test:postgres']

task default: :verify
