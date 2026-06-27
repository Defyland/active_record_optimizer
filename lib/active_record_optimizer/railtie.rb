# frozen_string_literal: true

require 'rails/railtie'

module ActiveRecordOptimizer
  class Railtie < Rails::Railtie
    rake_tasks do
      load 'tasks/active_record_optimizer.rake'
    end
  end
end
