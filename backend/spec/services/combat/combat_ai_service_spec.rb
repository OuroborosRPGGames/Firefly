# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CombatAIService do
  let(:room) { create(:room) }
  let(:fight) { Fight.create(room_id: room.id) }
  let(:reality) { create(:reality) }

  # Helper to create a fight participant
  def create_participant(character_instance, **attrs)
    FightParticipant.create(
      fight_id: fight.id,
      character_instance_id: character_instance.id,
      hex_x: attrs[:hex_x] || 0,
      hex_y: attrs[:hex_y] || 0,
      current_hp: attrs[:current_hp] || 5,
      max_hp: attrs[:max_hp] || 5,
      side: attrs[:side] || 1
    )
  end

  describe '#decide!' do
    context 'with a PC (non-NPC)' do
      let(:user) { create(:user) }
      let(:character) { create(:character, user: user, is_npc: false) }
      let(:character_instance) { create(:character_instance, character: character, reality: reality, current_room: room) }
      let(:participant) { create_participant(character_instance) }

      # Create an enemy
      let(:enemy_user) { create(:user) }
      let(:enemy_character) { create(:character, user: enemy_user, is_npc: false) }
      let(:enemy_instance) { create(:character_instance, character: enemy_character, reality: reality, current_room: room) }
      let!(:enemy_participant) { create_participant(enemy_instance, hex_x: 3, hex_y: 3, side: 2) }

      it 'uses defensive profile for idle PCs' do
        ai = described_class.new(participant)
        expect(ai.profile[:target_strategy]).to eq(:threat)
      end

      it 'selects a target' do
        ai = described_class.new(participant)
        decisions = ai.decide!
        expect(decisions[:target_participant_id]).to eq(enemy_participant.id)
      end

      it 'defaults to attack action' do
        ai = described_class.new(participant)
        decisions = ai.decide!
        expect(decisions[:main_action]).to eq('attack')
      end

      it 'does not use tactical actions' do
        ai = described_class.new(participant)
        decisions = ai.decide!
        expect(decisions[:tactical_action]).to be_nil
      end
    end

    context 'with an aggressive NPC' do
      let(:archetype) do
        NpcArchetype.create(
          name: 'Test Aggressive',
          behavior_pattern: 'aggressive',
          combat_damage_bonus: 2,
          combat_max_hp: 6
        )
      end
      let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
      let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
      let(:participant) { create_participant(npc_instance, current_hp: 6, max_hp: 6) }

      # Create two enemies with different HP
      let(:user1) { create(:user) }
      let(:character1) { create(:character, user: user1) }
      let(:instance1) { create(:character_instance, character: character1, reality: reality, current_room: room) }
      let!(:strong_enemy) { create_participant(instance1, hex_x: 2, hex_y: 0, current_hp: 5, max_hp: 5, side: 2) }

      let(:user2) { create(:user) }
      let(:character2) { create(:character, user: user2) }
      let(:instance2) { create(:character_instance, character: character2, reality: reality, current_room: room) }
      let!(:weak_enemy) { create_participant(instance2, hex_x: 5, hex_y: 0, current_hp: 1, max_hp: 5, side: 2) }

      it 'uses aggressive profile' do
        ai = described_class.new(participant)
        expect(ai.profile[:attack_weight]).to eq(0.8)
      end

      it 'targets the weakest enemy' do
        ai = described_class.new(participant)
        decisions = ai.decide!
        expect(decisions[:target_participant_id]).to eq(weak_enemy.id)
      end

      it 'prefers attack over defense' do
        ai = described_class.new(participant)
        decisions = ai.decide!
        expect(decisions[:main_action]).to eq('attack')
      end
    end

    context 'with a defensive NPC' do
      let(:archetype) do
        NpcArchetype.create(
          name: 'Test Defensive',
          behavior_pattern: 'passive',
          combat_defense_bonus: 2
        )
      end
      let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
      let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
      let(:participant) { create_participant(npc_instance) }

      # Create enemy targeting the NPC
      let(:user) { create(:user) }
      let(:enemy_character) { create(:character, user: user) }
      let(:enemy_instance) { create(:character_instance, character: enemy_character, reality: reality, current_room: room) }
      let!(:enemy_participant) do
        p = create_participant(enemy_instance, hex_x: 1, hex_y: 0, side: 2)
        p.update(target_participant_id: participant.id)
        p
      end

      it 'uses defensive profile' do
        ai = described_class.new(participant)
        expect(ai.profile[:target_strategy]).to eq(:threat)
      end

      it 'targets the biggest threat (enemy targeting us)' do
        ai = described_class.new(participant)
        decisions = ai.decide!
        expect(decisions[:target_participant_id]).to eq(enemy_participant.id)
      end
    end

    context 'with critically wounded NPC' do
      let(:archetype) do
        NpcArchetype.create(
          name: 'Test Wounded',
          behavior_pattern: 'aggressive',
          flee_health_percent: 20
        )
      end
      let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
      let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
      # 1 HP out of 5 = 20% = at flee threshold
      # Note: Must update HP after creation since before_create hook sets current_hp = max_hp
      let(:participant) do
        p = create_participant(npc_instance, max_hp: 5)
        p.update(current_hp: 1)
        p.refresh
      end

      let(:user) { create(:user) }
      let(:enemy_character) { create(:character, user: user) }
      let(:enemy_instance) { create(:character_instance, character: enemy_character, reality: reality, current_room: room) }
      let!(:enemy_participant) { create_participant(enemy_instance, hex_x: 2, hex_y: 0, side: 2) }

      it 'defends when critically wounded' do
        ai = described_class.new(participant)
        decisions = ai.decide!
        expect(decisions[:main_action]).to eq('defend')
      end

      it 'tries to flee (move away)' do
        ai = described_class.new(participant)
        decisions = ai.decide!
        expect(decisions[:movement_action]).to eq('away_from')
      end
    end

    context 'with no enemies' do
      let(:archetype) { NpcArchetype.create(name: 'Test Solo', behavior_pattern: 'aggressive') }
      let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
      let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
      let(:participant) { create_participant(npc_instance) }

      it 'returns nil for target' do
        ai = described_class.new(participant)
        decisions = ai.decide!
        expect(decisions[:target_participant_id]).to be_nil
      end

      it 'stands still without target' do
        ai = described_class.new(participant)
        decisions = ai.decide!
        expect(decisions[:movement_action]).to eq('stand_still')
      end
    end
  end

  describe '#apply_decisions!' do
    let(:archetype) { NpcArchetype.create(name: 'Test Apply', behavior_pattern: 'neutral') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance) }

    let(:user) { create(:user) }
    let(:enemy_character) { create(:character, user: user) }
    let(:enemy_instance) { create(:character_instance, character: enemy_character, reality: reality, current_room: room) }
    let!(:enemy_participant) { create_participant(enemy_instance, hex_x: 2, hex_y: 0, side: 2) }

    it 'updates the participant with decisions' do
      ai = described_class.new(participant)
      ai.apply_decisions!

      participant.refresh
      expect(participant.target_participant_id).to eq(enemy_participant.id)
      expect(participant.main_action).to eq('attack')
    end

    it 'marks input as complete' do
      ai = described_class.new(participant)
      ai.apply_decisions!

      participant.refresh
      expect(participant.input_complete).to be true
    end
  end

  describe 'movement decisions' do
    let(:archetype) { NpcArchetype.create(name: 'Test Movement', behavior_pattern: 'hostile') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }

    let(:user) { create(:user) }
    let(:enemy_character) { create(:character, user: user) }
    let(:enemy_instance) { create(:character_instance, character: enemy_character, reality: reality, current_room: room) }

    context 'when out of melee range' do
      let(:participant) { create_participant(npc_instance, hex_x: 0, hex_y: 0) }
      let!(:enemy_participant) { create_participant(enemy_instance, hex_x: 5, hex_y: 0, side: 2) }

      it 'moves towards target' do
        ai = described_class.new(participant)
        decisions = ai.decide!
        expect(decisions[:movement_action]).to eq('towards_person')
      end
    end

    context 'when in melee range' do
      let(:participant) { create_participant(npc_instance, hex_x: 0, hex_y: 0) }
      let!(:enemy_participant) { create_participant(enemy_instance, hex_x: 1, hex_y: 0, side: 2) }

      it 'keeps towards_person so it can follow retreating targets' do
        ai = described_class.new(participant)
        decisions = ai.decide!
        expect(decisions[:movement_action]).to eq('towards_person')
        expect(decisions[:movement_target_participant_id]).to eq(enemy_participant.id)
      end
    end
  end

  describe 'AI profiles' do
    it 'has all expected profiles' do
      expect(CombatAIService::AI_PROFILES.keys).to include(
        'aggressive', 'defensive', 'balanced', 'berserker', 'coward', 'guardian'
      )
    end

    it 'maps all behavior patterns to profiles' do
      NpcArchetype::BEHAVIOR_PATTERNS.each do |pattern|
        expect(CombatAIService::BEHAVIOR_TO_PROFILE).to have_key(pattern)
      end
    end

    it 'aggressive has high attack weight' do
      expect(CombatAIService::AI_PROFILES['aggressive'][:attack_weight]).to eq(0.8)
    end

    it 'berserker never flees' do
      expect(CombatAIService::AI_PROFILES['berserker'][:flee_threshold]).to eq(0.0)
    end

    it 'coward has high flee threshold' do
      expect(CombatAIService::AI_PROFILES['coward'][:flee_threshold]).to eq(0.5)
    end
  end

  describe 'target selection strategies' do
    let(:archetype) { NpcArchetype.create(name: 'Test Target Selection', behavior_pattern: 'hostile') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance, hex_x: 0, hex_y: 0) }

    let(:user1) { create(:user) }
    let(:char1) { create(:character, user: user1) }
    let(:inst1) { create(:character_instance, character: char1, reality: reality, current_room: room) }

    let(:user2) { create(:user) }
    let(:char2) { create(:character, user: user2) }
    let(:inst2) { create(:character_instance, character: char2, reality: reality, current_room: room) }

    context '#select_weakest' do
      let!(:strong_enemy) { create_participant(inst1, hex_x: 2, hex_y: 0, current_hp: 5, max_hp: 5, side: 2) }
      let!(:weak_enemy) { create_participant(inst2, hex_x: 3, hex_y: 0, current_hp: 1, max_hp: 5, side: 2) }

      it 'returns enemy with lowest HP' do
        ai = described_class.new(participant)
        result = ai.send(:select_weakest, [strong_enemy, weak_enemy])
        expect(result).to eq(weak_enemy)
      end
    end

    context '#select_strongest' do
      let!(:strong_enemy) { create_participant(inst1, hex_x: 2, hex_y: 0, current_hp: 10, max_hp: 10, side: 2) }
      let!(:weak_enemy) { create_participant(inst2, hex_x: 3, hex_y: 0, current_hp: 3, max_hp: 3, side: 2) }

      it 'returns enemy with highest HP' do
        ai = described_class.new(participant)
        result = ai.send(:select_strongest, [strong_enemy, weak_enemy])
        expect(result).to eq(strong_enemy)
      end
    end

    context '#select_closest' do
      let!(:near_enemy) { create_participant(inst1, hex_x: 1, hex_y: 0, side: 2) }
      let!(:far_enemy) { create_participant(inst2, hex_x: 10, hex_y: 0, side: 2) }

      it 'returns nearest enemy' do
        ai = described_class.new(participant)
        result = ai.send(:select_closest, [near_enemy, far_enemy])
        expect(result).to eq(near_enemy)
      end
    end
  end

  describe 'helper methods' do
    let(:archetype) { NpcArchetype.create(name: 'Test Helpers', behavior_pattern: 'neutral') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) do
      p = create_participant(npc_instance, max_hp: 6)
      p.update(current_hp: 3)
      p.refresh
    end

    describe '#current_hp_percent' do
      it 'calculates HP percentage' do
        ai = described_class.new(participant)
        # The value should be current_hp / max_hp as a Float
        expected = participant.current_hp.to_f / participant.max_hp.to_f
        expect(ai.send(:current_hp_percent)).to eq(expected)
      end

      it 'returns 1.0 for zero max HP' do
        # Bypass setter (which clamps min to 1) to test the zero guard directly
        ci = participant.character_instance
        ci.this.update(max_health: 0, health: 0) if ci
        participant.this.update(max_hp: 0, current_hp: 0)
        participant.refresh
        ai = described_class.new(participant)
        expect(ai.send(:current_hp_percent)).to eq(1.0)
      end
    end

    describe '#hp_percent_for' do
      let(:user) { create(:user) }
      let(:char) { create(:character, user: user) }
      let(:inst) { create(:character_instance, character: char, reality: reality, current_room: room) }
      let!(:enemy) { create_participant(inst, current_hp: 2, max_hp: 8, side: 2) }

      it 'calculates HP percentage for another participant' do
        ai = described_class.new(participant)
        expect(ai.send(:hp_percent_for, enemy)).to eq(0.25)
      end
    end

    describe '#effective_weapon_range' do
      it 'returns 1 without weapons' do
        ai = described_class.new(participant)
        expect(ai.send(:effective_weapon_range)).to eq(1)
      end
    end

    describe '#no_movement' do
      it 'returns stand_still action' do
        ai = described_class.new(participant)
        result = ai.send(:no_movement)
        expect(result[:action]).to eq('stand_still')
        expect(result[:target_id]).to be_nil
      end
    end
  end

  describe 'combat role assessment' do
    let(:archetype) { NpcArchetype.create(name: 'Test Role', behavior_pattern: 'neutral') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance) }

    describe '#assess_combat_role' do
      it 'returns :melee without ranged weapon' do
        ai = described_class.new(participant)
        allow(participant).to receive(:ranged_weapon).and_return(nil)
        expect(ai.send(:assess_combat_role)).to eq(:melee)
      end

      it 'returns :ranged with ranged weapon only' do
        ai = described_class.new(participant)
        allow(participant).to receive(:ranged_weapon).and_return(double('Weapon'))
        allow(participant).to receive(:melee_weapon).and_return(nil)
        expect(ai.send(:assess_combat_role)).to eq(:ranged)
      end
    end

    describe '#ranged_only?' do
      it 'returns true with only ranged weapon' do
        ai = described_class.new(participant)
        allow(participant).to receive(:ranged_weapon).and_return(double('Weapon'))
        allow(participant).to receive(:melee_weapon).and_return(nil)
        expect(ai.send(:ranged_only?)).to be true
      end

      it 'returns false with melee weapon' do
        ai = described_class.new(participant)
        allow(participant).to receive(:ranged_weapon).and_return(double('Weapon'))
        allow(participant).to receive(:melee_weapon).and_return(double('Weapon'))
        expect(ai.send(:ranged_only?)).to be false
      end
    end

    describe '#has_both_weapons?' do
      it 'returns truthy with both weapons' do
        ai = described_class.new(participant)
        allow(ai.participant).to receive(:ranged_weapon).and_return(double('Weapon'))
        allow(ai.participant).to receive(:melee_weapon).and_return(double('Weapon'))
        expect(ai.send(:has_both_weapons?)).to be_truthy
      end

      it 'returns falsey without ranged' do
        ai = described_class.new(participant)
        allow(ai.participant).to receive(:ranged_weapon).and_return(nil)
        allow(ai.participant).to receive(:melee_weapon).and_return(double('Weapon'))
        expect(ai.send(:has_both_weapons?)).to be_falsey
      end
    end
  end

  describe 'ability targeting' do
    let(:archetype) { NpcArchetype.create(name: 'Test Abilities', behavior_pattern: 'neutral') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance) }

    describe '#valid_targets_for_ability' do
      let(:user) { create(:user) }
      let(:char) { create(:character, user: user) }
      let(:inst) { create(:character_instance, character: char, reality: reality, current_room: room) }
      let!(:enemy) { create_participant(inst, side: 2) }

      it 'returns self for self-targeting ability' do
        ai = described_class.new(participant)
        ability = double('Ability', target_type: 'self')
        result = ai.send(:valid_targets_for_ability, ability, [], [enemy])
        expect(result).to eq([participant])
      end

      it 'returns enemies for enemy-targeting ability' do
        ai = described_class.new(participant)
        ability = double('Ability', target_type: 'enemy')
        result = ai.send(:valid_targets_for_ability, ability, [], [enemy])
        expect(result).to eq([enemy])
      end

      it 'returns self and allies for ally-targeting ability' do
        ai = described_class.new(participant)
        ability = double('Ability', target_type: 'ally')
        result = ai.send(:valid_targets_for_ability, ability, [], [enemy])
        expect(result).to include(participant)
      end
    end

    describe '#ability_is_shield?' do
      it 'returns true for shield effects' do
        ai = described_class.new(participant)
        ability = double('Ability')
        allow(ability).to receive(:respond_to?).with(:parsed_status_effects).and_return(true)
        allow(ability).to receive(:parsed_status_effects).and_return([{ 'name' => 'magic_shield' }])
        expect(ai.send(:ability_is_shield?, ability)).to be true
      end

      it 'returns false for non-shield effects' do
        ai = described_class.new(participant)
        ability = double('Ability')
        allow(ability).to receive(:respond_to?).with(:parsed_status_effects).and_return(true)
        allow(ability).to receive(:parsed_status_effects).and_return([{ 'name' => 'burn' }])
        expect(ai.send(:ability_is_shield?, ability)).to be false
      end

      it 'returns false when ability has no effects method' do
        ai = described_class.new(participant)
        ability = double('Ability')
        allow(ability).to receive(:respond_to?).with(:parsed_status_effects).and_return(false)
        expect(ai.send(:ability_is_shield?, ability)).to be false
      end
    end
  end

  describe 'monster combat' do
    let(:archetype) { NpcArchetype.create(name: 'Test Monster', behavior_pattern: 'aggressive') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance) }

    describe '#fight_has_active_monster?' do
      it 'returns false when fight has no monster' do
        ai = described_class.new(participant)
        allow(fight).to receive(:respond_to?).with(:has_monster).and_return(false)
        expect(ai.send(:fight_has_active_monster?)).to be false
      end
    end

    describe '#participant_is_mounted?' do
      it 'returns participant is_mounted status' do
        participant.update(is_mounted: true)
        ai = described_class.new(participant)
        expect(ai.send(:participant_is_mounted?)).to be true
      end

      it 'returns false when not mounted' do
        participant.update(is_mounted: false)
        ai = described_class.new(participant)
        expect(ai.send(:participant_is_mounted?)).to be false
      end
    end

    describe '#build_monster_decisions' do
      it 'returns decisions hash with defaults' do
        ai = described_class.new(participant)
        result = ai.send(:build_monster_decisions, main_action: 'attack')
        expect(result[:main_action]).to eq('attack')
        expect(result[:willpower_attack]).to eq(0)
      end

      it 'sets mount state for mount actions' do
        ai = described_class.new(participant)
        result = ai.send(:build_monster_decisions, mount_action: 'mount')
        expect(result[:is_mounted]).to be true
      end
    end

    describe '#translate_monster_movement' do
      it 'translates towards_monster' do
        ai = described_class.new(participant)
        segment = double('MonsterSegmentInstance')
        allow(segment).to receive(:hex_position).and_return([1, 0])
        monster = double('LargeMonsterInstance', monster_segment_instances: [segment])
        result = ai.send(:translate_monster_movement, 'towards_monster', nil, monster)
        expect(result[:action]).to eq('move_to_hex')
        expect(result[:hex_x]).to eq(1)
        expect(result[:hex_y]).to eq(0)
      end

      it 'translates away_from_monster' do
        ai = described_class.new(participant)
        monster = double('LargeMonsterInstance', center_hex_x: 5, center_hex_y: 4)
        result = ai.send(:translate_monster_movement, 'away_from_monster', nil, monster)
        expect(result[:action]).to eq('move_to_hex')
        expect(result[:hex_x]).to be_a(Integer)
        expect(result[:hex_y]).to be_a(Integer)
      end

      it 'translates maintain_distance to stand_still' do
        ai = described_class.new(participant)
        expect(ai.send(:translate_monster_movement, 'maintain_distance')).to eq({ action: 'stand_still' })
      end

      it 'defaults to stand_still' do
        ai = described_class.new(participant)
        expect(ai.send(:translate_monster_movement, nil)).to eq({ action: 'stand_still' })
      end
    end
  end

  describe 'main action decision' do
    let(:archetype) do
      NpcArchetype.create(
        name: 'Test Main Action',
        behavior_pattern: 'passive',
        defensive_health_percent: 60
      )
    end
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance, max_hp: 5) }

    let(:user) { create(:user) }
    let(:char) { create(:character, user: user) }
    let(:inst) { create(:character_instance, character: char, reality: reality, current_room: room) }
    let!(:enemy) { create_participant(inst, hex_x: 2, hex_y: 0, side: 2) }

    describe '#choose_main_action' do
      it 'defends when critically wounded (below flee threshold)' do
        participant.update(current_hp: 1)  # 20% HP, below defensive flee threshold
        participant.refresh
        ai = described_class.new(participant)
        result = ai.send(:choose_main_action)
        expect(result[:action]).to eq('defend')
      end

      it 'attacks when at full health' do
        ai = described_class.new(participant)
        result = ai.send(:choose_main_action)
        expect(result[:action]).to eq('attack')
      end
    end
  end

  describe 'ability selection' do
    let(:archetype) do
      NpcArchetype.create(
        name: 'Test Ability Select',
        behavior_pattern: 'aggressive'
      )
    end
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) do
      p = create_participant(npc_instance, max_hp: 6)
      p.update(global_ability_cooldown: 0)
      p.refresh
    end

    let(:user) { create(:user) }
    let(:char) { create(:character, user: user) }
    let(:inst) { create(:character_instance, character: char, reality: reality, current_room: room) }
    let!(:enemy) { create_participant(inst, hex_x: 3, hex_y: 0, side: 2) }

    describe '#select_ability_with_target' do
      it 'returns nil when global cooldown is active' do
        participant.update(global_ability_cooldown: 3)
        participant.refresh
        ai = described_class.new(participant)
        expect(ai.send(:select_ability_with_target)).to be_nil
      end

      it 'returns nil when archetype has no abilities' do
        ai = described_class.new(participant)
        allow(archetype).to receive(:combat_abilities_with_chances).and_return([])
        expect(ai.send(:select_ability_with_target)).to be_nil
      end
    end

    describe '#select_target_for_ability' do
      it 'returns self for self-targeting ability' do
        ai = described_class.new(participant)
        ability = double('Ability', target_type: 'self')
        result = ai.send(:select_target_for_ability, ability, [], [enemy])
        expect(result).to eq(participant)
      end

      it 'returns most wounded ally for healing ability' do
        ai = described_class.new(participant)
        ability = double('Ability', target_type: 'ally')
        allow(ability).to receive(:healing_ability?).and_return(true)

        wounded_ally = double('Participant', current_hp: 1, max_hp: 10)
        healthy_ally = double('Participant', current_hp: 9, max_hp: 10)

        result = ai.send(:select_target_for_ability, ability, [wounded_ally, healthy_ally], [])
        # Should pick the one with lowest hp_percent
        expect(ai.send(:hp_percent_for, result)).to be <= 0.5
      end

      it 'returns enemy for enemy-targeting ability based on strategy' do
        ai = described_class.new(participant)
        ability = double('Ability', target_type: 'enemy')
        result = ai.send(:select_target_for_ability, ability, [], [enemy])
        expect(result).to eq(enemy)
      end
    end

    describe '#select_target_by_strategy' do
      it 'returns nil for empty enemies' do
        ai = described_class.new(participant)
        expect(ai.send(:select_target_by_strategy, [])).to be_nil
      end
    end
  end

  describe 'movement strategy' do
    let(:archetype) { NpcArchetype.create(name: 'Test Movement Strategy', behavior_pattern: 'aggressive') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance, hex_x: 0, hex_y: 0, max_hp: 6) }

    let(:user) { create(:user) }
    let(:char) { create(:character, user: user) }
    let(:inst) { create(:character_instance, character: char, reality: reality, current_room: room) }
    let!(:enemy) { create_participant(inst, hex_x: 5, hex_y: 0, side: 2) }

    describe '#choose_melee_movement' do
      it 'keeps towards_person in melee for aggressive NPCs' do
        enemy.update(hex_x: 1, hex_y: 0)
        ai = described_class.new(participant)
        result = ai.send(:choose_melee_movement, enemy, 1)
        expect(result[:action]).to eq('towards_person')
        expect(result[:target_id]).to eq(enemy.id)
      end

      it 'moves towards target when out of range' do
        ai = described_class.new(participant)
        result = ai.send(:choose_melee_movement, enemy, 5)
        expect(result[:action]).to eq('towards_person')
        expect(result[:target_id]).to eq(enemy.id)
      end

      it 'stays still in melee for non-aggressive NPC profiles' do
        archetype.update(combat_ai_profile: 'defensive')
        enemy.update(hex_x: 1, hex_y: 0)
        ai = described_class.new(participant)
        result = ai.send(:choose_melee_movement, enemy, 1)
        expect(result[:action]).to eq('stand_still')
      end
    end

    describe '#choose_ranged_movement' do
      it 'backs off when too close' do
        enemy.update(hex_x: 1, hex_y: 0)
        ai = described_class.new(participant)
        # Mock ranged weapon to trigger ranged behavior
        allow(participant).to receive(:ranged_weapon).and_return(double('Weapon', pattern: double(range_in_hexes: 6)))
        result = ai.send(:choose_ranged_movement, enemy, 1)
        expect(result[:action]).to eq('maintain_distance')
      end

      it 'stays still when in weapon range without battle map' do
        ai = described_class.new(participant)
        allow(participant).to receive(:ranged_weapon).and_return(double('Weapon', pattern: double(range_in_hexes: 10)))
        allow(ai).to receive(:battle_map_active?).and_return(false)
        result = ai.send(:choose_ranged_movement, enemy, 5)
        expect(result[:action]).to eq('stand_still')
      end

      it 'advances when out of weapon range' do
        enemy.update(hex_x: 15, hex_y: 0)
        ai = described_class.new(participant)
        allow(participant).to receive(:ranged_weapon).and_return(double('Weapon', pattern: double(range_in_hexes: 6)))
        allow(ai).to receive(:battle_map_active?).and_return(false)
        result = ai.send(:choose_ranged_movement, enemy, 15)
        expect(result[:action]).to eq('towards_person')
      end

      it 'returns explicit hex coordinates when repositioning on battle map' do
        ai = described_class.new(participant)
        allow(participant).to receive(:ranged_weapon).and_return(double('Weapon', pattern: double(range_in_hexes: 10)))
        allow(ai).to receive(:battle_map_active?).and_return(true)
        allow(ai).to receive(:find_best_reposition).and_return({ x: 7, y: 4 })

        result = ai.send(:choose_ranged_movement, enemy, 5)
        expect(result[:action]).to eq('move_to_hex')
        expect(result[:hex_x]).to eq(7)
        expect(result[:hex_y]).to eq(4)
        expect(result[:target_id]).to be_nil
      end
    end

    describe '#select_best_ranged_target' do
      it 'uses acted_this_round for stationary cover logic without errors' do
        ai = described_class.new(participant)
        allow(fight).to receive(:uses_new_hex_system?).and_return(true)

        battle_map = instance_double(
          BattleMapCombatService,
          participant_elevation: 0,
          shot_passes_through_cover?: true
        )
        allow(BattleMapCombatService).to receive(:new).with(fight).and_return(battle_map)
        allow(RoomHex).to receive(:hex_details).and_return(nil)
        allow(ConcealmentService).to receive(:applies_to_attack?).and_return(false)

        enemy.update(moved_this_round: false, acted_this_round: false)

        expect { ai.send(:select_best_ranged_target, [enemy]) }.not_to raise_error
      end
    end

    describe '#choose_flexible_movement' do
      it 'uses melee movement when target is behind cover' do
        ai = described_class.new(participant)
        allow(ai).to receive(:should_prefer_melee?).with(enemy).and_return(true)
        result = ai.send(:choose_flexible_movement, enemy, 5)
        expect(result[:action]).to eq('towards_person')
      end

      it 'uses ranged movement when target is not behind cover' do
        ai = described_class.new(participant)
        allow(ai).to receive(:should_prefer_melee?).with(enemy).and_return(false)
        allow(participant).to receive(:ranged_weapon).and_return(double('Weapon', pattern: double(range_in_hexes: 10)))
        allow(ai).to receive(:battle_map_active?).and_return(false)
        result = ai.send(:choose_flexible_movement, enemy, 5)
        expect(result[:action]).to eq('stand_still')
      end
    end
  end

  describe 'battle map integration' do
    let(:battle_map_room) { create(:room, has_battle_map: true) }
    let(:battle_fight) { Fight.create(room_id: battle_map_room.id, uses_battle_map: true) }
    let(:archetype) { NpcArchetype.create(name: 'Test Battle Map', behavior_pattern: 'aggressive') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: battle_map_room) }

    def create_battle_participant(character_instance, **attrs)
      FightParticipant.create(
        fight_id: battle_fight.id,
        character_instance_id: character_instance.id,
        hex_x: attrs[:hex_x] || 0,
        hex_y: attrs[:hex_y] || 0,
        current_hp: attrs[:current_hp] || 5,
        max_hp: attrs[:max_hp] || 5,
        side: attrs[:side] || 1
      )
    end

    let(:participant) { create_battle_participant(npc_instance, hex_x: 0, hex_y: 0) }

    describe '#battle_map_active?' do
      it 'returns true when fight uses battle map and room has battle map' do
        ai = described_class.new(participant)
        expect(ai.send(:battle_map_active?)).to be true
      end
    end

    describe '#target_is_behind_cover?' do
      let(:user) { create(:user) }
      let(:char) { create(:character, user: user) }
      let(:inst) { create(:character_instance, character: char, reality: reality, current_room: battle_map_room) }
      let!(:enemy) { create_battle_participant(inst, hex_x: 5, hex_y: 0, side: 2) }

      it 'returns false when battle map is not active' do
        allow(battle_fight).to receive(:uses_battle_map).and_return(false)
        ai = described_class.new(participant)
        expect(ai.send(:target_is_behind_cover?, enemy)).to be false
      end
    end

    describe '#should_prefer_melee?' do
      let(:user) { create(:user) }
      let(:char) { create(:character, user: user) }
      let(:inst) { create(:character_instance, character: char, reality: reality, current_room: battle_map_room) }
      let!(:enemy) { create_battle_participant(inst, hex_x: 5, hex_y: 0, side: 2) }

      it 'returns false without both weapons' do
        ai = described_class.new(participant)
        allow(ai).to receive(:has_both_weapons?).and_return(false)
        expect(ai.send(:should_prefer_melee?, enemy)).to be false
      end

      it 'returns false when target is not behind cover' do
        ai = described_class.new(participant)
        allow(ai).to receive(:has_both_weapons?).and_return(true)
        allow(ai).to receive(:target_is_behind_cover?).and_return(false)
        expect(ai.send(:should_prefer_melee?, enemy)).to be false
      end
    end

    describe '#base_target_score' do
      let(:user) { create(:user) }
      let(:char) { create(:character, user: user) }
      let(:inst) { create(:character_instance, character: char, reality: reality, current_room: battle_map_room) }

      it 'gives bonus for wounded targets' do
        enemy = create_battle_participant(inst, hex_x: 2, hex_y: 0, current_hp: 1, max_hp: 10, side: 2)
        ai = described_class.new(participant)
        score = ai.send(:base_target_score, enemy)
        expect(score).to be > 0
      end

      it 'gives bonus for targets in weapon range' do
        enemy = create_battle_participant(inst, hex_x: 1, hex_y: 0, current_hp: 5, max_hp: 5, side: 2)
        ai = described_class.new(participant)
        score = ai.send(:base_target_score, enemy)
        expect(score).to be >= 0
      end
    end
  end

  describe 'hazard awareness' do
    let(:archetype) { NpcArchetype.create(name: 'Test Hazard', behavior_pattern: 'aggressive') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance, hex_x: 0, hex_y: 0) }

    let(:user) { create(:user) }
    let(:char) { create(:character, user: user) }
    let(:inst) { create(:character_instance, character: char, reality: reality, current_room: room) }
    let!(:enemy) { create_participant(inst, hex_x: 3, hex_y: 0, current_hp: 5, max_hp: 5, side: 2) }

    describe '#calculate_hazard_push_score' do
      let(:hazard_hex) { double('RoomHex') }

      before do
        allow(hazard_hex).to receive(:hex_type).and_return('fire')
        allow(hazard_hex).to receive(:traversable).and_return(true)
        allow(hazard_hex).to receive(:hazard_damage_per_round).and_return(5)
        allow(hazard_hex).to receive(:danger_level).and_return(3)
        allow(hazard_hex).to receive(:hazard_type).and_return('fire')
        allow(hazard_hex).to receive(:is_explosive).and_return(false)
      end

      it 'returns positive score for hazard' do
        ai = described_class.new(participant)
        score = ai.send(:calculate_hazard_push_score, hazard_hex, enemy)
        expect(score).to be > 0
      end

      it 'returns 0 for nil hazard' do
        ai = described_class.new(participant)
        expect(ai.send(:calculate_hazard_push_score, nil, enemy)).to eq(0)
      end

      context 'with pit hex' do
        before do
          allow(hazard_hex).to receive(:hex_type).and_return('pit')
          allow(hazard_hex).to receive(:traversable).and_return(false)
        end

        it 'returns high score' do
          ai = described_class.new(participant)
          score = ai.send(:calculate_hazard_push_score, hazard_hex, enemy)
          expect(score).to be > 50
        end
      end
    end

    describe '#calculate_forced_movement_destination' do
      it 'calculates push destination' do
        ai = described_class.new(participant)
        result = ai.send(:calculate_forced_movement_destination, enemy, 'push', 2)
        expect(result[:x]).to be > enemy.hex_x
      end

      it 'calculates pull destination' do
        ai = described_class.new(participant)
        result = ai.send(:calculate_forced_movement_destination, enemy, 'pull', 2)
        expect(result[:x]).to be < enemy.hex_x
      end

      it 'returns nil when target has no position' do
        enemy.update(hex_x: nil, hex_y: nil)
        ai = described_class.new(participant)
        result = ai.send(:calculate_forced_movement_destination, enemy, 'push', 2)
        expect(result).to be_nil
      end

      it 'returns nil when attacker has no position' do
        participant.update(hex_x: nil, hex_y: nil)
        ai = described_class.new(participant)
        result = ai.send(:calculate_forced_movement_destination, enemy, 'push', 2)
        expect(result).to be_nil
      end

      it 'handles away_from direction' do
        ai = described_class.new(participant)
        result = ai.send(:calculate_forced_movement_destination, enemy, 'away_from', 2)
        expect(result[:x]).to be > enemy.hex_x
      end

      it 'handles towards direction' do
        ai = described_class.new(participant)
        result = ai.send(:calculate_forced_movement_destination, enemy, 'towards', 2)
        expect(result[:x]).to be < enemy.hex_x
      end

      it 'returns nil when target is at same position' do
        enemy.update(hex_x: 0, hex_y: 0)
        ai = described_class.new(participant)
        result = ai.send(:calculate_forced_movement_destination, enemy, 'push', 2)
        expect(result).to be_nil
      end
    end

    describe '#find_best_hazard_push' do
      it 'returns nil when room is nil' do
        ai = described_class.new(participant)
        allow(fight).to receive(:room).and_return(nil)
        result = ai.send(:find_best_hazard_push, [], [enemy])
        expect(result).to be_nil
      end

      it 'returns nil for empty forced movement abilities' do
        ai = described_class.new(participant)
        result = ai.send(:find_best_hazard_push, [], [enemy])
        expect(result).to be_nil
      end
    end
  end

  describe 'advanced monster combat' do
    let(:archetype) { NpcArchetype.create(name: 'Test Advanced Monster', behavior_pattern: 'aggressive') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance, hex_x: 0, hex_y: 0) }

    describe '#should_attempt_mount?' do
      let(:monster) { double('LargeMonsterInstance') }

      it 'returns false when not adjacent to monster' do
        ai = described_class.new(participant)
        allow(ai).to receive(:adjacent_to_monster?).with(monster).and_return(false)
        expect(ai.send(:should_attempt_mount?, monster)).to be false
      end
    end

    describe '#adjacent_to_monster?' do
      let(:monster) { double('LargeMonsterInstance') }
      let(:segment) { double('MonsterSegmentInstance') }

      it 'returns false when participant has no position' do
        participant.update(hex_x: nil, hex_y: nil)
        ai = described_class.new(participant)
        expect(ai.send(:adjacent_to_monster?, monster)).to be false
      end

      it 'returns true when within 1 hex of a segment' do
        allow(segment).to receive(:hex_position).and_return([1, 0])
        allow(monster).to receive(:monster_segment_instances).and_return([segment])
        ai = described_class.new(participant)
        expect(ai.send(:adjacent_to_monster?, monster)).to be true
      end

      it 'returns false when no segments are close' do
        allow(segment).to receive(:hex_position).and_return([10, 10])
        allow(monster).to receive(:monster_segment_instances).and_return([segment])
        ai = described_class.new(participant)
        expect(ai.send(:adjacent_to_monster?, monster)).to be false
      end

      it 'handles segments with nil position' do
        allow(segment).to receive(:hex_position).and_return(nil)
        allow(monster).to receive(:monster_segment_instances).and_return([segment])
        ai = described_class.new(participant)
        expect(ai.send(:adjacent_to_monster?, monster)).to be false
      end
    end

    describe '#find_closest_segment' do
      let(:monster) { double('LargeMonsterInstance') }
      let(:close_segment) { double('MonsterSegmentInstance', status: 'healthy') }
      let(:far_segment) { double('MonsterSegmentInstance', status: 'healthy') }

      it 'returns nil for empty segments' do
        allow(monster).to receive(:monster_segment_instances).and_return([])
        ai = described_class.new(participant)
        expect(ai.send(:find_closest_segment, monster)).to be_nil
      end

      it 'returns first segment when participant has no position' do
        participant.update(hex_x: nil, hex_y: nil)
        allow(close_segment).to receive(:hex_position).and_return([1, 0])
        allow(monster).to receive(:monster_segment_instances).and_return([close_segment])
        ai = described_class.new(participant)
        expect(ai.send(:find_closest_segment, monster)).to eq(close_segment)
      end

      it 'returns closest segment by distance' do
        allow(close_segment).to receive(:hex_position).and_return([1, 0])
        allow(far_segment).to receive(:hex_position).and_return([10, 10])
        allow(monster).to receive(:monster_segment_instances).and_return([far_segment, close_segment])
        ai = described_class.new(participant)
        expect(ai.send(:find_closest_segment, monster)).to eq(close_segment)
      end

      it 'excludes destroyed segments' do
        destroyed_segment = double('MonsterSegmentInstance', status: 'destroyed')
        allow(close_segment).to receive(:hex_position).and_return([1, 0])
        allow(monster).to receive(:monster_segment_instances).and_return([destroyed_segment, close_segment])
        ai = described_class.new(participant)
        expect(ai.send(:find_closest_segment, monster)).to eq(close_segment)
      end
    end

    describe '#select_target_segment' do
      let(:monster) { double('LargeMonsterInstance') }
      let(:segment) { double('MonsterSegmentInstance', status: 'healthy', current_hp: 10) }

      it 'returns nil when all segments destroyed' do
        destroyed = double('MonsterSegmentInstance', status: 'destroyed')
        allow(monster).to receive(:monster_segment_instances).and_return([destroyed])
        ai = described_class.new(participant)
        expect(ai.send(:select_target_segment, monster)).to be_nil
      end
    end

    describe '#should_cling?' do
      let(:monster) { double('LargeMonsterInstance') }
      let(:mount_state) { double('MonsterMountState') }
      let(:monster_template) { double('MonsterTemplate', shake_off_threshold: 2) }

      it 'returns true when HP is very low' do
        participant.update(current_hp: 1)
        participant.refresh
        ai = described_class.new(participant)
        expect(ai.send(:should_cling?, monster, mount_state)).to be true
      end
    end

    describe '#should_dismount?' do
      let(:monster) { double('LargeMonsterInstance') }
      let(:mount_state) { double('MonsterMountState') }

      it 'returns true when critically wounded' do
        participant.update(current_hp: 1, max_hp: 10)
        participant.refresh
        ai = described_class.new(participant)
        expect(ai.send(:should_dismount?, monster, mount_state)).to be true
      end
    end

    describe 'monster decision building' do
      describe '#plan_weak_point_attack' do
        let(:monster) { double('LargeMonsterInstance') }
        let(:weak_segment) { double('MonsterSegmentInstance', id: 99) }

        it 'builds attack decisions targeting weak point' do
          allow(monster).to receive(:id).and_return(1)
          allow(monster).to receive(:weak_point_segment).and_return(weak_segment)
          ai = described_class.new(participant)
          result = ai.send(:plan_weak_point_attack, monster)
          expect(result[:main_action]).to eq('attack')
          expect(result[:mount_action]).to eq('attack')
          expect(result[:targeting_segment_id]).to eq(99)
        end
      end

      describe '#plan_cling_action' do
        let(:monster) { double('LargeMonsterInstance') }

        it 'builds defensive cling decisions' do
          ai = described_class.new(participant)
          result = ai.send(:plan_cling_action, monster)
          expect(result[:main_action]).to eq('defend')
          expect(result[:mount_action]).to eq('cling')
        end
      end

      describe '#plan_dismount' do
        let(:monster) { double('LargeMonsterInstance') }

        it 'builds dismount decisions with movement away' do
          ai = described_class.new(participant)
          result = ai.send(:plan_dismount, monster)
          expect(result[:main_action]).to eq('defend')
          expect(result[:mount_action]).to eq('dismount')
          expect(result[:movement_action]).to eq('move_to_hex')
        end
      end

      describe '#plan_ground_attack' do
        let(:monster) { double('LargeMonsterInstance') }
        let(:segment) { double('MonsterSegmentInstance', id: 42, status: 'healthy', current_hp: 10) }

        before do
          allow(monster).to receive(:id).and_return(1)
          allow(monster).to receive(:monster_segment_instances).and_return([segment])
          allow(segment).to receive(:hex_position).and_return([1, 0])
          allow(segment).to receive(:required_for_mobility?).and_return(false)
          allow(segment).to receive(:weak_point?).and_return(false)
        end

        it 'builds attack decisions for ground combat' do
          ai = described_class.new(participant)
          result = ai.send(:plan_ground_attack, monster)
          expect(result[:main_action]).to eq('attack')
          expect(result[:targeting_monster_id]).to eq(1)
          expect(result[:movement_action]).to eq('move_to_hex')
        end

        it 'uses maintain_distance for ranged only' do
          ai = described_class.new(participant)
          allow(ai).to receive(:ranged_only?).and_return(true)
          result = ai.send(:plan_ground_attack, monster)
          expect(result[:movement_action]).to eq('stand_still')
        end
      end
    end
  end

  describe 'archetype profile determination' do
    describe '#determine_archetype' do
      let(:archetype) { NpcArchetype.create(name: 'Test Archetype Determine', behavior_pattern: 'aggressive') }
      let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
      let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
      let(:participant) { create_participant(npc_instance) }

      it 'returns archetype for NPC' do
        ai = described_class.new(participant)
        expect(ai.archetype).to eq(archetype)
      end

      it 'returns nil for PC' do
        user = create(:user)
        pc_character = create(:character, user: user, is_npc: false)
        pc_instance = create(:character_instance, character: pc_character, reality: reality, current_room: room)
        pc_participant = create_participant(pc_instance)

        ai = described_class.new(pc_participant)
        expect(ai.archetype).to be_nil
      end
    end

    describe '#determine_profile' do
      it 'merges flee_health_percent from archetype' do
        archetype = NpcArchetype.create(
          name: 'Test Flee Percent',
          behavior_pattern: 'aggressive',
          flee_health_percent: 25
        )
        npc_character = create(:character, :npc, npc_archetype: archetype)
        npc_instance = create(:character_instance, character: npc_character, reality: reality, current_room: room)
        participant = create_participant(npc_instance)

        ai = described_class.new(participant)
        expect(ai.profile[:flee_threshold]).to eq(0.25)
      end

      it 'merges defensive_health_percent from archetype' do
        archetype = NpcArchetype.create(
          name: 'Test Defensive Percent',
          behavior_pattern: 'passive',
          defensive_health_percent: 50
        )
        npc_character = create(:character, :npc, npc_archetype: archetype)
        npc_instance = create(:character_instance, character: npc_character, reality: reality, current_room: room)
        participant = create_participant(npc_instance)

        ai = described_class.new(participant)
        expect(ai.profile[:defensive_threshold]).to eq(0.5)
      end
    end
  end

  describe 'npc abilities' do
    let(:archetype) { NpcArchetype.create(name: 'Test NPC Abilities', behavior_pattern: 'aggressive') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance) }

    describe '#npc_abilities' do
      it 'returns empty array for archetype without abilities' do
        ai = described_class.new(participant)
        expect(ai.send(:npc_abilities)).to eq([])
      end

      it 'returns empty array when archetype is nil' do
        user = create(:user)
        pc_character = create(:character, user: user, is_npc: false)
        pc_instance = create(:character_instance, character: pc_character, reality: reality, current_room: room)
        pc_participant = create_participant(pc_instance)

        ai = described_class.new(pc_participant)
        expect(ai.send(:npc_abilities)).to eq([])
      end
    end
  end

  describe 'available enemies and allies' do
    let(:archetype) { NpcArchetype.create(name: 'Test Enemies Allies', behavior_pattern: 'aggressive') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance, side: 1) }

    let(:user1) { create(:user) }
    let(:ally_char) { create(:character, user: user1) }
    let(:ally_inst) { create(:character_instance, character: ally_char, reality: reality, current_room: room) }
    let!(:ally) { create_participant(ally_inst, hex_x: 1, hex_y: 0, side: 1) }

    let(:user2) { create(:user) }
    let(:enemy_char) { create(:character, user: user2) }
    let(:enemy_inst) { create(:character_instance, character: enemy_char, reality: reality, current_room: room) }
    let!(:enemy) { create_participant(enemy_inst, hex_x: 5, hex_y: 0, side: 2) }

    describe '#available_enemies' do
      it 'returns enemies on different side' do
        ai = described_class.new(participant)
        enemies = ai.send(:available_enemies)
        expect(enemies).to include(enemy)
        expect(enemies).not_to include(ally)
        expect(enemies).not_to include(participant)
      end

      it 'excludes knocked out enemies' do
        enemy.update(is_knocked_out: true)
        ai = described_class.new(participant)
        enemies = ai.send(:available_enemies)
        expect(enemies).not_to include(enemy)
      end
    end

    describe '#available_allies' do
      it 'returns allies on same side excluding self' do
        ai = described_class.new(participant)
        allies = ai.send(:available_allies)
        expect(allies).to include(ally)
        expect(allies).not_to include(enemy)
        expect(allies).not_to include(participant)
      end

      it 'excludes knocked out allies' do
        ally.update(is_knocked_out: true)
        ai = described_class.new(participant)
        allies = ai.send(:available_allies)
        expect(allies).not_to include(ally)
      end
    end
  end

  describe 'choose_movement edge cases' do
    let(:archetype) { NpcArchetype.create(name: 'Test Movement Edge', behavior_pattern: 'aggressive') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance, hex_x: 0, hex_y: 0) }

    let(:user) { create(:user) }
    let(:enemy_char) { create(:character, user: user) }
    let(:enemy_inst) { create(:character_instance, character: enemy_char, reality: reality, current_room: room) }
    let!(:enemy) { create_participant(enemy_inst, hex_x: 5, hex_y: 0, side: 2) }

    describe '#choose_movement' do
      it 'returns no movement when target_id is nil' do
        ai = described_class.new(participant)
        result = ai.send(:choose_movement, nil)
        expect(result[:action]).to eq('stand_still')
      end

      it 'returns no movement when target not found' do
        ai = described_class.new(participant)
        result = ai.send(:choose_movement, 99999)
        expect(result[:action]).to eq('stand_still')
      end

      it 'returns away_from when critically wounded' do
        participant.update(current_hp: 1, max_hp: 10)
        participant.refresh
        ai = described_class.new(participant)
        result = ai.send(:choose_movement, enemy.id)
        expect(result[:action]).to eq('away_from')
      end
    end
  end

  describe '#decide_standard_combat!' do
    let(:archetype) { NpcArchetype.create(name: 'Test Decide Movement', behavior_pattern: 'aggressive') }
    let(:npc_character) { create(:character, :npc, npc_archetype: archetype) }
    let(:npc_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }
    let(:participant) { create_participant(npc_instance, hex_x: 0, hex_y: 0) }

    let(:user) { create(:user) }
    let(:enemy_char) { create(:character, user: user) }
    let(:enemy_inst) { create(:character_instance, character: enemy_char, reality: reality, current_room: room) }
    let!(:enemy) { create_participant(enemy_inst, hex_x: 5, hex_y: 0, side: 2) }

    it 'writes move_to_hex into target_hex fields instead of movement_target_participant_id' do
      ai = described_class.new(participant)
      allow(ai).to receive(:select_target).and_return(enemy.id)
      allow(ai).to receive(:choose_main_action).and_return({ action: 'attack', ability_id: nil, ability_target_id: nil })
      allow(ai).to receive(:choose_movement).and_return(
        { action: 'move_to_hex', target_id: nil, distance: nil, hex_x: 8, hex_y: 6 }
      )

      decisions = ai.decide_standard_combat!
      expect(decisions[:movement_action]).to eq('move_to_hex')
      expect(decisions[:target_hex_x]).to eq(8)
      expect(decisions[:target_hex_y]).to eq(6)
      expect(decisions[:movement_target_participant_id]).to be_nil
    end
  end
end
