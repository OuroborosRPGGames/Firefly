# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ApproachHandler do
  describe 'module extensions' do
    it 'extends TimedActionHandler' do
      expect(described_class.singleton_class.included_modules).to include(TimedActionHandler)
    end
  end

  describe 'class methods' do
    it 'defines call' do
      expect(described_class).to respond_to(:call)
    end

    describe '.call' do
      it 'accepts a timed_action parameter' do
        method_params = described_class.method(:call).parameters
        expect(method_params).to include([:req, :timed_action])
      end
    end
  end

  describe '.resolve_target_name' do
    # Access private class method
    def resolve_target_name(data)
      described_class.send(:resolve_target_name, data)
    end

    context 'when target_type is furniture' do
      it 'returns item name from database' do
        item = double(name: 'Leather Chair')
        allow(Item).to receive(:[]).with(123).and_return(item)

        result = resolve_target_name({ 'target_type' => 'furniture', 'target_id' => 123 })
        expect(result).to eq('Leather Chair')
      end

      it 'returns default when item not found' do
        allow(Item).to receive(:[]).with(999).and_return(nil)

        result = resolve_target_name({ 'target_type' => 'furniture', 'target_id' => 999 })
        expect(result).to eq('the object')
      end
    end

    context 'when target_type is character' do
      it 'returns character full name from database' do
        target_char = double(full_name: 'Bob Smith')
        char_instance = double(character: target_char)
        allow(CharacterInstance).to receive(:[]).with(456).and_return(char_instance)

        result = resolve_target_name({ 'target_type' => 'character', 'target_id' => 456 })
        expect(result).to eq('Bob Smith')
      end

      it 'returns default when character not found' do
        allow(CharacterInstance).to receive(:[]).with(999).and_return(nil)

        result = resolve_target_name({ 'target_type' => 'character', 'target_id' => 999 })
        expect(result).to eq('them')
      end
    end

    context 'when target_type is unknown' do
      it 'returns there' do
        result = resolve_target_name({ 'target_type' => 'unknown', 'target_id' => 1 })
        expect(result).to eq('there')
      end
    end
  end
end
