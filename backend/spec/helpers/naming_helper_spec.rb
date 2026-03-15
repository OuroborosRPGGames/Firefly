# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NamingHelper do
  describe 'module structure' do
    it 'is a module' do
      expect(described_class).to be_a(Module)
    end

    it 'uses module_function pattern' do
      expect(described_class).to respond_to(:to_snake_case)
      expect(described_class).to respond_to(:demodulize)
      expect(described_class).to respond_to(:class_to_snake_case)
    end
  end

  describe '.to_snake_case' do
    it 'converts CamelCase to snake_case' do
      expect(described_class.to_snake_case('CamelCase')).to eq('camel_case')
    end

    it 'converts PascalCase to snake_case' do
      expect(described_class.to_snake_case('PascalCaseTest')).to eq('pascal_case_test')
    end

    it 'handles consecutive capitals' do
      expect(described_class.to_snake_case('HTTPServer')).to eq('http_server')
    end

    it 'handles already snake_case' do
      expect(described_class.to_snake_case('already_snake')).to eq('already_snake')
    end

    it 'handles single word' do
      expect(described_class.to_snake_case('Word')).to eq('word')
    end

    it 'handles nil by converting to string' do
      expect(described_class.to_snake_case(nil)).to eq('')
    end
  end

  describe '.demodulize' do
    it 'returns last part of namespaced class' do
      expect(described_class.demodulize('Commands::Base::Registry')).to eq('Registry')
    end

    it 'returns class name for non-namespaced class' do
      expect(described_class.demodulize('SimpleClass')).to eq('SimpleClass')
    end

    it 'handles empty string' do
      expect(described_class.demodulize('')).to eq('')
    end

    it 'handles nil by converting to string' do
      result = described_class.demodulize(nil)
      expect(result).to eq('')
    end

    it 'handles deeply nested namespaces' do
      expect(described_class.demodulize('A::B::C::D::E')).to eq('E')
    end
  end

  describe '.class_to_snake_case' do
    it 'combines demodulize and to_snake_case' do
      expect(described_class.class_to_snake_case('Commands::TargetResolver')).to eq('target_resolver')
    end

    it 'handles simple class names' do
      expect(described_class.class_to_snake_case('SimpleName')).to eq('simple_name')
    end

    it 'handles deeply nested namespaces' do
      expect(described_class.class_to_snake_case('A::B::MyClass')).to eq('my_class')
    end
  end
end
