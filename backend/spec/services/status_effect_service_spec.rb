# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StatusEffectService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }
  let(:fight) { create(:fight, room: room, round_number: 1) }
  let(:participant) do
    create(:fight_participant, fight: fight, character_instance: character_instance, current_hp: 5, max_hp: 5)
  end

  # Helper to create a status effect
  def create_status_effect(name:, effect_type: 'stat_modifier', stacking_behavior: 'refresh', **attrs)
    StatusEffect.create(
      name: name,
      effect_type: effect_type,
      stacking_behavior: stacking_behavior,
      is_buff: attrs.delete(:is_buff) || false,
      max_stacks: attrs.delete(:max_stacks) || 1,
      mechanics: attrs.delete(:mechanics) || Sequel.pg_json_wrap({}),
      cleansable: attrs.key?(:cleansable) ? attrs.delete(:cleansable) : true,
      **attrs
    )
  end

  describe '.apply' do
    let(:effect) { create_status_effect(name: 'test_buff', is_buff: true) }

    it 'creates a new status effect on participant' do
      result = described_class.apply(
        participant: participant,
        effect: effect,
        duration_rounds: 3
      )

      expect(result).to be_a(ParticipantStatusEffect)
      expect(result.fight_participant_id).to eq participant.id
      expect(result.status_effect_id).to eq effect.id
      expect(result.expires_at_round).to eq 4 # round 1 + 3 duration
      expect(result.stack_count).to eq 1
    end

    it 'records who applied the effect' do
      attacker_ci = create(:character_instance, current_room: room, reality: reality)
      attacker = create(:fight_participant, fight: fight, character_instance: attacker_ci)

      result = described_class.apply(
        participant: participant,
        effect: effect,
        duration_rounds: 2,
        applied_by: attacker
      )

      expect(result.applied_by_participant_id).to eq attacker.id
    end

    context 'with refresh stacking behavior' do
      let(:effect) { create_status_effect(name: 'refresh_effect', stacking_behavior: 'refresh') }

      it 'refreshes duration on reapplication' do
        # Apply first time
        first = described_class.apply(participant: participant, effect: effect, duration_rounds: 2)
        expect(first.expires_at_round).to eq 3

        # Apply again
        second = described_class.apply(participant: participant, effect: effect, duration_rounds: 5)

        # Should return same record with updated duration
        expect(second.id).to eq first.id
        expect(second.expires_at_round).to eq 6 # round 1 + 5
      end
    end

    context 'with stack stacking behavior' do
      let(:effect) { create_status_effect(name: 'stack_effect', stacking_behavior: 'stack', max_stacks: 3) }

      it 'adds stacks on reapplication' do
        first = described_class.apply(participant: participant, effect: effect, duration_rounds: 2)
        expect(first.stack_count).to eq 1

        second = described_class.apply(participant: participant, effect: effect, duration_rounds: 2)
        expect(second.id).to eq first.id
        second.refresh
        expect(second.stack_count).to eq 2
      end

      it 'caps at max stacks' do
        # Apply 4 times (max is 3)
        4.times do
          described_class.apply(participant: participant, effect: effect, duration_rounds: 2)
        end

        pse = ParticipantStatusEffect.first(fight_participant_id: participant.id, status_effect_id: effect.id)
        expect(pse.stack_count).to eq 3
      end
    end

    context 'with duration stacking behavior' do
      let(:effect) { create_status_effect(name: 'duration_effect', stacking_behavior: 'duration') }

      it 'extends duration on reapplication' do
        first = described_class.apply(participant: participant, effect: effect, duration_rounds: 2)
        expect(first.expires_at_round).to eq 3

        second = described_class.apply(participant: participant, effect: effect, duration_rounds: 3)
        expect(second.id).to eq first.id
        second.refresh
        expect(second.expires_at_round).to eq 6 # 3 + 3 additional
      end
    end

    context 'with ignore stacking behavior' do
      let(:effect) { create_status_effect(name: 'ignore_effect', stacking_behavior: 'ignore') }

      it 'ignores reapplication if effect already exists' do
        first = described_class.apply(participant: participant, effect: effect, duration_rounds: 2)
        second = described_class.apply(participant: participant, effect: effect, duration_rounds: 5)

        expect(second.id).to eq first.id
        second.refresh
        # Duration should NOT be updated
        expect(second.expires_at_round).to eq 3 # original: round 1 + 2
      end
    end
  end

  describe '.apply_by_name' do
    it 'applies effect by name' do
      effect = create_status_effect(name: 'snared')

      result = described_class.apply_by_name(
        participant: participant,
        effect_name: 'snared',
        duration_rounds: 2
      )

      expect(result).to be_a(ParticipantStatusEffect)
      expect(result.status_effect_id).to eq effect.id
    end

    it 'returns nil for unknown effect name' do
      result = described_class.apply_by_name(
        participant: participant,
        effect_name: 'nonexistent_effect',
        duration_rounds: 2
      )

      expect(result).to be_nil
    end
  end

  describe '.active_effects' do
    it 'returns only active (non-expired) effects' do
      effect1 = create_status_effect(name: 'active_effect')
      effect2 = create_status_effect(name: 'expired_effect')

      # Active effect (expires at round 5, current is 1)
      ParticipantStatusEffect.create(
        fight_participant_id: participant.id,
        status_effect_id: effect1.id,
        expires_at_round: 5,
        applied_at_round: 1,
        stack_count: 1
      )

      # Expired effect (expires at round 1, current is 1)
      ParticipantStatusEffect.create(
        fight_participant_id: participant.id,
        status_effect_id: effect2.id,
        expires_at_round: 1,
        applied_at_round: 0,
        stack_count: 1
      )

      active = described_class.active_effects(participant)
      expect(active.length).to eq 1
      expect(active.first.status_effect.name).to eq 'active_effect'
    end

    it 'returns empty array for nil participant' do
      expect(described_class.active_effects(nil)).to eq []
    end
  end

  describe '.has_effect?' do
    it 'returns true when participant has the effect' do
      effect = create_status_effect(name: 'test_effect')
      described_class.apply(participant: participant, effect: effect, duration_rounds: 3)

      expect(described_class.has_effect?(participant, 'test_effect')).to be true
    end

    it 'returns false when participant does not have the effect' do
      expect(described_class.has_effect?(participant, 'nonexistent')).to be false
    end

    it 'returns false for expired effects' do
      effect = create_status_effect(name: 'expired_test')
      ParticipantStatusEffect.create(
        fight_participant_id: participant.id,
        status_effect_id: effect.id,
        expires_at_round: 1, # expires at current round
        applied_at_round: 0,
        stack_count: 1
      )

      expect(described_class.has_effect?(participant, 'expired_test')).to be false
    end
  end

  describe '.remove_effect' do
    it 'removes the specified effect' do
      effect = create_status_effect(name: 'removable_effect')
      described_class.apply(participant: participant, effect: effect, duration_rounds: 5)

      expect(described_class.has_effect?(participant, 'removable_effect')).to be true

      result = described_class.remove_effect(participant, 'removable_effect')

      expect(result).to be true
      expect(described_class.has_effect?(participant, 'removable_effect')).to be false
    end

    it 'returns false for unknown effect' do
      result = described_class.remove_effect(participant, 'nonexistent')
      expect(result).to be false
    end
  end

  describe '.remove_all_effects' do
    it 'removes all effects from participant' do
      effect1 = create_status_effect(name: 'effect_one')
      effect2 = create_status_effect(name: 'effect_two')

      described_class.apply(participant: participant, effect: effect1, duration_rounds: 3)
      described_class.apply(participant: participant, effect: effect2, duration_rounds: 3)

      count = described_class.remove_all_effects(participant)

      expect(count).to eq 2
      expect(described_class.active_effects(participant)).to be_empty
    end
  end

  describe '.expire_effects' do
    it 'removes expired effects from a fight' do
      effect = create_status_effect(name: 'soon_expired')

      # Create effect that expires at round 1 (current round)
      ParticipantStatusEffect.create(
        fight_participant_id: participant.id,
        status_effect_id: effect.id,
        expires_at_round: 1,
        applied_at_round: 0,
        stack_count: 1
      )

      deleted_count = described_class.expire_effects(fight)
      expect(deleted_count).to eq 1
    end
  end

  describe '.cleanse_effects' do
    it 'removes cleansable debuffs' do
      cleansable = create_status_effect(name: 'cleansable_debuff', is_buff: false, cleansable: true)
      non_cleansable = create_status_effect(name: 'permanent_debuff', is_buff: false, cleansable: false)
      buff = create_status_effect(name: 'helpful_buff', is_buff: true, cleansable: true)

      described_class.apply(participant: participant, effect: cleansable, duration_rounds: 5)
      described_class.apply(participant: participant, effect: non_cleansable, duration_rounds: 5)
      described_class.apply(participant: participant, effect: buff, duration_rounds: 5)

      removed = described_class.cleanse_effects(participant)

      expect(removed).to include('cleansable_debuff')
      expect(removed).not_to include('permanent_debuff')
      expect(removed).not_to include('helpful_buff')
      expect(described_class.has_effect?(participant, 'cleansable_debuff')).to be false
      expect(described_class.has_effect?(participant, 'permanent_debuff')).to be true
      expect(described_class.has_effect?(participant, 'helpful_buff')).to be true
    end
  end

  describe '.can_move?' do
    it 'returns true when no movement blocking effects' do
      expect(described_class.can_move?(participant)).to be true
    end

    it 'returns false when movement is blocked' do
      snare = create_status_effect(
        name: 'snare',
        effect_type: 'movement',
        mechanics: Sequel.pg_json_wrap({ 'can_move' => false })
      )
      described_class.apply(participant: participant, effect: snare, duration_rounds: 2)

      expect(described_class.can_move?(participant)).to be false
    end
  end

  describe '.incoming_damage_modifier' do
    it 'returns 0 with no effects' do
      expect(described_class.incoming_damage_modifier(participant)).to eq 0
    end

    it 'sums modifiers from multiple effects' do
      vuln = create_status_effect(
        name: 'vulnerability',
        effect_type: 'incoming_damage',
        mechanics: Sequel.pg_json_wrap({ 'modifier' => 5 })
      )
      resist = create_status_effect(
        name: 'resistance',
        effect_type: 'incoming_damage',
        mechanics: Sequel.pg_json_wrap({ 'modifier' => -3 })
      )

      described_class.apply(participant: participant, effect: vuln, duration_rounds: 3)
      described_class.apply(participant: participant, effect: resist, duration_rounds: 3)

      expect(described_class.incoming_damage_modifier(participant)).to eq 2 # 5 + (-3)
    end

    it 'multiplies by stack count' do
      stackable = create_status_effect(
        name: 'stacking_vuln',
        effect_type: 'incoming_damage',
        stacking_behavior: 'stack',
        max_stacks: 5,
        mechanics: Sequel.pg_json_wrap({ 'modifier' => 2 })
      )

      3.times do
        described_class.apply(participant: participant, effect: stackable, duration_rounds: 3)
      end

      expect(described_class.incoming_damage_modifier(participant)).to eq 6 # 2 * 3 stacks
    end
  end

  describe '.outgoing_damage_modifier' do
    it 'calculates outgoing damage modifiers' do
      empowered = create_status_effect(
        name: 'empowered',
        effect_type: 'outgoing_damage',
        mechanics: Sequel.pg_json_wrap({ 'modifier' => 10 })
      )
      described_class.apply(participant: participant, effect: empowered, duration_rounds: 3)

      expect(described_class.outgoing_damage_modifier(participant)).to eq 10
    end
  end

  describe '.can_use_main_action?' do
    it 'returns true when not stunned' do
      expect(described_class.can_use_main_action?(participant)).to be true
    end

    it 'returns false when stunned' do
      stun = create_status_effect(
        name: 'stunned',
        effect_type: 'action_restriction',
        mechanics: Sequel.pg_json_wrap({ 'blocks_main' => true })
      )
      described_class.apply(participant: participant, effect: stun, duration_rounds: 1)

      expect(described_class.can_use_main_action?(participant)).to be false
    end
  end

  describe '.can_use_tactical_action?' do
    it 'returns true when not dazed' do
      expect(described_class.can_use_tactical_action?(participant)).to be true
    end

    it 'returns false when dazed' do
      daze = create_status_effect(
        name: 'dazed',
        effect_type: 'action_restriction',
        mechanics: Sequel.pg_json_wrap({ 'blocks_tactical' => true })
      )
      described_class.apply(participant: participant, effect: daze, duration_rounds: 1)

      expect(described_class.can_use_tactical_action?(participant)).to be false
    end
  end

  describe '.absorb_damage_with_shields' do
    it 'absorbs damage with shield effect' do
      shield = create_status_effect(
        name: 'arcane_shield',
        effect_type: 'shield',
        mechanics: Sequel.pg_json_wrap({ 'types_absorbed' => ['all'] })
      )

      # Apply shield with 20 HP
      pse = described_class.apply(participant: participant, effect: shield, duration_rounds: 5, value: 20)
      pse.update(effect_value: 20)

      remaining = described_class.absorb_damage_with_shields(participant, 15, 'fire')

      expect(remaining).to eq 0 # shield absorbed all 15
      pse.refresh
      expect(pse.effect_value).to eq 5 # 20 - 15 absorbed
    end

    it 'destroys shield when depleted' do
      shield = create_status_effect(
        name: 'weak_shield',
        effect_type: 'shield',
        mechanics: Sequel.pg_json_wrap({ 'types_absorbed' => ['all'] })
      )

      pse = described_class.apply(participant: participant, effect: shield, duration_rounds: 5, value: 10)
      pse.update(effect_value: 10)

      remaining = described_class.absorb_damage_with_shields(participant, 25, 'physical')

      expect(remaining).to eq 15 # 25 - 10 absorbed
      expect(described_class.has_effect?(participant, 'weak_shield')).to be false
    end

    it 'respects damage type filtering' do
      fire_shield = create_status_effect(
        name: 'fire_shield',
        effect_type: 'shield',
        mechanics: Sequel.pg_json_wrap({ 'types_absorbed' => ['fire'] })
      )

      pse = described_class.apply(participant: participant, effect: fire_shield, duration_rounds: 5, value: 50)
      pse.update(effect_value: 50)

      # Cold damage should not be absorbed
      remaining = described_class.absorb_damage_with_shields(participant, 20, 'cold')
      expect(remaining).to eq 20

      # Fire damage should be absorbed
      remaining = described_class.absorb_damage_with_shields(participant, 10, 'fire')
      expect(remaining).to eq 0
    end
  end

  describe '.damage_type_multiplier' do
    it 'returns 1.0 with no effects' do
      expect(described_class.damage_type_multiplier(participant, 'fire')).to eq 1.0
    end

    it 'applies vulnerability multiplier' do
      vuln = create_status_effect(
        name: 'fire_vulnerability',
        effect_type: 'incoming_damage',
        mechanics: Sequel.pg_json_wrap({ 'damage_type' => 'fire', 'multiplier' => 2.0 })
      )
      described_class.apply(participant: participant, effect: vuln, duration_rounds: 3)

      expect(described_class.damage_type_multiplier(participant, 'fire')).to eq 2.0
      expect(described_class.damage_type_multiplier(participant, 'cold')).to eq 1.0
    end

    it 'applies resistance multiplier' do
      resist = create_status_effect(
        name: 'cold_resistance',
        effect_type: 'incoming_damage',
        mechanics: Sequel.pg_json_wrap({ 'damage_type' => 'cold', 'multiplier' => 0.5 })
      )
      described_class.apply(participant: participant, effect: resist, duration_rounds: 3)

      expect(described_class.damage_type_multiplier(participant, 'cold')).to eq 0.5
    end
  end

  describe '.flat_damage_reduction' do
    it 'calculates flat reduction' do
      armor = create_status_effect(
        name: 'armor',
        effect_type: 'damage_reduction',
        mechanics: Sequel.pg_json_wrap({ 'types' => ['physical'], 'flat_reduction' => 5 })
      )
      described_class.apply(participant: participant, effect: armor, duration_rounds: 10)

      expect(described_class.flat_damage_reduction(participant, 'physical')).to eq 5
      expect(described_class.flat_damage_reduction(participant, 'fire')).to eq 0
    end
  end

  describe '.overall_protection' do
    it 'returns 0 with no protection effects' do
      expect(described_class.overall_protection(participant, 'physical')).to eq 0
    end

    it 'calculates protection for all damage types' do
      protection = create_status_effect(
        name: 'iron_will',
        effect_type: 'protection',
        mechanics: Sequel.pg_json_wrap({ 'types' => ['all'], 'flat_protection' => 5 })
      )
      described_class.apply(participant: participant, effect: protection, duration_rounds: 10)

      expect(described_class.overall_protection(participant, 'physical')).to eq 5
      expect(described_class.overall_protection(participant, 'fire')).to eq 5
      expect(described_class.overall_protection(participant, 'cold')).to eq 5
    end

    it 'calculates type-specific protection' do
      fire_ward = create_status_effect(
        name: 'fire_ward',
        effect_type: 'protection',
        mechanics: Sequel.pg_json_wrap({ 'types' => ['fire'], 'flat_protection' => 10 })
      )
      described_class.apply(participant: participant, effect: fire_ward, duration_rounds: 10)

      expect(described_class.overall_protection(participant, 'fire')).to eq 10
      expect(described_class.overall_protection(participant, 'cold')).to eq 0
      expect(described_class.overall_protection(participant, 'physical')).to eq 0
    end

    it 'stacks multiple protection effects additively' do
      general = create_status_effect(
        name: 'general_protection',
        effect_type: 'protection',
        mechanics: Sequel.pg_json_wrap({ 'types' => ['all'], 'flat_protection' => 3 })
      )
      fire_specific = create_status_effect(
        name: 'fire_protection',
        effect_type: 'protection',
        mechanics: Sequel.pg_json_wrap({ 'types' => ['fire'], 'flat_protection' => 5 })
      )

      described_class.apply(participant: participant, effect: general, duration_rounds: 10)
      described_class.apply(participant: participant, effect: fire_specific, duration_rounds: 10)

      # Fire damage gets both protections
      expect(described_class.overall_protection(participant, 'fire')).to eq 8
      # Other types only get general protection
      expect(described_class.overall_protection(participant, 'cold')).to eq 3
    end

    it 'multiplies by stack count' do
      stackable = create_status_effect(
        name: 'stacking_protection',
        effect_type: 'protection',
        stacking_behavior: 'stack',
        max_stacks: 5,
        mechanics: Sequel.pg_json_wrap({ 'types' => ['all'], 'flat_protection' => 2 })
      )

      3.times do
        described_class.apply(participant: participant, effect: stackable, duration_rounds: 3)
      end

      expect(described_class.overall_protection(participant, 'physical')).to eq 6 # 2 * 3 stacks
    end
  end

  describe '.must_target' do
    it 'returns nil when not taunted' do
      expect(described_class.must_target(participant)).to be_nil
    end

    it 'returns taunter ID when taunted' do
      taunter_ci = create(:character_instance, current_room: room, reality: reality)
      taunter = create(:fight_participant, fight: fight, character_instance: taunter_ci)

      taunt = create_status_effect(
        name: 'taunted',
        effect_type: 'targeting_restriction',
        mechanics: Sequel.pg_json_wrap({ 'must_target_id' => taunter.id })
      )
      described_class.apply(participant: participant, effect: taunt, duration_rounds: 2)

      expect(described_class.must_target(participant)).to eq taunter.id
    end
  end

  describe '.is_grappled?' do
    it 'returns false when not grappled' do
      expect(described_class.is_grappled?(participant)).to be false
    end

    it 'returns true when grappled' do
      grapple = create_status_effect(name: 'grappled', effect_type: 'grapple')
      described_class.apply(participant: participant, effect: grapple, duration_rounds: 2)

      expect(described_class.is_grappled?(participant)).to be true
    end
  end

  describe '.movement_speed_multiplier' do
    it 'returns 1.0 with no effects' do
      expect(described_class.movement_speed_multiplier(participant)).to eq 1.0
    end

    it 'applies speed modifiers' do
      slow = create_status_effect(
        name: 'slowed',
        effect_type: 'movement',
        mechanics: Sequel.pg_json_wrap({ 'speed_multiplier' => 0.5 })
      )
      described_class.apply(participant: participant, effect: slow, duration_rounds: 3)

      expect(described_class.movement_speed_multiplier(participant)).to eq 0.5
    end
  end

  describe '.is_prone?' do
    it 'returns false when not prone' do
      expect(described_class.is_prone?(participant)).to be false
    end

    it 'returns true when prone' do
      prone = create_status_effect(
        name: 'prone',
        effect_type: 'movement',
        mechanics: Sequel.pg_json_wrap({ 'prone' => true, 'stand_cost' => 2 })
      )
      described_class.apply(participant: participant, effect: prone, duration_rounds: 1)

      expect(described_class.is_prone?(participant)).to be true
    end
  end

  describe '.stand_cost' do
    it 'returns 0 when not prone' do
      expect(described_class.stand_cost(participant)).to eq 0
    end

    it 'returns stand cost when prone' do
      prone = create_status_effect(
        name: 'knocked_down',
        effect_type: 'movement',
        mechanics: Sequel.pg_json_wrap({ 'prone' => true, 'stand_cost' => 3 })
      )
      described_class.apply(participant: participant, effect: prone, duration_rounds: 1)

      expect(described_class.stand_cost(participant)).to eq 3
    end
  end

  describe '.healing_modifier' do
    it 'returns 1.0 with no effects' do
      expect(described_class.healing_modifier(participant)).to eq 1.0
    end

    it 'applies healing modifiers' do
      anti_heal = create_status_effect(
        name: 'grievous_wound',
        effect_type: 'healing',
        mechanics: Sequel.pg_json_wrap({ 'multiplier' => 0.0 })
      )
      described_class.apply(participant: participant, effect: anti_heal, duration_rounds: 3)

      expect(described_class.healing_modifier(participant)).to eq 0.0
    end
  end

  describe '.calculate_dot_tick_segments' do
    it 'distributes ticks evenly across 100 segments' do
      segments = described_class.calculate_dot_tick_segments(10)

      expect(segments.length).to eq 10
      expect(segments.first).to eq 10
      expect(segments.last).to eq 100
    end

    it 'returns empty array for zero damage' do
      expect(described_class.calculate_dot_tick_segments(0)).to eq []
    end

    it 'respects applied_at_segment' do
      # If applied at segment 50, only ticks after 50 count
      segments = described_class.calculate_dot_tick_segments(10, 50)

      expect(segments.all? { |s| s > 50 }).to be true
    end
  end

  describe '.effects_for_display' do
    it 'returns display info for all active effects' do
      effect = create_status_effect(name: 'visible_effect', is_buff: true)
      described_class.apply(participant: participant, effect: effect, duration_rounds: 3)

      display = described_class.effects_for_display(participant)

      expect(display.length).to eq 1
      expect(display.first[:name]).to eq 'visible_effect'
      expect(display.first[:is_buff]).to be true
    end
  end

  describe '.grouped_effects' do
    it 'separates buffs and debuffs' do
      buff = create_status_effect(name: 'good_effect', is_buff: true)
      debuff = create_status_effect(name: 'bad_effect', is_buff: false)

      described_class.apply(participant: participant, effect: buff, duration_rounds: 3)
      described_class.apply(participant: participant, effect: debuff, duration_rounds: 3)

      grouped = described_class.grouped_effects(participant)

      expect(grouped[:buffs].length).to eq 1
      expect(grouped[:debuffs].length).to eq 1
      expect(grouped[:buffs].first[:name]).to eq 'good_effect'
      expect(grouped[:debuffs].first[:name]).to eq 'bad_effect'
    end
  end
end
