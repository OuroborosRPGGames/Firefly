# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveGuards do
  let(:service_class) do
    Class.new do
      extend ResultHandler
      extend DelveGuards
    end
  end

  describe '.validate_for_action' do
    it 'returns an error when participant is not in a delve' do
      participant = instance_double('DelveParticipant', current_room: nil, extracted?: false, dead?: false, time_expired?: false, active?: true)

      result = service_class.validate_for_action(participant)

      expect(result.success?).to be false
      expect(result.message).to eq("You're not in a delve.")
    end

    it 'returns an error when participant already extracted' do
      participant = instance_double('DelveParticipant', current_room: instance_double('Room'), extracted?: true, dead?: false, time_expired?: false, active?: true)

      result = service_class.validate_for_action(participant)

      expect(result.success?).to be false
      expect(result.message).to eq("You've already extracted.")
    end

    it 'returns an error when time has expired' do
      participant = instance_double('DelveParticipant', current_room: instance_double('Room'), extracted?: false, dead?: false, time_expired?: true, active?: true)

      result = service_class.validate_for_action(participant)

      expect(result.success?).to be false
      expect(result.message).to eq('Time has run out!')
    end

    it 'returns an error when participant is dead' do
      participant = instance_double('DelveParticipant', current_room: instance_double('Room'), extracted?: false, dead?: true, time_expired?: false, active?: false)

      result = service_class.validate_for_action(participant)

      expect(result.success?).to be false
      expect(result.message).to eq("You're dead.")
    end

    it 'returns an error when participant is no longer active' do
      participant = instance_double('DelveParticipant', current_room: instance_double('Room'), extracted?: false, dead?: false, time_expired?: false, active?: false)

      result = service_class.validate_for_action(participant)

      expect(result.success?).to be false
      expect(result.message).to eq('You can no longer continue this delve.')
    end

    it 'returns nil for a valid participant' do
      participant = instance_double('DelveParticipant', current_room: instance_double('Room'), extracted?: false, dead?: false, time_expired?: false, active?: true)

      expect(service_class.validate_for_action(participant)).to be_nil
    end
  end

  describe '.validate_not_in_combat' do
    it 'returns an error when character instance is in combat' do
      character_instance = instance_double('CharacterInstance', in_combat?: true)
      participant = instance_double('DelveParticipant', character_instance: character_instance)

      result = service_class.validate_not_in_combat(participant)

      expect(result.success?).to be false
      expect(result.message).to eq("You can't do that while in combat!")
    end

    it 'returns nil when character instance is not in combat' do
      character_instance = instance_double('CharacterInstance', in_combat?: false)
      participant = instance_double('DelveParticipant', character_instance: character_instance)

      expect(service_class.validate_not_in_combat(participant)).to be_nil
    end
  end

  describe '.validate_for_movement' do
    it 'returns an error when participant is not in a delve' do
      participant = instance_double('DelveParticipant', current_room: nil, extracted?: false, dead?: false, time_expired?: false, active?: true)

      result = service_class.validate_for_movement(participant)

      expect(result.success?).to be false
      expect(result.message).to eq("You're not in a delve.")
    end

    it 'returns an error when participant already extracted' do
      participant = instance_double('DelveParticipant', current_room: instance_double('Room'), extracted?: true, dead?: false, time_expired?: false, active?: false)

      result = service_class.validate_for_movement(participant)

      expect(result.success?).to be false
      expect(result.message).to eq("You've already extracted.")
    end

    it 'returns an error when participant is dead' do
      participant = instance_double('DelveParticipant', current_room: instance_double('Room'), extracted?: false, dead?: true, time_expired?: false, active?: false)

      result = service_class.validate_for_movement(participant)

      expect(result.success?).to be false
      expect(result.message).to eq("You're dead.")
    end

    it 'returns an error when participant is no longer active' do
      participant = instance_double('DelveParticipant', current_room: instance_double('Room'), extracted?: false, dead?: false, time_expired?: false, active?: false)

      result = service_class.validate_for_movement(participant)

      expect(result.success?).to be false
      expect(result.message).to eq('You can no longer move in this delve.')
    end

    it 'returns nil for valid movement state' do
      participant = instance_double('DelveParticipant', current_room: instance_double('Room'), extracted?: false, dead?: false, time_expired?: false, active?: true, character_instance: nil)

      expect(service_class.validate_for_movement(participant)).to be_nil
    end
  end
end
