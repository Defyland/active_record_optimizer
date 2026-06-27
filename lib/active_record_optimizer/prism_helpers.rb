# frozen_string_literal: true

module ActiveRecordOptimizer
  module PrismHelpers
    module_function

    def constant_name(node)
      case node
      when Prism::ConstantReadNode
        node.name.to_s
      when Prism::ConstantPathNode
        [constant_name(node.parent), node.name.to_s].compact.join('::')
      end
    end

    def symbol_or_string_value(node)
      case node
      when Prism::SymbolNode, Prism::StringNode
        node.unescaped
      end
    end

    def call_arguments(node)
      return [] unless node&.arguments

      node.arguments.arguments
    end

    def keyword_hash_arguments(node)
      call_arguments(node).grep(Prism::KeywordHashNode)
    end

    def keyword_hash_values(node)
      node.elements.to_h do |assoc|
        [symbol_or_string_value(assoc.key), primitive_value(assoc.value)]
      end
    end

    def keyword_column_names(node)
      keyword_hash_arguments(node).flat_map do |hash_node|
        hash_node.elements.filter_map { |assoc| symbol_or_string_value(assoc.key) }
      end
    end

    def primitive_value(node)
      case node
      when Prism::TrueNode then true
      when Prism::FalseNode then false
      when Prism::NilNode then nil
      when Prism::SymbolNode, Prism::StringNode then node.unescaped
      end
    end

    def string_arguments(node)
      call_arguments(node).grep(Prism::StringNode).map(&:unescaped)
    end
  end
end
