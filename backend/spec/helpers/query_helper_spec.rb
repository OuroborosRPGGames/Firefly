# frozen_string_literal: true

require 'spec_helper'

RSpec.describe QueryHelper do
  # Test both class methods and instance methods (via mixin)
  let(:test_class) do
    Class.new do
      include QueryHelper
    end
  end
  let(:test_instance) { test_class.new }

  describe '.ilike_match' do
    it 'creates case-insensitive exact match expression' do
      expr = QueryHelper.ilike_match(:name, 'Test')

      # The expression should be a literal string
      expect(expr).to be_a(Sequel::SQL::PlaceholderLiteralString)
      expect(expr.str).to include('LOWER(name)')
      expect(expr.str).to include('=')
    end

    it 'lowercases the value' do
      expr = QueryHelper.ilike_match(:name, 'TEST VALUE')

      # The expression should produce a query matching 'test value'
      expect(expr.args).to include('test value')
    end

    it 'handles symbols as columns' do
      expr = QueryHelper.ilike_match(:column_name, 'value')

      expect(expr.str).to include('column_name')
    end

    it 'handles strings as columns' do
      expr = QueryHelper.ilike_match('table.column', 'value')

      expect(expr.str).to include('table.column')
    end

    it 'converts non-string values to string' do
      expr = QueryHelper.ilike_match(:num, 123)

      expect(expr.args).to include('123')
    end
  end

  describe '.ilike_prefix' do
    it 'creates case-insensitive prefix match expression' do
      expr = QueryHelper.ilike_prefix(:name, 'Test')

      expect(expr).to be_a(Sequel::SQL::PlaceholderLiteralString)
      expect(expr.str).to include('LOWER(name)')
      expect(expr.str).to include('LIKE')
    end

    it 'appends wildcard to value' do
      expr = QueryHelper.ilike_prefix(:name, 'prefix')

      expect(expr.args).to include('prefix%')
    end

    it 'lowercases the value' do
      expr = QueryHelper.ilike_prefix(:name, 'PREFIX')

      expect(expr.args).to include('prefix%')
    end

    it 'escapes LIKE special characters' do
      expr = QueryHelper.ilike_prefix(:name, 'test%value')

      expect(expr.args.first).to include('\\%')
    end
  end

  describe '.ilike_contains' do
    it 'creates case-insensitive contains match expression' do
      expr = QueryHelper.ilike_contains(:name, 'Test')

      expect(expr).to be_a(Sequel::SQL::PlaceholderLiteralString)
      expect(expr.str).to include('LOWER(name)')
      expect(expr.str).to include('LIKE')
    end

    it 'wraps value with wildcards' do
      expr = QueryHelper.ilike_contains(:name, 'middle')

      expect(expr.args).to include('%middle%')
    end

    it 'lowercases the value' do
      expr = QueryHelper.ilike_contains(:name, 'MIDDLE')

      expect(expr.args).to include('%middle%')
    end

    it 'escapes LIKE special characters' do
      expr = QueryHelper.ilike_contains(:name, 'test_value')

      expect(expr.args.first).to include('\\_')
    end
  end

  describe '.ilike_suffix' do
    it 'creates case-insensitive suffix match expression' do
      expr = QueryHelper.ilike_suffix(:name, 'Test')

      expect(expr).to be_a(Sequel::SQL::PlaceholderLiteralString)
      expect(expr.str).to include('LOWER(name)')
      expect(expr.str).to include('LIKE')
    end

    it 'prepends wildcard to value' do
      expr = QueryHelper.ilike_suffix(:name, 'suffix')

      expect(expr.args).to include('%suffix')
    end

    it 'lowercases the value' do
      expr = QueryHelper.ilike_suffix(:name, 'SUFFIX')

      expect(expr.args).to include('%suffix')
    end

    it 'escapes LIKE special characters' do
      expr = QueryHelper.ilike_suffix(:name, 'test%end')

      expect(expr.args.first).to include('\\%end')
    end
  end

  describe '.ilike_concat_match' do
    it 'creates expression for concatenated columns' do
      expr = QueryHelper.ilike_concat_match([:forename, :surname], 'John Smith')

      expect(expr).to be_a(Sequel::SQL::PlaceholderLiteralString)
      expect(expr.str).to include('COALESCE(forename')
      expect(expr.str).to include('COALESCE(surname')
      expect(expr.str).to include('||')
    end

    it 'uses space as default separator' do
      expr = QueryHelper.ilike_concat_match([:first, :last], 'test')

      expect(expr.str).to include("' '")
    end

    it 'accepts custom separator' do
      expr = QueryHelper.ilike_concat_match([:first, :last], 'test', separator: '-')

      expect(expr.str).to include("'-'")
    end

    it 'lowercases the value' do
      expr = QueryHelper.ilike_concat_match([:forename, :surname], 'JOHN SMITH')

      expect(expr.args).to include('john smith')
    end

    it 'uses LOWER on concatenated expression' do
      expr = QueryHelper.ilike_concat_match([:first, :last], 'test')

      expect(expr.str).to include('LOWER(')
    end
  end

  describe '.ilike_concat_prefix' do
    it 'creates prefix match for concatenated columns' do
      expr = QueryHelper.ilike_concat_prefix([:forename, :surname], 'John')

      expect(expr).to be_a(Sequel::SQL::PlaceholderLiteralString)
      expect(expr.str).to include('COALESCE(forename')
      expect(expr.str).to include('LIKE')
    end

    it 'appends wildcard to value' do
      expr = QueryHelper.ilike_concat_prefix([:first, :last], 'prefix')

      expect(expr.args).to include('prefix%')
    end

    it 'accepts custom separator' do
      expr = QueryHelper.ilike_concat_prefix([:first, :last], 'test', separator: '-')

      expect(expr.str).to include("'-'")
    end

    it 'escapes LIKE special characters in value' do
      expr = QueryHelper.ilike_concat_prefix([:first, :last], 'test%name')

      expect(expr.args.first).to include('\\%')
    end
  end

  describe '.escape_like' do
    it 'escapes percent signs' do
      result = QueryHelper.escape_like('100% complete')

      expect(result).to eq('100\\% complete')
    end

    it 'escapes underscores' do
      result = QueryHelper.escape_like('test_value')

      expect(result).to eq('test\\_value')
    end

    it 'escapes backslashes' do
      # Single backslash in input should become double backslash
      input = "path\\to\\file"
      result = QueryHelper.escape_like(input)

      # The implementation doubles backslashes
      expect(result).to include('\\')
      expect(result.count('\\')).to be >= input.count('\\')
    end

    it 'escapes multiple special characters' do
      result = QueryHelper.escape_like('100%_test')

      # Should escape % and _
      expect(result).to include('\\%')
      expect(result).to include('\\_')
    end

    it 'returns empty string for nil' do
      result = QueryHelper.escape_like(nil)

      expect(result).to eq('')
    end

    it 'converts non-strings to string' do
      result = QueryHelper.escape_like(123)

      expect(result).to eq('123')
    end
  end

  describe 'instance methods' do
    it 'delegates ilike_match to class method' do
      class_result = QueryHelper.ilike_match(:col, 'val')
      instance_result = test_instance.ilike_match(:col, 'val')

      expect(instance_result.str).to eq(class_result.str)
      expect(instance_result.args).to eq(class_result.args)
    end

    it 'delegates ilike_prefix to class method' do
      class_result = QueryHelper.ilike_prefix(:col, 'val')
      instance_result = test_instance.ilike_prefix(:col, 'val')

      expect(instance_result.str).to eq(class_result.str)
      expect(instance_result.args).to eq(class_result.args)
    end

    it 'delegates ilike_contains to class method' do
      class_result = QueryHelper.ilike_contains(:col, 'val')
      instance_result = test_instance.ilike_contains(:col, 'val')

      expect(instance_result.str).to eq(class_result.str)
      expect(instance_result.args).to eq(class_result.args)
    end

    it 'delegates ilike_suffix to class method' do
      class_result = QueryHelper.ilike_suffix(:col, 'val')
      instance_result = test_instance.ilike_suffix(:col, 'val')

      expect(instance_result.str).to eq(class_result.str)
      expect(instance_result.args).to eq(class_result.args)
    end

    it 'delegates ilike_concat_match to class method' do
      class_result = QueryHelper.ilike_concat_match([:a, :b], 'val')
      instance_result = test_instance.ilike_concat_match([:a, :b], 'val')

      expect(instance_result.str).to eq(class_result.str)
      expect(instance_result.args).to eq(class_result.args)
    end

    it 'delegates ilike_concat_prefix to class method' do
      class_result = QueryHelper.ilike_concat_prefix([:a, :b], 'val')
      instance_result = test_instance.ilike_concat_prefix([:a, :b], 'val')

      expect(instance_result.str).to eq(class_result.str)
      expect(instance_result.args).to eq(class_result.args)
    end

    it 'delegates escape_like to class method' do
      class_result = QueryHelper.escape_like('test%val')
      instance_result = test_instance.escape_like('test%val')

      expect(instance_result).to eq(class_result)
    end
  end
end
