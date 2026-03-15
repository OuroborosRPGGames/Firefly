# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RestraintActionHelper do
  describe 'module structure' do
    it 'is a module' do
      expect(described_class).to be_a(Module)
    end
  end

  describe 'instance methods' do
    it 'defines apply_restraint_action' do
      expect(described_class.instance_methods).to include(:apply_restraint_action)
    end

    it 'defines remove_restraint_action' do
      expect(described_class.instance_methods).to include(:remove_restraint_action)
    end

    it 'defines transport_action' do
      expect(described_class.instance_methods).to include(:transport_action)
    end
  end

  # Create a test class that includes the helper with required dependencies
  let(:test_class) do
    Class.new do
      include RestraintActionHelper

      attr_accessor :character, :character_instance

      def success_result(msg, **opts)
        { success: true, message: msg }.merge(opts)
      end

      def error_result(msg)
        { success: false, error: msg }
      end

      def broadcast_to_room(msg, **opts)
        # mock broadcast
      end

      def send_to_character(target, msg)
        # mock send
      end

      def blank?(val)
        val.nil? || val.to_s.strip.empty?
      end

      def resolve_character_with_menu(name)
        { match: @mock_target }
      end

      def disambiguation_result(result)
        { disambiguation: true, result: result }
      end
    end
  end

  let(:character) { double(full_name: 'Actor Character', display_name_for: 'Actor Character') }
  let(:character_instance) { double(id: 1, can_be_prisoner?: true) }
  let(:target) { double(id: 2, full_name: 'Target Character', character: double(full_name: 'Target Character')) }

  let(:instance) do
    obj = test_class.new
    obj.character = character
    obj.character_instance = character_instance
    obj.instance_variable_set(:@mock_target, target)
    obj
  end

  describe '#apply_restraint_action' do
    before do
      allow(PrisonerService).to receive(:apply_restraint!).and_return({ success: true })
    end

    it 'returns error for empty target' do
      result = instance.apply_restraint_action(
        target_name: '',
        restraint_type: 'gag',
        action_verb: 'gag'
      )
      expect(result[:success]).to be false
    end

    it 'returns error when targeting self' do
      instance.instance_variable_set(:@mock_target, character_instance)
      allow(character_instance).to receive(:full_name).and_return('Self')
      allow(character_instance).to receive(:character).and_return(character)

      result = instance.apply_restraint_action(
        target_name: 'self',
        restraint_type: 'gag',
        action_verb: 'gag'
      )
      expect(result[:success]).to be false
    end

    it 'calls PrisonerService.apply_restraint!' do
      expect(PrisonerService).to receive(:apply_restraint!)
        .with(target, 'gag', actor: character_instance)
        .and_return({ success: true })

      instance.apply_restraint_action(
        target_name: 'Target',
        restraint_type: 'gag',
        action_verb: 'gag'
      )
    end

    it 'returns success result on successful restraint' do
      result = instance.apply_restraint_action(
        target_name: 'Target',
        restraint_type: 'blindfold',
        action_verb: 'blindfold'
      )
      expect(result[:success]).to be true
    end

    it 'checks timeline restrictions when check_timeline is true' do
      allow(character_instance).to receive(:can_be_prisoner?).and_return(false)
      result = instance.apply_restraint_action(
        target_name: 'Target',
        restraint_type: 'gag',
        action_verb: 'gag',
        check_timeline: true
      )
      expect(result[:success]).to be false
      expect(result[:error]).to include('timeline')
    end
  end

  describe '#remove_restraint_action' do
    before do
      allow(PrisonerService).to receive(:remove_restraint!).and_return({
        success: true,
        removed: ['gag']
      })
    end

    it 'returns error for empty target' do
      result = instance.remove_restraint_action(target_name: '')
      expect(result[:success]).to be false
    end

    it 'calls PrisonerService.remove_restraint!' do
      expect(PrisonerService).to receive(:remove_restraint!)
        .with(target, 'all', actor: character_instance)
        .and_return({ success: true, removed: ['gag'] })

      instance.remove_restraint_action(target_name: 'Target')
    end

    it 'returns success with removed items' do
      result = instance.remove_restraint_action(target_name: 'Target')
      expect(result[:success]).to be true
      expect(result[:data][:removed]).to include('gag')
    end
  end

  describe '#transport_action' do
    before do
      allow(PrisonerService).to receive(:start_drag!).and_return({ success: true })
      allow(PrisonerService).to receive(:pick_up!).and_return({ success: true })
    end

    it 'returns error for empty target' do
      result = instance.transport_action(target_name: '', action_type: :drag)
      expect(result[:success]).to be false
    end

    it 'returns error when targeting self' do
      instance.instance_variable_set(:@mock_target, character_instance)

      result = instance.transport_action(target_name: 'self', action_type: :drag)
      expect(result[:success]).to be false
    end

    it 'calls PrisonerService.start_drag! for drag action' do
      expect(PrisonerService).to receive(:start_drag!)
        .with(character_instance, target)
        .and_return({ success: true })

      instance.transport_action(target_name: 'Target', action_type: :drag)
    end

    it 'calls PrisonerService.pick_up! for carry action' do
      expect(PrisonerService).to receive(:pick_up!)
        .with(character_instance, target)
        .and_return({ success: true })

      instance.transport_action(target_name: 'Target', action_type: :carry)
    end

    it 'returns success for drag action' do
      result = instance.transport_action(target_name: 'Target', action_type: :drag)
      expect(result[:success]).to be true
      expect(result[:data][:action]).to eq('drag')
    end

    it 'returns success for carry action' do
      result = instance.transport_action(target_name: 'Target', action_type: :carry)
      expect(result[:success]).to be true
      expect(result[:data][:action]).to eq('carry')
    end
  end
end
