# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Combat::Spar, type: :command do
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
  it_behaves_like "command metadata", 'spar', :combat, ['sparring']

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
      it 'returns error when no one to spar' do
        result = command.execute('spar')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/no one.*to spar/i)
      end
    end

    context 'with target not in room' do
      it 'returns error about not seeing target' do
        result = command.execute('spar goblin')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't see/i)
      end
    end

    context 'when trying to spar self' do
      it 'returns error' do
        result = command.execute("spar #{character.forename}")
        expect(result[:success]).to be false
        # find_combat_target excludes self, so we get "don't see" rather than "can't spar yourself"
        expect(result[:error]).to match(/don't see|can't spar/i)
      end
    end

    context 'with valid target in room' do
      before { target_instance } # Ensure target exists

      it 'successfully starts spar' do
        result = command.execute('spar Bob')
        expect(result[:success]).to be true
      end

      it 'includes fight ID in data' do
        result = command.execute('spar Bob')
        expect(result[:data][:fight_id]).not_to be_nil
      end

      it 'includes target name in result' do
        result = command.execute('spar Bob')
        display_name = target_character.display_name_for(character_instance)
        expect(result[:message]).to include(display_name)
      end

      it 'includes sparring match language' do
        result = command.execute('spar Bob')
        expect(result[:message]).to match(/sparring/i)
      end

      it 'returns combat quickmenu when battle map is ready' do
        # Ensure room has a battle map so generation is not triggered
        room.update(has_battle_map: true)
        RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', danger_level: 0, traversable: true, cover_value: 0)
        result = command.execute('spar Bob')
        expect(result[:data][:quickmenu]).not_to be_nil
      end

      it 'defers quickmenu when battle map is generating' do
        # Room has bounds but no battle map, so generation will be triggered
        result = command.execute('spar Bob')
        expect(result[:data][:battle_map_generating]).to be true
        expect(result[:data][:quickmenu]).to be_nil
      end

      it 'sets action to spar_started' do
        result = command.execute('spar Bob')
        expect(result[:data][:action]).to eq(:spar_started)
      end

      it 'sets mode to spar in data' do
        result = command.execute('spar Bob')
        expect(result[:data][:mode]).to eq('spar')
      end

      it 'creates fight with spar mode' do
        result = command.execute('spar Bob')
        fight = Fight[result[:data][:fight_id]]
        expect(fight.spar_mode?).to be true
        expect(fight.mode).to eq('spar')
      end
    end

    context 'when already in a fight' do
      let!(:existing_fight) do
        target_instance
        FightService.start_fight(room: room, initiator: character_instance, target: target_instance)
      end

      it 'returns error about being in combat' do
        result = command.execute('spar Bob')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/already in combat/i)
      end
    end

    context 'when target is already in a fight' do
      let!(:existing_fight) do
        another_user = create(:user)
        another_char = create(:character, user: another_user, forename: 'Charlie')
        another_inst = create(:character_instance, character: another_char, current_room: room,
                              reality: reality, status: 'alive', stance: 'standing', online: true)
        target_instance
        FightService.start_fight(room: room, initiator: target_instance, target: another_inst)
      end

      it 'returns error about target being in combat' do
        result = command.execute('spar Bob')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/already in combat/i)
      end
    end

    context 'with aliases' do
      before { target_instance }

      it 'works with sparring alias' do
        result = command.execute('sparring Bob')
        expect(result[:success]).to be true
      end
    end
  end

  describe 'spar mode mechanics' do
    before { target_instance }

    let(:fight) do
      command = described_class.new(character_instance)
      command.execute('spar Bob')
      Fight.last
    end

    it 'creates participants with touch_count at 0' do
      fight
      fight.fight_participants.each do |p|
        expect(p.touch_count).to eq(0)
      end
    end

    describe '#spar_mode?' do
      it 'returns true for spar fights' do
        expect(fight.spar_mode?).to be true
      end

      it 'returns false for normal fights' do
        normal_fight = FightService.start_fight(room: room, initiator: character_instance, target: target_instance).fight
        expect(normal_fight.spar_mode?).to be false
      end
    end

    describe 'wound_penalty in spar mode' do
      it 'returns 0 regardless of touch count' do
        participant = fight.fight_participants.first
        participant.update(touch_count: 3)
        expect(participant.wound_penalty).to eq(0)
      end
    end

    describe 'should_end? in spar mode' do
      it 'returns false when no one has max touches' do
        fight.fight_participants.each { |p| p.update(touch_count: 2) }
        expect(fight.should_end?).to be false
      end

      it 'returns true when someone reaches max touches' do
        participant = fight.fight_participants.first
        participant.update(touch_count: participant.max_hp)
        expect(fight.should_end?).to be true
      end
    end

    describe 'apply_incremental_hp_loss! in spar mode' do
      it 'increments touch_count instead of reducing HP' do
        participant = fight.fight_participants.first
        original_hp = participant.current_hp

        participant.apply_incremental_hp_loss!(2, 0)

        expect(participant.touch_count).to eq(2)
        expect(participant.current_hp).to eq(original_hp)
      end

      it 'does not set is_knocked_out' do
        participant = fight.fight_participants.first
        participant.apply_incremental_hp_loss!(10, 0)

        expect(participant.is_knocked_out).to be false
      end
    end

    describe 'spar_winner and spar_loser' do
      it 'returns winner as the one with fewer touches after fight ends' do
        loser = fight.fight_participants.first
        winner = fight.fight_participants.last

        loser.update(touch_count: loser.max_hp)
        winner.update(touch_count: 2)
        fight.complete!

        expect(fight.spar_loser).to eq(loser)
        expect(fight.spar_winner).to eq(winner)
      end
    end

    describe 'complete! in spar mode' do
      it 'does not mark participants as knocked out' do
        fight.complete!
        fight.fight_participants.each do |p|
          expect(p.is_knocked_out).to be false
        end
      end
    end
  end
end
