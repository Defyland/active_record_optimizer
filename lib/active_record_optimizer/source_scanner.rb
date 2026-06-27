# frozen_string_literal: true

require 'prism'

module ActiveRecordOptimizer
  class SourceScanner
    DEFAULT_DIRECTORIES = %w[
      app/models
      app/controllers
      app/services
      app/jobs
      app/queries
      lib
    ].freeze

    def initialize(root:, directories: DEFAULT_DIRECTORIES)
      @root = root
      @directories = directories
    end

    def call(models:)
      visitor = build_query_visitor(models)
      ruby_files.flat_map { |path| visitor.scan_file(path) }
    end

    private

    attr_reader :root, :directories

    def build_query_visitor(models)
      QueryVisitor.new(
        root: root,
        models_by_name: models_by_name(models),
        models_by_path: models_by_path(models),
        table_columns: table_columns(models),
        jsonb_columns: jsonb_columns(models)
      )
    end

    def models_by_name(models)
      models.to_h { |model| [model.name, model] }
    end

    def models_by_path(models)
      models.filter_map { |model| [model.source_location, model] if model.source_location }.to_h
    end

    def table_columns(models)
      models.to_h { |model| [model.table_name, model.klass.columns.map(&:name)] }
    end

    def jsonb_columns(models)
      models.to_h do |model|
        [model.table_name, model.klass.columns.select { |column| column.sql_type == 'jsonb' }.map(&:name)]
      end
    end

    def ruby_files
      directories.flat_map do |directory|
        Dir[File.join(root.to_s, directory, '**/*.rb')]
      end.uniq.sort
    end

    module RelationHelperDefinitionSupport
      private

      def record_named_scope_definition(node)
        return unless node.name == :scope

        scope_name = named_scope_name(node)
        scope_body = named_scope_body(node)
        return unless scope_name && scope_body

        relation_helper_definitions[scope_name] = scope_body
      end

      def record_relation_class_method_definition(node)
        return unless relation_class_method_definition?(node)

        body = last_statement(node.body)
        relation_helper_definitions[node.name.to_s] = body if body
      end

      def relation_class_method_definition?(node)
        node.receiver.is_a?(Prism::SelfNode) || singleton_self_scope?
      end

      def named_scope_name(node)
        argument = call_arguments(node).first

        case argument
        when Prism::SymbolNode, Prism::StringNode
          argument.unescaped.to_s
        end
      end

      def named_scope_body(node)
        lambda_argument = call_arguments(node)[1]
        return last_statement(lambda_argument.body) if lambda_argument.is_a?(Prism::LambdaNode)
        return last_statement(node.block.body) if node.block

        nil
      end

      def last_statement(node)
        return unless node
        return node.body.last if node.is_a?(Prism::StatementsNode)

        node
      end
    end

    module SingletonScopeSupport
      private

      def singleton_self_scope?
        singleton_self_scopes.last == true
      end

      def with_singleton_self_scope(node)
        singleton_self_scopes << node.expression.is_a?(Prism::SelfNode)
        yield
      ensure
        singleton_self_scopes.pop
      end
    end

    class RelationHelperDefinitionCollector < Prism::Visitor
      include PrismHelpers
      include RelationHelperDefinitionSupport
      include SingletonScopeSupport

      attr_reader :relation_helper_definitions, :singleton_self_scopes

      def initialize
        super
        @relation_helper_definitions = {}
        @singleton_self_scopes = []
      end

      def visit_call_node(node) = record_named_scope_definition(node).then { super }

      def visit_def_node(node) = record_relation_class_method_definition(node).then { super }

      def visit_singleton_class_node(node) = with_singleton_self_scope(node) { super }
    end

    module RelationHelperResolutionSupport
      private

      def preload_relation_helper_definitions(program_node)
        collector = RelationHelperDefinitionCollector.new
        collector.visit(program_node)
        relation_helper_definitions[current_model.table_name].merge!(collector.relation_helper_definitions)
      end

      def relation_helper_state(helper_name, table_name)
        helper_name = helper_name.to_s
        state_map = relation_helper_states[table_name]
        return state_map[helper_name] if state_map.key?(helper_name)

        definition = relation_helper_definitions.fetch(table_name, {})[helper_name]
        return unless definition

        resolution_key = [table_name, helper_name]
        return if relation_helper_resolution_keys.include?(resolution_key)

        relation_helper_resolution_keys << resolution_key
        resolved_state = relation_state_for(definition, implicit_table_name: table_name)
        state_map[helper_name] = resolved_state if resolved_state
        resolved_state
      ensure
        relation_helper_resolution_keys.pop if relation_helper_resolution_keys.last == resolution_key
      end
    end

    class QueryVisitor < Prism::Visitor
      include PrismHelpers
      include SingletonScopeSupport
      include RelationHelperResolutionSupport

      RelationState = Data.define(:table_name, :where_columns)
      NON_RELATION_LOCAL = Object.new

      def initialize(models_by_name:, models_by_path:, table_columns:, jsonb_columns:, **)
        super()
        @models_by_name = models_by_name
        @models_by_path = models_by_path
        @table_columns = table_columns
        @jsonb_columns = jsonb_columns
        @relation_helper_states = Hash.new { |hash, table_name| hash[table_name] = {} }
        @relation_helper_definitions = Hash.new { |hash, table_name| hash[table_name] = {} }
        @relation_helper_resolution_keys = []
      end

      def scan_file(path)
        @path = path
        @current_model = models_by_path[path]
        @findings = []
        @local_relation_scopes = []
        @singleton_self_scopes = []
        @source = File.read(path)

        result = Prism.parse(@source)
        preload_relation_helper_definitions(result.value) if current_model
        visit(result.value)
        @findings
      rescue Errno::ENOENT
        []
      end

      def visit_call_node(node)
        relation_state = relation_state_for(node.receiver)
        record_where_usages(node, relation_state.table_name) if node.name == :where && relation_state
        record_order_usages(node, relation_state) if %i[order reorder].include?(node.name) && relation_state
        super
      end

      def visit_local_variable_write_node(node)
        current_local_relation_scope[node.name] = relation_state_for(node.value) || NON_RELATION_LOCAL
        super
      end

      def visit_program_node(node) = with_local_relation_scope { super }

      def visit_class_node(node) = with_local_relation_scope { super }

      def visit_module_node(node) = with_local_relation_scope { super }

      def visit_def_node(node) = with_local_relation_scope { super }

      def visit_defs_node(node) = with_local_relation_scope { super }

      def visit_block_node(node) = with_local_relation_scope { super }

      def visit_lambda_node(node) = with_local_relation_scope { super }

      def visit_singleton_class_node(node) = with_singleton_self_scope(node) { with_local_relation_scope { super } }

      private

      attr_reader :current_model, :findings, :jsonb_columns, :models_by_name, :models_by_path, :path, :source,
                  :table_columns, :local_relation_scopes, :relation_helper_states, :relation_helper_definitions,
                  :relation_helper_resolution_keys, :singleton_self_scopes

      def relation_state_for(receiver, implicit_table_name: current_model&.table_name)
        return base_relation_state(implicit_table_name) if !receiver && implicit_table_name

        case receiver
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          relation_state_for_model(receiver)
        when Prism::CallNode
          relation_state_after_call(receiver, implicit_table_name: implicit_table_name)
        when Prism::LocalVariableReadNode
          local_relation_state(receiver.name)
        end
      end

      def record_where_usages(node, table_name)
        columns_for(table_name).intersection(keyword_column_names(node)).each do |column|
          findings << build_usage(node, table_name, column, 'where')
        end

        jsonb_matches(node, table_name).each do |column|
          findings << build_usage(node, table_name, column, 'jsonb_where')
        end
      end

      def record_order_usages(node, relation_state)
        order_columns(node).intersection(columns_for(relation_state.table_name)).each do |column|
          findings << build_usage(node, relation_state.table_name, column, 'order',
                                  where_columns: relation_state.where_columns)
        end
      end

      def build_usage(node, table_name, column, operation, where_columns: [])
        QueryUsage.source(
          table: table_name,
          column: column,
          operation: operation,
          source: node.location.slice,
          path: path,
          line: node.location.start_line,
          where_columns: where_columns
        )
      end

      def relation_state_for_model(receiver)
        table_name = models_by_name[constant_name(receiver)]&.table_name
        table_name && base_relation_state(table_name)
      end

      def relation_state_after_call(receiver, implicit_table_name:)
        relation_state = relation_state_for(receiver.receiver, implicit_table_name: implicit_table_name)
        return unless relation_state

        scope_state = relation_helper_state(receiver.name, relation_state.table_name)
        return merge_relation_states(relation_state, scope_state) if scope_state
        return relation_state unless receiver.name == :where

        columns = columns_for(relation_state.table_name).intersection(keyword_column_names(receiver))
        RelationState.new(
          table_name: relation_state.table_name,
          where_columns: (relation_state.where_columns + columns).uniq
        )
      end

      def columns_for(table_name) = table_columns.fetch(table_name, [])

      def base_relation_state(table_name) = RelationState.new(table_name: table_name, where_columns: [])

      def merge_relation_states(base_state, added_state)
        RelationState.new(
          table_name: base_state.table_name,
          where_columns: (base_state.where_columns + added_state.where_columns).uniq
        )
      end

      def local_relation_state(name)
        local_relation_scopes.reverse_each do |scope|
          next unless scope.key?(name)

          relation_state = scope[name]
          return nil if relation_state.equal?(NON_RELATION_LOCAL)

          return relation_state
        end

        nil
      end

      def with_local_relation_scope
        local_relation_scopes << {}
        yield
      ensure
        local_relation_scopes.pop
      end

      def jsonb_matches(node, table_name)
        string_arguments(node).flat_map do |string|
          next [] unless string.match?(/(?:->>|->|@>|jsonb_extract_path)/)

          jsonb_columns.fetch(table_name, []).select { |column| string.match?(/\b#{Regexp.escape(column)}\b/) }
        end.uniq
      end

      def order_columns(node)
        keyword_column_names(node) + symbol_arguments(node) + string_order_columns(node)
      end

      def symbol_arguments(node)
        call_arguments(node).grep(Prism::SymbolNode).map(&:unescaped)
      end

      def string_order_columns(node)
        string_arguments(node).flat_map do |string|
          columns = string.split(',').map { |fragment| fragment.strip.split(/\s+/).first }
          columns.compact
        end
      end

      def current_local_relation_scope
        local_relation_scopes.last || raise('source scanner local scope missing')
      end
    end
  end
end
