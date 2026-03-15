# frozen_string_literal: true

require 'spec_helper'

# Test the concern by including it in a test class that mimics a command
RSpec.describe CombatInitiationConcern do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  let(:other_character) { create(:character, forename: 'Bob', surname: 'Fighter') }
  let!(:other_instance) { create(:character_instance, character: other_character, current_room: room, reality: reality, online: true) }

  # Include the concern in a test class to test its methods
  let(:test_class) do
    Class.new do
      include CombatInitiationConcern

      attr_accessor :character_instance

      def location
        character_instance&.current_room
      end

      def error_result(msg)
        { success: false, error: msg }
      end

      def create_quickmenu(ci, prompt, options, context: {})
        { success: true, type: :quickmenu, prompt: prompt, options: options, context: context }
      end
    end
  end

  let(:host) do
    obj = test_class.new
    obj.character_instance = character_instance
    obj
  end

  describe '#eligible_combat_targets' do
    it 'returns online characters in the same room' do
      targets = host.eligible_combat_targets
      expect(targets).to include(other_instance)
    end

    it 'excludes the character themselves' do
      targets = host.eligible_combat_targets
      expect(targets).not_to include(character_instance)
    end

    it 'excludes offline characters' do
      other_instance.update(online: false)
      targets = host.eligible_combat_targets
      expect(targets).not_to include(other_instance)
    end

    it 'excludes characters in other rooms' do
      other_room = create(:room)
      other_instance.update(current_room_id: other_room.id)
      targets = host.eligible_combat_targets
      expect(targets).not_to include(other_instance)
    end

    context 'with exclude_in_combat: true' do
      it 'excludes characters already in fights' do
        allow(FightService).to receive(:find_active_fight).with(other_instance).and_return(double('Fight'))
        targets = host.eligible_combat_targets(exclude_in_combat: true)
        expect(targets).not_to include(other_instance)
      end

      it 'includes characters not in fights' do
        allow(FightService).to receive(:find_active_fight).and_return(nil)
        targets = host.eligible_combat_targets(exclude_in_combat: true)
        expect(targets).to include(other_instance)
      end
    end
  end

  describe '#build_target_selection_menu' do
    it 'returns error when no targets available' do
      other_instance.update(online: false)
      result = host.build_target_selection_menu(prompt_text: 'Fight who?', command_name: 'fight')
      expect(result[:success]).to be false
      expect(result[:error]).to include('no one here')
    end

    it 'returns quickmenu with available targets' do
      result = host.build_target_selection_menu(prompt_text: 'Fight who?', command_name: 'fight')
      expect(result[:success]).to be true
      expect(result[:options].length).to eq(2) # target + cancel
    end

    it 'includes cancel option' do
      result = host.build_target_selection_menu(prompt_text: 'Fight who?', command_name: 'fight')
      cancel = result[:options].find { |o| o[:key] == 'q' }
      expect(cancel).not_to be_nil
      expect(cancel[:label]).to eq('Cancel')
    end

    it 'includes target names in options' do
      result = host.build_target_selection_menu(prompt_text: 'Fight who?', command_name: 'fight')
      labels = result[:options].map { |o| o[:label] }
      expect(labels).to include(other_character.full_name)
    end

    it 'includes command context' do
      result = host.build_target_selection_menu(prompt_text: 'Spar who?', command_name: 'spar')
      expect(result[:context][:command]).to eq('spar')
      expect(result[:context][:stage]).to eq('select_target')
    end
  end

  describe '#push_combat_menu_to_target' do
    let(:fight) { create(:fight, room: room) }
    let(:fight_service) { double('FightService') }
    let(:participant) { double('FightParticipant', id: 1) }
    let(:menu_data) { { prompt: 'Your turn', options: [{ key: '1', label: 'Attack' }], context: {} } }

    before do
      allow(fight_service).to receive(:participant_for).and_return(participant)
      allow(CombatQuickmenuHandler).to receive(:show_menu).and_return(menu_data)
      allow(OutputHelper).to receive(:store_agent_interaction)
      allow(BroadcastService).to receive(:to_character)
    end

    it 'sends quickmenu to non-NPC target' do
      host.push_combat_menu_to_target(fight_service, other_instance, broadcast_text: 'Combat begins!')

      expect(BroadcastService).to have_received(:to_character).with(
        other_instance,
        hash_including(content: 'Combat begins!'),
        hash_including(type: :quickmenu)
      )
    end

    it 'stores the interaction' do
      host.push_combat_menu_to_target(fight_service, other_instance, broadcast_text: 'Combat begins!')

      expect(OutputHelper).to have_received(:store_agent_interaction).with(
        other_instance,
        anything,
        hash_including(type: 'quickmenu')
      )
    end

    it 'does not send to NPC targets' do
      allow(other_instance.character).to receive(:npc?).and_return(true)
      host.push_combat_menu_to_target(fight_service, other_instance, broadcast_text: 'Combat!')

      expect(BroadcastService).not_to have_received(:to_character)
    end

    it 'handles errors gracefully' do
      allow(fight_service).to receive(:participant_for).and_raise(StandardError.new('boom'))

      # Should not raise
      expect {
        host.push_combat_menu_to_target(fight_service, other_instance, broadcast_text: 'Test')
      }.not_to raise_error
    end
  end
end
