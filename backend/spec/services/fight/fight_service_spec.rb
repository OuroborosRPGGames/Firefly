# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FightService do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Battle Room', short_description: 'A room for fighting', min_x: 0, max_x: 40, min_y: 0, max_y: 40) }
  let(:reality) { create(:reality) }

  let(:char1) { create(:character, forename: 'Fighter', surname: 'One') }
  let(:instance1) { create(:character_instance, character: char1, reality: reality, current_room: room) }

  let(:char2) { create(:character, forename: 'Fighter', surname: 'Two') }
  let(:instance2) { create(:character_instance, character: char2, reality: reality, current_room: room) }

  describe '.start_fight' do
    it 'creates a new fight in the room' do
      service = described_class.start_fight(room: room, initiator: instance1, target: instance2)

      expect(service.fight).not_to be_nil
      expect(service.fight.room_id).to eq(room.id)
      expect(service.fight.status).to eq('input')
    end

    it 'adds both participants to the fight' do
      service = described_class.start_fight(room: room, initiator: instance1, target: instance2)

      # Use dataset to avoid cached association
      expect(service.fight.fight_participants_dataset.count).to eq(2)
      expect(service.participant_for(instance1)).not_to be_nil
      expect(service.participant_for(instance2)).not_to be_nil
    end

    it 'assigns participants to opposite sides' do
      service = described_class.start_fight(room: room, initiator: instance1, target: instance2)

      p1 = service.participant_for(instance1)
      p2 = service.participant_for(instance2)

      expect(p1.side).not_to eq(p2.side)
    end

    it 'joins existing fight instead of creating new one' do
      # Start first fight
      first_service = described_class.start_fight(room: room, initiator: instance1, target: instance2)
      first_fight = first_service.fight

      # Create third participant
      user3 = User.create(email: 'user3@example.com', password_hash: 'hash', username: 'user3', salt: 'salt3')
      char3 = Character.create(forename: 'Fighter', surname: 'Three', user: user3, is_npc: false)
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

      # Second "start_fight" should join existing
      second_service = described_class.start_fight(room: room, initiator: instance3, target: instance1)

      expect(second_service.fight.id).to eq(first_fight.id)
      expect(second_service.fight.fight_participants_dataset.count).to eq(3)
    end

    it 'does not join existing fights from a different mode' do
      spar_service = described_class.start_fight(room: room, initiator: instance1, target: instance2, mode: 'spar')

      # Create another pair and start normal combat; should not merge with spar.
      user3 = User.create(email: 'user3_mode@example.com', password_hash: 'hash', username: 'user3mode', salt: 'salt3mode')
      char3 = Character.create(forename: 'Fighter', surname: 'Three', user: user3, is_npc: false)
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

      user4 = User.create(email: 'user4_mode@example.com', password_hash: 'hash', username: 'user4mode', salt: 'salt4mode')
      char4 = Character.create(forename: 'Fighter', surname: 'Four', user: user4, is_npc: false)
      instance4 = CharacterInstance.create(
        character: char4,
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

      normal_service = described_class.start_fight(room: room, initiator: instance3, target: instance4, mode: 'normal')
      expect(normal_service.fight.id).not_to eq(spar_service.fight.id)
      expect(normal_service.fight.mode).to eq('normal')
      expect(spar_service.fight.mode).to eq('spar')
    end

    it 'creates new fight if existing fight is complete' do
      # Start and complete first fight
      first_service = described_class.start_fight(room: room, initiator: instance1, target: instance2)
      first_service.fight.update(status: 'complete')

      # Create third and fourth participant
      user3 = User.create(email: 'user3@example.com', password_hash: 'hash', username: 'user3', salt: 'salt3')
      char3 = Character.create(forename: 'Fighter', surname: 'Three', user: user3, is_npc: false)
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
      user4 = User.create(email: 'user4@example.com', password_hash: 'hash', username: 'user4', salt: 'salt4')
      char4 = Character.create(forename: 'Fighter', surname: 'Four', user: user4, is_npc: false)
      instance4 = CharacterInstance.create(
        character: char4,
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

      # Second start should create new fight
      second_service = described_class.start_fight(room: room, initiator: instance3, target: instance4)

      expect(second_service.fight.id).not_to eq(first_service.fight.id)
    end
  end

  describe '.find_active_fight' do
    it 'returns fight for participant in active fight' do
      service = described_class.start_fight(room: room, initiator: instance1, target: instance2)

      found = described_class.find_active_fight(instance1)

      # Compare by ID to avoid timestamp precision issues
      expect(found.id).to eq(service.fight.id)
    end

    it 'returns nil for character not in a fight' do
      # Create third character not in any fight
      user3 = User.create(email: 'user3@example.com', password_hash: 'hash', username: 'user3', salt: 'salt3')
      char3 = Character.create(forename: 'Fighter', surname: 'Three', user: user3, is_npc: false)
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

      found = described_class.find_active_fight(instance3)

      expect(found).to be_nil
    end

    it 'returns nil when fight is complete' do
      service = described_class.start_fight(room: room, initiator: instance1, target: instance2)
      service.fight.update(status: 'complete')

      found = described_class.find_active_fight(instance1)

      expect(found).to be_nil
    end
  end

  describe '#add_participant' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }

    it 'creates FightParticipant for character' do
      participant = service.add_participant(instance1)

      expect(participant).to be_a(FightParticipant)
      expect(participant.character_instance_id).to eq(instance1.id)
      expect(participant.fight_id).to eq(fight.id)
    end

    it 'does not create duplicate participant' do
      first = service.add_participant(instance1)
      second = service.add_participant(instance1)

      expect(first).to eq(second)
      expect(fight.fight_participants_dataset.count).to eq(1)
    end

    it 'sets hex position for participant' do
      participant = service.add_participant(instance1)

      expect(participant.hex_x).not_to be_nil
      expect(participant.hex_y).not_to be_nil
    end
  end

  describe '#determine_side_for_new_participant' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }

    it 'assigns side 1 to first participant' do
      side = service.determine_side_for_new_participant(nil)
      expect(side).to eq(1)
    end

    it 'assigns side 2 to second participant without target' do
      service.add_participant(instance1)
      side = service.determine_side_for_new_participant(nil)
      expect(side).to eq(2)
    end

    it 'assigns opposite side when targeting existing participant' do
      p1 = service.add_participant(instance1)
      p1.update(side: 1)

      side = service.determine_side_for_new_participant(instance1)
      expect(side).to eq(2)
    end

    it 'chooses the least-populated opposing side in multi-side fights' do
      service.add_participant(instance1)
      service.participant_for(instance1).update(side: 1)

      service.add_participant(instance2)
      service.participant_for(instance2).update(side: 2)

      user3 = User.create(email: 'multi3@example.com', password_hash: 'hash', username: 'multi3', salt: 'salt_m3')
      char3 = Character.create(forename: 'Target', surname: 'SideThree', user: user3, is_npc: false)
      inst3 = CharacterInstance.create(
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
      service.add_participant(inst3)
      service.participant_for(inst3).update(side: 3)

      # Make side 2 larger than side 1 so side 1 is preferred.
      user4 = User.create(email: 'multi4@example.com', password_hash: 'hash', username: 'multi4', salt: 'salt_m4')
      char4 = Character.create(forename: 'Extra', surname: 'SideTwo', user: user4, is_npc: false)
      inst4 = CharacterInstance.create(
        character: char4,
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
      service.add_participant(inst4)
      service.participant_for(inst4).update(side: 2)

      side = service.determine_side_for_new_participant(inst3)
      expect(side).to eq(1)
    end

    it 'creates a new side when target side has no existing opponents' do
      p1 = service.add_participant(instance1)
      p1.update(side: 2)

      side = service.determine_side_for_new_participant(instance1)
      expect(side).to eq(3)
    end

    it 'balances sides with multiple participants' do
      # Add participant to side 1
      service.add_participant(instance1)
      service.fight.fight_participants_dataset.first.update(side: 1)

      # Add another to side 1
      user3 = User.create(email: 'user3@example.com', password_hash: 'hash', username: 'user3', salt: 'salt3')
      char3 = Character.create(forename: 'Fighter', surname: 'Three', user: user3, is_npc: false)
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
      service.add_participant(instance3)
      fight.fight_participants_dataset.where(character_instance_id: instance3.id).update(side: 1)

      # Add one to side 2
      service.add_participant(instance2)
      fight.fight_participants_dataset.where(character_instance_id: instance2.id).update(side: 2)

      # Refresh fight data
      fight.refresh

      # Next participant should go to side 2 (fewer fighters - 1 vs 2)
      side = service.determine_side_for_new_participant(nil)
      expect(side).to eq(2)
    end
  end

  describe '#participant_for' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }

    it 'returns participant for character in fight' do
      service.add_participant(instance1)

      found = service.participant_for(instance1)

      expect(found).not_to be_nil
      expect(found.character_instance_id).to eq(instance1.id)
    end

    it 'returns nil for character not in fight' do
      found = service.participant_for(instance1)
      expect(found).to be_nil
    end
  end

  describe '#change_side!' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }
    let!(:participant) { service.add_participant(instance1) }

    it 'changes participant to specified side' do
      service.change_side!(participant, 3)
      expect(participant.reload.side).to eq(3)
    end

    it 'creates new side when nil passed' do
      participant.update(side: 1)
      service.add_participant(instance2)
      service.fight.fight_participants_dataset.last.update(side: 2)

      new_side = service.change_side!(participant, nil)

      expect(new_side).to eq(3)
      expect(participant.reload.side).to eq(3)
    end
  end

  describe '#ready_to_resolve?' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }

    before do
      service.add_participant(instance1)
      service.add_participant(instance2)
    end

    it 'returns false when participants have not completed input' do
      expect(service.ready_to_resolve?).to be false
    end

    it 'returns true when all participants completed input' do
      fight.fight_participants_dataset.each { |p| p.update(input_complete: true) }
      expect(service.ready_to_resolve?).to be true
    end

    it 'returns true when input timed out' do
      fight.update(input_deadline_at: Time.now - 60)
      expect(service.ready_to_resolve?).to be true
    end
  end

  describe '#should_end?' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }

    it 'returns true with only one active participant' do
      service.add_participant(instance1)
      expect(service.should_end?).to be true
    end

    it 'returns true when all knocked out' do
      service.add_participant(instance1)
      service.add_participant(instance2)
      fight.fight_participants_dataset.each { |p| p.update(is_knocked_out: true) }

      expect(service.should_end?).to be true
    end

    it 'returns false with multiple active participants' do
      service.add_participant(instance1)
      service.add_participant(instance2)

      expect(service.should_end?).to be false
    end
  end

  describe '#end_fight!' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }

    before do
      service.add_participant(instance1)
      service.add_participant(instance2)
    end

    it 'marks fight as complete' do
      service.end_fight!
      expect(fight.reload.status).to eq('complete')
    end
  end

  describe '#apply_defaults!' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }

    before do
      service.add_participant(instance1)
      service.add_participant(instance2)
    end

    it 'applies defaults to participants needing input' do
      # Create spy to track calls
      ai_spy = instance_double(CombatAIService)
      allow(CombatAIService).to receive(:new).and_return(ai_spy)
      allow(ai_spy).to receive(:apply_decisions!)

      service.apply_defaults!

      expect(ai_spy).to have_received(:apply_decisions!).at_least(:once)
    end
  end

  describe '#process_choice' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }
    let!(:p1) { service.add_participant(instance1) }
    let!(:p2) { service.add_participant(instance2) }

    describe 'target stage' do
      before { p1.update(input_stage: 'main_target') }

      it 'sets target when valid target provided' do
        service.process_choice(p1, 'target', p2.id.to_s)

        p1.reload
        expect(p1.target_participant_id).to eq(p2.id)
        expect(p1.input_stage).to eq('main_action')
      end

      it 'stays on target stage for invalid target' do
        service.process_choice(p1, 'target', p1.id.to_s)

        p1.reload
        expect(p1.target_participant_id).to be_nil
        expect(p1.input_stage).to eq('main_target')
      end

      it 'stays on target stage for non-existent target' do
        service.process_choice(p1, 'target', '99999')

        p1.reload
        expect(p1.target_participant_id).to be_nil
        expect(p1.input_stage).to eq('main_target')
      end
    end

    describe 'main action stage' do
      before do
        p1.update(input_stage: 'main_action', target_participant_id: p2.id)
        allow(CombatQuickmenuHandler).to receive(:next_stage_for).and_return('tactical_action')
      end

      it 'sets attack action' do
        service.process_choice(p1, 'main', 'attack')

        p1.reload
        expect(p1.main_action).to eq('attack')
      end

      it 'sets defend action' do
        service.process_choice(p1, 'main', 'defend')

        p1.reload
        expect(p1.main_action).to eq('defend')
      end

      it 'defaults to attack for invalid choice' do
        service.process_choice(p1, 'main', 'invalid_action')

        p1.reload
        expect(p1.main_action).to eq('attack')
      end
    end

    describe 'ability stage' do
      let(:ability) { Ability.create(name: 'Fireball', ability_type: 'combat', description: 'Fire') }

      before do
        p1.update(input_stage: 'tactical_action', target_participant_id: p2.id, main_action: 'attack')
        allow(p1).to receive(:available_main_abilities).and_return([ability])
        allow(CombatQuickmenuHandler).to receive(:next_stage_for).and_return('willpower')
      end

      it 'sets ability by database ID format' do
        service.process_choice(p1, 'ability', "ability_#{ability.id}")

        p1.reload
        expect(p1.ability_id).to eq(ability.id)
        expect(p1.ability_choice).to eq('fireball')
      end

      it 'ignores legacy format ability choices (only ability_ID format supported)' do
        service.process_choice(p1, 'ability', 'fireball')

        p1.reload
        # Legacy plain-name format is no longer supported; only ability_<id> works
        expect(p1.ability_choice).to be_nil
        expect(p1.input_stage).to eq('willpower')
      end

      it 'ignores invalid ability choices' do
        service.process_choice(p1, 'ability', 'invalid_ability_format')

        p1.reload
        expect(p1.ability_id).to be_nil
      end
    end

    describe 'tactical ability stage' do
      let(:tactical_ability) { Ability.create(name: 'Shield Wall', ability_type: 'utility', description: 'Defense') }

      before do
        p1.update(input_stage: 'tactical_ability_target', main_action: 'attack')
        allow(p1).to receive(:available_tactical_abilities).and_return([tactical_ability])
        allow(CombatQuickmenuHandler).to receive(:next_stage_for).and_return('movement')
      end

      it 'skips tactical ability when requested' do
        service.process_choice(p1, 'tactical_ability', 'skip_tactical_ability')

        p1.reload
        expect(p1.tactical_ability_id).to be_nil
        expect(p1.input_stage).to eq('movement')
      end

      it 'sets tactical ability by ID' do
        service.process_choice(p1, 'tactical_ability', "tactical_ability_#{tactical_ability.id}")

        p1.reload
        expect(p1.tactical_ability_id).to eq(tactical_ability.id)
      end
    end

    describe 'tactical stage' do
      before do
        p1.update(input_stage: 'tactical_action')
        allow(CombatQuickmenuHandler).to receive(:next_stage_for).and_return('willpower')
      end

      it 'sets tactic choice' do
        service.process_choice(p1, 'tactical', 'aggressive')

        p1.reload
        expect(p1.tactic_choice).to eq('aggressive')
      end

      it 'sets nil for invalid tactic choice' do
        service.process_choice(p1, 'tactical', 'invalid')

        p1.reload
        expect(p1.tactic_choice).to be_nil
      end
    end

    describe 'willpower stage' do
      before do
        p1.update(input_stage: 'willpower', willpower_dice: 3)
        allow(CombatQuickmenuHandler).to receive(:next_stage_for).and_return('movement')
        allow(p1).to receive(:use_willpower_die!)
      end

      it 'skips willpower allocation' do
        service.process_choice(p1, 'willpower', 'skip')

        p1.reload
        expect(p1.input_stage).to eq('movement')
      end

      it 'allocates willpower to attack' do
        service.process_choice(p1, 'willpower', 'attack_2')

        p1.reload
        expect(p1.willpower_attack).to eq(2)
      end

      it 'allocates willpower to defense' do
        service.process_choice(p1, 'willpower', 'defense_1')

        p1.reload
        expect(p1.willpower_defense).to eq(1)
      end

      it 'allocates willpower to ability' do
        service.process_choice(p1, 'willpower', 'ability_3')

        p1.reload
        expect(p1.willpower_ability).to eq(3)
      end

      it 'ignores invalid willpower format' do
        service.process_choice(p1, 'willpower', 'invalid_format')

        p1.reload
        # Invalid format doesn't change the default value of 0
        expect(p1.willpower_attack).to eq(0)
      end
    end

    describe 'movement stage' do
      before do
        p1.update(input_stage: 'movement')
        allow(CombatQuickmenuHandler).to receive(:next_stage_for).and_return('done')
        allow(p1).to receive(:complete_input!)
      end

      it 'sets stand_still movement' do
        service.process_choice(p1, 'movement', 'stand_still')

        p1.reload
        expect(p1.movement_action).to eq('stand_still')
        expect(p1.movement_target_participant_id).to be_nil
      end

      it 'sets towards person movement' do
        service.process_choice(p1, 'movement', "towards_#{p2.id}")

        p1.reload
        expect(p1.movement_action).to eq('towards_person')
        expect(p1.movement_target_participant_id).to eq(p2.id)
      end

      it 'sets away from movement' do
        service.process_choice(p1, 'movement', "away_#{p2.id}")

        p1.reload
        expect(p1.movement_action).to eq('away_from')
        expect(p1.movement_target_participant_id).to eq(p2.id)
      end

      it 'sets maintain distance movement' do
        service.process_choice(p1, 'movement', "maintain_#{p2.id}_5")

        p1.reload
        expect(p1.movement_action).to eq('maintain_distance')
        expect(p1.movement_target_participant_id).to eq(p2.id)
        expect(p1.maintain_distance_range).to eq(5)
      end

      it 'sets move to hex movement' do
        service.process_choice(p1, 'movement', 'hex_10_8')

        p1.reload
        expect(p1.movement_action).to eq('move_to_hex')
        expect(p1.target_hex_x).to eq(10)
        expect(p1.target_hex_y).to eq(8)
      end

      it 'defaults to stand_still for unknown movement' do
        service.process_choice(p1, 'movement', 'unknown_movement')

        p1.reload
        expect(p1.movement_action).to eq('stand_still')
      end
    end

    describe 'weapon_melee stage' do
      let(:weapon_type) { UnifiedObjectType.create(name: 'Sword', category: 'Sword') }
      let(:pattern) { Pattern.create(unified_object_type: weapon_type, description: 'A sharp sword', is_melee: true) }
      let(:weapon) { Item.create(pattern: pattern, character_instance: instance1, equipped: true, name: 'Sword') }

      before do
        p1.update(input_stage: 'weapon_melee')
      end

      it 'sets melee weapon by ID' do
        service.process_choice(p1, 'weapon_melee', weapon.id.to_s)

        p1.reload
        expect(p1.melee_weapon_id).to eq(weapon.id)
        expect(p1.input_stage).to eq('weapon_ranged')
      end

      it 'sets none for unarmed' do
        service.process_choice(p1, 'weapon_melee', 'unarmed')

        p1.reload
        expect(p1.melee_weapon_id).to be_nil
      end

      it 'handles none choice' do
        service.process_choice(p1, 'weapon_melee', 'none')

        p1.reload
        expect(p1.melee_weapon_id).to be_nil
      end
    end

    describe 'weapon_ranged stage' do
      let(:weapon_type) { UnifiedObjectType.create(name: 'Bow', category: 'Firearm') }
      let(:pattern) { Pattern.create(unified_object_type: weapon_type, description: 'A sturdy bow', is_ranged: true) }
      let(:weapon) { Item.create(pattern: pattern, character_instance: instance1, equipped: true, name: 'Bow') }

      before do
        p1.update(input_stage: 'weapon_ranged')
        allow(p1).to receive(:complete_input!)
      end

      it 'sets ranged weapon and completes input' do
        service.process_choice(p1, 'weapon_ranged', weapon.id.to_s)

        p1.reload
        expect(p1.ranged_weapon_id).to eq(weapon.id)
      end

      it 'sets none for ranged and completes input' do
        service.process_choice(p1, 'weapon_ranged', 'none')

        p1.reload
        expect(p1.ranged_weapon_id).to be_nil
      end
    end
  end

  describe '#resolve_round!' do
    let(:fight) { Fight.create(room_id: room.id, status: 'input') }
    let(:service) { described_class.new(fight) }
    let(:mock_resolution) { instance_double(CombatResolutionService) }

    before do
      service.add_participant(instance1)
      service.add_participant(instance2)

      # Complete input for all participants
      fight.fight_participants_dataset.each { |p| p.update(input_complete: true) }

      # Mock dependencies
      allow(CombatAIService).to receive(:new).and_return(double(apply_decisions!: nil))
      allow(CombatResolutionService).to receive(:new).and_return(mock_resolution)
    end

    it 'advances fight to resolution then narrative' do
      allow(mock_resolution).to receive(:resolve!).and_return({ events: [], roll_display: nil })

      service.resolve_round!

      expect(fight.reload.status).to eq('narrative')
    end

    it 'returns events and roll display' do
      events = [{ type: 'attack', damage: 10 }]
      roll_display = { dice: [3, 4, 5] }
      allow(mock_resolution).to receive(:resolve!).and_return({ events: events, roll_display: roll_display })

      result = service.resolve_round!

      expect(result[:events]).to eq(events)
      expect(result[:roll_display]).to eq(roll_display)
    end

    it 'handles old array format from resolution' do
      events = [{ type: 'attack' }]
      allow(mock_resolution).to receive(:resolve!).and_return(events)

      result = service.resolve_round!

      expect(result[:events]).to eq(events)
      expect(result[:roll_display]).to be_nil
    end

    it 'stores events in fight' do
      events = [{ type: 'attack', target: 'Fighter Two' }]
      allow(mock_resolution).to receive(:resolve!).and_return({ events: events, roll_display: nil })

      service.resolve_round!

      # round_events is JSONB - Sequel wraps as JSONBArray
      stored_events = fight.reload.round_events.to_a
      expect(stored_events.first['type']).to eq('attack')
      expect(stored_events.first['target']).to eq('Fighter Two')
    end

    it 'logs errors but continues to narrative when resolution reports step errors' do
      allow(mock_resolution).to receive(:resolve!).and_return(
        {
          events: [],
          roll_display: nil,
          errors: [{ step: 'schedule_all_events', error_class: 'RuntimeError', message: 'boom' }]
        }
      )

      result = service.resolve_round!
      expect(result[:errors]).to eq([{ step: 'schedule_all_events', error_class: 'RuntimeError', message: 'boom' }])
      expect(fight.reload.status).to eq('narrative')
    end
  end

  describe '#generate_narrative' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }
    let(:mock_narrative_service) { instance_double(CombatNarrativeService) }

    it 'delegates to CombatNarrativeService' do
      allow(CombatNarrativeService).to receive(:new).with(fight).and_return(mock_narrative_service)
      allow(mock_narrative_service).to receive(:generate).and_return('The battle raged on...')

      result = service.generate_narrative

      expect(result).to eq('The battle raged on...')
    end
  end

  describe '#add_monster' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }
    let(:monster_template) do
      MonsterTemplate.create(
        name: 'Giant Spider',
        total_hp: 100,
        hex_width: 2,
        hex_height: 2,
        climb_distance: 3,
        defeat_threshold_percent: 50
      )
    end

    it 'spawns monster in fight' do
      allow(monster_template).to receive(:spawn_in_fight).and_return(
        instance_double(LargeMonsterInstance, id: 1)
      )

      monster = service.add_monster(monster_template)

      # Room is 40x40 feet (min_x: 0, max_x: 40, min_y: 0, max_y: 40)
      # Arena is 20x20 hexes, center is (10, 10)
      expect(monster_template).to have_received(:spawn_in_fight).with(fight, 10, 10)
    end

    it 'uses provided hex position' do
      allow(monster_template).to receive(:spawn_in_fight).and_return(
        instance_double(LargeMonsterInstance, id: 1)
      )

      service.add_monster(monster_template, hex_x: 5, hex_y: 8)

      expect(monster_template).to have_received(:spawn_in_fight).with(fight, 5, 8)
    end

    it 'marks fight as having monster' do
      allow(monster_template).to receive(:spawn_in_fight).and_return(
        instance_double(LargeMonsterInstance, id: 1)
      )

      service.add_monster(monster_template)

      expect(fight.reload.has_monster).to be true
    end
  end

  describe '#next_round!' do
    let(:fight) { Fight.create(room_id: room.id, status: 'narrative', round_number: 1) }
    let(:service) { described_class.new(fight) }
    let!(:p1) { service.add_participant(instance1) }
    let!(:p2) { service.add_participant(instance2) }

    before do
      allow(StatusEffectService).to receive(:expire_effects)
      allow(p1).to receive(:decay_all_penalties!)
      allow(p1).to receive(:decay_ability_cooldowns!)
      allow(p1).to receive(:reset_willpower_allocations!)
      allow(p1).to receive(:reset_menu_state!)
      allow(p2).to receive(:decay_all_penalties!)
      allow(p2).to receive(:decay_ability_cooldowns!)
      allow(p2).to receive(:reset_willpower_allocations!)
      allow(p2).to receive(:reset_menu_state!)
    end

    it 'expires status effects' do
      service.next_round!

      expect(StatusEffectService).to have_received(:expire_effects).with(fight)
    end

    it 'decays cooldowns and penalties for each participant' do
      # Force reload participants from database so the stubs work
      fight.fight_participants.each do |p|
        allow(p).to receive(:decay_all_penalties!)
        allow(p).to receive(:decay_ability_cooldowns!)
        allow(p).to receive(:reset_willpower_allocations!)
        allow(p).to receive(:reset_menu_state!)
      end

      service.next_round!

      fight.fight_participants.each do |p|
        expect(p).to have_received(:decay_all_penalties!)
        expect(p).to have_received(:decay_ability_cooldowns!)
        expect(p).to have_received(:reset_willpower_allocations!)
        expect(p).to have_received(:reset_menu_state!)
      end
    end

    it 'completes the round' do
      service.next_round!

      expect(fight.reload.round_number).to eq(2)
    end
  end

  # DEPRECATED: ensure_battle_map_ready was replaced by async generation as of 2026-02-16
  # These tests are kept for reference but marked as pending
  describe '.ensure_battle_map_ready' do
    before { skip 'Method deprecated - replaced by async generation' }
    let(:room_with_bounds) do
      Room.create(
        name: 'Bounded Room',
        short_description: 'Test',
        location: location,
        room_type: 'standard',
        min_x: 0, max_x: 40,
        min_y: 0, max_y: 40
      )
    end

    let(:room_without_bounds) do
      r = Room.create(
        name: 'No Bounds Room',
        short_description: 'Test',
        location: location,
        room_type: 'standard',
        min_x: 0, max_x: 100, min_y: 0, max_y: 100  # Required for validation
      )
      # Mock bounds to return nil to simulate no bounds
      allow(r).to receive(:min_x).and_return(nil)
      r
    end

    it 'skips room without bounds' do
      expect(BattleMapGeneratorService).not_to receive(:new)

      described_class.ensure_battle_map_ready(room_without_bounds)
    end

    it 'skips room that already has battle map' do
      allow(room_with_bounds).to receive(:battle_map_ready?).and_return(true)
      expect(BattleMapGeneratorService).not_to receive(:new)

      described_class.ensure_battle_map_ready(room_with_bounds)
    end

    it 'generates procedural battle map when AI disabled' do
      allow(room_with_bounds).to receive(:battle_map_ready?).and_return(false)
      allow(GameSetting).to receive(:get_boolean).with('ai_battle_maps_enabled').and_return(false)

      generator = instance_double(BattleMapGeneratorService)
      allow(BattleMapGeneratorService).to receive(:new).with(room_with_bounds).and_return(generator)
      allow(generator).to receive(:generate!)

      described_class.ensure_battle_map_ready(room_with_bounds)

      expect(generator).to have_received(:generate!)
    end

    it 'generates AI battle map when enabled' do
      allow(room_with_bounds).to receive(:battle_map_ready?).and_return(false)
      allow(GameSetting).to receive(:get_boolean).with('ai_battle_maps_enabled').and_return(true)

      generator = instance_double(AIBattleMapGeneratorService)
      allow(AIBattleMapGeneratorService).to receive(:new).with(room_with_bounds).and_return(generator)
      allow(generator).to receive(:generate)

      described_class.ensure_battle_map_ready(room_with_bounds)

      expect(generator).to have_received(:generate)
    end

    it 'logs error but does not fail on generation error' do
      allow(room_with_bounds).to receive(:battle_map_ready?).and_return(false)
      allow(GameSetting).to receive(:get_boolean).and_return(false)
      allow(BattleMapGeneratorService).to receive(:new).and_raise(StandardError.new('Generation failed'))

      expect { described_class.ensure_battle_map_ready(room_with_bounds) }.not_to raise_error
    end
  end

  describe '#add_participant with blocking conditions' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }

    context 'when character has fled from fight' do
      before do
        allow(instance1).to receive(:has_fled_from_fight?).with(fight).and_return(true)
      end

      it 'returns nil' do
        result = service.add_participant(instance1)

        expect(result).to be_nil
      end
    end

    context 'when character has surrendered from fight' do
      before do
        allow(instance1).to receive(:has_fled_from_fight?).with(fight).and_return(false)
        allow(instance1).to receive(:has_surrendered_from_fight?).with(fight).and_return(true)
      end

      it 'returns nil' do
        result = service.add_participant(instance1)

        expect(result).to be_nil
      end
    end
  end

  describe 'private methods' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }

    describe '#find_unoccupied_hex' do
      before do
        # Create floor hex records so playable_at? returns true
        HexGrid.hex_coords_for_room(room.min_x, room.min_y, room.max_x, room.max_y).each do |hx, hy|
          RoomHex.set_hex_details(room, hx, hy, hex_type: 'normal', traversable: true)
        end
      end

      it 'returns desired hex if unoccupied' do
        result = service.find_unoccupied_hex( 4, 4)

        expect(result).to eq([4, 4])
      end

      it 'finds nearby hex when desired is occupied' do
        # Add a participant at position 4,4
        service.add_participant(instance1)
        fight.fight_participants_dataset.first.update(hex_x: 4, hex_y: 4)

        result = service.find_unoccupied_hex( 4, 4)

        expect(result).not_to eq([4, 4])
      end
    end

    describe '#hexes_at_distance' do
      it 'returns center hex for distance 0' do
        result = service.send(:hexes_at_distance, 5, 4, 0)

        expect(result).to eq([[5, 4]])
      end

      it 'returns multiple hexes at distance 1' do
        result = service.send(:hexes_at_distance, 5, 4, 1)

        # Should have 6 hexes around the center (hex grid neighbors)
        expect(result.length).to be > 0
        result.each do |hex_x, hex_y|
          expect(HexGrid.hex_distance(5, 4, hex_x, hex_y)).to eq(1)
        end
      end
    end

    describe '#calculate_starting_hex' do
      it 'returns a valid hex coordinate pair' do
        result = service.send(:calculate_starting_hex, instance1)

        expect(result).to be_an(Array)
        expect(result.length).to eq(2)
      end

      it 'places within arena bounds' do
        result = service.send(:calculate_starting_hex, instance1)
        hx, hy = result

        arena_w = fight.arena_width || 10
        arena_h = fight.arena_height || 10
        hex_max_x = [arena_w - 1, 0].max
        hex_max_y = [(arena_h - 1) * 4 + 2, 0].max

        expect(hx).to be_between(0, hex_max_x)
        expect(hy).to be_between(0, hex_max_y)
      end
    end

    describe '#find_best_weapons' do
      let(:melee_type) { UnifiedObjectType.create(name: 'Sword', category: 'Sword') }
      let(:ranged_type) { UnifiedObjectType.create(name: 'Bow', category: 'Firearm') }
      let(:melee_pattern) { Pattern.create(unified_object_type: melee_type, description: 'A sharp sword', is_melee: true) }
      let(:ranged_pattern) { Pattern.create(unified_object_type: ranged_type, description: 'A sturdy bow', is_ranged: true) }
      let!(:melee_weapon) { Item.create(pattern: melee_pattern, character_instance: instance1, equipped: true, name: 'Sword') }
      let!(:ranged_weapon) { Item.create(pattern: ranged_pattern, character_instance: instance1, equipped: true, name: 'Bow') }

      it 'returns both melee and ranged weapons' do
        melee, ranged = service.send(:find_best_weapons, instance1)

        expect(melee&.id).to eq(melee_weapon.id)
        expect(ranged&.id).to eq(ranged_weapon.id)
      end

      it 'finds unequipped weapons from inventory' do
        melee_weapon.update(equipped: false)
        ranged_weapon.update(equipped: false)

        melee, ranged = service.send(:find_best_weapons, instance1)

        expect(melee&.id).to eq(melee_weapon.id)
        expect(ranged&.id).to eq(ranged_weapon.id)
      end

      it 'prefers already-equipped weapons over unequipped' do
        second_melee_pattern = Pattern.create(unified_object_type: melee_type, description: 'Another sword', is_melee: true)
        unequipped_melee = Item.create(pattern: second_melee_pattern, character_instance: instance1, equipped: false, name: 'Other Sword')

        melee, _ranged = service.send(:find_best_weapons, instance1)

        expect(melee&.id).to eq(melee_weapon.id)
        expect(unequipped_melee.reload.equipped?).to be false
      end

      it 'returns nil when no weapons exist in inventory' do
        melee_weapon.destroy
        ranged_weapon.destroy

        melee, ranged = service.send(:find_best_weapons, instance1)

        expect(melee).to be_nil
        expect(ranged).to be_nil
      end
    end

    describe '#apply_default_choices' do
      let!(:p1) { service.add_participant(instance1) }
      let!(:p2) { service.add_participant(instance2) }

      it 'sets target to first enemy if not set' do
        p1.update(target_participant_id: nil)

        service.send(:apply_default_choices, p1)

        expect(p1.reload.target_participant_id).not_to be_nil
      end

      it 'sets default main_action to attack' do
        p1.update(main_action: nil)

        service.send(:apply_default_choices, p1)

        expect(p1.reload.main_action).to eq('attack')
      end

      it 'sets default movement_action to stand_still' do
        p1.update(movement_action: nil)

        service.send(:apply_default_choices, p1)

        expect(p1.reload.movement_action).to eq('stand_still')
      end

      it 'preserves existing choices' do
        p1.update(main_action: 'defend', movement_action: 'away_from')

        service.send(:apply_default_choices, p1)

        p1.reload
        expect(p1.main_action).to eq('defend')
        expect(p1.movement_action).to eq('away_from')
      end
    end
  end

  describe 'monster mounting actions' do
    let(:fight) { Fight.create(room_id: room.id) }
    let(:service) { described_class.new(fight) }
    let!(:p1) { service.add_participant(instance1) }
    let(:monster_template) do
      MonsterTemplate.create(name: 'Dragon', total_hp: 200, hex_width: 3, hex_height: 3, climb_distance: 3, defeat_threshold_percent: 50)
    end
    let(:monster_instance) do
      LargeMonsterInstance.create(
        monster_template: monster_template,
        fight: fight,
        current_hp: 200,
        max_hp: 200,
        status: 'active',
        center_hex_x: 10,
        center_hex_y: 10
      )
    end
    let(:mount_state) do
      MonsterMountState.create(
        large_monster_instance: monster_instance,
        fight_participant: p1,
        mount_status: 'mounted',
        climb_progress: 0
      )
    end

    describe '#process_mount_action' do
      before do
        p1.update(input_stage: 'movement')
        allow(CombatQuickmenuHandler).to receive(:next_stage_for).and_return('done')
        allow(p1).to receive(:complete_input!)
      end

      it 'mounts monster successfully' do
        # Create a segment template for the segment instance
        segment_template = MonsterSegmentTemplate.create(
          monster_template: monster_template,
          name: 'Body',
          segment_type: 'body',
          hp_percent: 100,
          attacks_per_round: 1,
          attack_speed: 50,
          reach: 1
        )

        # Create a real segment for the FK constraint
        segment = MonsterSegmentInstance.create(
          large_monster_instance: monster_instance,
          monster_segment_template: segment_template,
          current_hp: 100,
          max_hp: 100,
          status: 'healthy'
        )

        mock_mounting = instance_double(MonsterMountingService)
        allow(MonsterMountingService).to receive(:new).with(fight).and_return(mock_mounting)
        allow(mock_mounting).to receive(:attempt_mount).and_return(
          { success: true, segment: segment }
        )

        service.send(:process_mount_action, p1, monster_instance.id)

        expect(p1.reload.is_mounted).to be true
        expect(p1.targeting_monster_id).to eq(monster_instance.id)
      end

      it 'does nothing for invalid monster' do
        service.send(:process_mount_action, p1, 99999)

        expect(p1.reload.is_mounted).to be_falsey
      end
    end

    describe '#process_climb_action' do
      before do
        p1.update(is_mounted: true, targeting_monster_id: monster_instance.id)
        mount_state
      end

      it 'delegates to MonsterMountingService' do
        mock_mounting = instance_double(MonsterMountingService)
        allow(MonsterMountingService).to receive(:new).with(fight).and_return(mock_mounting)
        allow(mock_mounting).to receive(:process_climb)

        service.send(:process_climb_action, p1)

        expect(mock_mounting).to have_received(:process_climb).with(mount_state)
      end

      it 'does nothing when not mounted' do
        p1.update(is_mounted: false)

        expect { service.send(:process_climb_action, p1) }.not_to raise_error
      end
    end

    describe '#process_cling_action' do
      before do
        p1.update(is_mounted: true, targeting_monster_id: monster_instance.id)
        mount_state
      end

      it 'delegates to MonsterMountingService' do
        mock_mounting = instance_double(MonsterMountingService)
        allow(MonsterMountingService).to receive(:new).with(fight).and_return(mock_mounting)
        allow(mock_mounting).to receive(:process_cling)

        service.send(:process_cling_action, p1)

        expect(mock_mounting).to have_received(:process_cling).with(mount_state)
      end
    end

    describe '#process_dismount_action' do
      before do
        p1.update(is_mounted: true, targeting_monster_id: monster_instance.id, hex_x: 10, hex_y: 10)
        mount_state
      end

      it 'dismounts successfully' do
        mock_mounting = instance_double(MonsterMountingService)
        allow(MonsterMountingService).to receive(:new).with(fight).and_return(mock_mounting)
        allow(mock_mounting).to receive(:process_dismount).and_return(
          { success: true, landing_position: [12, 10] }
        )

        service.send(:process_dismount_action, p1)

        p1.reload
        expect(p1.is_mounted).to be false
        expect(p1.hex_x).to eq(12)
        expect(p1.hex_y).to eq(10)
        expect(p1.targeting_monster_id).to be_nil
      end

      it 'does nothing when dismount fails' do
        mock_mounting = instance_double(MonsterMountingService)
        allow(MonsterMountingService).to receive(:new).with(fight).and_return(mock_mounting)
        allow(mock_mounting).to receive(:process_dismount).and_return({ success: false })

        service.send(:process_dismount_action, p1)

        expect(p1.reload.is_mounted).to be true
      end
    end
  end

  describe 'additional coverage tests' do
    describe '#find_melee_weapon' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }
      let(:melee_type) { UnifiedObjectType.create(name: 'Sword', category: 'Sword') }
      let(:melee_pattern) { Pattern.create(unified_object_type: melee_type, description: 'Sword', is_melee: true) }
      let!(:melee_weapon) { Item.create(pattern: melee_pattern, character_instance: instance1, equipped: true, name: 'Sword') }

      it 'returns the melee weapon' do
        result = service.send(:find_melee_weapon, instance1)
        expect(result&.id).to eq(melee_weapon.id)
      end

      it 'finds unequipped melee weapon from inventory' do
        melee_weapon.update(equipped: false)
        result = service.send(:find_melee_weapon, instance1)
        expect(result&.id).to eq(melee_weapon.id)
      end
    end

    describe '#find_ranged_weapon' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }
      let(:ranged_type) { UnifiedObjectType.create(name: 'Bow', category: 'Firearm') }
      let(:ranged_pattern) { Pattern.create(unified_object_type: ranged_type, description: 'Bow', is_ranged: true) }
      let!(:ranged_weapon) { Item.create(pattern: ranged_pattern, character_instance: instance1, equipped: true, name: 'Bow') }

      it 'returns the ranged weapon' do
        result = service.send(:find_ranged_weapon, instance1)
        expect(result&.id).to eq(ranged_weapon.id)
      end

      it 'finds unequipped ranged weapon from inventory' do
        ranged_weapon.update(equipped: false)
        result = service.send(:find_ranged_weapon, instance1)
        expect(result&.id).to eq(ranged_weapon.id)
      end
    end

    describe '#find_weapon_by_id' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }
      let(:weapon_type) { UnifiedObjectType.create(name: 'Dagger', category: 'Knife') }
      let(:weapon_pattern) { Pattern.create(unified_object_type: weapon_type, description: 'Dagger') }
      let!(:weapon) { Item.create(pattern: weapon_pattern, character_instance: instance1, equipped: true, name: 'Dagger') }

      it 'finds weapon by id' do
        result = service.send(:find_weapon_by_id, instance1, weapon.id)
        expect(result&.id).to eq(weapon.id)
      end

      it 'returns nil for wrong character_instance' do
        result = service.send(:find_weapon_by_id, instance2, weapon.id)
        expect(result).to be_nil
      end

      it 'returns nil for non-existent id' do
        result = service.send(:find_weapon_by_id, instance1, 99999)
        expect(result).to be_nil
      end
    end

    describe '#occupied_hexes' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }

      it 'returns empty set when no participants' do
        result = service.send(:occupied_hexes)
        expect(result).to be_a(Set)
        expect(result).to be_empty
      end

      it 'returns participant hex positions' do
        service.add_participant(instance1)
        service.add_participant(instance2)

        p1 = service.participant_for(instance1)
        p2 = service.participant_for(instance2)
        p1.update(hex_x: 5, hex_y: 4)
        p2.update(hex_x: 7, hex_y: 6)

        result = service.send(:occupied_hexes)

        expect(result).to include([5, 4])
        expect(result).to include([7, 6])
      end

      it 'excludes participants without position' do
        p1 = service.add_participant(instance1)
        p1.update(hex_x: nil, hex_y: nil)

        result = service.send(:occupied_hexes)
        expect(result).to be_empty
      end
    end

    describe '#hexes_at_distance' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }

      it 'returns center hex at distance 0' do
        result = service.send(:hexes_at_distance, 10, 8, 0)
        expect(result).to eq([[10, 8]])
      end

      it 'returns multiple hexes at distance 2' do
        result = service.send(:hexes_at_distance, 10, 8, 2)
        expect(result.length).to be > 1
        # All hexes should be exactly distance 2 from center
        result.each do |hx, hy|
          expect(HexGrid.hex_distance(10, 8, hx, hy)).to eq(2)
        end
      end

      it 'returns no duplicate hexes' do
        result = service.send(:hexes_at_distance, 10, 8, 3)
        expect(result.uniq.length).to eq(result.length)
      end
    end

    describe '#calculate_starting_hex' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }

      it 'returns a valid hex coordinate pair' do
        result = service.send(:calculate_starting_hex, instance1)
        expect(result).to be_an(Array)
        expect(result.length).to eq(2)
      end

      it 'returns valid hex coordinates' do
        result = service.send(:calculate_starting_hex, instance1)
        hx, hy = result
        expect(HexGrid.valid_hex_coords?(hx, hy)).to be true
      end
    end

    describe 'mount actions without monster' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }
      let!(:p1) { service.add_participant(instance1) }

      describe '#process_mount_action with invalid monster' do
        it 'does nothing for non-existent monster' do
          service.send(:process_mount_action, p1, 99999)
          expect(p1.reload.is_mounted).to be_falsey
        end
      end

      describe '#process_climb_action without being mounted' do
        it 'does nothing when not mounted' do
          p1.update(is_mounted: false)
          expect { service.send(:process_climb_action, p1) }.not_to raise_error
        end

        it 'does nothing without targeting_monster_id' do
          p1.update(is_mounted: true, targeting_monster_id: nil)
          expect { service.send(:process_climb_action, p1) }.not_to raise_error
        end
      end

      describe '#process_cling_action without being mounted' do
        it 'does nothing when not mounted' do
          p1.update(is_mounted: false)
          expect { service.send(:process_cling_action, p1) }.not_to raise_error
        end
      end

      describe '#process_dismount_action without being mounted' do
        it 'does nothing when not mounted' do
          p1.update(is_mounted: false)
          expect { service.send(:process_dismount_action, p1) }.not_to raise_error
        end
      end
    end

    describe 'spar mode' do
      it 'creates spar mode fight' do
        service = described_class.start_fight(room: room, initiator: instance1, target: instance2, mode: 'spar')
        expect(service.fight.spar_mode?).to be true
      end

      it 'tracks touches instead of damage in spar mode' do
        service = described_class.start_fight(room: room, initiator: instance1, target: instance2, mode: 'spar')
        expect(service.fight.mode).to eq('spar')
      end
    end

    describe 'fight ending scenarios' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }

      context 'with all participants knocked out' do
        before do
          service.add_participant(instance1)
          service.add_participant(instance2)
          fight.fight_participants_dataset.each { |p| p.update(is_knocked_out: true) }
        end

        it 'should_end? returns true' do
          expect(service.should_end?).to be true
        end
      end

      context 'with no participants' do
        it 'should_end? returns true' do
          expect(service.should_end?).to be true
        end
      end
    end

    describe 'side balancing scenarios' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }

      it 'balances sides with multiple participants' do
        # Create several participants
        service.add_participant(instance1)
        service.participant_for(instance1).update(side: 1)

        user3 = User.create(email: 'u3@test.com', password_hash: 'hash', username: 'user3test', salt: 'salt_u3')
        char3 = Character.create(forename: 'F3', surname: 'L3', user: user3, is_npc: false)
        inst3 = CharacterInstance.create(
          character: char3, reality: reality, current_room: room, online: true,
          status: 'alive', level: 1, experience: 0, health: 100, max_health: 100, mana: 50, max_mana: 50
        )
        service.add_participant(inst3)
        service.participant_for(inst3).update(side: 1)

        # Now add to side 2
        service.add_participant(instance2)
        service.participant_for(instance2).update(side: 2)

        # Force refresh the fight data
        fight.refresh

        # Next participant should join side 2 (has fewer)
        user4 = User.create(email: 'u4@test.com', password_hash: 'hash', username: 'user4test', salt: 'salt_u4')
        char4 = Character.create(forename: 'F4', surname: 'L4', user: user4, is_npc: false)
        inst4 = CharacterInstance.create(
          character: char4, reality: reality, current_room: room, online: true,
          status: 'alive', level: 1, experience: 0, health: 100, max_health: 100, mana: 50, max_mana: 50
        )

        side = service.determine_side_for_new_participant(nil)
        expect(side).to eq(2) # Side 2 has 1 fighter, side 1 has 2
      end
    end

    describe 'movement choice completeness' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }
      let!(:p1) { service.add_participant(instance1) }
      let!(:p2) { service.add_participant(instance2) }

      before do
        p1.update(input_stage: 'movement')
        allow(CombatQuickmenuHandler).to receive(:next_stage_for).and_return('done')
      end

      it 'handles maintain_distance with range' do
        service.process_choice(p1, 'movement', "maintain_#{p2.id}_7")
        p1.reload
        expect(p1.movement_action).to eq('maintain_distance')
        expect(p1.maintain_distance_range).to eq(7)
      end

      it 'handles hex movement choice' do
        service.process_choice(p1, 'movement', 'hex_15_12')
        p1.reload
        expect(p1.movement_action).to eq('move_to_hex')
        expect(p1.target_hex_x).to eq(15)
        expect(p1.target_hex_y).to eq(12)
      end
    end

    describe 'weapon choice stage transitions' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }
      let!(:p1) { service.add_participant(instance1) }

      describe 'melee weapon sets ranged as next stage' do
        let(:weapon_type) { UnifiedObjectType.create(name: 'Axe', category: 'Sword') }
        let(:weapon_pattern) { Pattern.create(unified_object_type: weapon_type, description: 'Axe', is_melee: true) }
        let!(:weapon) { Item.create(pattern: weapon_pattern, character_instance: instance1, equipped: true, name: 'Axe') }

        before { p1.update(input_stage: 'weapon_melee') }

        it 'advances to weapon_ranged after selecting melee weapon' do
          service.process_choice(p1, 'weapon_melee', weapon.id.to_s)
          expect(p1.reload.input_stage).to eq('weapon_ranged')
        end
      end
    end

    describe 'target choice edge cases' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }
      let!(:p1) { service.add_participant(instance1) }
      let!(:p2) { service.add_participant(instance2) }

      before { p1.update(input_stage: 'main_target') }

      it 'rejects self as target' do
        service.process_choice(p1, 'target', p1.id.to_s)
        p1.reload
        expect(p1.target_participant_id).to be_nil
        expect(p1.input_stage).to eq('main_target')
      end

      it 'stays on target stage for zero id' do
        service.process_choice(p1, 'target', '0')
        expect(p1.reload.input_stage).to eq('main_target')
      end

      it 'stays on target stage for negative id' do
        service.process_choice(p1, 'target', '-1')
        expect(p1.reload.input_stage).to eq('main_target')
      end
    end

    describe 'willpower allocation edge cases' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }
      let!(:p1) { service.add_participant(instance1) }

      before do
        p1.update(input_stage: 'willpower', willpower_dice: 5)
        allow(CombatQuickmenuHandler).to receive(:next_stage_for).and_return('movement')
      end

      it 'allocates ability willpower' do
        service.process_choice(p1, 'willpower', 'ability_2')
        expect(p1.reload.willpower_ability).to eq(2)
      end

      it 'handles malformed willpower choice' do
        service.process_choice(p1, 'willpower', 'attack')  # Missing count
        expect(p1.reload.willpower_attack).to eq(0)
      end

      it 'handles non-matching willpower choice' do
        service.process_choice(p1, 'willpower', 'something_2')
        expect(p1.reload.input_stage).to eq('movement')
      end
    end

    describe 'tactical ability skip' do
      let(:fight) { Fight.create(room_id: room.id) }
      let(:service) { described_class.new(fight) }
      let!(:p1) { service.add_participant(instance1) }

      before do
        p1.update(input_stage: 'tactical_ability_target')
        allow(CombatQuickmenuHandler).to receive(:next_stage_for).and_return('movement')
      end

      it 'skips tactical ability and advances' do
        old_stage = p1.input_stage
        service.process_choice(p1, 'tactical_ability', 'skip_tactical_ability')
        expect(p1.reload.tactical_ability_id).to be_nil
        expect(p1.input_stage).to eq('movement')
      end

      it 'handles invalid tactical ability format' do
        service.process_choice(p1, 'tactical_ability', 'invalid_format')
        expect(p1.reload.input_stage).to eq('movement')
      end
    end
  end

  describe '.room_needs_battle_map?' do
    let(:room) { create(:room, min_x: 0, max_x: 40, min_y: 0, max_y: 40) }

    it 'returns false if room has no bounds' do
      # Create room normally, then stub the bounds to be nil for testing
      allow(room).to receive(:min_x).and_return(nil)
      allow(room).to receive(:max_x).and_return(nil)
      expect(described_class.room_needs_battle_map?(room)).to be false
    end

    it 'returns false if room already has battle map' do
      room.update(has_battle_map: true)
      allow(room).to receive(:battle_map_ready?).and_return(true)
      expect(described_class.room_needs_battle_map?(room)).to be false
    end

    it 'returns false if another fight is already generating for this room' do
      create(:fight, room: room, battle_map_generating: true)
      expect(described_class.room_needs_battle_map?(room)).to be false
    end

    it 'ignores stale generating flags older than 10 minutes' do
      stale_fight = create(:fight, room: room, battle_map_generating: true)
      stale_time = Time.now - 900
      Fight.where(id: stale_fight.id).update(updated_at: stale_time)
      stale_fight.refresh
      expect(described_class.room_needs_battle_map?(room)).to be true
    end

    it 'returns true if room needs battle map and no generation in progress' do
      expect(described_class.room_needs_battle_map?(room)).to be true
    end
  end

  describe '.kick_off_async_generation' do
    let(:room) { create(:room, min_x: 0, max_x: 40, min_y: 0, max_y: 40) }
    let(:fight) { create(:fight, room: room) }

    it 'enqueues the battle map generation job' do
      expect(BattleMapGenerationJob).to receive(:perform_async).with(room.id, fight.id)
      described_class.kick_off_async_generation(room, fight)
    end

    it 'clears battle_map_generating when enqueue fails' do
      fight.update(battle_map_generating: true)
      allow(BattleMapGenerationJob).to receive(:perform_async).and_raise(StandardError, 'queue down')
      described_class.kick_off_async_generation(room, fight)
      fight.refresh
      expect(fight.battle_map_generating).to be false
    end
  end

  describe '.revalidate_participant_positions' do
    let(:room_with_bounds) { create(:room, location: location, min_x: 0, max_x: 40, min_y: 0, max_y: 40) }
    let(:fight) { create(:fight, room: room_with_bounds) }
    let(:service) { described_class.new(fight) }

    before do
      # Create floor hex records so playable_at? returns true for valid positions
      HexGrid.hex_coords_for_room(room_with_bounds.min_x, room_with_bounds.min_y, room_with_bounds.max_x, room_with_bounds.max_y).each do |hx, hy|
        RoomHex.set_hex_details(room_with_bounds, hx, hy, hex_type: 'normal', traversable: true)
      end
      service.add_participant(instance1)
      service.add_participant(instance2)
    end

    it 'does nothing when all participants are on traversable hexes' do
      p1 = service.participant_for(instance1)
      p2 = service.participant_for(instance2)
      old_pos1 = [p1.hex_x, p1.hex_y]
      old_pos2 = [p2.hex_x, p2.hex_y]

      described_class.revalidate_participant_positions(fight)

      p1.refresh
      p2.refresh
      expect([p1.hex_x, p1.hex_y]).to eq(old_pos1)
      expect([p2.hex_x, p2.hex_y]).to eq(old_pos2)
    end

    it 'moves participant off a wall hex to nearest traversable hex' do
      p1 = service.participant_for(instance1)
      p1.update(hex_x: 4, hex_y: 4)
      RoomHex.set_hex_details(room_with_bounds, 4, 4, hex_type: 'wall', traversable: false)

      described_class.revalidate_participant_positions(fight)

      p1.refresh
      expect([p1.hex_x, p1.hex_y]).not_to eq([4, 4])
      expect(RoomHex.traversable_at?(room_with_bounds, p1.hex_x, p1.hex_y)).to be true
    end

    it 'moves participant off a pit hex' do
      p1 = service.participant_for(instance1)
      p1.update(hex_x: 6, hex_y: 4)
      RoomHex.set_hex_details(room_with_bounds, 6, 4, hex_type: 'pit', traversable: false)

      described_class.revalidate_participant_positions(fight)

      p1.refresh
      expect([p1.hex_x, p1.hex_y]).not_to eq([6, 4])
    end

    it 'skips knocked out participants' do
      p1 = service.participant_for(instance1)
      p1.update(hex_x: 4, hex_y: 4, is_knocked_out: true)
      RoomHex.set_hex_details(room_with_bounds, 4, 4, hex_type: 'wall', traversable: false)

      described_class.revalidate_participant_positions(fight)

      p1.refresh
      expect([p1.hex_x, p1.hex_y]).to eq([4, 4])
    end
  end

  describe '.start_fight async generation' do
    let(:room) { create(:room, min_x: 0, max_x: 40, min_y: 0, max_y: 40) }
    let(:initiator) { create(:character_instance, current_room: room) }
    let(:target) { create(:character_instance, current_room: room) }

    it 'starts battle map generation when room needs it' do
      allow(described_class).to receive(:room_needs_battle_map?).and_return(true)
      # Thread runs async - battle_map_generating stays true until thread completes
      allow(Thread).to receive(:new) # Don't execute the block

      service = described_class.start_fight(room: room, initiator: initiator, target: target)

      expect(service.fight.battle_map_generating).to be true
    end

    it 'does not start generation when room already has battle map' do
      room.update(has_battle_map: true)
      allow(room).to receive(:battle_map_ready?).and_return(true)

      service = described_class.start_fight(room: room, initiator: initiator, target: target)

      expect(service.fight.battle_map_generating).to be false
    end
  end
end
