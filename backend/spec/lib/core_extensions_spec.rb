# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/core_extensions'

RSpec.describe CoreExtensions do
  describe '.present?' do
    it 'returns false for nil' do
      expect(described_class.present?(nil)).to be false
    end

    it 'returns false for empty string' do
      expect(described_class.present?('')).to be false
    end

    it 'returns false for empty array' do
      expect(described_class.present?([])).to be false
    end

    it 'returns false for empty hash' do
      expect(described_class.present?({})).to be false
    end

    it 'returns true for non-empty string' do
      expect(described_class.present?('hello')).to be true
    end

    it 'returns false for whitespace-only string' do
      expect(described_class.present?('  ')).to be false
    end

    it 'returns true for non-empty array' do
      expect(described_class.present?([1, 2])).to be true
    end

    it 'returns true for non-empty hash' do
      expect(described_class.present?({ a: 1 })).to be true
    end

    it 'returns true for zero' do
      expect(described_class.present?(0)).to be true
    end

    it 'returns false for false' do
      expect(described_class.present?(false)).to be false
    end
  end

  describe '.blank?' do
    it 'returns true for nil' do
      expect(described_class.blank?(nil)).to be true
    end

    it 'returns true for empty string' do
      expect(described_class.blank?('')).to be true
    end

    it 'returns true for whitespace-only string' do
      expect(described_class.blank?('   ')).to be true
    end

    it 'returns true for empty array' do
      expect(described_class.blank?([])).to be true
    end

    it 'returns true for empty hash' do
      expect(described_class.blank?({})).to be true
    end

    it 'returns false for non-empty string' do
      expect(described_class.blank?('hello')).to be false
    end

    it 'returns false for non-empty array' do
      expect(described_class.blank?([1])).to be false
    end

    it 'returns false for zero' do
      expect(described_class.blank?(0)).to be false
    end

    it 'returns true for false' do
      expect(described_class.blank?(false)).to be true
    end
  end

  describe '.titleize' do
    it 'converts underscored string to title case' do
      expect(described_class.titleize('some_category')).to eq('Some Category')
    end

    it 'converts dashed string to title case' do
      expect(described_class.titleize('user-profile')).to eq('User Profile')
    end

    it 'handles already formatted string' do
      expect(described_class.titleize('Hello World')).to eq('Hello World')
    end

    it 'handles single word' do
      expect(described_class.titleize('hello')).to eq('Hello')
    end

    it 'handles nil' do
      expect(described_class.titleize(nil)).to eq('')
    end

    it 'handles multiple underscores and dashes' do
      expect(described_class.titleize('some_long-category_name')).to eq('Some Long Category Name')
    end
  end

  describe '.humanize' do
    it 'converts underscored string to human readable' do
      expect(described_class.humanize('left_eye')).to eq('Left eye')
    end

    it 'converts dashed string to human readable' do
      expect(described_class.humanize('user-profile')).to eq('User profile')
    end

    it 'handles single word' do
      expect(described_class.humanize('hello')).to eq('Hello')
    end

    it 'handles nil' do
      expect(described_class.humanize(nil)).to eq('')
    end
  end

  describe '.truncate' do
    it 'returns short strings unchanged' do
      expect(described_class.truncate('short', 10)).to eq('short')
    end

    it 'truncates long strings with default ellipsis' do
      expect(described_class.truncate('this is a very long string', 15)).to eq('this is a ve...')
    end

    it 'truncates with custom omission' do
      expect(described_class.truncate('this is long', 10, omission: '~')).to eq('this is l~')
    end

    it 'handles nil' do
      expect(described_class.truncate(nil, 10)).to eq('')
    end

    it 'handles exact length' do
      expect(described_class.truncate('hello', 5)).to eq('hello')
    end

    it 'handles string shorter than omission' do
      expect(described_class.truncate('hi', 5)).to eq('hi')
    end
  end

  describe '.truncate_words' do
    it 'truncates at word boundary' do
      expect(described_class.truncate_words('hello beautiful world', 15)).to eq('hello...')
    end

    it 'returns short strings unchanged' do
      expect(described_class.truncate_words('hello', 10)).to eq('hello')
    end

    it 'handles nil' do
      expect(described_class.truncate_words(nil, 10)).to eq('')
    end

    it 'handles string with no spaces' do
      expect(described_class.truncate_words('verylongword', 8)).to eq('veryl...')
    end
  end

  describe '.underscore' do
    it 'converts CamelCase to snake_case' do
      expect(described_class.underscore('SomeClassName')).to eq('some_class_name')
    end

    it 'handles consecutive capitals' do
      expect(described_class.underscore('HTTPServer')).to eq('http_server')
    end

    it 'handles namespaces' do
      expect(described_class.underscore('Admin::UserController')).to eq('admin/user_controller')
    end

    it 'handles nil' do
      expect(described_class.underscore(nil)).to eq('')
    end
  end

  describe '.camelize' do
    it 'converts snake_case to CamelCase' do
      expect(described_class.camelize('some_class')).to eq('SomeClass')
    end

    it 'handles single word' do
      expect(described_class.camelize('hello')).to eq('Hello')
    end

    it 'handles nil' do
      expect(described_class.camelize(nil)).to eq('')
    end
  end

  describe '.lower_camelize' do
    it 'converts snake_case to lowerCamelCase' do
      expect(described_class.lower_camelize('some_method')).to eq('someMethod')
    end

    it 'handles single word' do
      expect(described_class.lower_camelize('hello')).to eq('hello')
    end

    it 'handles nil' do
      expect(described_class.lower_camelize(nil)).to eq('')
    end
  end

  describe '.safe_send' do
    let(:obj) { 'hello' }

    it 'calls method on non-nil object' do
      expect(described_class.safe_send(obj, :upcase)).to eq('HELLO')
    end

    it 'returns nil for nil object' do
      expect(described_class.safe_send(nil, :upcase)).to be_nil
    end

    it 'passes arguments to method' do
      expect(described_class.safe_send(obj, :gsub, 'l', 'x')).to eq('hexxo')
    end

    it 'returns nil if method does not exist' do
      expect(described_class.safe_send(obj, :nonexistent_method)).to be_nil
    end
  end

  describe '.ordinalize' do
    it 'handles 1st' do
      expect(described_class.ordinalize(1)).to eq('1st')
    end

    it 'handles 2nd' do
      expect(described_class.ordinalize(2)).to eq('2nd')
    end

    it 'handles 3rd' do
      expect(described_class.ordinalize(3)).to eq('3rd')
    end

    it 'handles 4th through 10th' do
      expect(described_class.ordinalize(4)).to eq('4th')
      expect(described_class.ordinalize(10)).to eq('10th')
    end

    it 'handles teens (11th, 12th, 13th)' do
      expect(described_class.ordinalize(11)).to eq('11th')
      expect(described_class.ordinalize(12)).to eq('12th')
      expect(described_class.ordinalize(13)).to eq('13th')
    end

    it 'handles 21st, 22nd, 23rd' do
      expect(described_class.ordinalize(21)).to eq('21st')
      expect(described_class.ordinalize(22)).to eq('22nd')
      expect(described_class.ordinalize(23)).to eq('23rd')
    end

    it 'handles nil' do
      expect(described_class.ordinalize(nil)).to eq('')
    end
  end

  describe '.pluralize' do
    it 'returns singular for count of 1' do
      expect(described_class.pluralize('item', 1)).to eq('item')
    end

    it 'adds s for regular plurals' do
      expect(described_class.pluralize('item', 5)).to eq('items')
    end

    it 'adds es for words ending in s, x, z, ch, sh' do
      expect(described_class.pluralize('box', 3)).to eq('boxes')
      expect(described_class.pluralize('bus', 2)).to eq('buses')
      expect(described_class.pluralize('match', 4)).to eq('matches')
    end

    it 'handles words ending in consonant+y' do
      expect(described_class.pluralize('city', 2)).to eq('cities')
      expect(described_class.pluralize('party', 3)).to eq('parties')
    end

    it 'handles words ending in vowel+y' do
      expect(described_class.pluralize('day', 2)).to eq('days')
      expect(described_class.pluralize('key', 3)).to eq('keys')
    end
  end

  describe '.count_with_word' do
    it 'formats singular correctly' do
      expect(described_class.count_with_word(1, 'item')).to eq('1 item')
    end

    it 'formats plural correctly' do
      expect(described_class.count_with_word(5, 'item')).to eq('5 items')
    end

    it 'handles zero' do
      expect(described_class.count_with_word(0, 'item')).to eq('0 items')
    end
  end

  # Integration test: Our module works correctly regardless of whether
  # Rails methods are available (they might be loaded by other gems).
  # The point is that code should use OUR explicit methods, not rely
  # on implicit availability.
  describe 'CoreExtensions provides consistent behavior' do
    it 'our present? works the same way ActiveSupport would' do
      expect(described_class.present?('hello')).to be true
      expect(described_class.present?('')).to be false
      expect(described_class.present?(nil)).to be false
    end

    it 'our titleize works the same way ActiveSupport would' do
      expect(described_class.titleize('some_name')).to eq('Some Name')
    end

    it 'our truncate works the same way ActiveSupport would' do
      expect(described_class.truncate('hello world', 8)).to eq('hello...')
    end

    it 'we provide safe alternatives without implicit dependencies' do
      # This test documents that our module can be relied upon
      # regardless of what other gems are loaded
      expect(described_class).to respond_to(:present?)
      expect(described_class).to respond_to(:blank?)
      expect(described_class).to respond_to(:titleize)
      expect(described_class).to respond_to(:humanize)
      expect(described_class).to respond_to(:truncate)
      expect(described_class).to respond_to(:camelize)
    end
  end
end
