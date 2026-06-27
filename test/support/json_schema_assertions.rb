# frozen_string_literal: true

require 'json_schemer'
require 'pathname'

module JsonSchemaAssertions
  private

  def assert_valid_against_schema(payload, schema_filename)
    errors = schema_for(schema_filename).validate(payload).to_a

    assert_empty errors, "Expected payload to match #{schema_filename}, got: #{errors.inspect}"
  end

  def schema_for(schema_filename)
    @schema_cache ||= {}
    @schema_cache[schema_filename] ||= JSONSchemer.schema(Pathname(schema_path(schema_filename)))
  end

  def schema_path(schema_filename)
    File.expand_path("../../docs/#{schema_filename}", __dir__)
  end
end
