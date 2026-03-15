# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BooleanHelpers do
  # Create a test class that uses BooleanHelpers
  let(:test_class) do
    Class.new(Sequel::Model) do
      set_dataset :characters # Use existing table for testing

      include BooleanHelpers
      boolean_predicate :admin
      boolean_predicate :invisible, :hidden
    end
  end

  let(:test_class_with_toggle) do
    Class.new(Sequel::Model) do
      set_dataset :characters

      include BooleanHelpers
      boolean_toggle :private_mode
    end
  end

  describe '.boolean_predicate' do
    let(:instance) { test_class.new }

    it 'defines a predicate method for the field' do
      expect(instance).to respond_to(:admin?)
    end

    it 'returns true when field is true' do
      instance.values[:admin] = true
      expect(instance.admin?).to be true
    end

    it 'returns false when field is false' do
      instance.values[:admin] = false
      expect(instance.admin?).to be false
    end

    it 'returns false when field is nil' do
      instance.values[:admin] = nil
      expect(instance.admin?).to be false
    end

    it 'returns false for truthy non-true values' do
      instance.values[:admin] = 1
      expect(instance.admin?).to be false
    end

    context 'with aliases' do
      it 'defines alias predicate methods' do
        expect(instance).to respond_to(:invisible?)
        expect(instance).to respond_to(:hidden?)
      end

      it 'aliases check the same underlying field' do
        instance.values[:invisible] = true
        expect(instance.invisible?).to be true
        expect(instance.hidden?).to be true
      end

      it 'aliases return false together when field is false' do
        instance.values[:invisible] = false
        expect(instance.invisible?).to be false
        expect(instance.hidden?).to be false
      end
    end
  end

  describe '.boolean_toggle' do
    let(:character) { create(:character) }
    let(:room) { create(:room) }
    let(:character_instance) { create(:character_instance, character: character, current_room: room, private_mode: false) }

    # Test with a real model that has the private_mode column
    describe 'toggle method' do
      it 'defines toggle_field! method' do
        expect(character_instance).to respond_to(:toggle_private_mode!)
      end

      it 'toggles false to true' do
        character_instance.update(private_mode: false)
        character_instance.toggle_private_mode!
        expect(character_instance.reload.private_mode?).to be true
      end

      it 'toggles true to false' do
        character_instance.update(private_mode: true)
        character_instance.toggle_private_mode!
        expect(character_instance.reload.private_mode?).to be false
      end
    end

    describe 'enable method' do
      it 'defines enable_field! method' do
        expect(character_instance).to respond_to(:enable_private_mode!)
      end

      it 'sets field to true' do
        character_instance.update(private_mode: false)
        character_instance.enable_private_mode!
        expect(character_instance.reload.private_mode?).to be true
      end

      it 'keeps field true if already true' do
        character_instance.update(private_mode: true)
        character_instance.enable_private_mode!
        expect(character_instance.reload.private_mode?).to be true
      end
    end

    describe 'disable method' do
      it 'defines disable_field! method' do
        expect(character_instance).to respond_to(:disable_private_mode!)
      end

      it 'sets field to false' do
        character_instance.update(private_mode: true)
        character_instance.disable_private_mode!
        expect(character_instance.reload.private_mode?).to be false
      end

      it 'keeps field false if already false' do
        character_instance.update(private_mode: false)
        character_instance.disable_private_mode!
        expect(character_instance.reload.private_mode?).to be false
      end
    end

    describe 'auto-creates predicate method' do
      it 'creates predicate method if not already defined' do
        instance = test_class_with_toggle.new
        expect(instance).to respond_to(:private_mode?)
      end
    end
  end
end
