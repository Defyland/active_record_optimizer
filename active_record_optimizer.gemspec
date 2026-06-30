# frozen_string_literal: true

require_relative 'lib/active_record_optimizer/version'

Gem::Specification.new do |spec|
  repository_uri = 'https://github.com/Defyland/active_record_optimizer'

  spec.name = 'active_record_optimizer'
  spec.version = ActiveRecordOptimizer::VERSION
  spec.authors = ['Allan Flavio']
  spec.email = ['2706523+Defyland@users.noreply.github.com']

  spec.summary = 'Static, schema-aware Active Record optimizer for Rails applications.'
  spec.description = 'Detects high-evidence Active Record and database integrity/performance risks in Rails apps.'
  spec.homepage = "#{repository_uri}#active-record-optimizer"
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['bug_tracker_uri'] = "#{repository_uri}/issues"
  spec.metadata['documentation_uri'] = "#{repository_uri}#readme"
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['source_code_uri'] = repository_uri

  spec.files = Dir.chdir(__dir__) do
    Dir[
      'lib/**/*.rb',
      'lib/tasks/**/*.rake',
      'README.md',
      'LICENSE.txt',
      'docs/*.json',
      'docs/*.md'
    ].reject { |file| file.start_with?('lib/active_record_optimizer/package_audit') }
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |file| File.basename(file) }
  spec.require_paths = ['lib']

  spec.add_dependency 'activerecord', '>= 7.1', '< 9.0'
  spec.add_dependency 'activesupport', '>= 7.1', '< 9.0'
  spec.add_dependency 'prism', '>= 1.4', '< 2.0'
  spec.add_dependency 'railties', '>= 7.1', '< 9.0'
end
