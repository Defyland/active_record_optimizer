# frozen_string_literal: true

module ActiveRecordOptimizer
  class SchemaScanner
    Schema = Data.define(:tables)
    Table = Data.define(:name, :primary_key, :columns, :indexes, :foreign_keys, :estimated_row_count)
    Column = Data.define(:name, :type, :sql_type, :null)
    Index = Data.define(:name, :columns, :unique, :using, :orders, :opclasses, :where)
    ForeignKey = Data.define(:name, :from_table, :to_table, :columns, :primary_key)

    def initialize(connection: ActiveRecord::Base.connection, ignored_tables: [], extra_tables: [])
      @connection = connection
      @ignored_tables = ignored_tables.map(&:to_s)
      @extra_tables = extra_tables.map(&:to_s)
    end

    def call
      Schema.new(tables: tables.to_h { |table| [table.name, table] })
    end

    private

    attr_reader :connection, :extra_tables, :ignored_tables

    def tables
      scan_table_names.filter_map do |table_name|
        next if ignored_tables.include?(table_name)

        Table.new(
          name: table_name,
          primary_key: connection.primary_key(table_name),
          columns: columns_for(table_name),
          indexes: indexes_for(table_name),
          foreign_keys: foreign_keys_for(table_name),
          estimated_row_count: estimated_row_count_for(table_name)
        )
      end
    end

    def scan_table_names
      deduplicate_search_path_aliases((connection.tables + extra_tables).uniq)
    end

    def columns_for(table_name)
      connection.columns(table_name).to_h do |column|
        [
          column.name,
          Column.new(
            name: column.name,
            type: column.type,
            sql_type: column.sql_type,
            null: column.null
          )
        ]
      end
    end

    def indexes_for(table_name)
      connection.indexes(table_name).map do |index|
        Index.new(
          name: index.name,
          columns: Array(index.columns).map(&:to_s),
          unique: index.unique,
          using: index.respond_to?(:using) ? index.using : nil,
          orders: index.respond_to?(:orders) ? index.orders : nil,
          opclasses: index.respond_to?(:opclasses) ? index.opclasses : nil,
          where: index.respond_to?(:where) ? index.where : nil
        )
      end
    end

    def foreign_keys_for(table_name)
      connection.foreign_keys(table_name).map do |foreign_key|
        ForeignKey.new(
          name: foreign_key.options[:name],
          from_table: foreign_key.from_table,
          to_table: foreign_key.to_table,
          columns: Array(foreign_key.options[:column]).map(&:to_s),
          primary_key: foreign_key.options[:primary_key]
        )
      end
    rescue NotImplementedError
      []
    end

    def estimated_row_count_for(table_name)
      return unless connection.adapter_name.to_s.downcase == 'postgresql'

      schema_name, relation_name = split_table_identifier(table_name)

      return estimated_row_count_for_search_path_table(relation_name) unless schema_name

      connection.select_value(<<~SQL)&.to_i
        SELECT c.reltuples::bigint
        FROM pg_class c
        INNER JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = #{connection.quote(relation_name)}
          AND n.nspname = #{connection.quote(schema_name)}
        LIMIT 1
      SQL
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def estimated_row_count_for_search_path_table(table_name)
      connection.select_value(<<~SQL)&.to_i
        SELECT c.reltuples::bigint
        FROM pg_class c
        INNER JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = #{connection.quote(table_name)}
          AND n.nspname = ANY (current_schemas(false))
        ORDER BY array_position(current_schemas(false), n.nspname)
        LIMIT 1
      SQL
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def split_table_identifier(table_name)
      parts = table_name.to_s.split('.', 2)
      return [nil, table_name] if parts.size == 1

      parts
    end

    def deduplicate_search_path_aliases(table_names)
      return table_names unless connection.adapter_name.to_s.downcase == 'postgresql'

      qualified_extra_tables = extra_tables.select do |table_name|
        schema_name, = split_table_identifier(table_name)
        schema_name && search_path_schemas.include?(schema_name)
      end
      redundant_unqualified_names = qualified_extra_tables.map { |table_name| split_table_identifier(table_name).last }.uniq

      table_names.reject do |table_name|
        schema_name, = split_table_identifier(table_name)
        schema_name.nil? && redundant_unqualified_names.include?(table_name)
      end
    end

    def search_path_schemas
      @search_path_schemas ||= connection.select_values('SELECT unnest(current_schemas(false))')
    rescue ActiveRecord::StatementInvalid
      []
    end
  end
end
