# frozen_string_literal: true

require 'prism'

module ActiveRecordOptimizer
  class MigrationScanner
    ReferenceChange = Data.define(:table, :column, :path, :line, :source)

    def initialize(root:)
      @root = root
    end

    def call
      migration_paths.flat_map { |path| MigrationVisitor.new.scan_file(path) }
    end

    private

    attr_reader :root

    def migration_paths
      Dir[File.join(root.to_s, 'db/migrate/*.rb')]
    end

    class MigrationVisitor < Prism::Visitor
      include PrismHelpers

      CREATE_TABLE_METHODS = %i[create_table].freeze
      REFERENCE_METHODS = %i[add_reference add_belongs_to references belongs_to].freeze

      def scan_file(path)
        @path = path
        @findings = []
        @source = File.read(path)
        @table_stack = []

        result = Prism.parse(@source)
        visit(result.value)
        @findings
      rescue Errno::ENOENT
        []
      end

      def visit_call_node(node)
        if create_table_call?(node)
          visit_create_table(node)
        else
          record_reference_change(node)
          super
        end
      end

      private

      attr_reader :findings, :path, :source, :table_stack

      def visit_create_table(node)
        table_name = symbol_or_string_value(call_arguments(node).first)
        builder_name = block_parameter_name(node.block)

        table_stack.push([table_name, builder_name])
        visit(node.block.body) if node.block&.body
      ensure
        table_stack.pop
      end

      def record_reference_change(node)
        change = top_level_reference_change(node) || add_column_reference_change(node) || create_table_reference_change(node)
        findings << change if change
      end

      def top_level_reference_change(node)
        build_reference_change(node, top_level_reference_parts(node))
      end

      def add_column_reference_change(node)
        build_reference_change(node, add_column_parts(node))
      end

      def create_table_reference_change(node)
        build_reference_change(node, create_table_reference_parts(node))
      end

      def create_table_call?(node)
        node.receiver.nil? && CREATE_TABLE_METHODS.include?(node.name) && node.block
      end

      def block_parameter_name(block)
        parameters = block&.parameters&.parameters
        required_parameter = parameters&.requireds&.first
        required_parameter&.name&.to_s
      end

      def builder_receiver?(receiver, builder_name)
        receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name.to_s == builder_name
      end

      def foreign_key_enabled?(node)
        value = keyword_argument_value_node(node, 'foreign_key')

        value.is_a?(Prism::TrueNode) || value.is_a?(Prism::HashNode)
      end

      def polymorphic_reference?(node)
        keyword_argument_value_node(node, 'polymorphic').is_a?(Prism::TrueNode)
      end

      def keyword_argument_value_node(node, key_name)
        keyword_hash_arguments(node).each do |hash_node|
          hash_node.elements.each do |assoc|
            return assoc.value if symbol_or_string_value(assoc.key) == key_name
          end
        end

        nil
      end

      def top_level_reference_parts(node)
        return unless node.receiver.nil?
        return unless %i[add_reference add_belongs_to].include?(node.name)

        table_name, reference_name = call_arguments(node).first(2).map { |arg| symbol_or_string_value(arg) }
        return unless table_name && reference_name

        [table_name, "#{reference_name}_id"]
      end

      def add_column_parts(node)
        return unless node.receiver.nil? && node.name == :add_column

        table_name = symbol_or_string_value(call_arguments(node).first)
        column_name = symbol_or_string_value(call_arguments(node)[1])
        return unless table_name && column_name&.end_with?('_id')

        [table_name, column_name]
      end

      def create_table_reference_parts(node)
        table_name, builder_name = table_stack.last
        return unless table_name && builder_name
        return unless REFERENCE_METHODS.include?(node.name)
        return unless builder_receiver?(node.receiver, builder_name)

        reference_name = symbol_or_string_value(call_arguments(node).first)
        return unless reference_name

        [table_name, "#{reference_name}_id"]
      end

      def build_reference_change(node, parts)
        return unless parts
        return if foreign_key_enabled?(node) || polymorphic_reference?(node)

        table_name, column_name = parts
        build_change(table_name, column_name, node)
      end

      def build_change(table_name, column_name, node)
        ReferenceChange.new(
          table: table_name,
          column: column_name,
          path: path,
          line: node.location.start_line,
          source: node.location.slice
        )
      end
    end
  end
end
