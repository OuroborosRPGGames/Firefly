# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StatusEnum do
  # Create a test class that uses StatusEnum
  let(:test_class) do
    Class.new(Sequel::Model) do
      set_dataset :characters # Use existing table for testing

      include StatusEnum
      status_enum :status, %w[pending active completed failed]
    end
  end

  let(:test_class_with_prefix) do
    Class.new(Sequel::Model) do
      set_dataset :characters

      include StatusEnum
      status_enum :status, %w[active inactive], prefix: true
    end
  end

  let(:test_class_custom_prefix) do
    Class.new(Sequel::Model) do
      set_dataset :characters

      include StatusEnum
      status_enum :status, %w[open closed], prefix: 'ticket'
    end
  end

  describe '.status_enum' do
    it 'creates STATUSES constant' do
      expect(test_class.const_defined?(:STATUSES)).to be true
      expect(test_class::STATUSES).to eq(%w[pending active completed failed])
    end

    it 'freezes the constant' do
      expect(test_class::STATUSES).to be_frozen
    end
  end

  describe 'query methods' do
    let(:instance) { test_class.new }

    context 'without prefix' do
      it 'defines query methods for each status' do
        expect(instance).to respond_to(:pending?)
        expect(instance).to respond_to(:active?)
        expect(instance).to respond_to(:completed?)
        expect(instance).to respond_to(:failed?)
      end

      it 'returns true when status matches' do
        instance.values[:status] = 'active'
        expect(instance.active?).to be true
      end

      it 'returns false when status does not match' do
        instance.values[:status] = 'pending'
        expect(instance.active?).to be false
      end
    end

    context 'with prefix: true' do
      let(:prefixed_instance) { test_class_with_prefix.new }

      it 'defines prefixed query methods' do
        expect(prefixed_instance).to respond_to(:status_active?)
        expect(prefixed_instance).to respond_to(:status_inactive?)
      end

      it 'returns correct values' do
        prefixed_instance.values[:status] = 'active'
        expect(prefixed_instance.status_active?).to be true
        expect(prefixed_instance.status_inactive?).to be false
      end
    end

    context 'with custom prefix' do
      let(:custom_instance) { test_class_custom_prefix.new }

      it 'defines custom prefixed query methods' do
        expect(custom_instance).to respond_to(:ticket_open?)
        expect(custom_instance).to respond_to(:ticket_closed?)
      end
    end
  end

  describe 'scope methods' do
    context 'without prefix' do
      it 'defines scope methods for each status' do
        expect(test_class.dataset).to respond_to(:pending)
        expect(test_class.dataset).to respond_to(:active)
        expect(test_class.dataset).to respond_to(:completed)
        expect(test_class.dataset).to respond_to(:failed)
      end

      it 'returns dataset filtered by status' do
        dataset = test_class.dataset.pending
        expect(dataset.sql).to include("\"status\" = 'pending'")
      end
    end

    context 'with prefix: true' do
      it 'defines prefixed scope methods' do
        expect(test_class_with_prefix.dataset).to respond_to(:status_active)
        expect(test_class_with_prefix.dataset).to respond_to(:status_inactive)
      end
    end
  end

  describe '.valid_status?' do
    it 'returns true for valid status' do
      expect(test_class.valid_status?(:status, 'pending')).to be true
      expect(test_class.valid_status?(:status, 'active')).to be true
    end

    it 'returns false for invalid status' do
      expect(test_class.valid_status?(:status, 'invalid')).to be false
    end

    it 'accepts symbol values' do
      expect(test_class.valid_status?(:status, :pending)).to be true
    end

    it 'returns false for unknown column' do
      expect(test_class.valid_status?(:unknown_column, 'pending')).to be false
    end
  end

  describe '#can_transition_to?' do
    let(:instance) { test_class.new }

    it 'returns true for valid status by default' do
      instance.values[:status] = 'pending'
      expect(instance.can_transition_to?('active')).to be true
    end

    it 'returns false for invalid status' do
      instance.values[:status] = 'pending'
      expect(instance.can_transition_to?('invalid')).to be false
    end
  end

  describe '#transition_to!' do
    # Use CharacterInstance which has a real status column
    let(:character) { create(:character) }
    let(:room) { create(:room) }
    let(:character_instance) { create(:character_instance, character: character, current_room: room) }

    # We need to use an actual saved model for this test
    before do
      # Dynamically add the status_enum to CharacterInstance for this test
      CharacterInstance.include(StatusEnum) unless CharacterInstance.ancestors.include?(StatusEnum)
      # Use validate: false to not conflict with existing validations
      CharacterInstance.status_enum :status, %w[alive unconscious dead ghost], validate: false, scopes: false
    end

    it 'updates the status' do
      character_instance.update(status: 'alive')
      character_instance.transition_to!('unconscious')
      expect(character_instance.reload.status).to eq('unconscious')
    end

    it 'raises error for invalid transition when validate is true' do
      character_instance.update(status: 'alive')
      expect { character_instance.transition_to!('invalid', validate: true) }.to raise_error(ArgumentError)
    end
  end

  describe 'validation' do
    it 'adds error for invalid status value' do
      instance = test_class.new
      instance.values[:status] = 'invalid'

      instance.valid?
      expect(instance.errors[:status]).to include('must be one of: pending, active, completed, failed')
    end

    it 'passes validation for valid status value' do
      instance = test_class.new
      instance.values[:status] = 'active'

      # Don't check full validation since we're using a mock model
      instance.send("validate_status_enum")
      # errors[:status] returns nil or empty array when no errors
      expect(instance.errors[:status]).to be_nil.or(be_empty)
    end

    it 'passes validation for nil status' do
      instance = test_class.new
      instance.values[:status] = nil

      instance.send("validate_status_enum")
      # errors[:status] returns nil or empty array when no errors
      expect(instance.errors[:status]).to be_nil.or(be_empty)
    end
  end

  describe 'with scopes: false' do
    let(:no_scopes_class) do
      Class.new(Sequel::Model) do
        set_dataset :characters

        include StatusEnum
        status_enum :status, %w[on off], scopes: false
      end
    end

    it 'does not define scope methods' do
      expect(no_scopes_class.dataset).not_to respond_to(:on)
      expect(no_scopes_class.dataset).not_to respond_to(:off)
    end

    it 'still defines query methods' do
      instance = no_scopes_class.new
      expect(instance).to respond_to(:on?)
      expect(instance).to respond_to(:off?)
    end
  end
end
