# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FightParticipant do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Battle Room', short_description: 'A room', room_type: 'standard') }
  let(:reality) { create(:reality) }
  let(:fight) { Fight.create(room_id: room.id) }

  let(:user) { create(:user) }
  let(:character) { Character.create(forename: 'Fighter', surname: 'One', user: user, is_npc: false) }
  let(:character_instance) do
    CharacterInstance.create(
      character: character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      level: 1,
      experience: 0,
      health: 6,
      max_health: 6,
      mana: 50,
      max_mana: 50
    )
  end

  describe 'validations' do
    it 'requires fight_id' do
      participant = FightParticipant.new(character_instance_id: character_instance.id)
      expect(participant.valid?).to be false
      expect(participant.errors[:fight_id]).to include('is not present')
    end

    it 'requires character_instance_id' do
      participant = FightParticipant.new(fight_id: fight.id)
      expect(participant.valid?).to be false
      expect(participant.errors[:character_instance_id]).to include('is not present')
    end

    it 'validates input_stage is valid' do
      participant = FightParticipant.new(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        input_stage: 'invalid'
      )
      expect(participant.valid?).to be false
      expect(participant.errors[:input_stage]).not_to be_empty
    end

    it 'validates main_action is valid' do
      participant = FightParticipant.new(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        main_action: 'invalid'
      )
      expect(participant.valid?).to be false
      expect(participant.errors[:main_action]).not_to be_empty
    end

    it 'accepts stand as a valid main_action' do
      participant = FightParticipant.new(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        main_action: 'stand'
      )

      expect(participant.valid?).to be true
      expect(participant.errors[:main_action]).to be_nil
    end

    it 'validates tactic_choice is valid when present' do
      participant = FightParticipant.new(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        tactic_choice: 'invalid'
      )
      expect(participant.valid?).to be false
      expect(participant.errors[:tactic_choice]).not_to be_empty
    end
  end

  describe 'before_create' do
    it 'sets default values' do
      participant = FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )

      expect(participant.current_hp).to eq(GameConfig::Mechanics::DEFAULT_HP[:current])
      expect(participant.max_hp).to eq(GameConfig::Mechanics::DEFAULT_HP[:max])
      expect(participant.willpower_dice).to eq(GameConfig::Mechanics::WILLPOWER[:initial_dice])
      expect(participant.input_stage).to eq('main_menu')
    end
  end

  describe '#wound_penalty' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        current_hp: 4,
        max_hp: 6
      )
    end

    it 'calculates penalty based on HP lost' do
      expect(participant.wound_penalty).to eq(2) # max_hp - current_hp = 6 - 4
    end

    it 'returns 0 at full HP' do
      participant.update(current_hp: 6)
      expect(participant.wound_penalty).to eq(0)
    end
  end

  describe '#damage_thresholds' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        current_hp: 6,
        max_hp: 6
      )
    end

    it 'returns base thresholds at full HP' do
      thresholds = participant.damage_thresholds
      expect(thresholds[:miss]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:miss])
      expect(thresholds[:one_hp]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:one_hp])
      expect(thresholds[:two_hp]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:two_hp])
      expect(thresholds[:three_hp]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:three_hp])
    end

    it 'reduces thresholds by wound penalty' do
      participant.update(current_hp: 4) # 2 HP lost
      thresholds = participant.damage_thresholds

      expect(thresholds[:miss]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:miss] - 2)
      expect(thresholds[:one_hp]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:one_hp] - 2)
      expect(thresholds[:two_hp]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:two_hp] - 2)
      expect(thresholds[:three_hp]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:three_hp] - 2)
    end
  end

  describe '#calculate_hp_from_damage' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        current_hp: 6,
        max_hp: 6
      )
    end

    it 'returns 0 HP for damage at or below miss threshold (<10)' do
      miss_threshold = GameConfig::Mechanics::DAMAGE_THRESHOLDS[:miss]
      expect(participant.calculate_hp_from_damage(miss_threshold)).to eq(0)
      expect(participant.calculate_hp_from_damage(miss_threshold - 5)).to eq(0)
    end

    it 'returns 1 HP for damage between miss and one_hp threshold (10-17)' do
      one_hp_threshold = GameConfig::Mechanics::DAMAGE_THRESHOLDS[:one_hp]
      expect(participant.calculate_hp_from_damage(one_hp_threshold)).to eq(1)
    end

    it 'returns 2 HP for damage between one_hp and two_hp threshold (18-29)' do
      two_hp_threshold = GameConfig::Mechanics::DAMAGE_THRESHOLDS[:two_hp]
      expect(participant.calculate_hp_from_damage(two_hp_threshold)).to eq(2)
    end

    it 'returns 3 HP for damage between two_hp and three_hp threshold (30-99)' do
      three_hp_threshold = GameConfig::Mechanics::DAMAGE_THRESHOLDS[:three_hp]
      expect(participant.calculate_hp_from_damage(three_hp_threshold)).to eq(3)
    end

    it 'returns 4+ HP for damage 100+ with 100 damage bands' do
      expect(participant.calculate_hp_from_damage(100)).to eq(4)
      expect(participant.calculate_hp_from_damage(199)).to eq(4)
      expect(participant.calculate_hp_from_damage(200)).to eq(5)
      expect(participant.calculate_hp_from_damage(299)).to eq(5)
      expect(participant.calculate_hp_from_damage(300)).to eq(6)
    end
  end

  describe '#take_damage' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        current_hp: 6,
        max_hp: 6,
        willpower_dice: 0
      )
    end

    it 'reduces HP based on threshold calculation' do
      one_hp_threshold = GameConfig::Mechanics::DAMAGE_THRESHOLDS[:one_hp]
      hp_lost = participant.take_damage(one_hp_threshold)

      expect(hp_lost).to eq(1)
      expect(participant.reload.current_hp).to eq(5)
    end

    it 'grants willpower dice for HP lost' do
      one_hp_threshold = GameConfig::Mechanics::DAMAGE_THRESHOLDS[:one_hp]
      participant.take_damage(one_hp_threshold)

      expected_wp = GameConfig::Mechanics::WILLPOWER[:gain_per_hp_lost]
      expect(participant.reload.willpower_dice).to eq(expected_wp)
    end

    it 'knocks out participant at 0 HP' do
      participant.update(current_hp: 1)
      two_hp_threshold = GameConfig::Mechanics::DAMAGE_THRESHOLDS[:two_hp]
      participant.take_damage(two_hp_threshold)

      expect(participant.reload.is_knocked_out).to be true
      expect(participant.current_hp).to eq(0)
    end

    it 'does not reduce HP below 0' do
      participant.update(current_hp: 1)
      # Force max damage
      participant.take_damage(100)

      expect(participant.reload.current_hp).to eq(0)
    end
  end

  describe '#available_willpower_dice' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        willpower_dice: 2.5
      )
    end

    it 'returns floored value' do
      expect(participant.available_willpower_dice).to eq(2)
    end

    it 'returns 0 when less than 1' do
      participant.update(willpower_dice: 0.75)
      expect(participant.available_willpower_dice).to eq(0)
    end
  end

  describe '#use_willpower_die!' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        willpower_dice: 2.0,
        willpower_dice_used_this_round: 0
      )
    end

    it 'returns true and deducts 1 willpower die when available' do
      result = participant.use_willpower_die!

      expect(result).to be true
      expect(participant.reload.willpower_dice).to eq(1.0)
      expect(participant.willpower_dice_used_this_round).to eq(1)
    end

    it 'returns false when no willpower dice available' do
      participant.update(willpower_dice: 0.5)
      result = participant.use_willpower_die!

      expect(result).to be false
      expect(participant.reload.willpower_dice).to eq(0.5)
    end

    it 'increments dice used counter' do
      participant.use_willpower_die!
      participant.use_willpower_die!

      expect(participant.reload.willpower_dice_used_this_round).to eq(2)
    end
  end

  describe '#set_willpower_allocation!' do
    let(:participant) do
      attrs = {
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        willpower_dice: 3.0,
        willpower_dice_used_this_round: 0,
        willpower_attack: 0,
        willpower_defense: 0,
        willpower_ability: 0
      }
      attrs[:willpower_movement] = 0 if FightParticipant.columns.include?(:willpower_movement)
      FightParticipant.create(attrs)
    end

    it 'deducts willpower when increasing allocation' do
      result = participant.set_willpower_allocation!(attack: 2, defense: 0, ability: 0, movement: 0)

      expect(result).to be true
      expect(participant.reload.willpower_attack).to eq(2)
      expect(participant.willpower_dice).to eq(1.0)
      expect(participant.willpower_dice_used_this_round).to eq(2)
    end

    it 'refunds willpower when reducing allocation' do
      participant.set_willpower_allocation!(attack: 2, defense: 0, ability: 0, movement: 0)
      participant.set_willpower_allocation!(attack: 0, defense: 1, ability: 0, movement: 0)

      participant.reload
      expect(participant.willpower_attack).to eq(0)
      expect(participant.willpower_defense).to eq(1)
      expect(participant.willpower_dice).to eq(2.0)
      expect(participant.willpower_dice_used_this_round).to eq(1)
    end

    it 'returns false if allocation increase exceeds available dice' do
      participant.update(willpower_dice: 0.0)

      result = participant.set_willpower_allocation!(attack: 1, defense: 0, ability: 0, movement: 0)

      expect(result).to be false
      participant.reload
      expect(participant.willpower_dice).to eq(0.0)
      expect(participant.willpower_attack).to eq(0)
    end
  end

  describe 'associations' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'belongs to fight' do
      expect(participant.fight).to eq(fight)
    end

    it 'belongs to character_instance' do
      expect(participant.character_instance).to eq(character_instance)
    end

    it 'can have a target_participant' do
      user2 = create(:user)
      char2 = Character.create(forename: 'Target', surname: 'Char', user: user2, is_npc: false)
      instance2 = CharacterInstance.create(
        character: char2,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
      target = FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: instance2.id,
        side: 2
      )

      participant.update(target_participant_id: target.id)
      expect(participant.reload.target_participant).to eq(target)
    end
  end

  describe '#character_name' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'returns the character full name' do
      expect(participant.character_name).to eq('Fighter One')
    end
  end

  describe '#can_act?' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'returns true when not knocked out' do
      expect(participant.can_act?).to be true
    end

    it 'returns false when knocked out' do
      participant.update(is_knocked_out: true)
      expect(participant.can_act?).to be false
    end
  end

  describe '#hex_distance_to' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        hex_x: 0,
        hex_y: 0
      )
    end

    let(:other_participant) do
      user2 = create(:user)
      char2 = Character.create(forename: 'Target', surname: 'Char', user: user2, is_npc: false)
      instance2 = CharacterInstance.create(
        character: char2,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: instance2.id,
        side: 2,
        hex_x: 6,
        hex_y: 4
      )
    end

    it 'calculates hex distance correctly' do
      # Distance from (0,0) to (6,4): dx=6, dy=4; dy<=2*dx → distance=6
      expect(participant.hex_distance_to(other_participant)).to eq(6)
    end

    it 'returns 1 for adjacent hexes' do
      # (0,0) to (1,2) is NE neighbor = 1 hex step
      other_participant.update(hex_x: 1, hex_y: 2)
      expect(participant.hex_distance_to(other_participant)).to eq(1)
    end

    it 'returns 0 for same position' do
      other_participant.update(hex_x: 0, hex_y: 0)
      expect(participant.hex_distance_to(other_participant)).to eq(0)
    end

    it 'returns nil if positions are not set' do
      participant.update(hex_x: nil, hex_y: nil)
      expect(participant.hex_distance_to(other_participant)).to be_nil
    end

    it 'returns 0 if other is nil' do
      expect(participant.hex_distance_to(nil)).to eq(0)
    end
  end

  describe '#in_melee_range?' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        hex_x: 0,
        hex_y: 0
      )
    end

    let(:other_participant) do
      user2 = create(:user)
      char2 = Character.create(forename: 'Melee', surname: 'Target', user: user2, is_npc: false)
      instance2 = CharacterInstance.create(
        character: char2,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: instance2.id,
        side: 2
      )
    end

    it 'returns true for adjacent hexes' do
      other_participant.update(hex_x: 1, hex_y: 0)
      expect(participant.in_melee_range?(other_participant)).to be true
    end

    it 'returns false for distant hexes' do
      other_participant.update(hex_x: 3, hex_y: 0)
      expect(participant.in_melee_range?(other_participant)).to be false
    end
  end

  describe '#movement_speed' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        main_action: 'attack'
      )
    end

    it 'returns base movement speed' do
      expect(participant.movement_speed).to eq(GameConfig::Mechanics::MOVEMENT[:base])
    end

    it 'adds sprint bonus when sprinting' do
      participant.update(main_action: 'sprint')
      expected = GameConfig::Mechanics::MOVEMENT[:base] + GameConfig::Mechanics::MOVEMENT[:sprint_bonus]
      expect(participant.movement_speed).to eq(expected)
    end
  end

  describe 'tactic modifiers' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    describe '#tactic_outgoing_damage_modifier' do
      it 'returns 0 with no tactic' do
        expect(participant.tactic_outgoing_damage_modifier).to eq(0)
      end

      it 'returns config value for aggressive' do
        participant.update(tactic_choice: 'aggressive')
        expect(participant.tactic_outgoing_damage_modifier).to eq(GameConfig::Tactics::OUTGOING_DAMAGE['aggressive'])
      end
    end

    describe '#tactic_incoming_damage_modifier' do
      it 'returns 0 with no tactic' do
        expect(participant.tactic_incoming_damage_modifier).to eq(0)
      end

      it 'returns config value for defensive' do
        participant.update(tactic_choice: 'defensive')
        expect(participant.tactic_incoming_damage_modifier).to eq(GameConfig::Tactics::INCOMING_DAMAGE['defensive'])
      end
    end

    describe '#tactic_movement_modifier' do
      it 'returns 0 with no tactic' do
        expect(participant.tactic_movement_modifier).to eq(0)
      end

      it 'returns config value for quick' do
        participant.update(tactic_choice: 'quick')
        expect(participant.tactic_movement_modifier).to eq(GameConfig::Tactics::MOVEMENT['quick'])
      end
    end
  end

  describe 'guard and back_to_back' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    let(:ally) do
      user2 = create(:user)
      char2 = Character.create(forename: 'Ally', surname: 'Char', user: user2, is_npc: false)
      instance2 = CharacterInstance.create(
        character: char2,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: instance2.id,
        side: 1
      )
    end

    describe '#guarding?' do
      it 'returns true when guarding the target' do
        participant.update(tactic_choice: 'guard', tactic_target_participant_id: ally.id)
        expect(participant.guarding?(ally)).to be true
      end

      it 'returns false when not guarding' do
        expect(participant.guarding?(ally)).to be false
      end
    end

    describe '#back_to_back_with?' do
      it 'returns true when back_to_back with target' do
        participant.update(tactic_choice: 'back_to_back', tactic_target_participant_id: ally.id)
        expect(participant.back_to_back_with?(ally)).to be true
      end

      it 'returns false when not back_to_back' do
        expect(participant.back_to_back_with?(ally)).to be false
      end
    end

    describe '#mutual_back_to_back_with?' do
      it 'returns true when both targeting each other' do
        participant.update(tactic_choice: 'back_to_back', tactic_target_participant_id: ally.id)
        ally.update(tactic_choice: 'back_to_back', tactic_target_participant_id: participant.id)
        expect(participant.mutual_back_to_back_with?(ally)).to be true
      end

      it 'returns false when only one targeting' do
        participant.update(tactic_choice: 'back_to_back', tactic_target_participant_id: ally.id)
        expect(participant.mutual_back_to_back_with?(ally)).to be false
      end
    end

    describe '#tactic_requires_target?' do
      it 'returns true for guard' do
        participant.update(tactic_choice: 'guard')
        expect(participant.tactic_requires_target?).to be true
      end

      it 'returns true for back_to_back' do
        participant.update(tactic_choice: 'back_to_back')
        expect(participant.tactic_requires_target?).to be true
      end

      it 'returns false for aggressive' do
        participant.update(tactic_choice: 'aggressive')
        expect(participant.tactic_requires_target?).to be false
      end
    end
  end

  describe '#complete_input!' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        input_stage: 'main_menu',
        input_complete: false
      )
    end

    it 'marks input as complete' do
      participant.complete_input!
      expect(participant.reload.input_complete).to be true
      expect(participant.input_stage).to eq('done')
    end
  end

  describe '#advance_stage!' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        input_stage: 'main_menu'
      )
    end

    it 'advances to the next stage' do
      participant.advance_stage!
      expect(participant.reload.input_stage).to eq('main_action')
    end

    it 'completes input when reaching done' do
      participant.update(input_stage: 'weapon_ranged')
      participant.advance_stage!
      expect(participant.reload.input_stage).to eq('done')
      expect(participant.input_complete).to be true
    end
  end

  describe 'side/team system' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    let(:ally) do
      user2 = create(:user)
      char2 = Character.create(forename: 'Ally', surname: 'Two', user: user2, is_npc: false)
      instance2 = CharacterInstance.create(
        character: char2,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: instance2.id,
        side: 1
      )
    end

    let(:enemy) do
      user3 = create(:user)
      char3 = Character.create(forename: 'Enemy', surname: 'One', user: user3, is_npc: false)
      instance3 = CharacterInstance.create(
        character: char3,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: instance3.id,
        side: 2
      )
    end

    describe '#same_side?' do
      it 'returns true for same side' do
        expect(participant.same_side?(ally)).to be true
      end

      it 'returns false for different sides' do
        expect(participant.same_side?(enemy)).to be false
      end

      it 'returns false for nil' do
        expect(participant.same_side?(nil)).to be false
      end
    end

    describe '#accumulate_damage!' do
      it 'adds to pending damage total' do
        participant.accumulate_damage!(10)
        participant.accumulate_damage!(15)
        expect(participant.reload.pending_damage_total).to eq(25)
        expect(participant.incoming_attack_count).to eq(2)
      end
    end

    describe '#clear_accumulated_damage!' do
      it 'resets damage counters' do
        participant.update(pending_damage_total: 50, incoming_attack_count: 3)
        participant.clear_accumulated_damage!
        expect(participant.reload.pending_damage_total).to eq(0)
        expect(participant.incoming_attack_count).to eq(0)
      end
    end
  end

  describe '#heal!' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        current_hp: 3,
        max_hp: 6
      )
    end

    it 'restores HP up to max' do
      healed = participant.heal!(5)
      expect(healed).to eq(3) # Only healed 3 (6 - 3)
      expect(participant.reload.current_hp).to eq(6)
    end

    it 'restores partial HP' do
      healed = participant.heal!(2)
      expect(healed).to eq(2)
      expect(participant.reload.current_hp).to eq(5)
    end
  end

  describe '#knockout!' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        current_hp: 6,
        max_hp: 6
      )
    end

    it 'sets HP to 0 and marks knocked out' do
      participant.knockout!
      expect(participant.reload.current_hp).to eq(0)
      expect(participant.is_knocked_out).to be true
    end
  end

  describe 'autobattle system' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    describe '#autobattle_enabled?' do
      it 'returns false by default' do
        expect(participant.autobattle_enabled?).to be false
      end

      it 'returns true when style is set' do
        participant.update(autobattle_style: 'aggressive')
        expect(participant.autobattle_enabled?).to be true
      end
    end

    describe '#enable_autobattle!' do
      it 'sets autobattle style' do
        participant.enable_autobattle!('defensive')
        expect(participant.reload.autobattle_style).to eq('defensive')
      end

      it 'ignores invalid styles' do
        participant.enable_autobattle!('invalid')
        expect(participant.reload.autobattle_style).to be_nil
      end
    end

    describe '#disable_autobattle!' do
      it 'clears autobattle style' do
        participant.update(autobattle_style: 'aggressive')
        participant.disable_autobattle!
        expect(participant.reload.autobattle_style).to be_nil
      end
    end
  end

  describe 'attacks_per_round' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'returns base speed without weapon' do
      expect(participant.attacks_per_round(nil)).to eq(1)
    end
  end

  describe '#protection_active_at_segment?' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'returns true when no movement completion segment' do
      expect(participant.protection_active_at_segment?(50)).to be true
    end

    it 'returns false before movement completion' do
      participant.update(movement_completed_segment: 60)
      expect(participant.protection_active_at_segment?(50)).to be false
    end

    it 'returns true at and after movement completion' do
      participant.update(movement_completed_segment: 50)
      expect(participant.protection_active_at_segment?(50)).to be true
      expect(participant.protection_active_at_segment?(60)).to be true
    end
  end

  describe 'penalty methods' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    describe '#total_attack_penalty' do
      it 'combines wound penalty and all_roll_penalty' do
        participant.update(current_hp: 4, max_hp: 6)
        expect(participant.total_attack_penalty).to eq(2) # wound_penalty = 2, all_roll_penalty = 0
      end
    end

    describe '#ability_roll_penalty' do
      it 'returns 0 when no penalties set' do
        expect(participant.ability_roll_penalty).to eq(0)
      end
    end

    describe '#all_roll_penalty' do
      it 'returns 0 when no penalties set' do
        expect(participant.all_roll_penalty).to eq(0)
      end
    end

    describe '#total_ability_penalty' do
      it 'does not include legacy cooldown penalty' do
        participant.update(ability_cooldown_penalty: -3)
        expect(participant.total_ability_penalty).to eq(0)
      end
    end
  end

  describe 'enhanced cooldown system' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    describe '#set_ability_cooldown!' do
      it 'stores cooldown in JSONB' do
        participant.set_ability_cooldown!('Fireball', 3)
        expect(participant.cooldown_for('Fireball')).to eq(3)
      end
    end

    describe '#decay_ability_cooldowns!' do
      it 'reduces cooldowns by 1' do
        participant.set_ability_cooldown!('Fireball', 3)
        participant.decay_ability_cooldowns!
        expect(participant.cooldown_for('Fireball')).to eq(2)
      end

      it 'removes cooldowns at 0' do
        participant.set_ability_cooldown!('Fireball', 1)
        participant.decay_ability_cooldowns!
        expect(participant.parsed_ability_cooldowns).not_to have_key('Fireball')
      end

      it 'decays global cooldown' do
        participant.update(global_ability_cooldown: 2)
        participant.decay_ability_cooldowns!
        expect(participant.reload.global_ability_cooldown).to eq(1)
      end
    end
  end

  describe 'reset methods' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        willpower_attack: 2,
        willpower_defense: 1,
        willpower_ability: 1,
        ability_choice: 'fireball'
      )
    end

    describe '#reset_willpower_allocations!' do
      it 'clears willpower allocations' do
        participant.reset_willpower_allocations!
        expect(participant.reload.willpower_attack).to eq(0)
        expect(participant.willpower_defense).to eq(0)
        expect(participant.willpower_ability).to eq(0)
        expect(participant.ability_choice).to be_nil
      end
    end

    describe '#reset_menu_state!' do
      it 'resets all menu tracking fields' do
        participant.update(
          main_action_set: true,
          tactical_action_set: true,
          movement_set: true,
          willpower_set: true,
          input_stage: 'done',
          input_complete: true
        )
        participant.reset_menu_state!
        participant.reload
        expect(participant.main_action_set).to be false
        expect(participant.tactical_action_set).to be false
        expect(participant.movement_set).to be false
        expect(participant.willpower_set).to be false
        expect(participant.input_stage).to eq('main_menu')
        expect(participant.input_complete).to be false
      end
    end
  end

  describe 'spar mode' do
    let(:spar_fight) { Fight.create(room_id: room.id, mode: 'spar') }
    let(:spar_participant) do
      FightParticipant.create(
        fight_id: spar_fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        current_hp: 6,
        max_hp: 6,
        touch_count: 0
      )
    end

    describe '#wound_penalty in spar mode' do
      it 'returns 0 regardless of HP' do
        spar_participant.update(current_hp: 2)
        expect(spar_participant.wound_penalty).to eq(0)
      end
    end

    describe '#spar_defeated?' do
      it 'returns false when touch count is below max HP' do
        spar_participant.update(touch_count: 3)
        expect(spar_participant.spar_defeated?).to be false
      end

      it 'returns true when touch count reaches max HP' do
        spar_participant.update(touch_count: 6)
        expect(spar_participant.spar_defeated?).to be true
      end
    end
  end

  describe 'incremental damage system' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        current_hp: 6,
        max_hp: 6,
        willpower_dice: 0
      )
    end

    describe '#hp_lost_from_cumulative' do
      it 'returns HP lost based on damage thresholds' do
        expect(participant.hp_lost_from_cumulative(5)).to eq(0)  # Miss
        expect(participant.hp_lost_from_cumulative(15)).to eq(1) # 1 HP
        expect(participant.hp_lost_from_cumulative(25)).to eq(2) # 2 HP
        expect(participant.hp_lost_from_cumulative(50)).to eq(3) # 3 HP
      end
    end

    describe '#apply_incremental_hp_loss!' do
      it 'applies additional HP loss since last check' do
        # First check: 15 damage = 1 HP
        additional = participant.apply_incremental_hp_loss!(1, 0)
        expect(additional).to eq(1)
        expect(participant.reload.current_hp).to eq(5)
      end

      it 'returns 0 when no additional loss' do
        additional = participant.apply_incremental_hp_loss!(1, 1)
        expect(additional).to eq(0)
      end

      it 'knocks out participant at 0 HP' do
        participant.update(current_hp: 1)
        participant.apply_incremental_hp_loss!(3, 0)
        expect(participant.reload.is_knocked_out).to be true
      end

      context 'in spar mode' do
        let(:spar_fight) { Fight.create(room_id: room.id, mode: 'spar') }
        let(:spar_participant) do
          FightParticipant.create(
            fight_id: spar_fight.id,
            character_instance_id: character_instance.id,
            side: 1,
            current_hp: 6,
            max_hp: 6,
            touch_count: 0
          )
        end

        it 'increments touch count instead of HP loss' do
          additional = spar_participant.apply_incremental_hp_loss!(2, 0)
          expect(additional).to eq(2)
          expect(spar_participant.reload.touch_count).to eq(2)
          expect(spar_participant.current_hp).to eq(6) # HP unchanged
        end
      end
    end
  end

  describe 'arena edge and flee system' do
    let(:fight_with_size) do
      f = Fight.create(room_id: room.id)
      # Set arena dimensions after creation to ensure they are fixed
      f.update(arena_width: 10, arena_height: 10)
      f
    end
    let(:participant) do
      FightParticipant.create(
        fight_id: fight_with_size.id,
        character_instance_id: character_instance.id,
        side: 1,
        hex_x: 5,
        hex_y: 5
      )
    end

    describe '#at_arena_edge?' do
      it 'returns false when in center' do
        expect(participant.at_arena_edge?).to be false
      end

      it 'returns true at north edge' do
        participant.update(hex_y: 0)
        expect(participant.at_arena_edge?).to be true
      end

      it 'returns true at south edge' do
        fight = participant.fight.reload
        participant.update(hex_y: ((fight.arena_height - 1) * 4 + 2))
        expect(participant.at_arena_edge?).to be true
      end

      it 'returns true at west edge' do
        participant.update(hex_x: 0)
        expect(participant.at_arena_edge?).to be true
      end

      it 'returns true at east edge' do
        fight = participant.fight.reload
        participant.update(hex_x: fight.arena_width - 1)
        expect(participant.at_arena_edge?).to be true
      end
    end

    describe '#arena_edges' do
      it 'returns empty array when in center' do
        expect(participant.arena_edges).to eq([])
      end

      it 'returns [:north] at north edge' do
        participant.update(hex_y: 0)
        expect(participant.arena_edges).to eq([:north])
      end

      it 'returns [:north, :west] at corner' do
        participant.update(hex_x: 0, hex_y: 0)
        expect(participant.arena_edges).to contain_exactly(:north, :west)
      end
    end

    describe '#can_flee?' do
      it 'returns false when not at edge' do
        expect(participant.can_flee?).to be false
      end

      it 'returns false at edge without exits' do
        participant.update(hex_x: 0)
        expect(participant.can_flee?).to be false
      end
    end

    describe '#cancel_flee!' do
      it 'clears flee state' do
        participant.update(is_fleeing: true, flee_direction: 'north')
        participant.cancel_flee!
        participant.reload
        expect(participant.is_fleeing).to be false
        expect(participant.flee_direction).to be_nil
      end
    end
  end

  describe 'surrender system' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        is_surrendering: true
      )
    end

    describe '#cancel_surrender!' do
      it 'clears surrender state' do
        participant.cancel_surrender!
        expect(participant.reload.is_surrendering).to be false
      end
    end
  end

  describe 'stat lookups' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    describe '#stat_modifier' do
      it 'returns default stat when character has no stats' do
        expect(participant.stat_modifier('Strength')).to eq(GameConfig::Mechanics::DEFAULT_STAT)
      end
    end

    describe '#strength_modifier' do
      it 'delegates to stat_modifier' do
        expect(participant.strength_modifier).to eq(GameConfig::Mechanics::DEFAULT_STAT)
      end
    end

    describe '#dexterity_modifier' do
      it 'delegates to stat_modifier' do
        expect(participant.dexterity_modifier).to eq(GameConfig::Mechanics::DEFAULT_STAT)
      end
    end

    describe '#intelligence_modifier' do
      it 'returns default stat when character has no stats' do
        expect(participant.intelligence_modifier).to eq(GameConfig::Mechanics::DEFAULT_STAT)
      end
    end
  end

  describe 'willpower rolls' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        willpower_defense: 2,
        willpower_attack: 1,
        willpower_ability: 1
      )
    end

    describe '#willpower_defense_roll' do
      it 'returns nil when no willpower defense allocated' do
        participant.update(willpower_defense: 0)
        expect(participant.willpower_defense_roll).to be_nil
      end

      it 'returns roll result when willpower defense allocated' do
        result = participant.willpower_defense_roll
        expect(result).not_to be_nil
        expect(result.total).to be >= 2 # At least 2 from 2d8
      end
    end

    describe '#willpower_attack_roll' do
      it 'returns nil when no willpower attack allocated' do
        participant.update(willpower_attack: 0)
        expect(participant.willpower_attack_roll).to be_nil
      end

      it 'returns roll result when willpower attack allocated' do
        result = participant.willpower_attack_roll
        expect(result).not_to be_nil
        expect(result.total).to be >= 1
      end
    end

    describe '#willpower_ability_roll' do
      it 'returns nil when no willpower ability allocated' do
        participant.update(willpower_ability: 0)
        expect(participant.willpower_ability_roll).to be_nil
      end

      it 'returns roll result when willpower ability allocated' do
        result = participant.willpower_ability_roll
        expect(result).not_to be_nil
        expect(result.total).to be >= 1
      end
    end

    describe '#willpower_attack_bonus' do
      it 'returns 0 when no attack allocated' do
        participant.update(willpower_attack: 0)
        expect(participant.willpower_attack_bonus).to eq(0)
      end

      it 'returns total from roll when allocated' do
        # Random roll, so just check it's a number
        expect(participant.willpower_attack_bonus).to be >= 1
      end
    end

    describe '#willpower_ability_bonus' do
      it 'returns 0 when no ability allocated' do
        participant.update(willpower_ability: 0)
        expect(participant.willpower_ability_bonus).to eq(0)
      end
    end
  end

  describe 'natural attacks' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        melee_weapon_id: nil,
        ranged_weapon_id: nil
      )
    end

    describe '#npc_archetype' do
      it 'returns nil for non-NPC character' do
        expect(participant.npc_archetype).to be_nil
      end
    end

    describe '#using_natural_attacks?' do
      it 'returns falsy when no weapons and no archetype' do
        # Non-NPC has no archetype, so no natural attacks (returns nil or false)
        expect(participant.using_natural_attacks?).to be_falsy
      end
    end

    describe '#effective_melee_attack' do
      it 'returns nil when no weapon and no archetype' do
        expect(participant.effective_melee_attack).to be_nil
      end
    end

    describe '#effective_ranged_attack' do
      it 'returns nil when no weapon and no archetype' do
        expect(participant.effective_ranged_attack).to be_nil
      end
    end

    describe '#has_any_attack?' do
      it 'returns falsy when no weapons and no archetype' do
        # Ensure no weapons equipped
        expect(participant.melee_weapon).to be_nil
        expect(participant.ranged_weapon).to be_nil
        expect(participant.npc_archetype).to be_nil
        expect(participant.has_any_attack?).to be_falsy
      end
    end

    describe '#npc_with_custom_dice?' do
      it 'returns false when NPC dice not set' do
        expect(participant.npc_with_custom_dice?).to be false
      end

      it 'returns true when NPC dice configured' do
        participant.update(npc_damage_dice_count: 2, npc_damage_dice_sides: 6)
        expect(participant.npc_with_custom_dice?).to be true
      end
    end
  end

  describe 'attack and movement segments' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        main_action: 'attack'
      )
    end

    describe '#attack_segments' do
      it 'returns array of segment numbers' do
        segments = participant.attack_segments(nil)
        expect(segments).to be_an(Array)
        expect(segments).not_to be_empty
        segments.each do |seg|
          expect(seg).to be_between(1, 100)
        end
      end

      it 'returns sorted segments' do
        segments = participant.attack_segments(nil)
        expect(segments).to eq(segments.sort)
      end
    end

    describe '#movement_segments' do
      it 'returns array of segment numbers based on movement speed' do
        segments = participant.movement_segments
        expect(segments).to be_an(Array)
        expect(segments.length).to eq(participant.movement_speed)
      end

      it 'returns empty array when no movement' do
        allow(participant).to receive(:movement_speed).and_return(0)
        expect(participant.movement_segments).to eq([])
      end
    end
  end

  describe 'team helpers' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        is_knocked_out: false
      )
    end

    let(:ally) do
      user2 = create(:user)
      char2 = Character.create(forename: 'Ally', surname: 'Three', user: user2, is_npc: false)
      instance2 = CharacterInstance.create(
        character: char2,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: instance2.id,
        side: 1,
        is_knocked_out: false
      )
    end

    let(:enemy) do
      user3 = create(:user)
      char3 = Character.create(forename: 'Enemy', surname: 'Two', user: user3, is_npc: false)
      instance3 = CharacterInstance.create(
        character: char3,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: instance3.id,
        side: 2,
        is_knocked_out: false
      )
    end

    describe '#allies' do
      it 'returns participants on same side excluding self' do
        ally # Force creation
        allies = participant.allies
        expect(allies.map(&:id)).to include(ally.id)
        expect(allies.map(&:id)).not_to include(participant.id)
      end
    end

    describe '#enemies' do
      it 'returns participants on different sides' do
        enemy # Force creation
        enemies = participant.enemies
        expect(enemies.map(&:id)).to include(enemy.id)
      end
    end

    describe '#guarded_by' do
      it 'returns participants guarding this one' do
        # Setup: ally guards participant
        ally.update(tactic_choice: 'guard', tactic_target_participant_id: participant.id)
        # Refresh the fight association to get fresh data
        fight.reload
        guardians = participant.guarded_by
        expect(guardians.map(&:id)).to include(ally.id)
      end
    end

    describe '#back_to_back_partner' do
      it 'returns partner with back_to_back' do
        ally.update(tactic_choice: 'back_to_back', tactic_target_participant_id: participant.id)
        fight.reload
        expect(participant.back_to_back_partner&.id).to eq(ally.id)
      end

      it 'returns nil when no partner' do
        expect(participant.back_to_back_partner).to be_nil
      end
    end
  end

  describe 'effective weapon' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    describe '#effective_weapon' do
      it 'returns melee weapon when no target' do
        melee = double(id: 1)
        allow(participant).to receive(:melee_weapon).and_return(melee)
        expect(participant.effective_weapon).to eq(melee)
      end
    end
  end

  describe 'ability system' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        ability_cooldown_penalty: 0
      )
    end

    describe '#ability_damage_roll' do
      it 'returns a positive number' do
        result = participant.ability_damage_roll('Fireball')
        expect(result).to be >= 0
      end
    end

    describe '#apply_ability_cooldown!' do
      it 'sets cooldown penalty from config' do
        participant.apply_ability_cooldown!
        expect(participant.reload.ability_cooldown_penalty).to eq(GameConfig::Mechanics::COOLDOWNS[:ability_penalty])
      end
    end

    describe '#decay_ability_cooldown!' do
      it 'decays cooldown penalty toward 0' do
        participant.update(ability_cooldown_penalty: -3)
        participant.decay_ability_cooldown!
        expected = [-3 + GameConfig::Mechanics::COOLDOWNS[:decay_per_round], 0].min
        expect(participant.reload.ability_cooldown_penalty).to eq(expected)
      end

      it 'does nothing when penalty is 0' do
        participant.update(ability_cooldown_penalty: 0)
        participant.decay_ability_cooldown!
        expect(participant.reload.ability_cooldown_penalty).to eq(0)
      end
    end

    describe '#all_combat_abilities' do
      it 'returns empty array when character has no abilities' do
        expect(participant.all_combat_abilities).to eq([])
      end
    end

    describe '#available_abilities' do
      it 'returns empty array when character has no abilities' do
        expect(participant.available_abilities).to eq([])
      end
    end

    describe '#available_main_abilities' do
      it 'returns empty array when character has no abilities' do
        expect(participant.available_main_abilities).to eq([])
      end
    end

    describe '#available_tactical_abilities' do
      it 'returns empty array when character has no abilities' do
        expect(participant.available_tactical_abilities).to eq([])
      end
    end

    describe '#top_powerful_abilities' do
      it 'returns empty array when character has no abilities' do
        expect(participant.top_powerful_abilities).to eq([])
      end

      it 'accepts count parameter' do
        expect(participant.top_powerful_abilities(3)).to eq([])
      end
    end
  end

  describe 'penalty system' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        roll_penalties: Sequel.pg_jsonb_wrap({})
      )
    end

    describe '#parsed_roll_penalties' do
      it 'returns empty hash when no penalties' do
        expect(participant.parsed_roll_penalties).to eq({})
      end
    end

    describe '#apply_penalty!' do
      it 'stores penalty in JSONB' do
        participant.apply_penalty!('ability_rolls', -5, 1)
        expect(participant.ability_roll_penalty).to eq(-5)
      end
    end

    describe '#decay_all_penalties!' do
      it 'decays ability penalty' do
        participant.apply_penalty!('ability_rolls', -5, 2)
        participant.decay_all_penalties!
        expect(participant.ability_roll_penalty).to eq(-3)
      end

      it 'removes penalty at 0' do
        participant.apply_penalty!('ability_rolls', -1, 2)
        participant.decay_all_penalties!
        expect(participant.parsed_roll_penalties).not_to have_key('ability_rolls')
      end

      it 'handles empty penalties' do
        expect { participant.decay_all_penalties! }.not_to raise_error
      end
    end
  end

  describe 'position sync' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        hex_x: 10,
        hex_y: 15
      )
    end

    describe '#sync_position_to_character!' do
      it 'updates character instance position' do
        participant.sync_position_to_character!
        character_instance.reload
        expect(character_instance.x.to_i).to eq(10)
        expect(character_instance.y.to_i).to eq(15)
      end
    end
  end

  describe 'round counters' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    describe '#attacks_this_round' do
      it 'returns 0 by default' do
        expect(participant.attacks_this_round).to eq(0)
      end
    end

    describe '#increment_attacks!' do
      it 'increments counter' do
        participant.increment_attacks!
        participant.increment_attacks!
        expect(participant.attacks_this_round).to eq(2)
      end
    end

    describe '#reset_round_counters!' do
      it 'resets attack counter to 0' do
        participant.increment_attacks!
        participant.reset_round_counters!
        expect(participant.attacks_this_round).to eq(0)
      end
    end
  end

  describe 'status effects integration' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    describe '#can_move?' do
      it 'delegates to StatusEffectService' do
        expect(StatusEffectService).to receive(:can_move?).with(participant).and_return(true)
        expect(participant.can_move?).to be true
      end
    end

    describe '#incoming_damage_modifier' do
      it 'delegates to StatusEffectService' do
        expect(StatusEffectService).to receive(:incoming_damage_modifier).with(participant).and_return(5)
        expect(participant.incoming_damage_modifier).to eq(5)
      end
    end

    describe '#outgoing_damage_modifier' do
      it 'delegates to StatusEffectService' do
        expect(StatusEffectService).to receive(:outgoing_damage_modifier).with(participant).and_return(3)
        expect(participant.outgoing_damage_modifier).to eq(3)
      end
    end

    describe '#active_status_effects' do
      it 'delegates to StatusEffectService' do
        expect(StatusEffectService).to receive(:active_effects).with(participant).and_return([])
        expect(participant.active_status_effects).to eq([])
      end
    end

    describe '#has_status_effect?' do
      it 'delegates to StatusEffectService' do
        expect(StatusEffectService).to receive(:has_effect?).with(participant, 'Stun').and_return(true)
        expect(participant.has_status_effect?('Stun')).to be true
      end
    end
  end

  # ========================================
  # Additional Edge Case Tests
  # ========================================

  describe '#best_attack_for_distance' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    context 'with equipped weapons' do
      it 'returns melee weapon at distance 1' do
        melee = double('melee')
        allow(participant).to receive(:melee_weapon).and_return(melee)
        expect(participant.best_attack_for_distance(1)).to eq(melee)
      end

      it 'returns ranged weapon at distance > 1' do
        ranged = double('ranged')
        allow(participant).to receive(:melee_weapon).and_return(nil)
        allow(participant).to receive(:ranged_weapon).and_return(ranged)
        expect(participant.best_attack_for_distance(5)).to eq(ranged)
      end

      it 'falls back to melee when no ranged weapon' do
        melee = double('melee')
        allow(participant).to receive(:melee_weapon).and_return(melee)
        allow(participant).to receive(:ranged_weapon).and_return(nil)
        expect(participant.best_attack_for_distance(5)).to eq(melee)
      end

      it 'falls back to ranged when no melee weapon' do
        ranged = double('ranged')
        allow(participant).to receive(:melee_weapon).and_return(nil)
        allow(participant).to receive(:ranged_weapon).and_return(ranged)
        expect(participant.best_attack_for_distance(1)).to eq(ranged)
      end
    end

    context 'without weapons' do
      it 'returns nil when no archetype' do
        allow(participant).to receive(:melee_weapon).and_return(nil)
        allow(participant).to receive(:ranged_weapon).and_return(nil)
        expect(participant.best_attack_for_distance(3)).to be_nil
      end
    end
  end

  describe '#effective_weapon with target' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        hex_x: 0,
        hex_y: 0
      )
    end

    let(:target) do
      user2 = create(:user)
      char2 = Character.create(forename: 'Target', surname: 'Test', user: user2, is_npc: false)
      instance2 = CharacterInstance.create(
        character: char2, reality: reality, current_room: room,
        online: true, status: 'alive', level: 1, experience: 0,
        health: 100, max_health: 100, mana: 50, max_mana: 50
      )
      FightParticipant.create(fight_id: fight.id, character_instance_id: instance2.id, side: 2)
    end

    it 'returns melee weapon when target in melee range' do
      target.update(hex_x: 1, hex_y: 0)
      participant.update(target_participant_id: target.id)

      melee = double('melee')
      ranged = double('ranged')
      allow(participant).to receive(:melee_weapon).and_return(melee)
      allow(participant).to receive(:ranged_weapon).and_return(ranged)

      expect(participant.effective_weapon).to eq(melee)
    end

    it 'returns ranged weapon when target out of melee range' do
      target.update(hex_x: 5, hex_y: 0)
      participant.update(target_participant_id: target.id)

      melee = double('melee')
      ranged = double('ranged')
      allow(participant).to receive(:melee_weapon).and_return(melee)
      allow(participant).to receive(:ranged_weapon).and_return(ranged)

      expect(participant.effective_weapon).to eq(ranged)
    end

    it 'falls back to melee when no ranged and target far' do
      target.update(hex_x: 5, hex_y: 0)
      participant.update(target_participant_id: target.id)

      melee = double('melee')
      allow(participant).to receive(:melee_weapon).and_return(melee)
      allow(participant).to receive(:ranged_weapon).and_return(nil)

      expect(participant.effective_weapon).to eq(melee)
    end
  end

  describe '#willpower_movement_roll' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'returns nil when no willpower movement allocated' do
      allow(participant).to receive(:willpower_movement).and_return(0)
      expect(participant.willpower_movement_roll).to be_nil
    end

    it 'returns roll result with bonus hexes when allocated' do
      allow(participant).to receive(:willpower_movement).and_return(2)
      roll_result = instance_double('RollResult', total: 7)
      allow(DiceRollService).to receive(:roll).with(2, 8, explode_on: 8, modifier: 0).and_return(roll_result)

      result = participant.willpower_movement_roll
      expect(result).to be_a(Hash)
      expect(result[:roll_result]).to eq(roll_result)
      expect(result[:bonus_hexes]).to eq(3) # floor(7 / 2.0)
    end
  end

  describe '#heal! with healing modifier' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        current_hp: 3,
        max_hp: 6
      )
    end

    it 'applies healing modifier from status effects' do
      # Modifier of 1.5 = 150% healing
      allow(StatusEffectService).to receive(:healing_modifier).with(participant).and_return(1.5)

      healed = participant.heal!(2) # 2 * 1.5 = 3
      expect(healed).to eq(3)
      expect(participant.reload.current_hp).to eq(6)
    end

    it 'applies reduced healing modifier' do
      # Modifier of 0.5 = 50% healing
      allow(StatusEffectService).to receive(:healing_modifier).with(participant).and_return(0.5)

      healed = participant.heal!(4) # 4 * 0.5 = 2
      expect(healed).to eq(2)
      expect(participant.reload.current_hp).to eq(5)
    end
  end

  describe '#ability_on_cooldown?' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        global_ability_cooldown: 0
      )
    end

    let(:ability) { double('Ability', name: 'Fireball') }

    it 'returns true when global cooldown active' do
      participant.update(global_ability_cooldown: 2)
      expect(participant.ability_on_cooldown?(ability)).to be true
    end

    it 'returns true when specific ability on cooldown' do
      participant.set_ability_cooldown!('Fireball', 3)
      expect(participant.ability_on_cooldown?(ability)).to be true
    end

    it 'returns false when no cooldowns active' do
      expect(participant.ability_on_cooldown?(ability)).to be false
    end
  end

  describe '#ability_available?' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    let(:ability) { double('Ability', name: 'Fireball') }

    it 'returns true when not on cooldown' do
      expect(participant.ability_available?(ability)).to be true
    end

    it 'returns false when on cooldown' do
      participant.set_ability_cooldown!('Fireball', 2)
      expect(participant.ability_available?(ability)).to be false
    end
  end

  describe '#npc_speed_modifier in attacks_per_round' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        npc_speed_modifier: 3
      )
    end

    it 'applies NPC speed modifier to weapon speed' do
      weapon = double('weapon', pattern: double(attack_speed: 5))
      expect(participant.attacks_per_round(weapon)).to eq(8) # 5 + 3 = 8
    end

    it 'clamps speed to maximum of 10' do
      participant.update(npc_speed_modifier: 10)
      weapon = double('weapon', pattern: double(attack_speed: 5))
      expect(participant.attacks_per_round(weapon)).to eq(10) # Clamped to 10
    end

    it 'ensures minimum speed of 1' do
      participant.update(npc_speed_modifier: -10)
      weapon = double('weapon', pattern: double(attack_speed: 1))
      expect(participant.attacks_per_round(weapon)).to eq(1) # Minimum 1
    end
  end

  describe '#movement_speed with tactic modifier' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        main_action: 'attack',
        tactic_choice: 'quick'
      )
    end

    it 'includes tactic movement modifier' do
      base = GameConfig::Mechanics::MOVEMENT[:base]
      tactic_bonus = GameConfig::Tactics::MOVEMENT['quick'] || 0
      expect(participant.movement_speed).to eq(base + tactic_bonus)
    end
  end

  describe 'validation edge cases' do
    it 'allows nil movement_action' do
      participant = FightParticipant.new(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        movement_action: nil
      )
      expect(participant.valid?).to be true
    end

    it 'validates movement_action when set' do
      participant = FightParticipant.new(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        movement_action: 'invalid_action'
      )
      expect(participant.valid?).to be false
      expect(participant.errors[:movement_action]).not_to be_empty
    end

    it 'validates autobattle_style when set' do
      participant = FightParticipant.new(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        autobattle_style: 'invalid_style'
      )
      expect(participant.valid?).to be false
      expect(participant.errors[:autobattle_style]).not_to be_empty
    end

    it 'allows valid autobattle_style values' do
      %w[aggressive defensive supportive].each do |style|
        participant = FightParticipant.new(
          fight_id: fight.id,
          character_instance_id: character_instance.id,
          autobattle_style: style
        )
        expect(participant.valid?).to be true
      end
    end
  end

  describe 'process_successful_flee!' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        is_fleeing: true,
        flee_direction: 'north'
      )
    end

    it 'does nothing when not fleeing' do
      participant.update(is_fleeing: false)
      # Should not raise error and should not change room
      expect { participant.process_successful_flee! }.not_to raise_error
    end

    it 'does nothing when flee_direction is nil' do
      participant.update(flee_direction: nil)
      expect { participant.process_successful_flee! }.not_to raise_error
    end
  end

  describe 'willpower limits' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        current_hp: 6,
        max_hp: 6,
        willpower_dice: 0
      )
    end

    it 'caps willpower dice at maximum from config' do
      max_wp = GameConfig::Mechanics::WILLPOWER[:max_dice]
      # Take massive damage to gain lots of willpower
      participant.update(current_hp: 6, willpower_dice: max_wp - 0.1)

      # Take damage that would grant more willpower
      hp_lost = 3
      wp_config = GameConfig::Mechanics::WILLPOWER
      participant.current_hp = [participant.current_hp - hp_lost, 0].max
      participant.willpower_dice = [(participant.willpower_dice.to_f + (hp_lost * wp_config[:gain_per_hp_lost])), wp_config[:max_dice]].min
      participant.save

      expect(participant.willpower_dice).to be <= max_wp
    end
  end

  describe 'decay_all_penalties! edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'decays both ability and all_rolls penalties' do
      participant.apply_penalty!('ability_rolls', -4, 2)
      participant.apply_penalty!('all_rolls', -3, 1)

      participant.decay_all_penalties!

      expect(participant.ability_roll_penalty).to eq(-2) # -4 + 2 = -2
      expect(participant.all_roll_penalty).to eq(-2)     # -3 + 1 = -2
    end

    it 'removes penalties that reach 0 or positive' do
      participant.apply_penalty!('ability_rolls', -1, 2)

      participant.decay_all_penalties!

      expect(participant.parsed_roll_penalties).not_to have_key('ability_rolls')
    end
  end

  describe 'coordinate edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        hex_x: 5,
        hex_y: 5
      )
    end

    describe '#hex_distance_to edge cases' do
      it 'handles nil other participant' do
        expect(participant.hex_distance_to(nil)).to eq(0)
      end

      it 'handles other participant with nil coordinates' do
        other = double('other', hex_x: nil, hex_y: 5)
        expect(participant.hex_distance_to(other)).to be_nil
      end
    end

    describe '#in_melee_range? edge cases' do
      it 'returns true for distance 0 (same hex)' do
        other = double('other', hex_x: 5, hex_y: 5)
        allow(participant).to receive(:hex_distance_to).with(other).and_return(0)
        expect(participant.in_melee_range?(other)).to be true
      end
    end
  end

  # ========================================
  # Additional Edge Case Tests - Phase 2
  # ========================================

  describe 'NPC combat stats' do
    describe '#apply_npc_combat_stats' do
      it 'applies archetype stats when character has archetype' do
        archetype = double('archetype', combat_stats: {
          max_hp: 10,
          damage_bonus: 5,
          defense_bonus: 3,
          speed_modifier: 2,
          damage_dice_count: 3,
          damage_dice_sides: 8
        })

        # Mock the character as an NPC with archetype
        npc_char = double('character',
                          npc?: true,
                          npc_archetype: archetype,
                          full_name: 'NPC Fighter')
        ci_state = { health: nil, max_health: nil }
        npc_instance = double('instance',
                              id: 999,
                              character: npc_char)
        allow(npc_instance).to receive(:health) { ci_state[:health] }
        allow(npc_instance).to receive(:max_health) { ci_state[:max_health] }
        allow(npc_instance).to receive(:update) do |attrs|
          ci_state.merge!(attrs)
        end

        participant = FightParticipant.new(
          fight_id: fight.id,
          character_instance_id: character_instance.id,
          side: 1
        )
        allow(participant).to receive(:character_instance).and_return(npc_instance)

        # Call apply_npc_combat_stats
        participant.apply_npc_combat_stats

        expect(participant.max_hp).to eq(10)
        expect(participant.current_hp).to eq(10)
        expect(participant.npc_damage_bonus).to eq(5)
        expect(participant.npc_defense_bonus).to eq(3)
        expect(participant.npc_speed_modifier).to eq(2)
        expect(participant.npc_damage_dice_count).to eq(3)
        expect(participant.npc_damage_dice_sides).to eq(8)
      end

      it 'does nothing when no archetype' do
        npc_char = double('character', npc?: true, npc_archetype: nil)
        npc_instance = double('instance', id: 999, character: npc_char)
        allow(npc_instance).to receive(:health).and_return(nil)
        allow(npc_instance).to receive(:max_health).and_return(nil)
        allow(npc_instance).to receive(:update)

        participant = FightParticipant.new(
          fight_id: fight.id,
          character_instance_id: character_instance.id,
          side: 1
        )
        allow(participant).to receive(:character_instance).and_return(npc_instance)

        # Should not raise error
        expect { participant.apply_npc_combat_stats }.not_to raise_error
      end

      it 'handles partial combat stats' do
        archetype = double('archetype', combat_stats: {
          max_hp: 8
          # Other stats missing
        })
        npc_char = double('character', npc?: true, npc_archetype: archetype)
        ci_state = { health: nil, max_health: nil }
        npc_instance = double('instance', id: 999, character: npc_char)
        allow(npc_instance).to receive(:health) { ci_state[:health] }
        allow(npc_instance).to receive(:max_health) { ci_state[:max_health] }
        allow(npc_instance).to receive(:update) { |attrs| ci_state.merge!(attrs) }

        participant = FightParticipant.new(
          fight_id: fight.id,
          character_instance_id: character_instance.id,
          side: 1
        )
        allow(participant).to receive(:character_instance).and_return(npc_instance)

        participant.apply_npc_combat_stats

        expect(participant.max_hp).to eq(8)
        expect(participant.npc_damage_bonus).to be_nil
      end
    end
  end

  describe '#natural_attack_segments' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'returns segments based on attack speed' do
      attack = double('attack', attack_speed: 5)
      segments = participant.natural_attack_segments(attack)

      expect(segments).to be_an(Array)
      expect(segments.length).to eq(5)
      segments.each { |s| expect(s).to be_between(1, 100) }
    end

    it 'returns single segment for speed 1' do
      attack = double('attack', attack_speed: 1)
      segments = participant.natural_attack_segments(attack)

      expect(segments.length).to eq(1)
    end

    it 'returns 10 segments for speed 10' do
      attack = double('attack', attack_speed: 10)
      segments = participant.natural_attack_segments(attack)

      expect(segments.length).to eq(10)
    end

    it 'returns sorted segments' do
      attack = double('attack', attack_speed: 5)
      segments = participant.natural_attack_segments(attack)

      expect(segments).to eq(segments.sort)
    end
  end

  describe '#available_flee_exits' do
    let(:dest_room) { Room.create(name: 'Escape', short_description: 'Safe', location: location, room_type: 'standard') }
    let(:fight_with_arena) do
      f = Fight.create(room_id: room.id)
      f.update(arena_width: 10, arena_height: 10)
      f
    end

    let(:participant) do
      FightParticipant.create(
        fight_id: fight_with_arena.id,
        character_instance_id: character_instance.id,
        side: 1,
        hex_x: 5,
        hex_y: 5
      )
    end

    it 'returns empty array when not at edge' do
      expect(participant.available_flee_exits).to eq([])
    end

    it 'returns empty array when at edge but no exits' do
      participant.update(hex_x: 0)
      expect(participant.available_flee_exits).to eq([])
    end

    it 'returns exits when at edge with valid exit via spatial adjacency' do
      participant.update(hex_x: 0, hex_y: 5) # At west edge
      allow(RoomAdjacencyService).to receive(:resolve_direction_movement).and_return(nil)
      allow(RoomAdjacencyService).to receive(:resolve_direction_movement)
        .with(room, :west).and_return(dest_room)

      exits = participant.available_flee_exits
      expect(exits.length).to eq(1)
      expect(exits.first[:direction]).to eq('west')
    end

    it 'returns empty when no spatial adjacency exits found' do
      participant.update(hex_x: 0)
      allow(RoomAdjacencyService).to receive(:resolve_direction_movement).and_return(nil)

      exits = participant.available_flee_exits
      expect(exits).to eq([])
    end

    it 'returns multiple exits at corner via spatial adjacency' do
      participant.update(hex_x: 0, hex_y: 0) # Northwest corner
      allow(RoomAdjacencyService).to receive(:resolve_direction_movement).and_return(nil)
      allow(RoomAdjacencyService).to receive(:resolve_direction_movement)
        .with(room, :north).and_return(dest_room)
      allow(RoomAdjacencyService).to receive(:resolve_direction_movement)
        .with(room, :west).and_return(dest_room)

      exits = participant.available_flee_exits
      expect(exits.length).to eq(2)
    end
  end

  describe '#process_surrender!' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        is_surrendering: true
      )
    end

    it 'marks participant as knocked out' do
      allow(PrisonerService).to receive(:process_surrender!)

      participant.process_surrender!

      expect(participant.reload.is_knocked_out).to be true
      expect(participant.is_surrendering).to be false
    end

    it 'calls PrisonerService for character instance' do
      expect(PrisonerService).to receive(:process_surrender!).with(character_instance)

      participant.process_surrender!
    end

    it 'updates character instance surrendered_from_fight_id' do
      allow(PrisonerService).to receive(:process_surrender!)

      participant.process_surrender!

      expect(character_instance.reload.surrendered_from_fight_id).to eq(fight.id)
    end
  end

  describe '#apply_ability_costs!' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        global_ability_cooldown: 0
      )
    end

    let(:ability) do
      double('Ability',
             name: 'Fireball',
             ability_penalty_config: {},
             all_roll_penalty_config: {},
             specific_cooldown_rounds: 0,
             global_cooldown_rounds: 0)
    end

    it 'applies ability penalty when configured' do
      allow(ability).to receive(:ability_penalty_config).and_return({
                                                                      'amount' => -5,
                                                                      'decay_per_round' => 2
                                                                    })

      participant.apply_ability_costs!(ability)

      expect(participant.ability_roll_penalty).to eq(-5)
    end

    it 'applies all roll penalty when configured' do
      allow(ability).to receive(:all_roll_penalty_config).and_return({
                                                                       'amount' => -3,
                                                                       'decay_per_round' => 1
                                                                     })

      participant.apply_ability_costs!(ability)

      expect(participant.all_roll_penalty).to eq(-3)
    end

    it 'sets specific ability cooldown when configured' do
      allow(ability).to receive(:specific_cooldown_rounds).and_return(3)

      participant.apply_ability_costs!(ability)

      expect(participant.cooldown_for('Fireball')).to eq(3)
    end

    it 'sets global cooldown when configured' do
      allow(ability).to receive(:global_cooldown_rounds).and_return(2)

      participant.apply_ability_costs!(ability)

      expect(participant.reload.global_ability_cooldown).to eq(2)
    end

    it 'applies multiple costs together' do
      allow(ability).to receive(:ability_penalty_config).and_return({
                                                                      'amount' => -4,
                                                                      'decay_per_round' => 2
                                                                    })
      allow(ability).to receive(:specific_cooldown_rounds).and_return(5)
      allow(ability).to receive(:global_cooldown_rounds).and_return(1)

      participant.apply_ability_costs!(ability)

      expect(participant.ability_roll_penalty).to eq(-4)
      expect(participant.cooldown_for('Fireball')).to eq(5)
      expect(participant.reload.global_ability_cooldown).to eq(1)
    end
  end

  describe '#character_name edge cases' do
    it 'returns Unknown when character_instance is nil' do
      participant = FightParticipant.new(fight_id: fight.id)
      allow(participant).to receive(:character_instance).and_return(nil)
      expect(participant.character_name).to eq('Unknown')
    end

    it 'returns Unknown when character is nil' do
      participant = FightParticipant.new(fight_id: fight.id)
      instance = double('instance', character: nil)
      allow(participant).to receive(:character_instance).and_return(instance)
      expect(participant.character_name).to eq('Unknown')
    end
  end

  describe '#same_side? edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'returns false when other does not respond to side' do
      other = double('other')
      expect(participant.same_side?(other)).to be false
    end
  end

  describe '#sync_position_to_character! edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        hex_x: 15,
        hex_y: 20
      )
    end

    it 'does nothing when character_instance is nil' do
      allow(participant).to receive(:character_instance).and_return(nil)
      expect { participant.sync_position_to_character! }.not_to raise_error
    end

    it 'handles nil z coordinate' do
      character_instance.update(z: nil)
      expect { participant.sync_position_to_character! }.not_to raise_error
    end
  end

  describe '#advance_stage! edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        input_stage: nil
      )
    end

    it 'handles nil input_stage gracefully' do
      participant.advance_stage!
      expect(participant.reload.input_stage).not_to be_nil
    end

    it 'handles invalid stage gracefully' do
      participant.update(input_stage: 'main_menu')
      5.times { participant.advance_stage! }
      # Should eventually reach 'done'
      expect(FightParticipant::INPUT_STAGES).to include(participant.reload.input_stage)
    end
  end

  describe '#reset_willpower_allocations! edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        willpower_attack: 3,
        willpower_defense: 2,
        willpower_ability: 1,
        ability_choice: 'fireball',
        ability_id: 99
      )
    end

    it 'clears ability_id in addition to legacy ability_choice' do
      participant.reset_willpower_allocations!
      expect(participant.reload.ability_id).to be_nil
    end
  end

  describe '#reset_menu_state! edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        tactic_choice: 'aggressive',
        tactic_target_participant_id: 999,
        tactical_ability_id: 123,
        movement_completed_segment: 50
      )
    end

    it 'clears all tactic-related fields' do
      participant.reset_menu_state!
      participant.reload

      expect(participant.tactic_choice).to be_nil
      expect(participant.tactic_target_participant_id).to be_nil
      expect(participant.tactical_ability_id).to be_nil
      expect(participant.movement_completed_segment).to be_nil
    end
  end

  describe '#take_damage edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        current_hp: 6,
        max_hp: 6,
        willpower_dice: 0
      )
    end

    it 'returns 0 when damage causes no HP loss' do
      hp_lost = participant.take_damage(5) # Below miss threshold
      expect(hp_lost).to eq(0)
      expect(participant.reload.current_hp).to eq(6)
    end

    it 'does not exceed max willpower dice' do
      max_wp = GameConfig::Mechanics::WILLPOWER[:max_dice]
      participant.update(willpower_dice: max_wp - 0.1)

      # Take damage that would grant lots of willpower
      participant.take_damage(100)

      expect(participant.reload.willpower_dice).to be <= max_wp
    end
  end

  describe '#apply_incremental_hp_loss! edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        current_hp: 6,
        max_hp: 6,
        willpower_dice: 0
      )
    end

    it 'returns 0 when new_hp_lost equals previously_lost' do
      result = participant.apply_incremental_hp_loss!(2, 2)
      expect(result).to eq(0)
    end

    it 'returns 0 when new_hp_lost is less than previously_lost' do
      result = participant.apply_incremental_hp_loss!(1, 3)
      expect(result).to eq(0)
    end
  end

  describe '#decay_ability_cooldown! edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        ability_cooldown_penalty: nil
      )
    end

    it 'handles nil ability_cooldown_penalty' do
      expect { participant.decay_ability_cooldown! }.not_to raise_error
    end

    it 'does nothing when penalty is positive' do
      participant.update(ability_cooldown_penalty: 5)
      participant.decay_ability_cooldown!
      expect(participant.reload.ability_cooldown_penalty).to eq(5)
    end
  end

  describe '#use_willpower_die! edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        willpower_dice: 1.0,
        willpower_dice_used_this_round: nil
      )
    end

    it 'handles nil willpower_dice_used_this_round' do
      result = participant.use_willpower_die!
      expect(result).to be true
      expect(participant.reload.willpower_dice_used_this_round).to eq(1)
    end
  end

  describe '#accumulate_damage! edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        pending_damage_total: nil,
        incoming_attack_count: nil
      )
    end

    it 'handles nil initial values' do
      participant.accumulate_damage!(10)
      expect(participant.reload.pending_damage_total).to eq(10)
      expect(participant.incoming_attack_count).to eq(1)
    end
  end

  describe '#spar_defeated? edge cases' do
    let(:spar_fight) { Fight.create(room_id: room.id, mode: 'spar') }
    let(:participant) do
      FightParticipant.create(
        fight_id: spar_fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        max_hp: 6,
        touch_count: nil
      )
    end

    it 'handles nil touch_count' do
      expect(participant.spar_defeated?).to be false
    end
  end

  describe '#process_successful_flee! edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        is_fleeing: true,
        flee_direction: 'north'
      )
    end

    it 'handles no spatial adjacency destination' do
      # When RoomAdjacencyService returns nil, flee should not raise
      allow(RoomAdjacencyService).to receive(:resolve_direction_movement).and_return(nil)
      expect { participant.process_successful_flee! }.not_to raise_error
    end

    it 'moves character to adjacent room via spatial adjacency' do
      dest_room = Room.create(name: 'Escape', short_description: 'Safe', location: location, room_type: 'standard',
                              min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      allow(RoomAdjacencyService).to receive(:resolve_direction_movement)
        .with(room, :north).and_return(dest_room)

      participant.process_successful_flee!
      expect(participant.reload.is_knocked_out).to be true
      expect(character_instance.reload.current_room_id).to eq(dest_room.id)
    end
  end

  describe '#top_powerful_abilities' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'returns abilities sorted by power descending' do
      # Create mock abilities with different power levels
      abilities = [
        double('ability1', power: 10),
        double('ability2', power: 30),
        double('ability3', power: 20)
      ]
      allow(participant).to receive(:all_combat_abilities).and_return(abilities)

      top = participant.top_powerful_abilities(2)
      expect(top.map(&:power)).to eq([30, 20])
    end
  end

  describe 'movement with sprint and tactic modifiers' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        main_action: 'sprint',
        tactic_choice: 'quick'
      )
    end

    it 'combines sprint bonus and tactic modifier' do
      base = GameConfig::Mechanics::MOVEMENT[:base]
      sprint = GameConfig::Mechanics::MOVEMENT[:sprint_bonus]
      tactic = GameConfig::Tactics::MOVEMENT['quick'] || 0

      expect(participant.movement_speed).to eq(base + sprint + tactic)
    end
  end

  describe '#can_act? with surrender' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1,
        is_knocked_out: false,
        is_surrendering: true
      )
    end

    it 'returns true while surrendering but not knocked out' do
      expect(participant.can_act?).to be true
    end

    it 'returns false after surrender is processed' do
      allow(PrisonerService).to receive(:process_surrender!)
      participant.process_surrender!
      expect(participant.reload.can_act?).to be false
    end
  end

  describe '#arena_edges all edge positions' do
    let(:fight_with_arena) do
      f = Fight.create(room_id: room.id)
      f.update(arena_width: 10, arena_height: 10)
      f
    end

    let(:participant) do
      FightParticipant.create(
        fight_id: fight_with_arena.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'returns all four edges at center of each edge' do
      max_y = ((fight_with_arena.arena_height - 1) * 4 + 2)

      # Test each edge position
      test_cases = [
        { x: 5, y: 0, expected: [:north] },
        { x: 5, y: max_y, expected: [:south] },
        { x: 0, y: 5, expected: [:west] },
        { x: 9, y: 5, expected: [:east] }
      ]

      test_cases.each do |tc|
        participant.update(hex_x: tc[:x], hex_y: tc[:y])
        expect(participant.arena_edges).to contain_exactly(*tc[:expected])
      end
    end

    it 'returns two edges at each corner' do
      max_y = ((fight_with_arena.arena_height - 1) * 4 + 2)

      corners = [
        { x: 0, y: 0, expected: [:north, :west] },
        { x: 9, y: 0, expected: [:north, :east] },
        { x: 0, y: max_y, expected: [:south, :west] },
        { x: 9, y: max_y, expected: [:south, :east] }
      ]

      corners.each do |c|
        participant.update(hex_x: c[:x], hex_y: c[:y])
        expect(participant.arena_edges).to contain_exactly(*c[:expected])
      end
    end
  end

  describe '#all_combat_abilities edge cases' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'returns empty array when character_instance is nil' do
      allow(participant).to receive(:character_instance).and_return(nil)
      expect(participant.all_combat_abilities).to eq([])
    end
  end

  describe '#stat_modifier case insensitivity' do
    let(:participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        side: 1
      )
    end

    it 'handles different case variations' do
      # These should all use default since no stats exist
      expect(participant.stat_modifier('STRENGTH')).to eq(GameConfig::Mechanics::DEFAULT_STAT)
      expect(participant.stat_modifier('strength')).to eq(GameConfig::Mechanics::DEFAULT_STAT)
      expect(participant.stat_modifier('Strength')).to eq(GameConfig::Mechanics::DEFAULT_STAT)
    end
  end
end
