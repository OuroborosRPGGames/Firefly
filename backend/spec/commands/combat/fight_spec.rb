# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Combat::Fight, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality,
           status: 'alive', stance: 'standing', online: true)
  end

  let(:target_user) { create(:user) }
  let(:target_character) { create(:character, user: target_user, forename: 'Bob') }
  let(:target_instance) do
    create(:character_instance, character: target_character, current_room: room, reality: reality,
           status: 'alive', stance: 'standing', online: true)
  end

  # Use shared example for standard metadata tests
  it_behaves_like "command metadata", 'fight', :combat, ['combat', 'engage']

  describe 'requirements' do
    it 'requires alive state' do
      requirements = described_class.requirements
      alive_req = requirements.find { |r| r[:type] == :character_state && r[:args]&.include?(:alive) }
      expect(alive_req).not_to be_nil
    end

    it 'requires standing position' do
      requirements = described_class.requirements
      standing_req = requirements.find { |r| r[:type] == :character_state && r[:args]&.include?(:standing) }
      expect(standing_req).not_to be_nil
    end
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no target specified' do
      it 'returns error asking who to attack' do
        result = command.execute('fight')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/who.*attack/i)
      end

      it 'handles empty target input' do
        result = command.execute('fight ')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/who.*attack/i)
      end
    end

    context 'with target not in room' do
      it 'returns error about not seeing target' do
        result = command.execute('fight goblin')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't see/i)
      end
    end

    context 'when trying to fight self' do
      it 'returns error' do
        # The target finder excludes self, so the result is "not found"
        result = command.execute("fight #{character.forename}")
        expect(result[:success]).to be false
        # Either "yourself" or "don't see" error is acceptable
        expect(result[:error]).to match(/yourself|don't see/i)
      end
    end

    context 'with valid target in room' do
      before { target_instance } # Ensure target exists

      it 'successfully starts fight' do
        result = command.execute('fight Bob')
        expect(result[:success]).to be true
      end

      it 'includes fight ID in data' do
        result = command.execute('fight Bob')
        expect(result[:data][:fight_id]).not_to be_nil
      end

      it 'includes target name in result' do
        result = command.execute('fight Bob')
        display_name = target_character.display_name_for(character_instance)
        expect(result[:message]).to include(display_name)
      end

      it 'returns combat quickmenu when battle map is ready' do
        # Ensure room has a battle map so generation is not triggered
        room.update(has_battle_map: true)
        RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', danger_level: 0, traversable: true, cover_value: 0)
        result = command.execute('fight Bob')
        expect(result[:data][:quickmenu]).not_to be_nil
      end

      it 'defers quickmenu when battle map is generating' do
        # Room has bounds but no battle map, so generation will be triggered
        result = command.execute('fight Bob')
        expect(result[:data][:battle_map_generating]).to be true
        expect(result[:data][:quickmenu]).to be_nil
      end

      it 'sets action to fight_started' do
        result = command.execute('fight Bob')
        expect(result[:data][:action]).to eq(:fight_started)
      end
    end

    context 'when already in a fight' do
      let!(:existing_fight) do
        # Create a fight using FightService
        target_instance # Ensure target exists
        FightService.start_fight(room: room, initiator: character_instance, target: target_instance)
      end

      it 'reuses attack behavior and updates combat target' do
        result = command.execute('fight Bob')
        expect(result[:success]).to be true
        expect(result[:message]).to match(/target|prepare to attack/i)
      end
    end

    context 'with aliases' do
      before { target_instance }

      it 'works with combat alias' do
        result = command.execute('combat Bob')
        expect(result[:success]).to be true
      end

      it 'works with engage alias' do
        result = command.execute('engage Bob')
        expect(result[:success]).to be true
      end
    end

    context 'with partial name match' do
      let(:target_character) { create(:character, forename: 'Benjamin') }
      before { target_instance }

      it 'finds target with partial name' do
        result = command.execute('fight Benj')
        expect(result[:success]).to be true
      end
    end

    context 'with non-combat NPC target' do
      let(:npc_archetype) { NpcArchetype.create(name: 'Test NPC', behavior_pattern: 'neutral') }
      let(:npc_character) { create(:character, :npc, npc_archetype: npc_archetype, forename: 'Goblin') }
      let(:npc_instance) do
        create(:character_instance, character: npc_character, current_room: room, reality: reality,
               status: 'alive', stance: 'standing')
      end

      before { npc_instance }

      it 'blocks the fight' do
        result = command.execute('fight Goblin')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/isn't a combatant/i)
      end
    end

    context 'with combat-capable NPC target' do
      let(:npc_archetype) do
        NpcArchetype.create(
          name: 'Combat NPC',
          behavior_pattern: 'aggressive',
          npc_attacks: [{ 'name' => 'Claw', 'attack_type' => 'melee', 'damage_dice' => '1d8', 'range_hexes' => 1 }]
        )
      end
      let(:npc_character) { create(:character, :npc, npc_archetype: npc_archetype, forename: 'Goblin') }
      let(:npc_instance) do
        create(:character_instance, character: npc_character, current_room: room, reality: reality,
               status: 'alive', stance: 'standing')
      end

      before { npc_instance }

      it 'starts combat successfully' do
        result = command.execute('fight Goblin')
        expect(result[:success]).to be true
      end
    end
  end

  describe '#can_execute?' do
    subject(:command) { described_class.new(character_instance) }

    it 'returns true when character meets requirements' do
      expect(command.can_execute?).to be true
    end
  end

  describe 'additional metadata' do
    it 'has usage info' do
      expect(described_class.usage).to be_a(String)
      expect(described_class.usage).to include('fight')
    end

    it 'has examples' do
      expect(described_class.examples).to be_an(Array)
      expect(described_class.examples.length).to be > 0
    end
  end
end
