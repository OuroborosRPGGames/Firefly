# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EmoteApproachHelper do
  let(:host_class) do
    Class.new do
      include EmoteApproachHelper

      attr_accessor :location, :character_instance
    end
  end

  let(:helper) { host_class.new }
  let(:location) { instance_double('Location', id: 42) }
  let(:character_instance) do
    instance_double(
      'CharacterInstance',
      id: 100,
      at_place?: false,
      in_combat?: false,
      movement_state: nil,
      position: [0.0, 0.0, 0.0]
    )
  end
  let(:target_instance) do
    instance_double(
      'CharacterInstance',
      id: 200,
      at_place?: false,
      position: [10.0, 0.0, 0.0]
    )
  end

  before do
    helper.location = location
    helper.character_instance = character_instance
  end

  describe '#resolve_mentions_and_approach' do
    it 'returns resolved text and approaches first resolved target' do
      allow(CharacterInstance).to receive_message_chain(:where, :eager, :all).and_return([target_instance])
      allow(EmoteFormatterService).to receive(:resolve_at_mentions_with_targets)
        .with('waves at @bob', character_instance, [target_instance])
        .and_return({ text: 'waves at Bob', targets: [target_instance] })

      expect(helper).to receive(:approach_emote_target).with(target_instance)

      result = helper.resolve_mentions_and_approach('waves at @bob')
      expect(result).to eq('waves at Bob')
    end

    it 'does not approach when no targets are resolved' do
      allow(CharacterInstance).to receive_message_chain(:where, :eager, :all).and_return([])
      allow(EmoteFormatterService).to receive(:resolve_at_mentions_with_targets)
        .and_return({ text: 'waves', targets: [] })

      expect(helper).not_to receive(:approach_emote_target)
      expect(helper.resolve_mentions_and_approach('waves')).to eq('waves')
    end
  end

  describe '#approach_emote_target' do
    it 'does nothing when targeting self' do
      self_target = instance_double('CharacterInstance', id: character_instance.id)
      expect(character_instance).not_to receive(:move_to_valid_position)
      helper.send(:approach_emote_target, self_target)
    end

    it 'does nothing when already close (<= 5ft)' do
      allow(DistanceService).to receive(:calculate_distance).and_return(5.0)
      expect(character_instance).not_to receive(:move_to_valid_position)

      helper.send(:approach_emote_target, target_instance)
    end

    it 'moves character toward target when beyond 5ft' do
      allow(DistanceService).to receive(:calculate_distance).and_return(10.0)
      allow(helper).to receive(:rand).and_return(0.0) # stop_dist = 2.0
      expect(character_instance).to receive(:move_to_valid_position).with(8.0, 0.0, 0.0, snap_to_valid: true)

      helper.send(:approach_emote_target, target_instance)
    end

    it 'does nothing when character is moving already' do
      moving_character = instance_double(
        'CharacterInstance',
        id: 100,
        at_place?: false,
        in_combat?: false,
        movement_state: 'moving',
        position: [0.0, 0.0, 0.0]
      )
      helper.character_instance = moving_character
      expect(moving_character).not_to receive(:move_to_valid_position)

      helper.send(:approach_emote_target, target_instance)
    end
  end
end
