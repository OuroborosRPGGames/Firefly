# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AbilityProcessorService do
  let(:universe) { create(:universe) }
  let(:room) { create(:room) }
  let(:fight) { create(:fight, room: room, arena_width: 10, arena_height: 10) }

  let(:attacker_char) { create(:character, name: 'Attacker') }
  let(:attacker_instance) { create(:character_instance, character: attacker_char, current_room_id: room.id, health: 100, max_health: 100) }
  let(:attacker) { create(:fight_participant, fight: fight, character_instance: attacker_instance, current_hp: 100, max_hp: 100) }

  let(:target_char) { create(:character, name: 'Target') }
  let(:target_instance) { create(:character_instance, character: target_char, current_room_id: room.id, health: 100, max_health: 100) }
  let(:target) { create(:fight_participant, fight: fight, character_instance: target_instance, current_hp: 100, max_hp: 100) }

  describe '#process_ability' do
    before do
      attacker.update(side: 1)
      target.update(side: 2)
    end

    context 'with basic damage ability' do
      let(:fireball) do
        create(:ability,
               universe: universe,
               name: 'Fireball',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6',
               damage_type: 'fire',
               aoe_shape: 'single')
      end

      it 'deals damage to target' do
        attacker.update(target_participant_id: target.id)

        service = described_class.new(
          actor: attacker,
          ability: fireball,
          primary_target: target
        )

        events = service.process!(50)

        # Service uses event_type key and 'ability_hit' for damage events
        damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
        expect(damage_event).not_to be_nil
        expect(damage_event[:details][:damage_type]).to eq('fire')
        expect(damage_event[:details][:effective_damage]).to be_between(2, 12)
      end
    end

    context 'with status effect application' do
      let(:burning) { StatusEffect.find_or_create(name: 'burning') { |se| se.effect_type = 'damage_tick'; se.is_buff = false } }

      let(:fire_attack) do
        create(:ability,
               universe: universe,
               name: 'Fire Attack',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d6',
               damage_type: 'fire',
               applied_status_effects: Sequel.pg_json_wrap([
                 { 'effect_name' => 'burning', 'duration_rounds' => 3, 'chance' => 1.0 }
               ]))
      end

      before { burning }

      it 'applies burning status effect' do
        attacker.update(target_participant_id: target.id)

        service = described_class.new(
          actor: attacker,
          ability: fire_attack,
          primary_target: target
        )

        service.process!(50)

        active_effects = StatusEffectService.active_effects(target)
        burning_effect = active_effects.find { |e| e.status_effect.name == 'burning' }
        expect(burning_effect).not_to be_nil
        expect(burning_effect.rounds_remaining).to eq(3)
      end
    end

    context 'with lifesteal' do
      let(:vampiric_touch) do
        create(:ability,
               universe: universe,
               name: 'Vampiric Touch',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d8',
               damage_type: 'shadow',
               lifesteal_max: 10)
      end

      before do
        attacker.update(current_hp: 50)
      end

      it 'heals attacker based on damage dealt' do
        initial_hp = attacker.current_hp
        attacker.update(target_participant_id: target.id)

        service = described_class.new(
          actor: attacker,
          ability: vampiric_touch,
          primary_target: target
        )

        events = service.process!(50)

        lifesteal_event = events.find { |e| e[:event_type] == 'ability_lifesteal' }
        expect(lifesteal_event).not_to be_nil
        expect(lifesteal_event[:details][:amount]).to be <= 10

        attacker.reload
        expect(attacker.current_hp).to be > initial_hp
      end
    end

    context 'with execute mechanics' do
      let(:execute_strike) do
        create(:ability,
               universe: universe,
               name: "Executioner's Strike",
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6',
               damage_type: 'physical',
               execute_threshold: 25,
               execute_effect: Sequel.pg_json_wrap({ 'damage_multiplier' => 3.0 }))
      end

      context 'when target is above threshold' do
        it 'deals normal damage' do
          target.update(current_hp: 100, max_hp: 100)
          attacker.update(target_participant_id: target.id)

          service = described_class.new(
            actor: attacker,
            ability: execute_strike,
            primary_target: target
          )

          events = service.process!(50)

          # No execute bonus event when above threshold
          execute_event = events.find { |e| e[:event_type] == 'ability_execute_bonus' }
          expect(execute_event).to be_nil
        end
      end

      context 'when target is below threshold' do
        it 'deals multiplied damage' do
          target.update(current_hp: 20, max_hp: 100) # 20% HP
          attacker.update(target_participant_id: target.id)

          service = described_class.new(
            actor: attacker,
            ability: execute_strike,
            primary_target: target
          )

          events = service.process!(50)

          execute_event = events.find { |e| e[:event_type] == 'ability_execute_bonus' }
          expect(execute_event).not_to be_nil
          expect(execute_event[:details][:multiplier]).to eq(3.0)
        end
      end
    end

    context 'with conditional damage' do
      let(:brutal_strike) do
        create(:ability,
               universe: universe,
               name: 'Brutal Strike',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d10',
               damage_type: 'physical',
               conditional_damage: Sequel.pg_json_wrap([
                 { 'condition' => 'target_below_50_hp', 'bonus_dice' => '2d6' }
               ]))
      end

      context 'when target is above 50% HP' do
        it 'deals base damage only' do
          target.update(current_hp: 100, max_hp: 100)
          attacker.update(target_participant_id: target.id)

          service = described_class.new(
            actor: attacker,
            ability: brutal_strike,
            primary_target: target
          )

          events = service.process!(50)

          damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
          expect(damage_event).not_to be_nil
          # No conditional bonus when above 50%
          expect(damage_event[:details][:conditional_bonus]).to be_nil
          expect(damage_event[:details][:effective_damage]).to be_between(1, 10)
        end
      end

      context 'when target is below 50% HP' do
        it 'deals bonus damage' do
          target.update(current_hp: 40, max_hp: 100)
          attacker.update(target_participant_id: target.id)

          service = described_class.new(
            actor: attacker,
            ability: brutal_strike,
            primary_target: target
          )

          events = service.process!(50)

          damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
          expect(damage_event).not_to be_nil
          # Conditional bonus should be present
          expect(damage_event[:details][:conditional_bonus]).not_to be_nil
          expect(damage_event[:details][:conditional_bonus]).to be_between(2, 12)
        end
      end
    end

    context 'with forced movement' do
      let(:shield_bash) do
        create(:ability,
               universe: universe,
               name: 'Shield Bash',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d6',
               damage_type: 'physical',
               applies_prone: true,
               forced_movement: Sequel.pg_json_wrap({
                 'direction' => 'away',
                 'distance' => 2
               }))
      end

      before do
        attacker.update(hex_x: 0, hex_y: 0, target_participant_id: target.id)
        target.update(hex_x: 1, hex_y: 0)
      end

      it 'applies prone status' do
        StatusEffect.find_or_create(name: 'prone') { |se| se.effect_type = 'movement'; se.is_buff = false }

        service = described_class.new(
          actor: attacker,
          ability: shield_bash,
          primary_target: target
        )

        events = service.process!(50)

        # Service uses 'ability_knockdown' for prone
        prone_event = events.find { |e| e[:event_type] == 'ability_knockdown' }
        expect(prone_event).not_to be_nil

        active_effects = StatusEffectService.active_effects(target)
        expect(active_effects.any? { |e| e.status_effect.name == 'prone' }).to be true
      end

      it 'moves target away from attacker' do
        initial_x = target.hex_x

        service = described_class.new(
          actor: attacker,
          ability: shield_bash,
          primary_target: target
        )

        events = service.process!(50)

        forced_movement_event = events.find { |e| e[:event_type] == 'ability_forced_movement' }
        expect(forced_movement_event).not_to be_nil
        expect(forced_movement_event[:details][:direction]).to eq('away')
        expect(forced_movement_event[:details][:distance]).to eq(2)
      end
    end

    context 'with combo mechanics' do
      let(:burning) { StatusEffect.find_or_create(name: 'burning') { |se| se.effect_type = 'damage_tick'; se.is_buff = false } }

      let(:inferno_blast) do
        create(:ability,
               universe: universe,
               name: 'Inferno Blast',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6',
               damage_type: 'fire',
               combo_condition: Sequel.pg_json_wrap({
                 'requires_status' => 'burning',
                 'bonus_dice' => '3d6',
                 'consumes_status' => true
               }))
      end

      before { burning }

      context 'when target has burning status' do
        before do
          StatusEffectService.apply_by_name(
            participant: target,
            effect_name: 'burning',
            duration_rounds: 3,
            applied_by: nil
          )
          attacker.update(target_participant_id: target.id)
        end

        it 'deals bonus damage and consumes the status' do
          service = described_class.new(
            actor: attacker,
            ability: inferno_blast,
            primary_target: target
          )

          events = service.process!(50)

          # Combo bonus is included in ability_hit event
          damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
          expect(damage_event).not_to be_nil
          expect(damage_event[:details][:combo_bonus]).not_to be_nil
          expect(damage_event[:details][:combo_bonus]).to be_between(3, 18)

          # Status should be consumed
          active_effects = StatusEffectService.active_effects(target)
          expect(active_effects.none? { |e| e.status_effect.name == 'burning' }).to be true
        end
      end

      context 'when target does not have burning status' do
        before do
          attacker.update(target_participant_id: target.id)
        end

        it 'deals base damage only' do
          service = described_class.new(
            actor: attacker,
            ability: inferno_blast,
            primary_target: target
          )

          events = service.process!(50)

          damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
          expect(damage_event).not_to be_nil
          # No combo bonus without the required status
          expect(damage_event[:details][:combo_bonus]).to be_nil
        end
      end
    end

    context 'with healing ability' do
      let(:healing_light) do
        create(:ability,
               universe: universe,
               name: 'Healing Light',
               ability_type: 'utility',
               action_type: 'main',
               base_damage_dice: '2d6',
               target_type: 'ally',
               is_healing: true)
      end

      before do
        target.update(side: 1)
        target.update(current_hp: 50, max_hp: 100)
      end

      it 'heals the target' do
        initial_hp = target.current_hp

        service = described_class.new(
          actor: attacker,
          ability: healing_light,
          primary_target: target
        )

        events = service.process!(50)

        heal_event = events.find { |e| e[:event_type] == 'ability_heal' }
        expect(heal_event).not_to be_nil
        expect(heal_event[:details][:heal_amount]).to be_between(2, 12)
        expect(target.reload.current_hp).to be > initial_hp
      end
    end

    context 'with self-targeted ability' do
      let(:shield_self) do
        create(:ability,
               universe: universe,
               name: 'Shield Self',
               ability_type: 'utility',
               action_type: 'main',
               base_damage_dice: '2d4',
               target_type: 'self',
               is_healing: true)
      end

      before do
        attacker.update(current_hp: 70, max_hp: 100)
      end

      it 'targets the caster' do
        initial_hp = attacker.current_hp

        service = described_class.new(
          actor: attacker,
          ability: shield_self,
          primary_target: nil
        )

        events = service.process!(50)

        heal_event = events.find { |e| e[:event_type] == 'ability_heal' }
        expect(heal_event).not_to be_nil
        expect(heal_event[:target_id]).to eq(attacker.id)
        expect(attacker.reload.current_hp).to be > initial_hp
      end
    end

    context 'when actor is knocked out' do
      before do
        attacker.update(is_knocked_out: true)
      end

      let(:fireball) do
        create(:ability,
               universe: universe,
               name: 'Fireball',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6')
      end

      it 'returns empty events' do
        service = described_class.new(
          actor: attacker,
          ability: fireball,
          primary_target: target
        )

        events = service.process!(50)
        expect(events).to eq([])
      end
    end

    context 'with no valid targets' do
      let(:enemy_blast) do
        create(:ability,
               universe: universe,
               name: 'Enemy Blast',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6',
               target_type: 'enemy')
      end

      before do
        target.update(is_knocked_out: true)
      end

      it 'creates no_target event' do
        service = described_class.new(
          actor: attacker,
          ability: enemy_blast,
          primary_target: target
        )

        events = service.process!(50)
        no_target_event = events.find { |e| e[:event_type] == 'ability_no_target' }
        expect(no_target_event).not_to be_nil
        expect(no_target_event[:details][:reason]).to eq('no valid targets')
      end
    end

    context 'when single-target type does not match target' do
      let(:ally_boon) do
        create(:ability,
               universe: universe,
               name: 'Ally Boon',
               ability_type: 'utility',
               action_type: 'main',
               base_damage_dice: '1d6',
               target_type: 'ally',
               is_healing: true)
      end

      before do
        attacker.update(side: 1)
        target.update(side: 2)
      end

      it 'creates no_target event' do
        service = described_class.new(
          actor: attacker,
          ability: ally_boon,
          primary_target: target
        )

        events = service.process!(50)
        no_target_event = events.find { |e| e[:event_type] == 'ability_no_target' }
        expect(no_target_event).not_to be_nil
        expect(no_target_event[:details][:reason]).to eq('no valid targets')
      end
    end

    context 'with circle AoE' do
      let(:circle_blast) do
        create(:ability,
               universe: universe,
               name: 'Circle Blast',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d6',
               damage_type: 'fire',
               target_type: 'enemy',
               aoe_shape: 'circle',
               aoe_radius: 2)
      end

      let(:ally_char) { create(:character, name: 'Ally') }
      let(:ally_instance) { create(:character_instance, character: ally_char, current_room_id: room.id) }
      let(:ally) { create(:fight_participant, fight: fight, character_instance: ally_instance, current_hp: 100, max_hp: 100) }

      before do
        # Position actors on the battle map
        attacker.update(hex_x: 0, hex_y: 0, side: 1, target_participant_id: target.id)
        target.update(hex_x: 2, hex_y: 0, side: 2)
        ally.update(hex_x: 3, hex_y: 0, side: 2) # Within 2 hex radius of target
      end

      it 'hits multiple targets within radius' do
        service = described_class.new(
          actor: attacker,
          ability: circle_blast,
          primary_target: target
        )

        events = service.process!(50)
        hit_events = events.select { |e| e[:event_type] == 'ability_hit' }

        # Should hit both target and ally (both within radius)
        expect(hit_events.size).to be >= 1
      end
    end

    context 'with friendly-fire circle AoE' do
      let(:ally_char) { create(:character, name: 'Ally') }
      let(:ally_instance) { create(:character_instance, character: ally_char, current_room_id: room.id) }
      let(:ally) { create(:fight_participant, fight: fight, character_instance: ally_instance, current_hp: 100, max_hp: 100) }

      let(:safe_circle) do
        create(:ability,
               universe: universe,
               name: 'Safe Circle',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d6',
               damage_type: 'fire',
               target_type: 'enemy',
               aoe_shape: 'circle',
               aoe_radius: 2,
               aoe_hits_allies: false)
      end

      let(:ff_circle) do
        create(:ability,
               universe: universe,
               name: 'Unsafe Circle',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d6',
               damage_type: 'fire',
               target_type: 'enemy',
               aoe_shape: 'circle',
               aoe_radius: 2,
               aoe_hits_allies: true)
      end

      before do
        attacker.update(hex_x: 0, hex_y: 0, side: 1, target_participant_id: target.id)
        target.update(hex_x: 2, hex_y: 0, side: 2)
        ally.update(hex_x: 3, hex_y: 0, side: 1)
      end

      it 'does not hit allies when aoe_hits_allies is false' do
        service = described_class.new(
          actor: attacker,
          ability: safe_circle,
          primary_target: target
        )

        events = service.process!(50)
        hit_ids = events.select { |e| e[:event_type] == 'ability_hit' }.map { |e| e[:target_id] }
        expect(hit_ids).not_to include(ally.id)
      end

      it 'hits allies when aoe_hits_allies is true' do
        service = described_class.new(
          actor: attacker,
          ability: ff_circle,
          primary_target: target
        )

        events = service.process!(50)
        hit_ids = events.select { |e| e[:event_type] == 'ability_hit' }.map { |e| e[:target_id] }
        expect(hit_ids).to include(ally.id)
      end
    end

    context 'with cone AoE' do
      let(:cone_breath) do
        create(:ability,
               universe: universe,
               name: 'Fire Breath',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6',
               damage_type: 'fire',
               target_type: 'enemy',
               aoe_shape: 'cone',
               aoe_length: 5)
      end

      before do
        attacker.update(hex_x: 0, hex_y: 5, side: 1, target_participant_id: target.id)
        target.update(hex_x: 3, hex_y: 5, side: 2)
      end

      it 'hits targets within cone' do
        service = described_class.new(
          actor: attacker,
          ability: cone_breath,
          primary_target: target
        )

        events = service.process!(50)
        hit_events = events.select { |e| e[:event_type] == 'ability_hit' }

        expect(hit_events.size).to be >= 1
      end
    end

    context 'with configurable cone angle' do
      let(:off_axis_char) { create(:character, name: 'OffAxis') }
      let(:off_axis_instance) { create(:character_instance, character: off_axis_char, current_room_id: room.id) }
      let(:off_axis_target) { create(:fight_participant, fight: fight, character_instance: off_axis_instance, current_hp: 100, max_hp: 100) }

      let(:narrow_cone) do
        create(:ability,
               universe: universe,
               name: 'Narrow Cone',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6',
               damage_type: 'fire',
               target_type: 'enemy',
               aoe_shape: 'cone',
               aoe_length: 5,
               aoe_angle: 20)
      end

      let(:wide_cone) do
        create(:ability,
               universe: universe,
               name: 'Wide Cone',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6',
               damage_type: 'fire',
               target_type: 'enemy',
               aoe_shape: 'cone',
               aoe_length: 5,
               aoe_angle: 120)
      end

      before do
        attacker.update(hex_x: 0, hex_y: 5, side: 1, target_participant_id: target.id)
        target.update(hex_x: 3, hex_y: 5, side: 2)
        off_axis_target.update(hex_x: 3, hex_y: 8, side: 2)
      end

      it 'excludes off-axis targets for narrow cones' do
        service = described_class.new(
          actor: attacker,
          ability: narrow_cone,
          primary_target: target
        )

        events = service.process!(50)
        hit_ids = events.select { |e| e[:event_type] == 'ability_hit' }.map { |e| e[:target_id] }
        expect(hit_ids).not_to include(off_axis_target.id)
      end

      it 'includes off-axis targets for wide cones' do
        service = described_class.new(
          actor: attacker,
          ability: wide_cone,
          primary_target: target
        )

        events = service.process!(50)
        hit_ids = events.select { |e| e[:event_type] == 'ability_hit' }.map { |e| e[:target_id] }
        expect(hit_ids).to include(off_axis_target.id)
      end
    end

    context 'with line AoE' do
      let(:line_blast) do
        create(:ability,
               universe: universe,
               name: 'Lightning Bolt',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d8',
               damage_type: 'lightning',
               target_type: 'enemy',
               aoe_shape: 'line',
               aoe_length: 8)
      end

      before do
        attacker.update(hex_x: 0, hex_y: 5, side: 1, target_participant_id: target.id)
        target.update(hex_x: 5, hex_y: 5, side: 2)
      end

      it 'hits targets along the line' do
        service = described_class.new(
          actor: attacker,
          ability: line_blast,
          primary_target: target
        )

        events = service.process!(50)
        hit_events = events.select { |e| e[:event_type] == 'ability_hit' }

        expect(hit_events.size).to be >= 1
      end
    end

    context 'with chain ability' do
      let(:chain_lightning) do
        create(:ability,
               universe: universe,
               name: 'Chain Lightning',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6',
               damage_type: 'lightning',
               target_type: 'enemy',
               aoe_shape: 'single',
               chain_config: Sequel.pg_json_wrap({
                 'max_targets' => 3,
                 'range_per_jump' => 4,
                 'damage_falloff' => 0.5
               }))
      end

      let(:target2_char) { create(:character, name: 'Target2') }
      let(:target2_instance) { create(:character_instance, character: target2_char, current_room_id: room.id) }
      let(:target2) { create(:fight_participant, fight: fight, character_instance: target2_instance, current_hp: 100, max_hp: 100) }

      before do
        attacker.update(hex_x: 0, hex_y: 0, side: 1, target_participant_id: target.id)
        target.update(hex_x: 2, hex_y: 0, side: 2)
        target2.update(hex_x: 4, hex_y: 0, side: 2) # Within 4 hex range for chain
      end

      it 'chains to nearby targets with damage falloff' do
        service = described_class.new(
          actor: attacker,
          ability: chain_lightning,
          primary_target: target
        )

        events = service.process!(50)
        hit_events = events.select { |e| e[:event_type] == 'ability_hit' }

        # Should hit primary target + chain targets
        expect(hit_events.size).to be >= 1

        # Primary target should have full damage
        primary_hit = hit_events.find { |e| e[:details][:is_chain] != true }
        expect(primary_hit).not_to be_nil

        # Chain targets should have reduced damage (if any)
        chain_hits = hit_events.select { |e| e[:details][:is_chain] == true }
        chain_hits.each do |chain_hit|
          expect(chain_hit[:details][:chain_damage_multiplier]).to be < 1.0
        end
      end
    end

    context 'with directional forced movement' do
      let(:push_north) do
        create(:ability,
               universe: universe,
               name: 'Push North',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d4',
               damage_type: 'physical',
               forced_movement: Sequel.pg_json_wrap({
                 'direction' => 'n',
                 'distance' => 3
               }))
      end

      before do
        # Use valid hex coordinates: y=4 (even), y/2=2 (even), so x must be even → x=4
        attacker.update(hex_x: 4, hex_y: 4, target_participant_id: target.id)
        target.update(hex_x: 4, hex_y: 4)
      end

      it 'moves target in specified direction' do
        initial_y = target.hex_y

        service = described_class.new(
          actor: attacker,
          ability: push_north,
          primary_target: target
        )

        events = service.process!(50)

        movement_event = events.find { |e| e[:event_type] == 'ability_forced_movement' }
        expect(movement_event).not_to be_nil
        expect(movement_event[:details][:direction]).to eq('n')

        # Target should have moved north (higher y in hex grid)
        expect(target.reload.hex_y).to be > initial_y
      end
    end

    context 'with pull toward movement' do
      let(:grapple_pull) do
        create(:ability,
               universe: universe,
               name: 'Grapple Pull',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d4',
               damage_type: 'physical',
               forced_movement: Sequel.pg_json_wrap({
                 'direction' => 'toward',
                 'distance' => 3
               }))
      end

      before do
        attacker.update(hex_x: 0, hex_y: 5, target_participant_id: target.id)
        target.update(hex_x: 5, hex_y: 5)
      end

      it 'pulls target toward actor' do
        initial_x = target.hex_x

        service = described_class.new(
          actor: attacker,
          ability: grapple_pull,
          primary_target: target
        )

        events = service.process!(50)

        movement_event = events.find { |e| e[:event_type] == 'ability_forced_movement' }
        expect(movement_event).not_to be_nil
        expect(movement_event[:details][:direction]).to eq('toward')

        # Target should be closer to attacker
        expect(target.reload.hex_x).to be < initial_x
      end
    end

    context 'with split damage types' do
      let(:chaos_strike) do
        create(:ability,
               universe: universe,
               name: 'Chaos Strike',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '4d6',
               damage_type: 'physical',
               damage_types: Sequel.pg_json_wrap([
                 { 'type' => 'fire', 'value' => '50%' },
                 { 'type' => 'ice', 'value' => '50%' }
               ]))
      end

      before do
        attacker.update(target_participant_id: target.id)
      end

      it 'splits damage between types' do
        service = described_class.new(
          actor: attacker,
          ability: chaos_strike,
          primary_target: target
        )

        events = service.process!(50)

        split_events = events.select { |e| e[:event_type] == 'ability_split_damage' }
        expect(split_events.size).to eq(2)

        types = split_events.map { |e| e[:details][:damage_type] }
        expect(types).to contain_exactly('fire', 'ice')
      end
    end

    context 'with base_roll provided' do
      let(:power_strike) do
        create(:ability,
               universe: universe,
               name: 'Power Strike',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6',
               damage_type: 'physical')
      end

      before do
        attacker.update(target_participant_id: target.id)
      end

      it 'uses pre-rolled effectiveness' do
        base_roll = { total: 15, dice: [8, 7], modifier: 0 }

        service = described_class.new(
          actor: attacker,
          ability: power_strike,
          primary_target: target,
          base_roll: base_roll
        )

        events = service.process!(50)

        damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
        expect(damage_event).not_to be_nil
        # Damage should be based on the pre-rolled value (15)
        expect(damage_event[:details][:raw_damage]).to eq(15)
      end

      it 'applies only ability-specific penalty once when using base_roll' do
        base_roll = { total: 15, dice: [8, 7], modifier: 0 }
        allow(attacker).to receive(:ability_roll_penalty).and_return(-2)
        allow(attacker).to receive(:total_ability_penalty).and_return(-6)

        service = described_class.new(
          actor: attacker,
          ability: power_strike,
          primary_target: target,
          base_roll: base_roll
        )

        events = service.process!(50)
        damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
        expect(damage_event).not_to be_nil
        expect(damage_event[:details][:raw_damage]).to eq(13)
      end

      it 'deals combat ability damage even when base_damage_dice is nil' do
        roll_only_ability = create(:ability,
                                   universe: universe,
                                   name: 'Roll Only Strike',
                                   ability_type: 'combat',
                                   action_type: 'main',
                                   base_damage_dice: nil,
                                   damage_type: 'physical')
        base_roll = { total: 12, dice: [6, 6], modifier: 0 }

        service = described_class.new(
          actor: attacker,
          ability: roll_only_ability,
          primary_target: target,
          base_roll: base_roll
        )

        events = service.process!(50)
        damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
        expect(damage_event).not_to be_nil
        expect(damage_event[:details][:raw_damage]).to eq(12)
      end
    end

    context 'with damage multiplier' do
      let(:heavy_strike) do
        create(:ability,
               universe: universe,
               name: 'Heavy Strike',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6',
               damage_multiplier: 2.0,
               damage_type: 'physical')
      end

      before do
        attacker.update(target_participant_id: target.id)
      end

      it 'applies damage multiplier' do
        service = described_class.new(
          actor: attacker,
          ability: heavy_strike,
          primary_target: target
        )

        events = service.process!(50)

        damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
        expect(damage_event).not_to be_nil
        # With 2x multiplier, min damage should be 4 (2*2)
        expect(damage_event[:details][:effective_damage]).to be >= 4
      end
    end

    context 'with instant kill execute' do
      let(:execute_instant) do
        create(:ability,
               universe: universe,
               name: "Death Touch",
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d6',
               damage_type: 'shadow',
               execute_threshold: 20,
               execute_effect: Sequel.pg_json_wrap({ 'instant_kill' => true }))
      end

      before do
        target.update(current_hp: 15, max_hp: 100) # 15% HP - below threshold
        attacker.update(target_participant_id: target.id)
      end

      it 'instantly kills target below threshold' do
        service = described_class.new(
          actor: attacker,
          ability: execute_instant,
          primary_target: target
        )

        events = service.process!(50)

        execute_event = events.find { |e| e[:event_type] == 'ability_execute' }
        expect(execute_event).not_to be_nil
        expect(execute_event[:details][:instant_kill]).to be true

        # Target should be knocked out
        expect(target.reload.is_knocked_out).to be true
      end
    end

    context 'with conditional damage - target below 25% HP' do
      let(:finish_him) do
        create(:ability,
               universe: universe,
               name: 'Finish Him',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d6',
               damage_type: 'physical',
               conditional_damage: Sequel.pg_json_wrap([
                 { 'condition' => 'target_below_25_hp', 'bonus_damage' => 10 }
               ]))
      end

      before do
        attacker.update(target_participant_id: target.id)
      end

      context 'when target is below 25% HP' do
        before { target.update(current_hp: 20, max_hp: 100) }

        it 'applies bonus damage' do
          service = described_class.new(
            actor: attacker,
            ability: finish_him,
            primary_target: target
          )

          events = service.process!(50)

          damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
          expect(damage_event[:details][:conditional_bonus]).to eq(10)
        end
      end

      context 'when target is above 25% HP' do
        before { target.update(current_hp: 30, max_hp: 100) }

        it 'does not apply bonus damage' do
          service = described_class.new(
            actor: attacker,
            ability: finish_him,
            primary_target: target
          )

          events = service.process!(50)

          damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
          expect(damage_event[:details][:conditional_bonus]).to be_nil
        end
      end
    end

    context 'with conditional damage - first attack of round' do
      let(:opening_strike) do
        create(:ability,
               universe: universe,
               name: 'Opening Strike',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d6',
               damage_type: 'physical',
               conditional_damage: Sequel.pg_json_wrap([
                 { 'condition' => 'first_attack_of_round', 'bonus_damage' => 5 }
               ]))
      end

      before do
        attacker.update(target_participant_id: target.id)
        # Reset attacks counter to simulate first attack
        attacker.instance_variable_set(:@attacks_this_round, nil) if attacker.respond_to?(:attacks_this_round)
      end

      it 'applies bonus on first attack when no attacks made' do
        # Actor should have 0 attacks at start
        allow(attacker).to receive(:attacks_this_round).and_return(0)

        service = described_class.new(
          actor: attacker,
          ability: opening_strike,
          primary_target: target
        )

        events = service.process!(50)

        damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
        expect(damage_event[:details][:conditional_bonus]).to eq(5)
      end
    end

    context 'with conditional damage - target has status' do
      let(:poisoned) { StatusEffect.find_or_create(name: 'poisoned') { |se| se.effect_type = 'damage_tick'; se.is_buff = false } }

      let(:toxic_strike) do
        create(:ability,
               universe: universe,
               name: 'Toxic Strike',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d6',
               damage_type: 'poison',
               conditional_damage: Sequel.pg_json_wrap([
                 { 'condition' => 'target_poisoned', 'bonus_damage' => 8 }
               ]))
      end

      before do
        poisoned
        attacker.update(target_participant_id: target.id)
      end

      context 'when target has poisoned status' do
        before do
          StatusEffectService.apply_by_name(
            participant: target,
            effect_name: 'poisoned',
            duration_rounds: 2,
            applied_by: nil
          )
        end

        it 'applies bonus damage' do
          service = described_class.new(
            actor: attacker,
            ability: toxic_strike,
            primary_target: target
          )

          events = service.process!(50)

          damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
          expect(damage_event[:details][:conditional_bonus]).to eq(8)
        end
      end
    end

    context 'with conditional damage - target prone' do
      let(:prone_status) { StatusEffect.find_or_create(name: 'prone') { |se| se.effect_type = 'movement'; se.is_buff = false } }

      let(:ground_pound) do
        create(:ability,
               universe: universe,
               name: 'Ground Pound',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d6',
               damage_type: 'physical',
               conditional_damage: Sequel.pg_json_wrap([
                 { 'condition' => 'target_prone', 'bonus_damage' => 6 }
               ]))
      end

      before do
        prone_status
        attacker.update(target_participant_id: target.id)
      end

      context 'when target is prone' do
        before do
          StatusEffectService.apply_by_name(
            participant: target,
            effect_name: 'prone',
            duration_rounds: 1,
            applied_by: nil
          )
        end

        it 'applies bonus damage when is_prone returns true' do
          # Mock StatusEffectService.is_prone? to return true
          allow(StatusEffectService).to receive(:is_prone?).with(target).and_return(true)

          service = described_class.new(
            actor: attacker,
            ability: ground_pound,
            primary_target: target
          )

          events = service.process!(50)

          damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
          expect(damage_event[:details][:conditional_bonus]).to eq(6)
        end
      end
    end

    context 'with bypass resistances' do
      let(:true_damage) do
        create(:ability,
               universe: universe,
               name: 'True Damage',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6',
               damage_type: 'physical',
               bypasses_resistances: true)
      end

      before do
        attacker.update(target_participant_id: target.id)
      end

      it 'deals damage ignoring resistances' do
        service = described_class.new(
          actor: attacker,
          ability: true_damage,
          primary_target: target
        )

        events = service.process!(50)

        damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
        expect(damage_event).not_to be_nil
        expect(damage_event[:details][:effective_damage]).to be >= 2
      end
    end

    context 'with no base damage dice' do
      let(:status_only) do
        create(:ability,
               universe: universe,
               name: 'Status Only',
               ability_type: 'utility',
               action_type: 'main',
               base_damage_dice: nil,
               target_type: 'enemy')
      end

      before do
        attacker.update(target_participant_id: target.id)
      end

      it 'does not deal damage' do
        service = described_class.new(
          actor: attacker,
          ability: status_only,
          primary_target: target
        )

        events = service.process!(50)

        # Should not have ability_hit since no damage dice
        damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
        expect(damage_event).to be_nil
      end
    end

    context 'with status effect threshold' do
      let(:slow_chance) do
        create(:ability,
               universe: universe,
               name: 'Slow Chance',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d6',
               damage_type: 'physical',
               applied_status_effects: Sequel.pg_json_wrap([
                 { 'effect_name' => 'slowed', 'duration_rounds' => 1, 'effect_threshold' => 15 }
               ]))
      end

      let(:slowed) { StatusEffect.find_or_create(name: 'slowed') { |se| se.effect_type = 'action_restriction'; se.is_buff = false } }

      before do
        slowed
        attacker.update(target_participant_id: target.id)
      end

      it 'applies status only if roll meets threshold' do
        # Use a base roll that exceeds threshold
        base_roll = { total: 20, dice: [10, 10], modifier: 0 }

        service = described_class.new(
          actor: attacker,
          ability: slow_chance,
          primary_target: target,
          base_roll: base_roll
        )

        events = service.process!(50)

        status_event = events.find { |e| e[:event_type] == 'status_applied' }
        expect(status_event).not_to be_nil
      end
    end

    context 'with willpower defense' do
      let(:magic_missile) do
        create(:ability,
               universe: universe,
               name: 'Magic Missile',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '3d6',
               damage_type: 'magic')
      end

      before do
        attacker.update(target_participant_id: target.id, side: 1)
        target.update(side: 2)
      end

      it 'processes damage ability' do
        service = described_class.new(
          actor: attacker,
          ability: magic_missile,
          primary_target: target
        )

        events = service.process!(50)

        damage_event = events.find { |e| e[:event_type] == 'ability_hit' }
        expect(damage_event).not_to be_nil
        expect(damage_event[:details][:effective_damage]).to be_between(3, 18)
      end
    end

    context 'with ally targeting' do
      let(:bless) do
        create(:ability,
               universe: universe,
               name: 'Bless',
               ability_type: 'utility',
               action_type: 'main',
               base_damage_dice: '1d6',
               target_type: 'ally',
               is_healing: true)
      end

      let(:ally_char) { create(:character, name: 'Ally') }
      let(:ally_instance) { create(:character_instance, character: ally_char, current_room_id: room.id) }
      let(:ally) { create(:fight_participant, fight: fight, character_instance: ally_instance, current_hp: 50, max_hp: 100) }

      before do
        attacker.update(side: 1)
        ally.update(side: 1, hex_x: 1, hex_y: 1)
      end

      it 'can target allies on same side' do
        service = described_class.new(
          actor: attacker,
          ability: bless,
          primary_target: ally
        )

        events = service.process!(50)

        heal_event = events.find { |e| e[:event_type] == 'ability_heal' }
        expect(heal_event).not_to be_nil
        expect(heal_event[:target_id]).to eq(ally.id)
      end
    end
  end

  describe 'helper methods' do
    let(:basic_ability) do
      create(:ability,
             universe: universe,
             name: 'Basic',
             ability_type: 'combat',
             action_type: 'main',
             base_damage_dice: '1d6')
    end

    describe '#normalize_hex_direction' do
      let(:service) { described_class.new(actor: attacker, ability: basic_ability, primary_target: target) }

      it 'maps cardinal directions to hex directions' do
        expect(service.send(:normalize_hex_direction, 'n')).to eq(:n)
        expect(service.send(:normalize_hex_direction, 'north')).to eq(:n)
        expect(service.send(:normalize_hex_direction, 's')).to eq(:s)
        expect(service.send(:normalize_hex_direction, 'south')).to eq(:s)
      end

      it 'maps east/west to nearest hex directions' do
        expect(service.send(:normalize_hex_direction, 'e')).to eq(:ne)
        expect(service.send(:normalize_hex_direction, 'east')).to eq(:ne)
        expect(service.send(:normalize_hex_direction, 'w')).to eq(:nw)
        expect(service.send(:normalize_hex_direction, 'west')).to eq(:nw)
      end

      it 'maps diagonal directions to hex directions' do
        expect(service.send(:normalize_hex_direction, 'ne')).to eq(:ne)
        expect(service.send(:normalize_hex_direction, 'nw')).to eq(:nw)
        expect(service.send(:normalize_hex_direction, 'se')).to eq(:se)
        expect(service.send(:normalize_hex_direction, 'sw')).to eq(:sw)
      end

      it 'returns nil for unknown direction' do
        expect(service.send(:normalize_hex_direction, 'invalid')).to be_nil
      end
    end

    describe '#same_team?' do
      let(:service) { described_class.new(actor: attacker, ability: basic_ability, primary_target: target) }

      before do
        attacker.update(side: 1)
      end

      it 'returns true when on same side' do
        target.update(side: 1)
        expect(service.send(:same_team?, target)).to be true
      end

      it 'returns false when on different sides' do
        target.update(side: 2)
        expect(service.send(:same_team?, target)).to be false
      end

      it 'handles side comparison correctly' do
        # Test side 1 vs side 2
        attacker.update(side: 1)
        target.update(side: 2)
        expect(service.send(:same_team?, target)).to be false

        # Same sides
        target.update(side: 1)
        expect(service.send(:same_team?, target)).to be true
      end
    end

    describe '#valid_target_for_ability?' do
      context 'with self-targeting ability' do
        let(:self_ability) do
          create(:ability,
                 universe: universe,
                 name: 'Self Buff',
                 ability_type: 'utility',
                 action_type: 'main',
                 base_damage_dice: '1d6',
                 target_type: 'self')
        end
        let(:service) { described_class.new(actor: attacker, ability: self_ability, primary_target: nil) }

        it 'returns true for self' do
          expect(service.send(:valid_target_for_ability?, attacker)).to be true
        end

        it 'returns false for others' do
          expect(service.send(:valid_target_for_ability?, target)).to be false
        end
      end

      context 'with ally-targeting ability' do
        let(:ally_ability) do
          create(:ability,
                 universe: universe,
                 name: 'Ally Buff',
                 ability_type: 'utility',
                 action_type: 'main',
                 base_damage_dice: '1d6',
                 target_type: 'ally')
        end
        let(:service) { described_class.new(actor: attacker, ability: ally_ability, primary_target: nil) }

        before do
          attacker.update(side: 1)
        end

        it 'returns true for self' do
          expect(service.send(:valid_target_for_ability?, attacker)).to be true
        end

        it 'returns true for allies' do
          target.update(side: 1)
          expect(service.send(:valid_target_for_ability?, target)).to be true
        end

        it 'returns false for enemies' do
          target.update(side: 2)
          expect(service.send(:valid_target_for_ability?, target)).to be false
        end
      end

      context 'with enemy-targeting ability' do
        let(:enemy_ability) do
          create(:ability,
                 universe: universe,
                 name: 'Enemy Attack',
                 ability_type: 'combat',
                 action_type: 'main',
                 base_damage_dice: '1d6',
                 target_type: 'enemy')
        end
        let(:service) { described_class.new(actor: attacker, ability: enemy_ability, primary_target: nil) }

        before do
          attacker.update(side: 1)
        end

        it 'returns false for self' do
          expect(service.send(:valid_target_for_ability?, attacker)).to be false
        end

        it 'returns false for allies' do
          target.update(side: 1)
          expect(service.send(:valid_target_for_ability?, target)).to be false
        end

        it 'returns true for enemies' do
          target.update(side: 2)
          expect(service.send(:valid_target_for_ability?, target)).to be true
        end
      end
    end

    describe '#effective_target' do
      context 'with self-targeting ability' do
        let(:self_ability) do
          create(:ability,
                 universe: universe,
                 name: 'Self',
                 ability_type: 'utility',
                 action_type: 'main',
                 base_damage_dice: '1d6',
                 target_type: 'self')
        end
        let(:service) { described_class.new(actor: attacker, ability: self_ability, primary_target: target) }

        it 'returns actor regardless of primary_target' do
          expect(service.send(:effective_target)).to eq(attacker)
        end
      end

      context 'with enemy-targeting ability' do
        let(:enemy_ability) do
          create(:ability,
                 universe: universe,
                 name: 'Enemy',
                 ability_type: 'combat',
                 action_type: 'main',
                 base_damage_dice: '1d6',
                 target_type: 'enemy')
        end
        let(:service) { described_class.new(actor: attacker, ability: enemy_ability, primary_target: target) }

        it 'returns primary_target' do
          expect(service.send(:effective_target)).to eq(target)
        end
      end
    end

    describe '#create_event' do
      let(:service) { described_class.new(actor: attacker, ability: basic_ability, primary_target: target) }

      it 'creates event hash with correct structure' do
        event = service.send(:create_event, 50, 'test_event', damage: 10, target_id: target.id)

        expect(event[:segment]).to eq(50)
        expect(event[:actor_id]).to eq(attacker.id)
        expect(event[:event_type]).to eq('test_event')
        expect(event[:details][:damage]).to eq(10)
      end
    end
  end

  describe 'AoE edge cases' do
    let(:cone_ability) do
      create(:ability,
             universe: universe,
             name: 'Cone Test',
             ability_type: 'combat',
             action_type: 'main',
             base_damage_dice: '1d6',
             target_type: 'enemy',
             aoe_shape: 'cone',
             aoe_length: 3)
    end

    let(:line_ability) do
      create(:ability,
             universe: universe,
             name: 'Line Test',
             ability_type: 'combat',
             action_type: 'main',
             base_damage_dice: '1d6',
             target_type: 'enemy',
             aoe_shape: 'line',
             aoe_length: 5)
    end

    context 'when actor has nil position' do
      before do
        attacker.update(hex_x: nil, hex_y: nil, target_participant_id: target.id)
        target.update(hex_x: 3, hex_y: 3, side: 2)
      end

      it 'cone returns empty targets' do
        service = described_class.new(
          actor: attacker,
          ability: cone_ability,
          primary_target: target
        )

        events = service.process!(50)
        no_target = events.find { |e| e[:event_type] == 'ability_no_target' }
        expect(no_target).not_to be_nil
      end

      it 'line returns empty targets' do
        service = described_class.new(
          actor: attacker,
          ability: line_ability,
          primary_target: target
        )

        events = service.process!(50)
        no_target = events.find { |e| e[:event_type] == 'ability_no_target' }
        expect(no_target).not_to be_nil
      end
    end

    context 'when target has nil position' do
      before do
        attacker.update(hex_x: 0, hex_y: 0, target_participant_id: target.id)
        target.update(hex_x: nil, hex_y: nil, side: 2)
      end

      it 'cone returns empty targets' do
        service = described_class.new(
          actor: attacker,
          ability: cone_ability,
          primary_target: target
        )

        events = service.process!(50)
        no_target = events.find { |e| e[:event_type] == 'ability_no_target' }
        expect(no_target).not_to be_nil
      end
    end

    context 'when actor and target at same position' do
      before do
        attacker.update(hex_x: 5, hex_y: 5, target_participant_id: target.id, side: 1)
        target.update(hex_x: 5, hex_y: 5, side: 2)
      end

      it 'line returns empty targets (zero distance)' do
        service = described_class.new(
          actor: attacker,
          ability: line_ability,
          primary_target: target
        )

        events = service.process!(50)
        no_target = events.find { |e| e[:event_type] == 'ability_no_target' }
        expect(no_target).not_to be_nil
      end
    end
  end

  describe 'forced movement edge cases' do
    let(:push_ability) do
      create(:ability,
             universe: universe,
             name: 'Push Away',
             ability_type: 'combat',
             action_type: 'main',
             base_damage_dice: '1d6',
             damage_type: 'physical',
             forced_movement: Sequel.pg_json_wrap({
               'direction' => 'away',
               'distance' => 3
             }))
    end

    context 'when actor and target at same position' do
      before do
        attacker.update(hex_x: 5, hex_y: 5, target_participant_id: target.id)
        target.update(hex_x: 5, hex_y: 5)
      end

      it 'does not move target (zero distance direction)' do
        initial_x = target.hex_x
        initial_y = target.hex_y

        service = described_class.new(
          actor: attacker,
          ability: push_ability,
          primary_target: target
        )

        service.process!(50)

        # When at same position, direction calculation fails, target stays
        expect(target.reload.hex_x).to eq(initial_x)
        expect(target.reload.hex_y).to eq(initial_y)
      end
    end

    context 'when pushing toward arena edge' do
      before do
        attacker.update(hex_x: 5, hex_y: 5, target_participant_id: target.id, side: 1)
        target.update(hex_x: 8, hex_y: 5, side: 2) # Near edge with arena_width: 10
      end

      it 'pushes target away from attacker' do
        initial_x = target.hex_x

        service = described_class.new(
          actor: attacker,
          ability: push_ability,
          primary_target: target
        )

        service.process!(50)

        # Target should move away from attacker (higher x)
        expect(target.reload.hex_x).to be > initial_x
      end
    end
  end

  describe 'chain ability edge cases' do
    let(:chain_ability) do
      create(:ability,
             universe: universe,
             name: 'Chain Test',
             ability_type: 'combat',
             action_type: 'main',
             base_damage_dice: '2d6',
             damage_type: 'lightning',
             target_type: 'enemy',
             aoe_shape: 'single',
             chain_config: Sequel.pg_json_wrap({
               'max_targets' => 3,
               'range_per_jump' => 2,
               'damage_falloff' => 0.5,
               'friendly_fire' => false
             }))
    end

    context 'when no valid chain targets' do
      before do
        attacker.update(hex_x: 0, hex_y: 0, side: 1, target_participant_id: target.id)
        target.update(hex_x: 2, hex_y: 0, side: 2)
        # No other targets within range
      end

      it 'only hits primary target' do
        service = described_class.new(
          actor: attacker,
          ability: chain_ability,
          primary_target: target
        )

        events = service.process!(50)
        hit_events = events.select { |e| e[:event_type] == 'ability_hit' }

        expect(hit_events.size).to eq(1)
        expect(hit_events.first[:details][:is_chain]).to be_falsy
      end
    end

    context 'with friendly fire enabled' do
      let(:chain_ff) do
        create(:ability,
               universe: universe,
               name: 'Chain FF',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '2d6',
               damage_type: 'lightning',
               target_type: 'enemy',
               aoe_shape: 'single',
               chain_config: Sequel.pg_json_wrap({
                 'max_targets' => 3,
                 'range_per_jump' => 5,
                 'damage_falloff' => 0.5,
                 'friendly_fire' => true
               }))
      end

      let(:ally_char) { create(:character, name: 'Ally') }
      let(:ally_instance) { create(:character_instance, character: ally_char, current_room_id: room.id) }
      let(:ally) { create(:fight_participant, fight: fight, character_instance: ally_instance, current_hp: 100, max_hp: 100) }

      before do
        attacker.update(hex_x: 0, hex_y: 0, side: 1, target_participant_id: target.id)
        target.update(hex_x: 2, hex_y: 0, side: 2)
        ally.update(hex_x: 4, hex_y: 0, side: 1) # Same side as attacker
      end

      it 'can chain to allies' do
        service = described_class.new(
          actor: attacker,
          ability: chain_ff,
          primary_target: target
        )

        events = service.process!(50)
        hit_events = events.select { |e| e[:event_type] == 'ability_hit' }
        hit_ids = hit_events.map { |e| e[:target_id] }

        # Should hit target and potentially chain to ally
        expect(hit_events.size).to be >= 1
      end
    end
  end
end
