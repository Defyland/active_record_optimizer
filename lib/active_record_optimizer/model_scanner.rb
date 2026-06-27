# frozen_string_literal: true

module ActiveRecordOptimizer
  class ModelScanner
    Model = Data.define(:klass, :name, :table_name, :reflections, :default_scopes, :defined_enums, :source_location)
    Reflection = Data.define(:name, :macro, :options, :foreign_key, :foreign_type, :table_name, :klass_name,
                             :polymorphic, :inverse_name, :association_primary_key)

    def initialize(base: ActiveRecord::Base, root: nil)
      @base = base
      @root = root
    end

    def call
      eager_load_application
      models
    end

    private

    attr_reader :base, :root

    def eager_load_application
      Rails.application.eager_load! if defined?(Rails.application) && Rails.application
    end

    def models
      scanned_models = base.descendants.filter_map do |klass|
        next if klass.abstract_class?
        next unless klass.table_exists?

        Model.new(
          klass: klass,
          name: klass.name,
          table_name: klass.table_name,
          reflections: reflections_for(klass),
          default_scopes: default_scopes_for(klass),
          defined_enums: defined_enums_for(klass),
          source_location: source_location_for(klass)
        )
      rescue ActiveRecord::StatementInvalid, NoMethodError
        nil
      end

      scanned_models.uniq { |model| [model.name, model.table_name] }
    end

    def reflections_for(klass)
      klass.reflect_on_all_associations.map do |reflection|
        Reflection.new(
          name: reflection.name.to_s,
          macro: reflection.macro.to_s,
          options: reflection.options.transform_keys(&:to_s),
          foreign_key: reflection.respond_to?(:foreign_key) ? reflection.foreign_key.to_s : nil,
          foreign_type: reflection.respond_to?(:foreign_type) ? reflection.foreign_type.to_s : nil,
          table_name: table_name_for(reflection),
          klass_name: reflection.class_name,
          polymorphic: reflection.options[:polymorphic] == true,
          inverse_name: inverse_name_for(reflection),
          association_primary_key: association_primary_key_for(reflection)
        )
      end
    end

    def table_name_for(reflection)
      return nil if reflection.options[:polymorphic]

      reflection.klass.table_name
    rescue NameError, ActiveRecord::StatementInvalid
      nil
    end

    def inverse_name_for(reflection)
      reflection.inverse_of&.name&.to_s
    rescue NameError, ActiveRecord::StatementInvalid
      nil
    end

    def association_primary_key_for(reflection)
      return nil unless reflection.respond_to?(:association_primary_key)

      reflection.association_primary_key&.to_s
    rescue NameError, ActiveRecord::StatementInvalid
      nil
    end

    def default_scopes_for(klass)
      return [] unless klass.respond_to?(:default_scopes)

      klass.default_scopes
    end

    def defined_enums_for(klass)
      return {} unless klass.respond_to?(:defined_enums)

      klass.defined_enums.transform_keys(&:to_s)
    end

    def source_location_for(klass)
      return nil unless root && klass.name

      relative_path = "app/models/#{klass.name.underscore}.rb"
      path = File.join(root.to_s, relative_path)
      File.exist?(path) ? path : nil
    end
  end
end
