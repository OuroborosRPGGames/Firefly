# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GameSetting do
  # Clean up between tests
  before do
    described_class.clear_cache!
    described_class.dataset.delete
  end

  describe 'constants' do
    it 'defines VALUE_TYPES' do
      expect(described_class::VALUE_TYPES).to eq(%w[string integer boolean json])
    end

    it 'defines CATEGORIES' do
      expect(described_class::CATEGORIES).to eq(%w[general weather time ai system delve])
    end

    it 'defines CACHE_TTL' do
      expect(described_class::CACHE_TTL).to eq(GameConfig::Cache::GAME_SETTING_TTL)
    end

    it 'defines CACHE_PREFIX' do
      expect(described_class::CACHE_PREFIX).to eq('game_setting:')
    end
  end

  describe 'validations' do
    it 'requires key' do
      setting = described_class.new(value: 'test')
      expect(setting.valid?).to be false
      expect(setting.errors[:key]).not_to be_nil
    end

    it 'validates key uniqueness' do
      described_class.create(key: 'unique_key', value: 'value1')
      setting = described_class.new(key: 'unique_key', value: 'value2')
      expect(setting.valid?).to be false
    end

    it 'validates value_type is in VALUE_TYPES when present' do
      setting = described_class.new(key: 'test', value: 'test', value_type: 'invalid')
      expect(setting.valid?).to be false
    end

    it 'accepts valid value_types' do
      described_class::VALUE_TYPES.each do |type|
        setting = described_class.new(key: "test_#{type}", value: 'test', value_type: type)
        expect(setting.valid?).to be true
      end
    end

    it 'allows nil value_type' do
      setting = described_class.new(key: 'test', value: 'test', value_type: nil)
      expect(setting.valid?).to be true
    end
  end

  describe '.get' do
    it 'returns nil for non-existent key' do
      expect(described_class.get('nonexistent')).to be_nil
    end

    it 'returns string value' do
      described_class.create(key: 'str_key', value: 'hello', value_type: 'string')
      expect(described_class.get('str_key')).to eq('hello')
    end

    it 'returns integer value' do
      described_class.create(key: 'int_key', value: '42', value_type: 'integer')
      expect(described_class.get('int_key')).to eq(42)
    end

    it 'returns boolean true value' do
      described_class.create(key: 'bool_key', value: 'true', value_type: 'boolean')
      expect(described_class.get('bool_key')).to be true
    end

    it 'returns boolean false value' do
      described_class.create(key: 'bool_key', value: 'false', value_type: 'boolean')
      expect(described_class.get('bool_key')).to be false
    end

    it 'returns parsed json value' do
      described_class.create(key: 'json_key', value: '{"foo":"bar"}', value_type: 'json')
      expect(described_class.get('json_key')).to eq({ 'foo' => 'bar' })
    end

    it 'returns empty hash for invalid json' do
      described_class.create(key: 'bad_json', value: 'not json', value_type: 'json')
      expect(described_class.get('bad_json')).to eq({})
    end

    it 'accepts symbol keys' do
      described_class.create(key: 'sym_key', value: 'value', value_type: 'string')
      expect(described_class.get(:sym_key)).to eq('value')
    end
  end

  describe '.get_boolean' do
    it 'returns true for boolean true' do
      described_class.create(key: 'bool', value: 'true', value_type: 'boolean')
      expect(described_class.get_boolean('bool')).to be true
    end

    it 'returns true for string "true"' do
      described_class.create(key: 'str_true', value: 'true', value_type: 'string')
      expect(described_class.get_boolean('str_true')).to be true
    end

    it 'returns true for string "1"' do
      described_class.create(key: 'str_one', value: '1', value_type: 'string')
      expect(described_class.get_boolean('str_one')).to be true
    end

    it 'returns false for other values' do
      described_class.create(key: 'other', value: 'hello', value_type: 'string')
      expect(described_class.get_boolean('other')).to be false
    end

    it 'returns false for nil' do
      expect(described_class.get_boolean('nonexistent')).to be false
    end
  end

  describe '.get_integer' do
    it 'returns integer value' do
      described_class.create(key: 'int', value: '100', value_type: 'integer')
      expect(described_class.get_integer('int')).to eq(100)
    end

    it 'converts string to integer' do
      described_class.create(key: 'str_int', value: '50', value_type: 'string')
      expect(described_class.get_integer('str_int')).to eq(50)
    end

    it 'returns 0 for non-numeric string' do
      described_class.create(key: 'str', value: 'hello', value_type: 'string')
      expect(described_class.get_integer('str')).to eq(0)
    end
  end

  describe '.get_float' do
    it 'returns float value' do
      described_class.create(key: 'float', value: '3.14', value_type: 'string')
      expect(described_class.get_float('float')).to be_within(0.001).of(3.14)
    end

    it 'converts integer to float' do
      described_class.create(key: 'int', value: '5', value_type: 'integer')
      expect(described_class.get_float('int')).to eq(5.0)
    end

    it 'returns nil for missing keys' do
      expect(described_class.get_float('nonexistent')).to be_nil
    end
  end

  describe '.set' do
    it 'creates new setting' do
      result = described_class.set('new_key', 'new_value')
      expect(result).to be_a(described_class)
      expect(described_class.get('new_key')).to eq('new_value')
    end

    it 'updates existing setting' do
      described_class.create(key: 'existing', value: 'old', value_type: 'string')
      described_class.set('existing', 'new')
      expect(described_class.get('existing')).to eq('new')
    end

    it 'accepts type parameter for new settings' do
      described_class.set('typed', '42', type: 'integer')
      expect(described_class.get('typed')).to eq(42)
    end

    it 'updates type for existing settings when provided' do
      described_class.create(key: 'changing', value: '10', value_type: 'string')
      described_class.set('changing', '20', type: 'integer')
      expect(described_class.get('changing')).to eq(20)
    end

    it 'serializes hash values to json' do
      described_class.set('hash_val', { a: 1, b: 2 }, type: 'json')
      setting = described_class.first(key: 'hash_val')
      expect(setting.value).to eq('{"a":1,"b":2}')
    end

    it 'serializes array values to json' do
      described_class.set('arr_val', [1, 2, 3], type: 'json')
      setting = described_class.first(key: 'arr_val')
      expect(setting.value).to eq('[1,2,3]')
    end
  end

  describe '.for_category' do
    before do
      described_class.create(key: 'weather_temp', value: '72', value_type: 'integer', category: 'weather')
      described_class.create(key: 'weather_rain', value: 'true', value_type: 'boolean', category: 'weather')
      described_class.create(key: 'general_name', value: 'Firefly', value_type: 'string', category: 'general')
    end

    it 'returns hash of settings in category' do
      result = described_class.for_category('weather')
      expect(result).to be_a(Hash)
      expect(result['weather_temp']).to eq(72)
      expect(result['weather_rain']).to be true
    end

    it 'does not include settings from other categories' do
      result = described_class.for_category('weather')
      expect(result.keys).not_to include('general_name')
    end

    it 'returns empty hash for unknown category' do
      result = described_class.for_category('nonexistent')
      expect(result).to eq({})
    end
  end

  describe '.clear_cache!' do
    it 'returns true' do
      expect(described_class.clear_cache!).to be true
    end
  end

  describe '.invalidate_cache' do
    it 'does not raise error' do
      expect { described_class.invalidate_cache('test_key') }.not_to raise_error
    end
  end

  describe 'caching behavior' do
    # These tests verify the caching mechanism works correctly

    it 'caches values after first get' do
      described_class.create(key: 'cached', value: 'original', value_type: 'string')

      # First get populates cache
      expect(described_class.get('cached')).to eq('original')

      # Direct database update (bypassing cache)
      described_class.first(key: 'cached').update(value: 'changed')

      # Should still return cached value
      expect(described_class.get('cached')).to eq('original')
    end

    it 'invalidates cache on set' do
      described_class.create(key: 'invalidate_test', value: 'old', value_type: 'string')
      described_class.get('invalidate_test') # Populate cache

      # Use set which invalidates cache
      described_class.set('invalidate_test', 'new')

      expect(described_class.get('invalidate_test')).to eq('new')
    end
  end

  describe 'private class methods' do
    describe '#cast_value' do
      it 'returns nil for nil value' do
        result = described_class.send(:cast_value, nil, 'string')
        expect(result).to be_nil
      end

      it 'casts to integer' do
        result = described_class.send(:cast_value, '42', 'integer')
        expect(result).to eq(42)
      end

      it 'casts boolean "yes" to true' do
        result = described_class.send(:cast_value, 'yes', 'boolean')
        expect(result).to be true
      end

      it 'casts boolean "no" to false' do
        result = described_class.send(:cast_value, 'no', 'boolean')
        expect(result).to be false
      end

      it 'casts boolean "1" to true' do
        result = described_class.send(:cast_value, '1', 'boolean')
        expect(result).to be true
      end

      it 'parses json' do
        result = described_class.send(:cast_value, '{"key":"value"}', 'json')
        expect(result).to eq({ 'key' => 'value' })
      end

      it 'returns empty hash for invalid json' do
        result = described_class.send(:cast_value, 'not json', 'json')
        expect(result).to eq({})
      end

      it 'returns string for unknown type' do
        result = described_class.send(:cast_value, 'test', 'unknown')
        expect(result).to eq('test')
      end
    end

    describe '#serialize_value' do
      it 'serializes hash to json' do
        result = described_class.send(:serialize_value, { a: 1 })
        expect(result).to eq('{"a":1}')
      end

      it 'serializes array to json' do
        result = described_class.send(:serialize_value, [1, 2])
        expect(result).to eq('[1,2]')
      end

      it 'converts other values to string' do
        result = described_class.send(:serialize_value, 42)
        expect(result).to eq('42')
      end
    end
  end
end
