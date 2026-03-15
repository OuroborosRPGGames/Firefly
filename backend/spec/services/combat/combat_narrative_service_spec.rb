# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CombatNarrativeService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { Reality.create(name: 'Primary', reality_type: 'primary', time_offset: 0) }

  let(:user1) { create(:user) }
  let(:character1) { create(:character, user: user1, forename: 'Alpha', surname: 'Fighter') }
  let(:character_instance1) do
    CharacterInstance.create(
      character: character1,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive'
    )
  end

  let(:user2) { create(:user) }
  let(:character2) { create(:character, user: user2, forename: 'Beta', surname: 'Warrior') }
  let(:character_instance2) do
    CharacterInstance.create(
      character: character2,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive'
    )
  end

  let(:fight) { Fight.create(room_id: room.id, status: 'narrative', round_number: 1) }

  let(:participant1) do
    FightParticipant.create(
      fight_id: fight.id,
      character_instance_id: character_instance1.id,
      side: 1,
      current_hp: 6,
      max_hp: 6,
      main_action: 'attack',
      hex_x: 0,
      hex_y: 0
    )
  end

  let(:participant2) do
    FightParticipant.create(
      fight_id: fight.id,
      character_instance_id: character_instance2.id,
      side: 2,
      current_hp: 6,
      max_hp: 6,
      main_action: 'defend',
      hex_x: 1,
      hex_y: 0
    )
  end

  describe '#initialize' do
    it 'creates service with fight reference' do
      service = described_class.new(fight)
      expect(service.fight).to eq(fight)
    end

    it 'parses round events on initialization' do
      service = described_class.new(fight)
      expect(service.round_events).to be_an(Array)
    end

    it 'accepts enhance_prose option' do
      service = described_class.new(fight, enhance_prose: false)
      expect(service.fight).to eq(fight)
    end
  end

  describe '#generate' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    context 'with no events' do
      it 'returns default message' do
        narrative = service.generate
        expect(narrative).to eq('The combatants size each other up...')
      end
    end

    context 'with hit events' do
      before do
        participant1
        participant2
        FightEvent.create(
          fight_id: fight.id,
          round_number: 1,
          segment: 1,
          event_type: 'hit',
          actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({
            actor_name: 'Alpha Fighter',
            target_name: 'Beta Warrior',
            total: 5,
            effective_damage: 5
          })
        )
      end

      it 'generates narrative text' do
        # Re-initialize to pick up new events
        svc = described_class.new(fight, enhance_prose: false)
        narrative = svc.generate
        expect(narrative).to be_a(String)
        expect(narrative).not_to eq('The combatants size each other up...')
      end
    end

    context 'with knockout events' do
      before do
        participant1
        participant2
        FightEvent.create(
          fight_id: fight.id,
          round_number: 1,
          segment: 10,
          event_type: 'knockout',
          actor_participant_id: nil,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({
            target_name: 'Beta Warrior'
          })
        )
      end

      it 'includes knockout in narrative' do
        svc = described_class.new(fight, enhance_prose: false)
        narrative = svc.generate
        expect(narrative).to include('collapses')
      end
    end
  end

  describe '#build_movement_context' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'returns empty hash for no movements' do
      result = service.build_movement_context([])
      expect(result).to eq({})
    end

    it 'builds context from movement events' do
      movements = [
        {
          actor_id: 1,
          event_type: 'move',
          details: { direction: 'towards', target_name: 'Beta', entered_melee: true }
        }
      ]

      result = service.build_movement_context(movements)

      expect(result[1]).to be_a(Hash)
      expect(result[1][:direction]).to eq('towards')
      expect(result[1][:moved]).to be true
    end

    it 'handles stand_still as not moved' do
      movements = [
        {
          actor_id: 1,
          event_type: 'move',
          details: { direction: 'stand_still' }
        }
      ]

      result = service.build_movement_context(movements)
      expect(result[1][:moved]).to be false
    end
  end

  describe 'constants' do
    it 'has NUMBER_WORDS' do
      expect(described_class::NUMBER_WORDS[1]).to eq('one')
      expect(described_class::NUMBER_WORDS[5]).to eq('five')
      expect(described_class::NUMBER_WORDS[10]).to eq('ten')
    end

    it 'has WEAPON_ACTIONS' do
      expect(described_class::WEAPON_ACTIONS[:sword][:verb]).to eq('swinging')
      expect(described_class::WEAPON_ACTIONS[:pistol][:verb]).to eq('firing')
      expect(described_class::WEAPON_ACTIONS[:unarmed][:verb]).to eq('throwing')
    end

    it 'has DEFEND_PHRASES' do
      expect(described_class::DEFEND_PHRASES).to include('sets a defensive stance')
      expect(described_class::DEFEND_PHRASES).to include('raises their guard')
    end

    it 'has MOVEMENT_ATTACK_VERBS' do
      expect(described_class::MOVEMENT_ATTACK_VERBS[:melee_towards]).to include('moves toward')
      expect(described_class::MOVEMENT_ATTACK_VERBS[:ranged_away]).to include('retreats from')
    end
  end

  describe 'narrative generation helpers' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    describe 'number_word' do
      it 'converts numbers to words' do
        expect(service.send(:number_word, 1)).to eq('one')
        expect(service.send(:number_word, 3)).to eq('three')
        expect(service.send(:number_word, 12)).to eq('twelve')
      end

      it 'returns string for numbers outside dictionary' do
        expect(service.send(:number_word, 15)).to eq('15')
        expect(service.send(:number_word, 100)).to eq('100')
      end
    end

    describe 'capitalize_name' do
      it 'capitalizes first letter' do
        expect(service.send(:capitalize_name, 'alpha')).to eq('Alpha')
      end

      it 'handles already capitalized names' do
        expect(service.send(:capitalize_name, 'Alpha')).to eq('Alpha')
      end

      it 'handles nil' do
        expect(service.send(:capitalize_name, nil)).to be_nil
      end

      it 'handles empty string' do
        expect(service.send(:capitalize_name, '')).to eq('')
      end
    end
  end

  describe 'event type detection' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    describe 'attack_event?' do
      it 'returns true for hit events' do
        event = { event_type: 'hit' }
        expect(service.send(:attack_event?, event)).to be true
      end

      it 'returns true for miss events' do
        event = { event_type: 'miss' }
        expect(service.send(:attack_event?, event)).to be true
      end

      it 'returns true for ability events' do
        expect(service.send(:attack_event?, { event_type: 'ability_start' })).to be true
        expect(service.send(:attack_event?, { event_type: 'ability_hit' })).to be true
        expect(service.send(:attack_event?, { event_type: 'ability_heal' })).to be true
      end

      it 'returns false for move events' do
        event = { event_type: 'move' }
        expect(service.send(:attack_event?, event)).to be false
      end

      it 'returns false for out_of_range events (handled via movement instead)' do
        event = { event_type: 'out_of_range' }
        expect(service.send(:attack_event?, event)).to be false
      end
    end

    describe 'combat_event?' do
      it 'returns true for combat-related events' do
        expect(service.send(:combat_event?, { event_type: 'hit' })).to be true
        expect(service.send(:combat_event?, { event_type: 'miss' })).to be true
        expect(service.send(:combat_event?, { event_type: 'move' })).to be true
        expect(service.send(:combat_event?, { event_type: 'ability_hit' })).to be true
      end

      it 'returns false for non-combat events' do
        expect(service.send(:combat_event?, { event_type: 'damage_applied' })).to be false
        expect(service.send(:combat_event?, { event_type: 'knockout' })).to be false
      end
    end
  end

  describe 'hazard damage description' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'returns nil for empty events' do
      expect(service.send(:describe_hazard_damage, [])).to be_nil
    end

    it 'describes fire hazard' do
      events = [{
        event_type: 'hazard_damage',
        target_name: 'Alpha',
        details: { hazard_type: 'fire', damage: 5 }
      }]

      result = service.send(:describe_hazard_damage, events)
      expect(result).to include('flames')
      expect(result).to include('5 damage')
    end

    it 'describes acid hazard' do
      events = [{
        event_type: 'hazard_damage',
        target_name: 'Alpha',
        details: { hazard_type: 'acid', damage: 3 }
      }]

      result = service.send(:describe_hazard_damage, events)
      expect(result).to include('acid')
    end

    it 'handles unknown hazard types' do
      events = [{
        event_type: 'hazard_damage',
        target_name: 'Alpha',
        details: { hazard_type: 'unknown', damage: 2 }
      }]

      result = service.send(:describe_hazard_damage, events)
      expect(result).to include('dangerous terrain')
    end
  end

  describe 'status effect descriptions' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'describes burning status' do
      event = { details: { effect_name: 'burning', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('catches fire')
    end

    it 'describes stunned status' do
      event = { details: { effect_name: 'stunned', target_name: 'Beta' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('stunned')
    end

    it 'describes shielded status' do
      event = { details: { effect_name: 'shielded', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('magical shield')
    end

    it 'handles unknown status with generic message' do
      event = { details: { effect_name: 'weird_debuff', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('affected by')
    end
  end

  describe 'knockout generation' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'returns nil for no knockouts' do
      expect(service.send(:generate_knockouts, [])).to be_nil
    end

    it 'generates knockout text' do
      events = [{ target_name: 'Beta Warrior' }]
      result = service.send(:generate_knockouts, events)
      expect(result).to include('Beta Warrior')
      expect(result).to include('collapses')
    end

    it 'handles multiple knockouts' do
      events = [
        { target_name: 'Alpha' },
        { target_name: 'Beta' }
      ]
      result = service.send(:generate_knockouts, events)
      expect(result).to include('Alpha')
      expect(result).to include('Beta')
    end
  end

  describe 'opening generation' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'returns empty string for round 1' do
      expect(service.send(:generate_opening)).to eq('')
    end

    it 'returns empty string for later rounds too' do
      fight.update(round_number: 3)
      svc = described_class.new(fight, enhance_prose: false)
      expect(svc.send(:generate_opening)).to eq('')
    end
  end

  describe 'weapon type inference' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'infers sword type' do
      pattern = double('Pattern', description: 'A sharp longsword', name: 'Longsword')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:sword)
    end

    it 'infers knife type' do
      pattern = double('Pattern', description: 'A deadly dagger', name: 'Dagger')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:knife)
    end

    it 'infers pistol type' do
      pattern = double('Pattern', description: 'A flintlock pistol', name: 'Pistol')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:pistol)
    end

    it 'infers bow type' do
      pattern = double('Pattern', description: 'A longbow', name: 'Bow')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:bow)
    end

    it 'defaults to unarmed for unknown' do
      pattern = double('Pattern', description: 'A mysterious object', name: 'Unknown')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:unarmed)
    end
  end

  describe 'damage type inference' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'infers slashing damage' do
      pattern = double('Pattern', description: 'A sharp sword', name: 'Sword', damage_type: nil)
      expect(service.send(:infer_damage_type, pattern)).to eq('slashing')
    end

    it 'infers piercing damage' do
      pattern = double('Pattern', description: 'A spear', name: 'Spear', damage_type: nil)
      expect(service.send(:infer_damage_type, pattern)).to eq('piercing')
    end

    it 'infers bludgeoning damage' do
      pattern = double('Pattern', description: 'A heavy hammer', name: 'Hammer', damage_type: nil)
      expect(service.send(:infer_damage_type, pattern)).to eq('bludgeoning')
    end

    it 'infers elemental damage' do
      pattern = double('Pattern', description: 'A ball of fire', name: 'Fire Ball', damage_type: nil)
      expect(service.send(:infer_damage_type, pattern)).to eq('fire')
    end

    it 'defaults to bludgeoning' do
      pattern = double('Pattern', description: 'Something', name: 'Thing', damage_type: nil)
      expect(service.send(:infer_damage_type, pattern)).to eq('bludgeoning')
    end
  end

  describe 'deep_symbolize_keys' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'converts string keys to symbols' do
      input = { 'name' => 'Alpha', 'damage' => 5 }
      result = service.send(:deep_symbolize_keys, input)
      expect(result).to eq({ name: 'Alpha', damage: 5 })
    end

    it 'handles nested hashes' do
      input = { 'outer' => { 'inner' => 'value' } }
      result = service.send(:deep_symbolize_keys, input)
      expect(result).to eq({ outer: { inner: 'value' } })
    end

    it 'returns non-hashes unchanged' do
      expect(service.send(:deep_symbolize_keys, 'string')).to eq('string')
      expect(service.send(:deep_symbolize_keys, 123)).to eq(123)
    end
  end

  describe '#parse_details' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'returns empty hash for nil' do
      expect(service.send(:parse_details, nil)).to eq({})
    end

    it 'parses JSON string' do
      json_str = '{"name": "Alpha", "damage": 5}'
      result = service.send(:parse_details, json_str)
      expect(result[:name]).to eq('Alpha')
      expect(result[:damage]).to eq(5)
    end

    it 'handles Hash input' do
      input = { 'name' => 'Beta', 'damage' => 3 }
      result = service.send(:parse_details, input)
      expect(result[:name]).to eq('Beta')
    end

    it 'handles objects with to_h method' do
      obj = double('PgJson', to_h: { 'name' => 'Gamma' })
      result = service.send(:parse_details, obj)
      expect(result[:name]).to eq('Gamma')
    end

    it 'returns empty hash for invalid JSON' do
      result = service.send(:parse_details, 'not valid json')
      expect(result).to eq({})
    end

    it 'returns empty hash for unknown types' do
      result = service.send(:parse_details, 12345)
      expect(result).to eq({})
    end
  end

  describe '#lookup_participant_name' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'returns nil for nil participant_id' do
      expect(service.send(:lookup_participant_name, nil)).to be_nil
    end

    it 'returns character name for valid participant' do
      name = service.send(:lookup_participant_name, participant1.id)
      expect(name).to eq('Alpha Fighter')
    end

    it 'returns nil for non-existent participant' do
      expect(service.send(:lookup_participant_name, 999999)).to be_nil
    end
  end

  describe '#participant' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'returns participant by id' do
      result = service.send(:participant, participant1.id)
      expect(result).to eq(participant1)
    end

    it 'caches participant lookups' do
      service.send(:participant, participant1.id)
      expect(FightParticipant).not_to receive(:[]).with(participant1.id)
      service.send(:participant, participant1.id)
    end

    it 'returns nil for non-existent id' do
      expect(service.send(:participant, 999999)).to be_nil
    end
  end

  describe '#generate_interlaced_narrative' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'returns nil for empty events' do
      expect(service.send(:generate_interlaced_narrative, [])).to be_nil
    end

    it 'generates narrative for hit events' do
      events = [
        {
          event_type: 'hit',
          actor_id: participant1.id,
          target_id: participant2.id,
          details: { total: 5, actor_name: 'Alpha Fighter', target_name: 'Beta Warrior' }
        }
      ]

      result = service.send(:generate_interlaced_narrative, events)
      expect(result).to be_a(String)
    end

    it 'combines multiple exchanges' do
      events = [
        { event_type: 'hit', actor_id: participant1.id, target_id: participant2.id, details: { total: 5 } },
        { event_type: 'miss', actor_id: participant2.id, target_id: participant1.id, details: {} }
      ]

      result = service.send(:generate_interlaced_narrative, events)
      expect(result).to be_a(String)
    end
  end

  describe '#group_into_exchanges' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'returns empty array for empty events' do
      expect(service.send(:group_into_exchanges, [])).to eq([])
    end

    it 'groups related events into exchanges' do
      events = [
        { event_type: 'hit', actor_id: participant1.id, target_id: participant2.id, details: {} },
        { event_type: 'hit', actor_id: participant1.id, target_id: participant2.id, details: {} }
      ]

      exchanges = service.send(:group_into_exchanges, events)
      expect(exchanges).to be_an(Array)
      expect(exchanges.length).to be >= 1
    end

    it 'creates separate exchanges for different actor-target pairs' do
      events = [
        { event_type: 'hit', actor_id: participant1.id, target_id: participant2.id, details: {} },
        { event_type: 'hit', actor_id: participant2.id, target_id: participant1.id, details: {} }
      ]

      exchanges = service.send(:group_into_exchanges, events)
      expect(exchanges).to be_an(Array)
    end
  end

  describe '#describe_combat_exchange' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'returns nil for empty hits and misses' do
      result = service.send(:describe_combat_exchange, {}, {}, {})
      expect(result).to be_nil
    end

    it 'describes one-sided attack with hits' do
      hits_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: { total: 5 } }]
      }
      misses_by_actor = {}

      result = service.send(:describe_combat_exchange, hits_by_actor, misses_by_actor, {})
      expect(result).to be_a(String)
    end

    it 'describes one-sided attack with misses only' do
      hits_by_actor = {}
      misses_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: {} }]
      }

      result = service.send(:describe_combat_exchange, hits_by_actor, misses_by_actor, {})
      expect(result).to be_a(String)
    end
  end

  describe '#describe_one_sided_attack' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'returns nil for invalid actor' do
      expect(service.send(:describe_one_sided_attack, 999999, [], [])).to be_nil
    end

    it 'describes hits' do
      hits = [{ target_id: participant2.id, details: { total: 5 } }]

      result = service.send(:describe_one_sided_attack, participant1.id, hits, [])
      expect(result).to be_a(String)
    end

    it 'describes misses' do
      misses = [{ target_id: participant2.id, details: {} }]

      result = service.send(:describe_one_sided_attack, participant1.id, [], misses)
      expect(result).to be_a(String)
    end

    it 'describes mixed hits and misses' do
      hits = [{ target_id: participant2.id, details: { total: 5 } }]
      misses = [{ target_id: participant2.id, details: {} }]

      result = service.send(:describe_one_sided_attack, participant1.id, hits, misses)
      expect(result).to be_a(String)
    end
  end

  describe '#name_for' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'returns character name for participant' do
      expect(service.send(:name_for, participant1)).to eq('Alpha Fighter')
    end

    it 'returns Unknown for nil' do
      # name_for returns 'Unknown' for nil participants
      expect(service.send(:name_for, nil)).to eq('Unknown')
    end

    it 'handles participant id' do
      expect(service.send(:name_for, participant1.id)).to eq('Alpha Fighter')
    end
  end

  describe '#weapon_name_for' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'returns fists for participant without weapon' do
      expect(service.send(:weapon_name_for, participant1)).to eq('fists')
    end

    it 'returns weapon name when participant has weapon' do
      # The name service uses description first, then name - so description should be set
      pattern = create(:pattern, name: 'Longsword', description: 'a longsword')
      item = create(:item, pattern: pattern, character_instance: character_instance1)
      participant1.set(melee_weapon_id: item.id)
      participant1.save_changes

      result = service.send(:weapon_name_for, participant1)
      # The result depends on CombatNameAlternationService alternation logic
      # First use returns the full name (with article stripped)
      expect(result).to be_a(String)
      expect(result.downcase).to include('longsword')
    end
  end

  describe '#weapon_action_for' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'returns unarmed action for participant without weapon' do
      result = service.send(:weapon_action_for, participant1)
      # The constant WEAPON_ACTIONS[:unarmed] returns a hash
      expect(result).to be_a(Hash)
      expect(result[:verb]).to eq('throwing')
      # Note: unarmed noun is 'punches and kicks'
      expect(result[:noun]).to eq('punches and kicks')
    end

    it 'returns weapon action when participant has weapon' do
      pattern = create(:pattern, name: 'Longsword', description: 'A sharp sword')
      item = create(:item, pattern: pattern, character_instance: character_instance1)
      participant1.set(melee_weapon_id: item.id)
      participant1.save_changes

      result = service.send(:weapon_action_for, participant1)
      expect(result[:verb]).to eq('swinging')
    end
  end

  describe '#attack_verb_for' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'returns appropriate verb for unarmed' do
      result = service.send(:attack_verb_for, participant1)
      expect(result).to be_a(String)
    end

    it 'returns swing-related verb for sword' do
      pattern = create(:pattern, name: 'Sword', description: 'A sharp sword')
      item = create(:item, pattern: pattern, character_instance: character_instance1)
      participant1.set(melee_weapon_id: item.id)
      participant1.save_changes

      result = service.send(:attack_verb_for, participant1)
      expect(['slashes', 'cuts', 'strikes', 'swings']).to include(result)
    end
  end

  describe '#damage_type' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'returns bludgeoning for unarmed' do
      hit_event = { details: {} }
      result = service.send(:damage_type, participant1, hit_event)
      expect(result).to eq('bludgeoning')
    end

    it 'uses explicit damage type from event' do
      hit_event = { details: { damage_type: 'fire' } }
      result = service.send(:damage_type, participant1, hit_event)
      expect(result).to eq('fire')
    end
  end

  describe '#weapons_match?' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'returns true for both unarmed' do
      expect(service.send(:weapons_match?, participant1, participant2)).to be true
    end

    it 'returns true for same weapon type' do
      pattern = create(:pattern, name: 'Sword', description: 'A sharp sword')
      item1 = create(:item, pattern: pattern, character_instance: character_instance1)
      item2 = create(:item, pattern: pattern, character_instance: character_instance2)
      participant1.set(melee_weapon_id: item1.id)
      participant1.save_changes
      participant2.set(melee_weapon_id: item2.id)
      participant2.save_changes

      expect(service.send(:weapons_match?, participant1, participant2)).to be true
    end
  end

  describe '#describe_ability' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'describes ability hit' do
      event = {
        event_type: 'ability_hit',
        actor_id: participant1.id,
        details: {
          ability_name: 'Fireball',
          target_name: 'Beta Warrior',
          damage: 10
        }
      }

      result = service.send(:describe_ability, event)
      expect(result).to include('Fireball')
    end

    it 'describes ability heal' do
      event = {
        event_type: 'ability_heal',
        actor_id: participant1.id,
        details: {
          ability_name: 'Heal',
          target_name: 'Alpha Fighter',
          healing: 5
        }
      }

      result = service.send(:describe_ability, event)
      expect(result).to include('Heal')
    end
  end

  describe '#describe_ability_start' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'describes ability start' do
      event = {
        actor_id: participant1.id,
        details: { ability_name: 'Power Strike' }
      }

      result = service.send(:describe_ability_start, event)
      expect(result).to include('Power Strike')
    end

    it 'handles missing ability name' do
      event = { actor_id: participant1.id, details: {} }

      result = service.send(:describe_ability_start, event)
      expect(result).to include('ability')
    end
  end

  describe '#generate_damage_summary' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'returns nil for empty events' do
      expect(service.send(:generate_damage_summary, [])).to be_nil
    end

    it 'summarizes damage for single target' do
      # Must have total_damage > 0 for summary to be generated
      events = [{
        target_id: participant2.id,
        target_name: 'Beta Warrior',
        details: { total_damage: 15, hp_lost: 2 }
      }]

      result = service.send(:generate_damage_summary, events)
      expect(result).to be_a(String)
      expect(result).to include('Beta Warrior')
      expect(result).to include('15 dmg')
    end

    it 'summarizes damage for multiple targets' do
      events = [
        { target_id: participant1.id, target_name: 'Alpha Fighter', details: { total_damage: 10, hp_lost: 1 } },
        { target_id: participant2.id, target_name: 'Beta Warrior', details: { total_damage: 20, hp_lost: 2 } }
      ]

      result = service.send(:generate_damage_summary, events)
      expect(result).to be_a(String)
      expect(result).to include('Alpha Fighter')
      expect(result).to include('Beta Warrior')
    end

    it 'returns nil when no damage dealt' do
      events = [{ target_name: 'Alpha', details: { total_damage: 0, hp_lost: 0 } }]
      expect(service.send(:generate_damage_summary, events)).to be_nil
    end
  end

  describe '#movement_attack_opening' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'generates melee opening' do
      result = service.send(:movement_attack_opening, participant1.id, 'Beta Warrior', is_ranged: false)
      expect(result).to be_a(String)
    end

    it 'generates ranged opening' do
      result = service.send(:movement_attack_opening, participant1.id, 'Beta Warrior', is_ranged: true)
      expect(result).to be_a(String)
    end
  end

  describe '#build_movement_opening' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'builds movement description' do
      result = service.send(:build_movement_opening, participant1.id, participant1, 'Beta Warrior', false, 'fists', { verb: 'throwing', noun: 'punches' })
      expect(result).to be_a(String)
    end

    context 'with movement context' do
      it 'builds melee moving towards description' do
        # Set movement context
        service.instance_variable_set(:@movement_by_actor, {
          participant1.id => { direction: 'towards', moved: true }
        })
        result = service.send(:build_movement_opening, participant1.id, participant1, 'Beta Warrior', false, 'sword', { verb: 'swinging', noun: 'slashes' })
        expect(result).to be_a(String)
        expect(result).to include('raised')  # "sword raised" for melee towards
      end

      it 'builds melee moving away description' do
        service.instance_variable_set(:@movement_by_actor, {
          participant1.id => { direction: 'away', moved: true }
        })
        result = service.send(:build_movement_opening, participant1.id, participant1, 'Beta Warrior', false, 'sword', { verb: 'swinging', noun: 'slashes' })
        expect(result).to be_a(String)
        expect(result).to include('defensively')
      end

      it 'builds ranged moving description' do
        service.instance_variable_set(:@movement_by_actor, {
          participant1.id => { direction: 'towards', moved: true }
        })
        result = service.send(:build_movement_opening, participant1.id, participant1, 'Beta Warrior', true, 'pistol', { verb: 'firing', noun: 'shots' })
        expect(result).to be_a(String)
        expect(result).to include('firing')
      end

      it 'builds stationary ranged description' do
        service.instance_variable_set(:@movement_by_actor, {
          participant1.id => { moved: false }
        })
        result = service.send(:build_movement_opening, participant1.id, participant1, 'Beta Warrior', true, 'rifle', { verb: 'firing', noun: 'shots' })
        expect(result).to be_a(String)
      end

      it 'builds stationary melee description' do
        service.instance_variable_set(:@movement_by_actor, {
          participant1.id => { moved: false }
        })
        result = service.send(:build_movement_opening, participant1.id, participant1, 'Beta Warrior', false, 'fists', { verb: 'throwing', noun: 'punches' })
        expect(result).to be_a(String)
      end
    end
  end

  # ===== EDGE CASE TESTS FOR ADDITIONAL COVERAGE =====

  describe 'status effect descriptions - all types' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'describes poisoned status' do
      event = { details: { effect_name: 'poisoned', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('poisoned')
    end

    it 'describes blinded status' do
      event = { details: { effect_name: 'blinded', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('blinded')
    end

    it 'describes slowed status' do
      event = { details: { effect_name: 'slowed', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('slowed')
    end

    it 'describes prone status' do
      event = { details: { effect_name: 'prone', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('knocked prone')
    end

    it 'describes bleeding status' do
      event = { details: { effect_name: 'bleeding', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('bleeding')
    end

    it 'describes frozen status' do
      event = { details: { effect_name: 'frozen', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('frozen solid')
    end

    it 'describes weakened status' do
      event = { details: { effect_name: 'weakened', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('weakened')
    end

    it 'describes empowered status' do
      event = { details: { effect_name: 'empowered', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('empowered')
    end

    it 'describes regenerating status' do
      event = { details: { effect_name: 'regenerating', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('regenerate')
    end

    it 'formats underscored status names nicely' do
      event = { details: { effect_name: 'acid_burn', target_name: 'Alpha' } }
      result = service.send(:describe_status_applied, event)
      expect(result).to include('Acid burn')  # Underscores become spaces
    end
  end

  describe 'hazard damage - all types' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'describes cold hazard' do
      events = [{
        event_type: 'hazard_damage',
        target_name: 'Alpha',
        details: { hazard_type: 'cold', damage: 4 }
      }]
      result = service.send(:describe_hazard_damage, events)
      expect(result).to include('4 damage')
    end

    it 'describes electric hazard' do
      events = [{
        event_type: 'hazard_damage',
        target_name: 'Alpha',
        details: { hazard_type: 'electric', damage: 6 }
      }]
      result = service.send(:describe_hazard_damage, events)
      expect(result).to include('6 damage')
    end

    it 'describes poison hazard' do
      events = [{
        event_type: 'hazard_damage',
        target_name: 'Alpha',
        details: { hazard_type: 'poison', damage: 3 }
      }]
      result = service.send(:describe_hazard_damage, events)
      expect(result).to include('3 damage')
    end

    it 'describes water hazard' do
      events = [{
        event_type: 'hazard_damage',
        target_name: 'Alpha',
        details: { hazard_type: 'water', damage: 2 }
      }]
      result = service.send(:describe_hazard_damage, events)
      expect(result).to include('2 damage')
    end

    it 'handles multiple targets taking hazard damage' do
      events = [
        { event_type: 'hazard_damage', target_name: 'Alpha', details: { hazard_type: 'fire', damage: 5 } },
        { event_type: 'hazard_damage', target_name: 'Beta', details: { hazard_type: 'fire', damage: 3 } }
      ]
      result = service.send(:describe_hazard_damage, events)
      expect(result).to include('Alpha')
      expect(result).to include('Beta')
    end
  end

  describe 'knockout generation - spar mode' do
    let(:spar_fight) { Fight.create(room_id: room.id, status: 'narrative', round_number: 1, mode: 'spar') }
    let(:spar_participant1) do
      FightParticipant.create(
        fight_id: spar_fight.id,
        character_instance_id: character_instance1.id,
        side: 1,
        current_hp: 6,
        max_hp: 6,
        main_action: 'attack',
        hex_x: 0,
        hex_y: 0
      )
    end
    let(:spar_participant2) do
      FightParticipant.create(
        fight_id: spar_fight.id,
        character_instance_id: character_instance2.id,
        side: 2,
        current_hp: 0,
        max_hp: 6,
        main_action: 'defend',
        hex_x: 1,
        hex_y: 0
      )
    end
    let(:spar_service) { described_class.new(spar_fight, enhance_prose: false) }

    before do
      spar_participant1
      spar_participant2
    end

    it 'generates win message instead of knockout in spar mode' do
      events = [{ target_name: 'Beta Warrior' }]
      result = spar_service.send(:generate_knockouts, events)
      expect(result).to include('wins the sparring match')
      expect(result).not_to include('collapses')
    end

    it 'identifies winner correctly' do
      # Refresh the fight to pick up the participants association
      spar_fight.refresh
      # Create a fresh service after participants exist
      service = described_class.new(spar_fight, enhance_prose: false)
      events = [{ target_name: 'Beta Warrior' }]
      result = service.send(:generate_knockouts, events)
      expect(result).to include('Alpha Fighter')
    end
  end

  describe 'damage summary - spar mode' do
    let(:spar_fight) { Fight.create(room_id: room.id, status: 'narrative', round_number: 1, mode: 'spar') }
    let(:spar_participant1) do
      FightParticipant.create(
        fight_id: spar_fight.id,
        character_instance_id: character_instance1.id,
        side: 1,
        current_hp: 6,
        max_hp: 6,
        main_action: 'attack',
        touch_count: 3,
        hex_x: 0,
        hex_y: 0
      )
    end
    let(:spar_service) { described_class.new(spar_fight, enhance_prose: false) }

    before { spar_participant1 }

    it 'shows touch counts instead of HP in spar mode' do
      events = [{
        target_name: 'Alpha Fighter',
        details: { total_damage: 10, hp_lost: 1 }
      }]
      result = spar_service.send(:generate_damage_summary, events)
      expect(result).to include('touch')
      expect(result).not_to include('dmg')
    end
  end

  describe 'damage summary - status effects' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'includes status effects in summary' do
      # Set round_events with status applied event
      service.instance_variable_set(:@round_events, [
        {
          event_type: 'status_applied',
          details: { target_name: 'Beta Warrior', effect_name: 'burning', duration_rounds: 3 }
        }
      ])

      result = service.send(:generate_damage_summary, [])
      # The summary should include the status effect
      expect(result).to include('burning')
      expect(result).to include('3 rds')
    end

    it 'includes ability damage in summary' do
      service.instance_variable_set(:@round_events, [
        {
          event_type: 'ability_hit',
          details: { target_name: 'Beta Warrior', effective_damage: 15 }
        }
      ])

      result = service.send(:generate_damage_summary, [])
      expect(result).to include('Beta Warrior')
      expect(result).to include('15 dmg')
    end

    it 'includes healing in summary' do
      service.instance_variable_set(:@round_events, [
        {
          event_type: 'ability_heal',
          details: { target_name: 'Alpha Fighter', actual_heal: 8 }
        }
      ])

      result = service.send(:generate_damage_summary, [])
      expect(result).to include('Alpha Fighter')
      expect(result).to include('healed 8 HP')
    end

    it 'omits duration for single round status effects' do
      service.instance_variable_set(:@round_events, [
        {
          event_type: 'status_applied',
          details: { target_name: 'Beta Warrior', effect_name: 'stunned', duration_rounds: 1 }
        }
      ])

      result = service.send(:generate_damage_summary, [])
      expect(result).to include('stunned')
      expect(result).not_to include('rds')
    end
  end

  describe 'describe_two_way_exchange' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'returns nil for invalid actors' do
      result = service.send(:describe_two_way_exchange, [999998, 999999], {}, {})
      expect(result).to be_nil
    end

    it 'describes exchange when both actors hit' do
      hits_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: { total: 5 } }],
        participant2.id => [{ target_id: participant1.id, details: { total: 3 } }]
      }
      misses_by_actor = {}

      result = service.send(:describe_two_way_exchange, [participant1.id, participant2.id], hits_by_actor, misses_by_actor)
      expect(result).to be_a(String)
      expect(result.length).to be > 10
    end

    it 'describes exchange with same weapons and counts' do
      hits_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: {} }],
        participant2.id => [{ target_id: participant1.id, details: {} }]
      }
      misses_by_actor = {}

      result = service.send(:describe_two_way_exchange, [participant1.id, participant2.id], hits_by_actor, misses_by_actor)
      expect(result).to be_a(String)
    end

    it 'describes exchange when only actor1 attacks' do
      hits_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: {} }]
      }
      misses_by_actor = {}

      result = service.send(:describe_two_way_exchange, [participant1.id, participant2.id], hits_by_actor, misses_by_actor)
      expect(result).to be_a(String)
      expect(result.length).to be > 10
    end

    it 'describes exchange when only actor2 attacks' do
      hits_by_actor = {
        participant2.id => [{ target_id: participant1.id, details: {} }]
      }
      misses_by_actor = {}

      result = service.send(:describe_two_way_exchange, [participant1.id, participant2.id], hits_by_actor, misses_by_actor)
      expect(result).to be_a(String)
      expect(result.length).to be > 10
    end

    it 'includes wound descriptions when hits land' do
      hits_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: { total: 10 } }],
        participant2.id => [{ target_id: participant1.id, details: { total: 5 } }]
      }
      misses_by_actor = {}

      result = service.send(:describe_two_way_exchange, [participant1.id, participant2.id], hits_by_actor, misses_by_actor)
      # With new attack pattern system, hits produce impact phrases
      expect(result).to be_a(String)
      expect(result.length).to be > 20
    end

    it 'includes miss descriptions' do
      hits_by_actor = {}
      misses_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: {} }],
        participant2.id => [{ target_id: participant1.id, details: {} }]
      }

      result = service.send(:describe_two_way_exchange, [participant1.id, participant2.id], hits_by_actor, misses_by_actor)
      # With new pattern system, misses use defensive verbs from MISS_FLAVORS
      expect(result).to match(/blocks|parries|deflects|turns aside|catches|sidesteps/i)
    end

    context 'with movement' do
      it 'describes exchange when both move' do
        service.instance_variable_set(:@movement_by_actor, {
          participant1.id => { moved: true, direction: 'towards' },
          participant2.id => { moved: true, direction: 'towards' }
        })

        hits_by_actor = {
          participant1.id => [{ target_id: participant2.id, details: {} }],
          participant2.id => [{ target_id: participant1.id, details: {} }]
        }
        misses_by_actor = {}

        result = service.send(:describe_two_way_exchange, [participant1.id, participant2.id], hits_by_actor, misses_by_actor)
        expect(result).to be_a(String)
      end

      it 'describes exchange when one moves' do
        service.instance_variable_set(:@movement_by_actor, {
          participant1.id => { moved: true, direction: 'towards' }
        })

        hits_by_actor = {
          participant1.id => [{ target_id: participant2.id, details: {} }],
          participant2.id => [{ target_id: participant1.id, details: {} }]
        }
        misses_by_actor = {}

        result = service.send(:describe_two_way_exchange, [participant1.id, participant2.id], hits_by_actor, misses_by_actor)
        expect(result).to be_a(String)
      end
    end

    context 'with different weapons' do
      before do
        pattern1 = create(:pattern, name: 'Sword', description: 'A sharp sword')
        item1 = create(:item, pattern: pattern1, character_instance: character_instance1)
        participant1.set(melee_weapon_id: item1.id)
        participant1.save_changes

        pattern2 = create(:pattern, name: 'Pistol', description: 'A flintlock pistol')
        item2 = create(:item, pattern: pattern2, character_instance: character_instance2)
        participant2.set(ranged_weapon_id: item2.id)
        participant2.save_changes
      end

      it 'describes exchange with different weapons' do
        # Include damage_type in details to avoid calling pattern.damage_type (which doesn't exist)
        hits_by_actor = {
          participant1.id => [{ target_id: participant2.id, details: { damage_type: 'slashing' } }],
          participant2.id => [{ target_id: participant1.id, details: { weapon_type: 'ranged', damage_type: 'piercing' } }]
        }
        misses_by_actor = {}

        result = service.send(:describe_two_way_exchange, [participant1.id, participant2.id], hits_by_actor, misses_by_actor)
        # With new pattern system, uses describe_attack_pattern for each side
        expect(result).to be_a(String)
        expect(result.length).to be > 20
      end
    end
  end

  describe 'describe_melee' do
    let(:user3) { create(:user) }
    let(:character3) { create(:character, user: user3, forename: 'Gamma', surname: 'Knight') }
    let(:character_instance3) do
      CharacterInstance.create(
        character: character3,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive'
      )
    end
    let(:participant3) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance3.id,
        side: 1,
        current_hp: 6,
        max_hp: 6,
        main_action: 'attack',
        hex_x: 2,
        hex_y: 0
      )
    end
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
      participant3
    end

    it 'describes multi-way melee with hits' do
      actor_ids = [participant1.id, participant2.id, participant3.id]
      hits_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: { total: 5 } }],
        participant2.id => [{ target_id: participant3.id, details: { total: 3 } }],
        participant3.id => [{ target_id: participant1.id, details: { total: 4 } }]
      }
      misses_by_actor = {}

      result = service.send(:describe_melee, actor_ids, hits_by_actor, misses_by_actor)
      expect(result).to include('chaotic melee')
      # With new pattern system, hits produce impact phrases via describe_attack_pattern
      expect(result).to be_a(String)
      expect(result.length).to be > 30
    end

    it 'describes multi-way melee with misses' do
      actor_ids = [participant1.id, participant2.id, participant3.id]
      hits_by_actor = {}
      misses_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: {} }],
        participant2.id => [{ target_id: participant3.id, details: {} }]
      }

      result = service.send(:describe_melee, actor_ids, hits_by_actor, misses_by_actor)
      expect(result).to include('chaotic melee')
      # With new pattern system, misses use defensive verbs from MISS_FLAVORS
      expect(result).to match(/blocks|parries|deflects|turns aside|catches|sidesteps/i)
    end

    it 'skips invalid participants' do
      actor_ids = [participant1.id, 999999]
      hits_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: { total: 5 } }]
      }
      misses_by_actor = {}

      result = service.send(:describe_melee, actor_ids, hits_by_actor, misses_by_actor)
      expect(result).to include('chaotic melee')
    end

    it 'skips participants with no hits or misses' do
      actor_ids = [participant1.id, participant2.id, participant3.id]
      hits_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: { total: 5 } }]
      }
      misses_by_actor = {}

      result = service.send(:describe_melee, actor_ids, hits_by_actor, misses_by_actor)
      expect(result).to include('chaotic melee')
      expect(result).to include('Alpha Fighter')
      # Gamma should not appear since they have no hits or misses
    end
  end

  describe 'describe_one_sided_attack - ranged and multiple hits' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'describes multiple hits' do
      hits = [
        { target_id: participant2.id, details: { total: 5 } },
        { target_id: participant2.id, details: { total: 4 } },
        { target_id: participant2.id, details: { total: 3 } }
      ]

      result = service.send(:describe_one_sided_attack, participant1.id, hits, [])
      expect(result).to include('three')
    end

    it 'describes single hit' do
      hits = [{ target_id: participant2.id, details: { total: 5 } }]

      result = service.send(:describe_one_sided_attack, participant1.id, hits, [])
      # With new pattern system, single hits use describe_all_hits which says "catches"
      expect(result).to match(/catches|lands/i)
    end

    it 'describes ranged attack' do
      pattern = create(:pattern, name: 'Pistol', description: 'A flintlock pistol')
      item = create(:item, pattern: pattern, character_instance: character_instance1)
      participant1.set(ranged_weapon_id: item.id)
      participant1.save_changes

      # Include damage_type in details to avoid calling pattern.damage_type (which doesn't exist)
      hits = [{ target_id: participant2.id, details: { weapon_type: 'ranged', total: 5, damage_type: 'piercing' } }]

      result = service.send(:describe_one_sided_attack, participant1.id, hits, [])
      expect(result).to be_a(String)
    end

    it 'handles different gender pronouns for misses' do
      # Set different genders
      character1.update(gender: 'male')
      character2.update(gender: 'female')

      misses = [
        { target_id: participant2.id, details: {} },
        { target_id: participant2.id, details: {} }
      ]

      result = service.send(:describe_one_sided_attack, participant1.id, [], misses)
      # Should use pronoun instead of repeating name
      expect(result).to be_a(String)
    end

    it 'uses name when genders match to avoid ambiguity' do
      character1.update(gender: 'male')
      character2.update(gender: 'male')

      misses = [
        { target_id: participant2.id, details: {} }
      ]

      result = service.send(:describe_one_sided_attack, participant1.id, [], misses)
      expect(result).to include('Beta Warrior')
    end

    it 'falls back to their opponent when target unknown' do
      hits = [{ details: { total: 5 } }]  # No target_id

      result = service.send(:describe_one_sided_attack, participant1.id, hits, [])
      expect(result).to include('their opponent')
    end
  end

  describe 'weapon type inference - all types' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'infers axe type' do
      pattern = double('Pattern', description: 'A battle axe', name: 'Axe')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:axe)
    end

    it 'infers hammer type' do
      pattern = double('Pattern', description: 'A war hammer', name: 'Hammer')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:hammer)
    end

    it 'infers club type' do
      pattern = double('Pattern', description: 'A wooden club', name: 'Club')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:club)
    end

    it 'infers staff type' do
      pattern = double('Pattern', description: 'A quarterstaff', name: 'Staff')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:staff)
    end

    it 'infers spear type' do
      pattern = double('Pattern', description: 'A long spear', name: 'Spear')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:spear)
    end

    it 'infers rifle type' do
      pattern = double('Pattern', description: 'A hunting rifle', name: 'Rifle')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:rifle)
    end

    it 'infers gun type' do
      pattern = double('Pattern', description: 'A firearm', name: 'Gun')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:gun)
    end

    it 'infers fists type' do
      pattern = double('Pattern', description: 'bare fists', name: 'Fist')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:fists)
    end

    it 'uses description over name for inference' do
      # name says one thing, description says another - description should win
      pattern = double('Pattern', description: 'A sharp dagger for stabbing', name: 'Generic Weapon')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:knife)
    end

    it 'handles nil description gracefully' do
      pattern = double('Pattern', description: nil, name: 'Sword')
      expect(service.send(:infer_weapon_type, pattern)).to eq(:sword)
    end

    it 'handles nil name gracefully' do
      pattern = double('Pattern', description: 'A knife', name: nil)
      expect(service.send(:infer_weapon_type, pattern)).to eq(:knife)
    end
  end

  describe 'damage type inference - elemental types' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'infers cold damage from ice' do
      pattern = double('Pattern', description: 'Made of ice', name: 'Ice Shard')
      expect(service.send(:infer_damage_type, pattern)).to eq('cold')
    end

    it 'infers frost damage as cold' do
      pattern = double('Pattern', description: 'Covered in frost', name: 'Frost Blast')
      expect(service.send(:infer_damage_type, pattern)).to eq('cold')
    end

    it 'infers lightning damage' do
      pattern = double('Pattern', description: 'A lightning strike', name: 'Lightning')
      expect(service.send(:infer_damage_type, pattern)).to eq('lightning')
    end

    it 'infers shock damage as lightning' do
      pattern = double('Pattern', description: 'A shock attack', name: 'Shock')
      expect(service.send(:infer_damage_type, pattern)).to eq('lightning')
    end

    it 'handles nil description' do
      pattern = double('Pattern', description: nil, name: 'Something')
      expect(service.send(:infer_damage_type, pattern)).to eq('bludgeoning')
    end
  end

  describe 'describe_ability - chain hits' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'describes chain hit specially' do
      event = {
        event_type: 'ability_hit',
        actor_id: participant1.id,
        details: {
          ability_name: 'Chain Lightning',
          target_name: 'Beta Warrior',
          is_chain: true,
          chain_index: 1
        }
      }

      result = service.send(:describe_ability, event)
      expect(result).to include('arcs')
    end

    it 'describes primary chain hit normally' do
      event = {
        event_type: 'ability_hit',
        actor_id: participant1.id,
        details: {
          ability_name: 'Chain Lightning',
          target_name: 'Beta Warrior',
          is_chain: true,
          chain_index: 0
        }
      }

      result = service.send(:describe_ability, event)
      expect(result).to include('slams')
    end

    it 'describes non-chain ability hit' do
      event = {
        event_type: 'ability_hit',
        actor_id: participant1.id,
        details: {
          ability_name: 'Fireball',
          target_name: 'Beta Warrior',
          is_chain: false
        }
      }

      result = service.send(:describe_ability, event)
      expect(result).to include('Fireball')
      expect(result).to include('slams')
    end

    it 'uses target_name from event when not in details' do
      event = {
        event_type: 'ability_hit',
        actor_id: participant1.id,
        target_name: 'Beta Warrior',
        details: {
          ability_name: 'Fireball'
        }
      }

      result = service.send(:describe_ability, event)
      expect(result).to include('Beta Warrior')
    end
  end

  describe 'describe_ability_start - edge cases' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'returns nil for invalid actor' do
      event = { actor_id: 999999, details: { ability_name: 'Fireball' } }
      expect(service.send(:describe_ability_start, event)).to be_nil
    end

    it 'handles nil details' do
      event = { actor_id: participant1.id, details: nil }
      result = service.send(:describe_ability_start, event)
      expect(result).to include('ability')
    end
  end

  describe 'weapon_action_for - edge cases' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'returns unarmed for nil participant' do
      result = service.send(:weapon_action_for, nil)
      expect(result[:verb]).to eq('throwing')
    end

    it 'returns unarmed when weapon has no pattern' do
      item = create(:item, pattern: nil, character_instance: character_instance1)
      participant1.set(melee_weapon_id: item.id)
      participant1.save_changes

      result = service.send(:weapon_action_for, participant1)
      expect(result[:verb]).to eq('throwing')
    end

    it 'prefers melee weapon for non-ranged attack' do
      melee_pattern = create(:pattern, name: 'Sword', description: 'A sharp sword')
      ranged_pattern = create(:pattern, name: 'Bow', description: 'A longbow')
      melee_item = create(:item, pattern: melee_pattern, character_instance: character_instance1)
      ranged_item = create(:item, pattern: ranged_pattern, character_instance: character_instance1)
      participant1.set(melee_weapon_id: melee_item.id, ranged_weapon_id: ranged_item.id)
      participant1.save_changes

      result = service.send(:weapon_action_for, participant1, is_ranged: false)
      expect(result[:verb]).to eq('swinging')
    end

    it 'prefers ranged weapon for ranged attack' do
      melee_pattern = create(:pattern, name: 'Sword', description: 'A sharp sword')
      ranged_pattern = create(:pattern, name: 'Bow', description: 'A longbow')
      melee_item = create(:item, pattern: melee_pattern, character_instance: character_instance1)
      ranged_item = create(:item, pattern: ranged_pattern, character_instance: character_instance1)
      participant1.set(melee_weapon_id: melee_item.id, ranged_weapon_id: ranged_item.id)
      participant1.save_changes

      result = service.send(:weapon_action_for, participant1, is_ranged: true)
      expect(result[:verb]).to eq('loosing')  # bow verb
    end
  end

  describe 'weapon_name_for - edge cases' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'returns bare hands for nil participant' do
      result = service.send(:weapon_name_for, nil)
      expect(result).to eq('bare hands')
    end

    it 'uses participant id' do
      result = service.send(:weapon_name_for, participant1.id)
      expect(result).to be_a(String)
    end
  end

  describe 'natural attack narrative' do
    let(:service) { described_class.new(fight, enhance_prose: false) }
    let(:archetype) do
      create(:npc_archetype, :creature, name: 'Giant Spider',
             npc_attacks: [
               { 'name' => 'Bite', 'attack_type' => 'melee', 'damage_dice' => '3d6', 'range_hexes' => 1 },
               { 'name' => 'Spit', 'attack_type' => 'ranged', 'damage_dice' => '2d6', 'range_hexes' => 5 }
             ])
    end
    let(:npc_character) { create(:character, :npc, forename: 'Spider', surname: 'Monster', npc_archetype: archetype) }
    let(:npc_instance) do
      CharacterInstance.create(
        character: npc_character,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive'
      )
    end
    let(:npc_participant) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: npc_instance.id,
        side: 2,
        current_hp: 6,
        max_hp: 6,
        main_action: 'attack',
        hex_x: 2,
        hex_y: 0
      )
    end

    before do
      participant1
      npc_participant
    end

    describe '#weapon_action_for with natural attacks' do
      it 'returns bite action for melee natural attack' do
        result = service.send(:weapon_action_for, npc_participant)
        expect(result[:verb]).to eq('biting')
        expect(result[:verb_3p]).to eq('bites')
        expect(result[:noun]).to eq('bites')
        expect(result[:noun_singular]).to eq('bite')
        expect(result[:singular]).to eq('a bite')
      end

      it 'returns spit action for ranged natural attack' do
        result = service.send(:weapon_action_for, npc_participant, is_ranged: true)
        expect(result[:verb]).to eq('spitting')
        expect(result[:verb_3p]).to eq('spits')
      end

      it 'falls back to first attack if no matching type' do
        melee_only_archetype = create(:npc_archetype, :creature, name: 'Bear',
                                      npc_attacks: [
                                        { 'name' => 'Claw', 'attack_type' => 'melee', 'damage_dice' => '2d6', 'range_hexes' => 1 }
                                      ])
        allow(npc_participant).to receive(:npc_archetype).and_return(melee_only_archetype)
        result = service.send(:weapon_action_for, npc_participant, is_ranged: true)
        expect(result[:verb]).to eq('clawing')
        expect(result[:verb_3p]).to eq('claws')
      end

      it 'does not return unarmed punches and kicks' do
        result = service.send(:weapon_action_for, npc_participant)
        expect(result[:noun]).not_to eq('punches and kicks')
      end
    end

    describe '#weapon_name_for with natural attacks' do
      it 'returns attack name instead of bare hands' do
        result = service.send(:weapon_name_for, npc_participant)
        expect(result).to eq('bite')
      end

      it 'returns ranged attack name when is_ranged' do
        result = service.send(:weapon_name_for, npc_participant, is_ranged: true)
        expect(result).to eq('spit')
      end

      it 'falls back to natural weapons when no attacks match' do
        archetype.update(npc_attacks: [])
        # No attacks but using_natural_attacks? will be false, so it goes to normal path
        # Test with stubbed using_natural_attacks? to cover the fallback
        allow(npc_participant).to receive(:using_natural_attacks?).and_return(true)
        allow(npc_participant).to receive(:npc_archetype).and_return(archetype)
        result = service.send(:weapon_name_for, npc_participant)
        expect(result).to eq('natural weapons')
      end
    end

    describe '#natural_attack_action' do
      it 'handles bite attacks' do
        attack = NpcAttack.new('name' => 'Bite', 'attack_type' => 'melee')
        result = service.send(:natural_attack_action, attack)
        expect(result[:verb]).to eq('biting')
        expect(result[:verb_3p]).to eq('bites')
        expect(result[:noun]).to eq('bites')
      end

      it 'handles claw attacks' do
        attack = NpcAttack.new('name' => 'Claw', 'attack_type' => 'melee')
        result = service.send(:natural_attack_action, attack)
        expect(result[:verb]).to eq('clawing')
        expect(result[:verb_3p]).to eq('claws')
        expect(result[:noun]).to eq('claws')
      end

      it 'handles slam attacks' do
        attack = NpcAttack.new('name' => 'Slam', 'attack_type' => 'melee')
        result = service.send(:natural_attack_action, attack)
        expect(result[:verb]).to eq('slamming')
        expect(result[:verb_3p]).to eq('slams')
        expect(result[:noun]).to eq('slams')
      end

      it 'handles sting attacks' do
        attack = NpcAttack.new('name' => 'Sting', 'attack_type' => 'melee')
        result = service.send(:natural_attack_action, attack)
        expect(result[:verb]).to eq('stinging')
        expect(result[:verb_3p]).to eq('stings')
        expect(result[:noun]).to eq('stings')
      end

      it 'handles breath attacks' do
        attack = NpcAttack.new('name' => 'Fire Breath', 'attack_type' => 'ranged')
        result = service.send(:natural_attack_action, attack)
        expect(result[:verb]).to eq('breathing')
        expect(result[:verb_3p]).to eq('breathes fire at')
      end

      it 'derives verb forms for unknown attack names' do
        attack = NpcAttack.new('name' => 'Peck', 'attack_type' => 'melee')
        result = service.send(:natural_attack_action, attack)
        expect(result[:verb]).to eq('pecking')
        expect(result[:verb_3p]).to eq('pecks')
        expect(result[:noun]).to eq('pecks')
        expect(result[:noun_singular]).to eq('peck')
        expect(result[:singular]).to eq('a peck')
      end
    end
  end

  describe 'damage_type - with weapon' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'infers slashing damage type from sword pattern' do
      pattern = create(:pattern, name: 'Sword', description: 'A sharp sword')
      item = create(:item, pattern: pattern, character_instance: character_instance1)
      participant1.set(melee_weapon_id: item.id)
      participant1.save_changes

      hit_event = { details: {} }
      result = service.send(:damage_type, participant1, hit_event)
      expect(result).to eq('slashing')
    end

    it 'infers piercing damage type from spear pattern' do
      pattern = create(:pattern, name: 'Spear', description: 'A long spear')
      item = create(:item, pattern: pattern, character_instance: character_instance1)
      participant1.set(melee_weapon_id: item.id)
      participant1.save_changes

      hit_event = { details: {} }
      result = service.send(:damage_type, participant1, hit_event)
      expect(result).to eq('piercing')
    end

    it 'uses ranged weapon for ranged attacks' do
      melee_pattern = create(:pattern, name: 'Sword', description: 'A sword')
      ranged_pattern = create(:pattern, name: 'Bow', description: 'A bow with arrows')
      melee_item = create(:item, pattern: melee_pattern, character_instance: character_instance1)
      ranged_item = create(:item, pattern: ranged_pattern, character_instance: character_instance1)
      participant1.set(melee_weapon_id: melee_item.id, ranged_weapon_id: ranged_item.id)
      participant1.save_changes

      hit_event = { details: { weapon_type: 'ranged' } }
      result = service.send(:damage_type, participant1, hit_event)
      # Bow infers piercing from 'bow' pattern name
      expect(result).to eq('piercing')
    end
  end

  describe 'attack_verb_for' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'converts -ing verbs to present tense' do
      # Unarmed is "throwing" which should become "throws"
      result = service.send(:attack_verb_for, participant1)
      expect(result).to end_with('s')
    end

    it 'handles verbs not ending in -ing' do
      # If somehow verb doesn't end in -ing, it just appends 's'
      # This is a defensive test
      allow(service).to receive(:weapon_action_for).and_return({ verb: 'stab' })
      result = service.send(:attack_verb_for, participant1)
      expect(result).to eq('stabs')
    end
  end

  describe 'generate - with various event types' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'handles status_applied events' do
      FightEvent.create(
        fight_id: fight.id,
        round_number: 1,
        segment: 5,
        event_type: 'status_applied',
        actor_participant_id: participant1.id,
        target_participant_id: participant2.id,
        details: Sequel.pg_json_wrap({
          target_name: 'Beta Warrior',
          effect_name: 'burning',
          duration_rounds: 3
        })
      )

      svc = described_class.new(fight, enhance_prose: false)
      narrative = svc.generate
      expect(narrative).to include('catches fire')
    end

    it 'handles ability_start events' do
      FightEvent.create(
        fight_id: fight.id,
        round_number: 1,
        segment: 5,
        event_type: 'ability_start',
        actor_participant_id: participant1.id,
        target_participant_id: nil,
        details: Sequel.pg_json_wrap({
          ability_name: 'Fireball'
        })
      )

      svc = described_class.new(fight, enhance_prose: false)
      narrative = svc.generate
      expect(narrative).to include('Fireball')
    end

    it 'handles damage_applied events (summary now broadcast separately)' do
      FightEvent.create(
        fight_id: fight.id,
        round_number: 1,
        segment: 5,
        event_type: 'hit',
        actor_participant_id: participant1.id,
        target_participant_id: participant2.id,
        details: Sequel.pg_json_wrap({
          actor_name: 'Alpha Fighter',
          target_name: 'Beta Warrior',
          total: 15
        })
      )
      FightEvent.create(
        fight_id: fight.id,
        round_number: 1,
        segment: 10,
        event_type: 'damage_applied',
        actor_participant_id: nil,
        target_participant_id: participant2.id,
        details: Sequel.pg_json_wrap({
          target_name: 'Beta Warrior',
          total_damage: 15,
          hp_lost: 2
        })
      )

      svc = described_class.new(fight, enhance_prose: false)
      narrative = svc.generate
      # Damage summary is now broadcast separately as combat_damage_summary,
      # not included in narrative text
      expect(narrative).not_to include('15 dmg')
    end

    it 'handles hazard_damage events' do
      FightEvent.create(
        fight_id: fight.id,
        round_number: 1,
        segment: 5,
        event_type: 'hazard_damage',
        actor_participant_id: nil,
        target_participant_id: participant2.id,
        details: Sequel.pg_json_wrap({
          target_name: 'Beta Warrior',
          hazard_type: 'fire',
          damage: 5
        })
      )

      svc = described_class.new(fight, enhance_prose: false)
      narrative = svc.generate
      expect(narrative).to include('flames')
    end
  end

  describe 'describe_combat_exchange - actor count branches' do
    let(:user3) { create(:user) }
    let(:character3) { create(:character, user: user3, forename: 'Gamma', surname: 'Knight') }
    let(:character_instance3) do
      CharacterInstance.create(
        character: character3,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive'
      )
    end
    let(:participant3) do
      FightParticipant.create(
        fight_id: fight.id,
        character_instance_id: character_instance3.id,
        side: 1,
        current_hp: 6,
        max_hp: 6,
        main_action: 'attack',
        hex_x: 2,
        hex_y: 0
      )
    end
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
      participant3
    end

    it 'delegates to describe_one_sided_attack for single actor' do
      hits_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: { total: 5 } }]
      }
      misses_by_actor = {}

      result = service.send(:describe_combat_exchange, hits_by_actor, misses_by_actor, {})
      expect(result).to be_a(String)
    end

    it 'delegates to describe_two_way_exchange for two actors' do
      hits_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: {} }],
        participant2.id => [{ target_id: participant1.id, details: {} }]
      }
      misses_by_actor = {}

      result = service.send(:describe_combat_exchange, hits_by_actor, misses_by_actor, {})
      expect(result).to be_a(String)
    end

    it 'delegates to describe_melee for three+ actors' do
      hits_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: {} }],
        participant2.id => [{ target_id: participant3.id, details: {} }],
        participant3.id => [{ target_id: participant1.id, details: {} }]
      }
      misses_by_actor = {}

      result = service.send(:describe_combat_exchange, hits_by_actor, misses_by_actor, {})
      expect(result).to include('chaotic melee')
    end

    it 'counts actors from both hits and misses' do
      # Actor 1 hits, actor 2 only misses
      hits_by_actor = {
        participant1.id => [{ target_id: participant2.id, details: {} }]
      }
      misses_by_actor = {
        participant2.id => [{ target_id: participant1.id, details: {} }]
      }

      result = service.send(:describe_combat_exchange, hits_by_actor, misses_by_actor, {})
      # Should be two-way since two unique actors
      expect(result).to be_a(String)
    end
  end

  describe 'parse_round_events' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    it 'parses events with actor_participant_id into actor_id' do
      FightEvent.create(
        fight_id: fight.id,
        round_number: 1,
        segment: 5,
        event_type: 'hit',
        actor_participant_id: participant1.id,
        target_participant_id: participant2.id,
        details: Sequel.pg_json_wrap({ total: 10 })
      )

      svc = described_class.new(fight, enhance_prose: false)
      events = svc.round_events

      expect(events.first[:actor_id]).to eq(participant1.id)
      expect(events.first[:target_id]).to eq(participant2.id)
    end

    it 'populates actor_name and target_name from participant lookup' do
      FightEvent.create(
        fight_id: fight.id,
        round_number: 1,
        segment: 5,
        event_type: 'hit',
        actor_participant_id: participant1.id,
        target_participant_id: participant2.id,
        details: Sequel.pg_json_wrap({})
      )

      svc = described_class.new(fight, enhance_prose: false)
      events = svc.round_events

      expect(events.first[:actor_name]).to eq('Alpha Fighter')
      expect(events.first[:target_name]).to eq('Beta Warrior')
    end

    it 'preserves names from details if provided' do
      FightEvent.create(
        fight_id: fight.id,
        round_number: 1,
        segment: 5,
        event_type: 'hit',
        actor_participant_id: participant1.id,
        target_participant_id: participant2.id,
        details: Sequel.pg_json_wrap({
          actor_name: 'Custom Actor Name',
          target_name: 'Custom Target Name'
        })
      )

      svc = described_class.new(fight, enhance_prose: false)
      events = svc.round_events

      expect(events.first[:actor_name]).to eq('Custom Actor Name')
      expect(events.first[:target_name]).to eq('Custom Target Name')
    end
  end

  describe 'WEAPON_ACTIONS constant coverage' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before { participant1 }

    it 'has action for all inferred weapon types' do
      weapon_types = [:fists, :sword, :knife, :axe, :hammer, :club, :staff, :spear, :pistol, :rifle, :gun, :bow, :unarmed]

      weapon_types.each do |type|
        action = described_class::WEAPON_ACTIONS[type]
        if action
          expect(action).to have_key(:verb)
          expect(action).to have_key(:noun)
        end
      end
    end
  end

  describe 'DEFAULT_WEAPON_ACTION constant' do
    it 'exists and has required keys' do
      default = described_class::DEFAULT_WEAPON_ACTION
      expect(default).to have_key(:verb)
      expect(default).to have_key(:noun)
    end
  end

  describe 'opening generation - round 2+' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
      fight.update(round_number: 2)
    end

    it 'does not prefix narrative with round number' do
      FightEvent.create(
        fight_id: fight.id,
        round_number: 2,
        segment: 5,
        event_type: 'hit',
        actor_participant_id: participant1.id,
        target_participant_id: participant2.id,
        details: Sequel.pg_json_wrap({ total: 10 })
      )

      svc = described_class.new(fight, enhance_prose: false)
      narrative = svc.generate
      expect(narrative).not_to start_with('Round')
    end
  end

  describe 'edge cases and boundary conditions' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    describe '#generate with no events' do
      it 'returns default message when no events exist' do
        # No events created
        narrative = service.generate
        expect(narrative).to include('size each other up')
      end
    end

    describe 'constants' do
      it 'has NUMBER_WORDS for 1-12' do
        (1..12).each do |n|
          expect(described_class::NUMBER_WORDS[n]).to be_a(String)
        end
      end

      it 'has WEAPON_ACTIONS for common weapons' do
        expect(described_class::WEAPON_ACTIONS[:sword]).to have_key(:verb)
        expect(described_class::WEAPON_ACTIONS[:pistol]).to have_key(:verb)
        expect(described_class::WEAPON_ACTIONS[:unarmed]).to have_key(:verb)
      end

      it 'has DEFAULT_WEAPON_ACTION' do
        expect(described_class::DEFAULT_WEAPON_ACTION).to have_key(:verb)
        expect(described_class::DEFAULT_WEAPON_ACTION).to have_key(:noun)
      end

      it 'has DEFEND_PHRASES array' do
        expect(described_class::DEFEND_PHRASES).to be_an(Array)
        expect(described_class::DEFEND_PHRASES).not_to be_empty
      end
    end

    describe '#infer_weapon_type' do
      it 'infers unarmed when pattern description is empty' do
        pattern = double('Pattern', description: '', name: '')
        result = service.send(:infer_weapon_type, pattern)
        expect(result).to eq(:unarmed)
      end

      it 'infers sword type from description' do
        pattern = double('Pattern', description: 'A sharp iron sword', name: 'sword')
        result = service.send(:infer_weapon_type, pattern)
        expect(result).to eq(:sword)
      end

      it 'infers axe type from description' do
        pattern = double('Pattern', description: 'Battle Axe', name: 'weapon')
        result = service.send(:infer_weapon_type, pattern)
        expect(result).to eq(:axe)
      end

      it 'infers pistol type from description' do
        pattern = double('Pattern', description: 'Semi-automatic pistol', name: 'weapon')
        result = service.send(:infer_weapon_type, pattern)
        expect(result).to eq(:pistol)
      end

      it 'infers bow type from description' do
        pattern = double('Pattern', description: 'Longbow', name: 'bow')
        result = service.send(:infer_weapon_type, pattern)
        expect(result).to eq(:bow)
      end

      it 'returns unarmed for unknown weapon types' do
        pattern = double('Pattern', description: 'Alien Blaster XR-7000', name: 'weapon')
        result = service.send(:infer_weapon_type, pattern)
        expect(result).to eq(:unarmed)
      end
    end

    describe '#attack_event?' do
      it 'recognizes hit as attack event' do
        event = { event_type: 'hit' }
        expect(service.send(:attack_event?, event)).to be true
      end

      it 'recognizes miss as attack event' do
        event = { event_type: 'miss' }
        expect(service.send(:attack_event?, event)).to be true
      end

      it 'does not recognize move as attack event' do
        event = { event_type: 'move' }
        expect(service.send(:attack_event?, event)).to be false
      end

      it 'does not recognize knockout as attack event' do
        event = { event_type: 'knockout' }
        expect(service.send(:attack_event?, event)).to be false
      end
    end

    describe '#build_movement_context' do
      it 'builds context from movement events' do
        movements = [
          { actor_id: participant1.id, details: { direction: 'towards', distance: 2 } }
        ]

        result = service.send(:build_movement_context, movements)
        expect(result[participant1.id]).to be_a(Hash)
      end

      it 'handles empty movement array' do
        result = service.send(:build_movement_context, [])
        expect(result).to be_empty
      end
    end

    describe 'prose enhancement toggle' do
      it 'respects enhance_prose: false parameter' do
        svc = described_class.new(fight, enhance_prose: false)
        expect(svc.instance_variable_get(:@enhance_prose)).to be false
      end

      it 'respects enhance_prose: true parameter' do
        svc = described_class.new(fight, enhance_prose: true)
        expect(svc.instance_variable_get(:@enhance_prose)).to be true
      end

      it 'auto-detects enhancement setting when nil' do
        allow(CombatProseEnhancementService).to receive(:enabled?).and_return(true)
        svc = described_class.new(fight, enhance_prose: nil)
        expect(svc.instance_variable_get(:@enhance_prose)).to be true
      end
    end

    describe 'spar mode touch descriptions' do
      let(:spar_fight) { Fight.create(room_id: room.id, status: 'narrative', round_number: 1, mode: 'spar') }
      let(:spar_service) { described_class.new(spar_fight, enhance_prose: false) }

      before do
        FightParticipant.create(
          fight_id: spar_fight.id,
          character_instance_id: character_instance1.id,
          side: 1,
          current_hp: 6,
          max_hp: 6,
          main_action: 'attack',
          hex_x: 0,
          hex_y: 0
        )
      end

      it 'has touch descriptions for 1, 2, and 3 touches' do
        expect(described_class::TOUCH_DESCRIPTIONS[1]).not_to be_empty
        expect(described_class::TOUCH_DESCRIPTIONS[2]).not_to be_empty
        expect(described_class::TOUCH_DESCRIPTIONS[3]).not_to be_empty
      end
    end

    describe 'weapon action descriptions' do
      it 'has verb and noun for sword' do
        expect(described_class::WEAPON_ACTIONS[:sword][:verb]).to be_a(String)
        expect(described_class::WEAPON_ACTIONS[:sword][:noun]).to be_a(String)
      end

      it 'has verb and noun for pistol' do
        expect(described_class::WEAPON_ACTIONS[:pistol][:verb]).to be_a(String)
        expect(described_class::WEAPON_ACTIONS[:pistol][:noun]).to be_a(String)
      end

      it 'has verb and noun for unarmed' do
        expect(described_class::WEAPON_ACTIONS[:unarmed][:verb]).to be_a(String)
        expect(described_class::WEAPON_ACTIONS[:unarmed][:noun]).to be_a(String)
      end

      it 'has verb and noun for rifle' do
        expect(described_class::WEAPON_ACTIONS[:rifle][:verb]).to be_a(String)
        expect(described_class::WEAPON_ACTIONS[:rifle][:noun]).to be_a(String)
      end
    end

    describe 'number_word helper edge cases' do
      it 'returns word for numbers 1-12' do
        (1..12).each do |n|
          result = service.send(:number_word, n)
          expect(result).to be_a(String)
          expect(result).not_to eq(n.to_s) # Should be word, not number
        end
      end

      it 'returns number as string for numbers over 12' do
        expect(service.send(:number_word, 13)).to eq('13')
        expect(service.send(:number_word, 100)).to eq('100')
      end

      it 'handles zero' do
        result = service.send(:number_word, 0)
        expect(result).to eq('0')
      end

      it 'handles negative numbers' do
        result = service.send(:number_word, -5)
        expect(result).to eq('-5')
      end
    end

    describe 'capitalize_name helper edge cases' do
      it 'capitalizes simple name' do
        result = service.send(:capitalize_name, 'john')
        expect(result).to eq('John')
      end

      it 'handles already capitalized name' do
        result = service.send(:capitalize_name, 'John')
        expect(result).to eq('John')
      end

      it 'handles all caps name' do
        result = service.send(:capitalize_name, 'JOHN')
        expect(result[0]).to eq('J')
      end

      it 'handles empty string' do
        result = service.send(:capitalize_name, '')
        expect(result).to eq('')
      end

      it 'handles single character' do
        result = service.send(:capitalize_name, 'j')
        expect(result).to eq('J')
      end
    end

    describe 'event grouping edge cases' do
      it 'groups sequential hit events from same attacker' do
        # Create FightEvent records (generate reads from database)
        3.times do |i|
          FightEvent.create(
            fight_id: fight.id,
            round_number: fight.round_number,
            segment: i,
            event_type: 'hit',
            actor_participant_id: participant1.id,
            target_participant_id: participant2.id,
            details: Sequel.pg_json_wrap({ total: 10 })
          )
        end

        svc = described_class.new(fight, enhance_prose: false)
        result = svc.generate
        expect(result).to be_a(String)
      end

      it 'handles interleaved events from different attackers' do
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 0,
          event_type: 'hit', actor_participant_id: participant1.id,
          target_participant_id: participant2.id, details: Sequel.pg_json_wrap({ total: 10 })
        )
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 1,
          event_type: 'hit', actor_participant_id: participant2.id,
          target_participant_id: participant1.id, details: Sequel.pg_json_wrap({ total: 8 })
        )
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 2,
          event_type: 'hit', actor_participant_id: participant1.id,
          target_participant_id: participant2.id, details: Sequel.pg_json_wrap({ total: 12 })
        )

        svc = described_class.new(fight, enhance_prose: false)
        result = svc.generate
        expect(result).to be_a(String)
      end

      it 'handles mixed event types' do
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 0,
          event_type: 'hit', actor_participant_id: participant1.id,
          target_participant_id: participant2.id, details: Sequel.pg_json_wrap({ total: 10 })
        )
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 1,
          event_type: 'move', actor_participant_id: participant1.id,
          target_participant_id: nil, details: Sequel.pg_json_wrap({ direction: 'towards' })
        )
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 2,
          event_type: 'miss', actor_participant_id: participant2.id,
          target_participant_id: participant1.id, details: Sequel.pg_json_wrap({})
        )

        svc = described_class.new(fight, enhance_prose: false)
        result = svc.generate
        expect(result).to be_a(String)
      end
    end

    describe 'damage description edge cases' do
      it 'generates narrative for zero damage hit' do
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 0,
          event_type: 'hit', actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({ total: 0, effective_damage: 0 })
        )

        svc = described_class.new(fight, enhance_prose: false)
        result = svc.generate
        expect(result).to be_a(String)
      end

      it 'generates narrative for very high damage hit' do
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 0,
          event_type: 'hit', actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({ total: 1000, effective_damage: 1000 })
        )

        svc = described_class.new(fight, enhance_prose: false)
        result = svc.generate
        expect(result).to be_a(String)
      end

      it 'handles hit events with missing damage details' do
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 0,
          event_type: 'hit', actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({})
        )

        svc = described_class.new(fight, enhance_prose: false)
        result = svc.generate
        expect(result).to be_a(String)
      end
    end

    describe 'status effect narrative edge cases' do
      it 'describes multiple status effects applied' do
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 0,
          event_type: 'status_applied', actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({ effect_name: 'burning', duration_rounds: 3, target_name: 'Target' })
        )
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 1,
          event_type: 'status_applied', actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({ effect_name: 'stunned', duration_rounds: 1, target_name: 'Target' })
        )

        svc = described_class.new(fight, enhance_prose: false)
        result = svc.generate
        expect(result).to be_a(String)
        expect(result).to include('fire') # burning includes fire
        expect(result).to include('stunned')
      end

      it 'handles unknown status effect' do
        event = { event_type: 'status_applied', details: { effect_name: 'unknown_effect', duration_rounds: 2, target_name: 'Test' } }
        result = service.send(:describe_status_applied, event)
        expect(result).to include('Unknown effect')
      end
    end

    describe 'ability narrative edge cases' do
      it 'describes heal ability' do
        event = {
          event_type: 'ability_heal',
          actor_id: participant1.id,
          target_name: 'Self',
          details: { ability_name: 'Heal', self_target: true, target_name: 'Self' }
        }
        result = service.send(:describe_ability, event)
        expect(result).to include('restorative')
      end

      it 'describes damage ability' do
        event = {
          event_type: 'ability_hit',
          actor_id: participant1.id,
          target_name: 'Target',
          details: { ability_name: 'Fireball', target_name: 'Target' }
        }
        result = service.send(:describe_ability, event)
        expect(result).to include('slams into')
      end

      it 'describes chain ability' do
        event = {
          event_type: 'ability_hit',
          actor_id: participant1.id,
          target_name: 'Second Target',
          details: { ability_name: 'Chain Lightning', is_chain: true, chain_index: 1, target_name: 'Second Target' }
        }
        result = service.send(:describe_ability, event)
        expect(result).to include('arcs to')
      end
    end

    describe 'movement narrative edge cases' do
      # Movement is handled via build_movement_context and integrated into attack descriptions
      it 'builds movement context for towards direction' do
        movements = [{
          actor_id: participant1.id,
          event_type: 'move',
          details: { direction: 'towards', distance: 3, target_name: 'Target' }
        }]

        result = service.build_movement_context(movements)
        expect(result[participant1.id][:direction]).to eq('towards')
        expect(result[participant1.id][:moved]).to be true
      end

      it 'builds movement context for away direction' do
        movements = [{
          actor_id: participant1.id,
          event_type: 'move',
          details: { direction: 'away', distance: 2, target_name: 'Target' }
        }]

        result = service.build_movement_context(movements)
        expect(result[participant1.id][:direction]).to eq('away')
        expect(result[participant1.id][:moved]).to be true
      end

      it 'handles stand_still movement' do
        movements = [{
          actor_id: participant1.id,
          event_type: 'move',
          details: { direction: 'stand_still', distance: 0 }
        }]

        result = service.build_movement_context(movements)
        expect(result[participant1.id][:direction]).to eq('stand_still')
        expect(result[participant1.id][:moved]).to be false
      end
    end

    describe 'knockout narrative edge cases' do
      it 'generates knockout text with target name' do
        events = [{ event_type: 'knockout', target_name: 'Alpha' }]
        result = service.send(:generate_knockouts, events)
        expect(result).to include('Alpha')
        expect(result).to include('knocked out')
      end

      it 'handles multiple knockouts' do
        events = [
          { event_type: 'knockout', target_name: 'Alpha' },
          { event_type: 'knockout', target_name: 'Beta' }
        ]
        result = service.send(:generate_knockouts, events)
        expect(result).to include('Alpha')
        expect(result).to include('Beta')
      end

      it 'returns nil for empty events' do
        result = service.send(:generate_knockouts, [])
        expect(result).to be_nil
      end
    end

    describe 'flee and surrender narrative edge cases' do
      # Note: flee_success, flee_failed, surrender are not currently handled by generate
      # but the service should not crash when encountering unknown event types
      it 'handles unknown event types gracefully' do
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 0,
          event_type: 'flee_success', actor_participant_id: participant1.id,
          target_participant_id: nil, details: Sequel.pg_json_wrap({})
        )

        svc = described_class.new(fight, enhance_prose: false)
        # Should not raise error, but may return default message
        expect { svc.generate }.not_to raise_error
      end

      it 'includes flee events in round_events' do
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 0,
          event_type: 'flee_success', actor_participant_id: participant1.id,
          target_participant_id: nil, details: Sequel.pg_json_wrap({})
        )

        svc = described_class.new(fight, enhance_prose: false)
        expect(svc.round_events).not_to be_empty
        expect(svc.round_events.first[:event_type]).to eq('flee_success')
      end
    end

    describe 'defend narrative edge cases' do
      it 'uses varied defend phrases' do
        expect(described_class::DEFEND_PHRASES).to be_an(Array)
        expect(described_class::DEFEND_PHRASES.size).to be > 1
      end
    end

    describe 'round damage summary edge cases' do
      it 'generates damage summary from damage_applied events' do
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 0,
          event_type: 'damage_applied', actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({ total_damage: 15, hp_lost: 2, target_name: 'Beta' })
        )

        svc = described_class.new(fight, enhance_prose: false)
        result = svc.generate
        # Should include damage summary at end
        expect(result).to be_a(String)
      end

      it 'generates summary with multiple participants damaged' do
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 0,
          event_type: 'hit', actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({ total: 20, effective_damage: 20 })
        )
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 1,
          event_type: 'hit', actor_participant_id: participant2.id,
          target_participant_id: participant1.id,
          details: Sequel.pg_json_wrap({ total: 25, effective_damage: 25 })
        )
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 2,
          event_type: 'damage_applied', actor_participant_id: nil,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({ total_damage: 20, hp_lost: 2, target_name: 'Beta' })
        )
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 3,
          event_type: 'damage_applied', actor_participant_id: nil,
          target_participant_id: participant1.id,
          details: Sequel.pg_json_wrap({ total_damage: 25, hp_lost: 2, target_name: 'Alpha' })
        )

        svc = described_class.new(fight, enhance_prose: false)
        result = svc.generate
        expect(result).to be_a(String)
        # Damage summary is now broadcast separately, not in narrative
        expect(result).not_to include('[')
      end
    end

    describe 'monster combat narrative edge cases' do
      # Monster-specific events are not directly handled but shouldn't crash
      it 'handles unknown monster event types gracefully' do
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 0,
          event_type: 'monster_attack', actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({ monster_name: 'Giant Spider', segment_name: 'Leg' })
        )

        svc = described_class.new(fight, enhance_prose: false)
        expect { svc.generate }.not_to raise_error
      end

      it 'parses monster event details correctly' do
        FightEvent.create(
          fight_id: fight.id, round_number: fight.round_number, segment: 0,
          event_type: 'monster_attack', actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({ monster_name: 'Dragon', segment_name: 'Claw' })
        )

        svc = described_class.new(fight, enhance_prose: false)
        expect(svc.round_events).not_to be_empty
        expect(svc.round_events.first[:details][:monster_name]).to eq('Dragon')
      end
    end

    describe 'event details parsing edge cases' do
      it 'parses string details as JSON' do
        # parse_details is a private method that handles various detail formats
        result = service.send(:parse_details, '{"key": "value"}')
        expect(result).to eq({ key: 'value' })
      end

      it 'handles invalid JSON string gracefully' do
        # Should return empty hash on parse error
        result = service.send(:parse_details, 'not valid json')
        expect(result).to eq({})
      end

      it 'handles nil details' do
        result = service.send(:parse_details, nil)
        expect(result).to eq({})
      end

      it 'handles empty hash details' do
        result = service.send(:parse_details, {})
        expect(result).to eq({})
      end

      it 'handles hash-like objects with to_h' do
        obj = double('HashLike')
        allow(obj).to receive(:respond_to?).with(:to_h).and_return(true)
        allow(obj).to receive(:to_h).and_return({ foo: 'bar' })
        result = service.send(:parse_details, obj)
        expect(result).to eq({ foo: 'bar' })
      end

      it 'deep symbolizes keys' do
        result = service.send(:deep_symbolize_keys, { 'outer' => { 'inner' => 'value' } })
        expect(result).to eq({ outer: { inner: 'value' } })
      end
    end
  end

  describe 'attack sequence constants' do
    it 'has MISS_FLAVORS with melee and ranged pools' do
      expect(described_class::MISS_FLAVORS[:melee]).to be_an(Array)
      expect(described_class::MISS_FLAVORS[:melee].length).to be >= 4
      expect(described_class::MISS_FLAVORS[:ranged]).to be_an(Array)
      expect(described_class::MISS_FLAVORS[:ranged].length).to be >= 4
    end

    it 'has IMPACT_DESCRIPTIONS organized by damage type and hp_lost' do
      %i[slashing piercing bludgeoning generic].each do |type|
        expect(described_class::IMPACT_DESCRIPTIONS[type]).to be_a(Hash)
        (1..4).each do |hp|
          expect(described_class::IMPACT_DESCRIPTIONS[type][hp]).to be_an(Array)
          expect(described_class::IMPACT_DESCRIPTIONS[type][hp].length).to be >= 2
        end
      end
    end

    it 'has IMPACT_DESCRIPTIONS for elemental types' do
      %i[fire cold lightning].each do |type|
        expect(described_class::IMPACT_DESCRIPTIONS[type]).to be_a(Hash)
        expect(described_class::IMPACT_DESCRIPTIONS[type][1]).to be_an(Array)
      end
    end

    it 'has SPAR_MISS_FLAVORS' do
      expect(described_class::SPAR_MISS_FLAVORS).to be_an(Array)
      expect(described_class::SPAR_MISS_FLAVORS.length).to be >= 3
    end

    it 'has SPAR_IMPACT_DESCRIPTIONS' do
      expect(described_class::SPAR_IMPACT_DESCRIPTIONS).to be_a(Hash)
      (1..3).each do |hp|
        expect(described_class::SPAR_IMPACT_DESCRIPTIONS[hp]).to be_an(Array)
      end
    end

    it 'has ORDINAL_WORDS' do
      expect(described_class::ORDINAL_WORDS[1]).to eq('first')
      expect(described_class::ORDINAL_WORDS[5]).to eq('fifth')
    end
  end

  describe '#analyze_attack_sequence' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'returns structured analysis of hits and misses' do
      events = [
        { event_type: 'miss', details: { weapon_type: 'melee', damage_type: 'slashing', threshold_crossed: false, hp_lost_this_attack: 0 } },
        { event_type: 'miss', details: { weapon_type: 'melee', damage_type: 'slashing', threshold_crossed: false, hp_lost_this_attack: 0 } },
        { event_type: 'hit', details: { weapon_type: 'melee', damage_type: 'slashing', threshold_crossed: true, hp_lost_this_attack: 1 } },
        { event_type: 'miss', details: { weapon_type: 'melee', damage_type: 'slashing', threshold_crossed: false, hp_lost_this_attack: 0 } },
        { event_type: 'hit', details: { weapon_type: 'melee', damage_type: 'slashing', threshold_crossed: false, hp_lost_this_attack: 0 } },
      ]

      result = service.send(:analyze_attack_sequence, events)

      expect(result[:total_attacks]).to eq(5)
      expect(result[:hit_indices]).to eq([2, 4])
      expect(result[:miss_indices]).to eq([0, 1, 3])
      expect(result[:threshold_indices]).to eq([2])
      expect(result[:total_hp_lost]).to eq(1)
      expect(result[:weapon_type]).to eq('melee')
      expect(result[:damage_type]).to eq('slashing')
    end

    it 'handles all hits' do
      events = [
        { event_type: 'hit', details: { weapon_type: 'melee', damage_type: 'bludgeoning', threshold_crossed: true, hp_lost_this_attack: 2 } },
      ]

      result = service.send(:analyze_attack_sequence, events)
      expect(result[:total_attacks]).to eq(1)
      expect(result[:hit_indices]).to eq([0])
      expect(result[:miss_indices]).to eq([])
      expect(result[:total_hp_lost]).to eq(2)
    end

    it 'handles all misses' do
      events = [
        { event_type: 'miss', details: { weapon_type: 'ranged', damage_type: 'piercing', threshold_crossed: false, hp_lost_this_attack: 0 } },
        { event_type: 'miss', details: { weapon_type: 'ranged', damage_type: 'piercing', threshold_crossed: false, hp_lost_this_attack: 0 } },
      ]

      result = service.send(:analyze_attack_sequence, events)
      expect(result[:total_attacks]).to eq(2)
      expect(result[:hit_indices]).to eq([])
      expect(result[:total_hp_lost]).to eq(0)
      expect(result[:weapon_type]).to eq('ranged')
    end

    it 'works without threshold data (backwards compat)' do
      events = [
        { event_type: 'hit', details: { weapon_type: 'melee', damage_type: 'slashing' } },
        { event_type: 'miss', details: { weapon_type: 'melee', damage_type: 'slashing' } },
      ]

      result = service.send(:analyze_attack_sequence, events)
      expect(result[:total_attacks]).to eq(2)
      expect(result[:hit_indices]).to eq([0])
      expect(result[:threshold_indices]).to eq([0])
    end
  end

  describe '#describe_attack_pattern' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    def make_analysis(total:, hits:, misses:, thresholds:, hp_lost:, weapon: 'melee', damage: 'slashing')
      {
        total_attacks: total,
        hit_indices: hits,
        miss_indices: misses,
        threshold_indices: thresholds,
        total_hp_lost: hp_lost,
        weapon_type: weapon,
        damage_type: damage
      }
    end

    context 'all misses' do
      it 'describes melee misses as blocks/parries' do
        analysis = make_analysis(total: 3, hits: [], misses: [0, 1, 2], thresholds: [], hp_lost: 0)
        result = service.send(:describe_attack_pattern, analysis, 'Alpha', 'Beta', 'punches')
        expect(result).to match(/blocks|parries|deflects|sidesteps|catches|turns aside|wards off/i)
      end

      it 'describes ranged misses as going wide' do
        analysis = make_analysis(total: 3, hits: [], misses: [0, 1, 2], thresholds: [], hp_lost: 0, weapon: 'ranged')
        result = service.send(:describe_attack_pattern, analysis, 'Alpha', 'Beta', 'shots')
        expect(result).to match(/wide|miss|past|overhead|astray/i)
      end
    end

    context 'all hits with HP loss' do
      it 'includes impact description' do
        analysis = make_analysis(total: 2, hits: [0, 1], misses: [], thresholds: [0], hp_lost: 1)
        result = service.send(:describe_attack_pattern, analysis, 'Alpha', 'Beta', 'slashes')
        expect(result.length).to be > 10
        expect(result).to match(/Alpha|Beta/)
      end
    end

    context 'mixed hits and misses' do
      it 'generates prose for mixed attack pattern' do
        analysis = make_analysis(total: 5, hits: [2, 3], misses: [0, 1, 4], thresholds: [2], hp_lost: 1)
        result = service.send(:describe_attack_pattern, analysis, 'Alpha', 'Beta', 'punches')
        expect(result.length).to be > 20
      end

      it 'describes melee miss portion with defensive verbs' do
        analysis = make_analysis(total: 5, hits: [2], misses: [0, 1, 3, 4], thresholds: [2], hp_lost: 1)
        result = service.send(:describe_attack_pattern, analysis, 'Alpha', 'Beta', 'punches')
        expect(result).to match(/blocks|parries|deflects|sidesteps|catches|turns aside|wards off/i)
      end
    end

    context 'spar mode' do
      before { allow(fight).to receive(:spar_mode?).and_return(true) }

      it 'uses spar-flavored language for misses' do
        analysis = make_analysis(total: 3, hits: [], misses: [0, 1, 2], thresholds: [], hp_lost: 0)
        result = service.send(:describe_attack_pattern, analysis, 'Alpha', 'Beta', 'swings')
        expect(result).to match(/blocks|deflects|sidesteps|ducks|wards off/i)
      end

      it 'uses spar-flavored language for hits' do
        analysis = make_analysis(total: 2, hits: [0, 1], misses: [], thresholds: [0], hp_lost: 1)
        result = service.send(:describe_attack_pattern, analysis, 'Alpha', 'Beta', 'swings')
        expect(result).to match(/tag|touch|scoring|point/i)
      end
    end
  end

  describe '#join_ordinals' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'handles single ordinal' do
      expect(service.send(:join_ordinals, ['first'])).to eq('first')
    end

    it 'handles two ordinals' do
      expect(service.send(:join_ordinals, ['second', 'fourth'])).to eq('second and fourth')
    end

    it 'handles three ordinals with Oxford comma' do
      expect(service.send(:join_ordinals, ['first', 'third', 'fifth'])).to eq('first, third, and fifth')
    end
  end

  describe '#impact_phrase' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    it 'returns slashing impact for slashing damage' do
      result = service.send(:impact_phrase, 1, 'slashing', false)
      expect(CombatNarrativeService::IMPACT_DESCRIPTIONS[:slashing][1]).to include(result)
    end

    it 'returns generic impact for unknown damage type' do
      result = service.send(:impact_phrase, 1, 'unknown_type', false)
      expect(CombatNarrativeService::IMPACT_DESCRIPTIONS[:generic][1]).to include(result)
    end

    it 'returns spar impact in spar mode' do
      result = service.send(:impact_phrase, 1, 'slashing', true)
      expect(CombatNarrativeService::SPAR_IMPACT_DESCRIPTIONS[1]).to include(result)
    end

    it 'clamps HP lost to 4' do
      result = service.send(:impact_phrase, 6, 'bludgeoning', false)
      expect(CombatNarrativeService::IMPACT_DESCRIPTIONS[:bludgeoning][4]).to include(result)
    end
  end

  describe 'exchange narrative with attack patterns' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    context 'one-sided melee attack with mixed results' do
      before do
        participant1; participant2
        [10, 20, 30].each do |seg|
          FightEvent.create(
            fight_id: fight.id, round_number: 1, segment: seg,
            event_type: 'miss',
            actor_participant_id: participant1.id,
            target_participant_id: participant2.id,
            details: Sequel.pg_json_wrap({
              weapon_type: 'melee', damage_type: 'slashing',
              threshold_crossed: false, hp_lost_this_attack: 0, total: 5
            })
          )
        end
        FightEvent.create(
          fight_id: fight.id, round_number: 1, segment: 40,
          event_type: 'hit',
          actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({
            weapon_type: 'melee', damage_type: 'slashing',
            threshold_crossed: true, hp_lost_this_attack: 1, total: 15
          })
        )
      end

      it 'generates narrative with defensive verbs for misses' do
        svc = described_class.new(fight, enhance_prose: false)
        narrative = svc.generate
        expect(narrative).to match(/blocks|parries|deflects|sidesteps|wards off|turns aside/i)
        expect(narrative.length).to be > 30
      end
    end

    context 'ranged attacks all missing' do
      before do
        participant1; participant2
        3.times do |i|
          FightEvent.create(
            fight_id: fight.id, round_number: 1, segment: (i + 1) * 10,
            event_type: 'miss',
            actor_participant_id: participant1.id,
            target_participant_id: participant2.id,
            details: Sequel.pg_json_wrap({
              weapon_type: 'ranged', damage_type: 'piercing',
              threshold_crossed: false, hp_lost_this_attack: 0, total: 3
            })
          )
        end
      end

      it 'uses ranged miss language' do
        svc = described_class.new(fight, enhance_prose: false)
        narrative = svc.generate
        expect(narrative).to match(/wide|miss|past|overhead|mark|astray/i)
      end
    end

    context 'two-way exchange' do
      before do
        participant1; participant2
        FightEvent.create(
          fight_id: fight.id, round_number: 1, segment: 10,
          event_type: 'hit',
          actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({
            weapon_type: 'melee', damage_type: 'bludgeoning',
            threshold_crossed: true, hp_lost_this_attack: 1, total: 15
          })
        )
        FightEvent.create(
          fight_id: fight.id, round_number: 1, segment: 15,
          event_type: 'miss',
          actor_participant_id: participant2.id,
          target_participant_id: participant1.id,
          details: Sequel.pg_json_wrap({
            weapon_type: 'melee', damage_type: 'slashing',
            threshold_crossed: false, hp_lost_this_attack: 0, total: 3
          })
        )
      end

      it 'describes both sides of the exchange' do
        svc = described_class.new(fight, enhance_prose: false)
        narrative = svc.generate
        expect(narrative.length).to be > 30
        # Should have both attacker names
        expect(narrative).to include('Alpha').or include('Beta')
      end
    end

    context 'ability events woven inline' do
      before do
        participant1; participant2
        FightEvent.create(
          fight_id: fight.id, round_number: 1, segment: 10,
          event_type: 'miss',
          actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({ weapon_type: 'melee', damage_type: 'bludgeoning', threshold_crossed: false, hp_lost_this_attack: 0, total: 5 })
        )
        FightEvent.create(
          fight_id: fight.id, round_number: 1, segment: 30,
          event_type: 'ability_start',
          actor_participant_id: participant1.id,
          target_participant_id: nil,
          details: Sequel.pg_json_wrap({ ability_name: 'Power Strike' })
        )
        FightEvent.create(
          fight_id: fight.id, round_number: 1, segment: 40,
          event_type: 'ability_hit',
          actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({ ability_name: 'Power Strike', target_name: 'Beta Warrior', effective_damage: 20 })
        )
      end

      it 'includes ability name in narrative' do
        svc = described_class.new(fight, enhance_prose: false)
        narrative = svc.generate
        expect(narrative).to include('Power Strike')
      end
    end
  end

  describe 'weapon phase transitions' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    before do
      participant1
      participant2
    end

    describe '#split_by_weapon_phase' do
      it 'returns single phase when all events have same weapon_type' do
        events = [
          { event_type: 'hit', details: { weapon_type: 'melee' }, segment: 1 },
          { event_type: 'miss', details: { weapon_type: 'melee' }, segment: 2 },
          { event_type: 'hit', details: { weapon_type: 'melee' }, segment: 3 }
        ]
        phases = service.send(:split_by_weapon_phase, events)
        expect(phases.length).to eq(1)
        expect(phases[0][:weapon_type]).to eq('melee')
        expect(phases[0][:events].length).to eq(3)
      end

      it 'splits events when weapon type changes from ranged to melee' do
        events = [
          { event_type: 'hit', details: { weapon_type: 'ranged' }, segment: 1 },
          { event_type: 'miss', details: { weapon_type: 'ranged' }, segment: 2 },
          { event_type: 'hit', details: { weapon_type: 'melee' }, segment: 3 },
          { event_type: 'hit', details: { weapon_type: 'melee' }, segment: 4 }
        ]
        phases = service.send(:split_by_weapon_phase, events)
        expect(phases.length).to eq(2)
        expect(phases[0][:weapon_type]).to eq('ranged')
        expect(phases[0][:events].length).to eq(2)
        expect(phases[1][:weapon_type]).to eq('melee')
        expect(phases[1][:events].length).to eq(2)
      end

      it 'splits events when weapon type changes from melee to ranged' do
        events = [
          { event_type: 'hit', details: { weapon_type: 'melee' }, segment: 1 },
          { event_type: 'hit', details: { weapon_type: 'ranged' }, segment: 2 }
        ]
        phases = service.send(:split_by_weapon_phase, events)
        expect(phases.length).to eq(2)
        expect(phases[0][:weapon_type]).to eq('melee')
        expect(phases[1][:weapon_type]).to eq('ranged')
      end

      it 'handles empty events' do
        phases = service.send(:split_by_weapon_phase, [])
        expect(phases.length).to eq(1)
        expect(phases[0][:events]).to be_empty
      end

      it 'defaults to melee when weapon_type is missing' do
        events = [
          { event_type: 'hit', details: {}, segment: 1 }
        ]
        phases = service.send(:split_by_weapon_phase, events)
        expect(phases[0][:weapon_type]).to eq('melee')
      end
    end

    describe 'WEAPON_TRANSITION_PHRASES' do
      it 'has ranged_to_melee phrases for towards direction' do
        phrases = described_class::WEAPON_TRANSITION_PHRASES[:ranged_to_melee_towards]
        expect(phrases).to be_an(Array)
        expect(phrases).not_to be_empty
        expect(phrases).to include('closes to melee range, drawing')
      end

      it 'has ranged_to_melee phrases for still direction' do
        phrases = described_class::WEAPON_TRANSITION_PHRASES[:ranged_to_melee_still]
        expect(phrases).to be_an(Array)
        expect(phrases).not_to be_empty
      end

      it 'has melee_to_ranged phrases for away direction' do
        phrases = described_class::WEAPON_TRANSITION_PHRASES[:melee_to_ranged_away]
        expect(phrases).to be_an(Array)
        expect(phrases).not_to be_empty
        expect(phrases).to include('falls back, drawing')
      end
    end

    describe 'one-sided attack with weapon switch' do
      it 'generates multi-phase narrative for ranged-to-melee transition' do
        # Create events: 2 ranged shots then 2 melee hits
        [
          { segment: 1, weapon_type: 'ranged', event_type: 'hit' },
          { segment: 2, weapon_type: 'ranged', event_type: 'miss' },
          { segment: 3, weapon_type: 'melee', event_type: 'hit' },
          { segment: 4, weapon_type: 'melee', event_type: 'hit' }
        ].each do |attrs|
          FightEvent.create(
            fight_id: fight.id,
            round_number: 1,
            segment: attrs[:segment],
            event_type: attrs[:event_type],
            actor_participant_id: participant1.id,
            target_participant_id: participant2.id,
            details: Sequel.pg_json_wrap({
              actor_name: 'Alpha Fighter',
              target_name: 'Beta Warrior',
              weapon_type: attrs[:weapon_type],
              total: 10,
              effective_damage: 10
            })
          )
        end

        svc = described_class.new(fight, enhance_prose: false)
        narrative = svc.generate

        # Should mention both weapon phases - the narrative should contain a transition
        expect(narrative).to include('Alpha Fighter')
        expect(narrative).to include('Beta Warrior')
        # Should have transition language (still/away variants use simpler phrases)
        expect(narrative).to match(/then (closes to melee range|charges in|closes the distance|rushes in|switches to|draws|pulls out|readies)/)
      end

      it 'generates single-phase narrative when no weapon switch occurs' do
        # All melee events
        [1, 2, 3].each do |seg|
          FightEvent.create(
            fight_id: fight.id,
            round_number: 1,
            segment: seg,
            event_type: 'hit',
            actor_participant_id: participant1.id,
            target_participant_id: participant2.id,
            details: Sequel.pg_json_wrap({
              actor_name: 'Alpha Fighter',
              target_name: 'Beta Warrior',
              weapon_type: 'melee',
              total: 10,
              effective_damage: 10
            })
          )
        end

        svc = described_class.new(fight, enhance_prose: false)
        narrative = svc.generate

        # Should NOT contain transition phrases
        expect(narrative).not_to match(/then (closes to melee range|charges in|falls back|disengages)/)
      end
    end

    describe '#weapon_transition_phrase' do
      it 'generates ranged-to-melee transition with no movement (still)' do
        phrase = service.send(:weapon_transition_phrase, :ranged, :melee, participant1, false)
        expect(phrase).to start_with('then ')
        expect(phrase).to match(/(switches to|draws|pulls out|readies)/)
      end

      it 'generates ranged-to-melee transition with towards movement' do
        service.instance_variable_get(:@movement_by_actor)[participant1.id] = { direction: 'towards', moved: true }
        phrase = service.send(:weapon_transition_phrase, :ranged, :melee, participant1, false, actor_id: participant1.id)
        expect(phrase).to start_with('then ')
        expect(phrase).to match(/(closes to melee range|charges in|closes the distance|rushes in)/)
      end

      it 'generates melee-to-ranged transition with away movement' do
        service.instance_variable_get(:@movement_by_actor)[participant1.id] = { direction: 'away', moved: true }
        phrase = service.send(:weapon_transition_phrase, :melee, :ranged, participant1, true, actor_id: participant1.id)
        expect(phrase).to start_with('then ')
        expect(phrase).to match(/(falls back|disengages|backs off|retreats)/)
      end

      it 'generates melee-to-ranged transition with no movement (still)' do
        phrase = service.send(:weapon_transition_phrase, :melee, :ranged, participant1, true)
        expect(phrase).to start_with('then ')
        expect(phrase).to match(/(switches to|brings up|draws|pulls out)/)
      end

      it 'returns nil for invalid transition key' do
        phrase = service.send(:weapon_transition_phrase, :melee, :melee, participant1, false)
        expect(phrase).to be_nil
      end
    end
  end

  describe '#build_name_mapping' do
    let(:service) { described_class.new(fight) }

    context 'with characters that have nicknames' do
      before do
        character1.update(forename: 'Linis', surname: 'Dao', nickname: 'Lin')
        character2.update(forename: 'Robert', surname: 'Smith', nickname: 'Bob')
        participant1
        participant2
      end

      it 'maps full names to short names' do
        mapping = service.send(:build_name_mapping)

        expect(mapping["Linis 'Lin' Dao"]).to eq('Lin')
        expect(mapping["Robert 'Bob' Smith"]).to eq('Bob')
      end
    end

    context 'with characters without nicknames' do
      before do
        character1.update(forename: 'Alpha', surname: 'Fighter', nickname: nil)
        character2.update(forename: 'Beta', surname: 'Warrior', nickname: nil)
        participant1
        participant2
      end

      it 'maps forename + surname to forename' do
        mapping = service.send(:build_name_mapping)

        expect(mapping['Alpha Fighter']).to eq('Alpha')
        expect(mapping['Beta Warrior']).to eq('Beta')
      end
    end

    context 'with colliding short names' do
      before do
        character1.update(forename: 'John', surname: 'Smith', nickname: nil)
        character2.update(forename: 'John', surname: 'Doe', nickname: nil)
        participant1
        participant2
      end

      it 'disambiguates with surname initial' do
        mapping = service.send(:build_name_mapping)

        expect(mapping['John Smith']).to eq('John S.')
        expect(mapping['John Doe']).to eq('John D.')
      end
    end

    context 'with characters that already have simple names' do
      before do
        character1.update(forename: 'Alpha', surname: nil, nickname: nil)
        participant1
      end

      it 'skips characters where full_name equals short_name' do
        mapping = service.send(:build_name_mapping)

        expect(mapping).not_to have_key('Alpha')
      end
    end
  end

  describe '#describe_non_attack_stances' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    context 'when a participant is defending' do
      before do
        participant1.update(main_action: 'attack')
        participant2.update(main_action: 'defend')
      end

      it 'includes a defend description' do
        result = service.send(:describe_non_attack_stances)
        expect(result).to be_a(String)
        expect(result).to include('Beta')
        expect(result).to match(/sets a defensive stance|braces for incoming attacks|raises their guard|focuses on defense/)
      end

      it 'does not include attacking participants' do
        result = service.send(:describe_non_attack_stances)
        expect(result).not_to include('Alpha')
      end
    end

    context 'when a participant is dodging' do
      before do
        participant1.update(main_action: 'attack')
        participant2.update(main_action: 'dodge')
      end

      it 'includes a dodge description' do
        result = service.send(:describe_non_attack_stances)
        expect(result).to be_a(String)
        expect(result).to match(/weaves and dodges|bobs and weaves|ducks and sidesteps|focuses on evasion/)
      end
    end

    context 'when a participant is sprinting' do
      before do
        participant1.update(main_action: 'attack')
        participant2.update(main_action: 'sprint')
      end

      it 'includes a sprint description' do
        result = service.send(:describe_non_attack_stances)
        expect(result).to be_a(String)
        expect(result).to match(/sprints across the battlefield|dashes across the arena|breaks into a full sprint|races across the ground/)
      end
    end

    context 'when a participant is passing' do
      before do
        participant1.update(main_action: 'attack')
        participant2.update(main_action: 'pass')
      end

      it 'includes a pass description' do
        result = service.send(:describe_non_attack_stances)
        expect(result).to be_a(String)
        expect(result).to match(/holds position|bides their time|watches and waits|stands their ground/)
      end
    end

    context 'when all participants are attacking' do
      before do
        participant1.update(main_action: 'attack')
        participant2.update(main_action: 'attack')
      end

      it 'returns nil' do
        result = service.send(:describe_non_attack_stances)
        expect(result).to be_nil
      end
    end

    context 'when knocked out participants are excluded' do
      before do
        participant1.update(main_action: 'attack')
        participant2.update(main_action: 'defend', is_knocked_out: true)
      end

      it 'does not describe knocked out participants' do
        result = service.send(:describe_non_attack_stances)
        expect(result).to be_nil
      end
    end

    context 'when multiple participants have non-attack stances' do
      before do
        participant1.update(main_action: 'defend')
        participant2.update(main_action: 'dodge')
      end

      it 'includes descriptions for both' do
        result = service.send(:describe_non_attack_stances)
        expect(result).to include('Alpha')
        expect(result).to include('Beta')
      end
    end

    context 'integration with generate' do
      before do
        participant1.update(main_action: 'attack')
        participant2.update(main_action: 'defend')
        FightEvent.create(
          fight_id: fight.id,
          round_number: 1,
          segment: 1,
          event_type: 'hit',
          actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({
            actor_name: 'Alpha Fighter',
            target_name: 'Beta Warrior',
            total: 5,
            effective_damage: 5
          })
        )
      end

      it 'includes stance descriptions in the full narrative' do
        svc = described_class.new(fight, enhance_prose: false)
        narrative = svc.generate
        expect(narrative).to match(/sets a defensive stance|braces for incoming attacks|raises their guard|focuses on defense/)
      end
    end
  end

  describe 'movement terrain helpers' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    describe '#compute_elevation_change' do
      it 'returns :climbed_up when elevation increased' do
        events = [
          { details: { old_elevation_level: 0 } },
          { details: { elevation_level: 2 } }
        ]
        expect(service.send(:compute_elevation_change, events)).to eq(:climbed_up)
      end

      it 'returns :descended when elevation decreased' do
        events = [
          { details: { old_elevation_level: 3 } },
          { details: { elevation_level: 1 } }
        ]
        expect(service.send(:compute_elevation_change, events)).to eq(:descended)
      end

      it 'returns :level when elevation unchanged' do
        events = [
          { details: { old_elevation_level: 2 } },
          { details: { elevation_level: 2 } }
        ]
        expect(service.send(:compute_elevation_change, events)).to eq(:level)
      end

      it 'returns nil for empty events' do
        expect(service.send(:compute_elevation_change, [])).to be_nil
      end
    end

    describe '#compute_elevation_delta' do
      it 'returns absolute difference' do
        events = [
          { details: { old_elevation_level: 1 } },
          { details: { elevation_level: 4 } }
        ]
        expect(service.send(:compute_elevation_delta, events)).to eq(3)
      end

      it 'returns 0 for empty events' do
        expect(service.send(:compute_elevation_delta, [])).to eq(0)
      end
    end

    describe '#detect_climb_method' do
      it 'detects stairs' do
        events = [{ details: { is_stairs: true } }]
        expect(service.send(:detect_climb_method, events)).to eq(:stairs)
      end

      it 'detects ladder' do
        events = [{ details: { is_ladder: true } }]
        expect(service.send(:detect_climb_method, events)).to eq(:ladder)
      end

      it 'detects ramp' do
        events = [{ details: { is_ramp: true } }]
        expect(service.send(:detect_climb_method, events)).to eq(:ramp)
      end

      it 'returns nil when no climb method' do
        events = [{ details: {} }]
        expect(service.send(:detect_climb_method, events)).to be_nil
      end
    end

    describe '#any_difficult_terrain?' do
      it 'returns true when any step has difficult terrain' do
        events = [{ details: {} }, { details: { difficult_terrain: true } }]
        expect(service.send(:any_difficult_terrain?, events)).to be true
      end

      it 'returns false when no difficult terrain' do
        events = [{ details: {} }, { details: { difficult_terrain: false } }]
        expect(service.send(:any_difficult_terrain?, events)).to be false
      end
    end

    describe '#detect_water_type' do
      it 'returns highest priority water type' do
        events = [
          { details: { water_type: 'wading' } },
          { details: { water_type: 'swimming' } }
        ]
        expect(service.send(:detect_water_type, events)).to eq('swimming')
      end

      it 'normalizes deep to swimming' do
        events = [{ details: { water_type: 'deep' } }]
        expect(service.send(:detect_water_type, events)).to eq('swimming')
      end

      it 'returns nil when no water' do
        events = [{ details: {} }]
        expect(service.send(:detect_water_type, events)).to be_nil
      end
    end

    describe '#detect_cover_entry' do
      it 'detects entering cover on last step' do
        events = [
          { details: { has_cover: false } },
          { details: { has_cover: true, cover_object: 'barrel' } }
        ]
        expect(service.send(:detect_cover_entry, events)).to eq('barrel')
      end

      it 'returns nil if already had cover' do
        events = [
          { details: { has_cover: true, cover_object: 'pillar' } },
          { details: { has_cover: true, cover_object: 'barrel' } }
        ]
        expect(service.send(:detect_cover_entry, events)).to be_nil
      end

      it 'returns nil if last step has no cover' do
        events = [
          { details: { has_cover: false } },
          { details: { has_cover: false } }
        ]
        expect(service.send(:detect_cover_entry, events)).to be_nil
      end
    end

    describe '#detect_cover_exit' do
      it 'detects leaving cover' do
        events = [
          { details: { has_cover: true, cover_object: 'wall' } },
          { details: { has_cover: false } }
        ]
        expect(service.send(:detect_cover_exit, events)).to eq('wall')
      end

      it 'returns nil if still in cover' do
        events = [
          { details: { has_cover: true, cover_object: 'pillar' } },
          { details: { has_cover: true, cover_object: 'barrel' } }
        ]
        expect(service.send(:detect_cover_exit, events)).to be_nil
      end
    end

    describe '#detect_notable_object' do
      it 'finds an object that is not start or end cover' do
        events = [
          { details: { cover_object: 'pillar' } },
          { details: { cover_object: 'barrel' } },
          { details: { cover_object: 'crate' } }
        ]
        expect(service.send(:detect_notable_object, events)).to eq('barrel')
      end

      it 'returns nil when all objects match start/end' do
        events = [
          { details: { cover_object: 'pillar' } },
          { details: { cover_object: 'pillar' } }
        ]
        expect(service.send(:detect_notable_object, events)).to be_nil
      end
    end
  end

  describe 'movement terrain narrative' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    describe '#movement_terrain_clauses' do
      it 'includes elevation clause for climbing' do
        movement = { elevation_change: :climbed_up, climbed_via: :stairs }
        clauses = service.send(:movement_terrain_clauses, movement)
        expect(clauses).to include('up the stairs')
      end

      it 'includes elevation clause for descending via ladder' do
        movement = { elevation_change: :descended, climbed_via: :ladder }
        clauses = service.send(:movement_terrain_clauses, movement)
        expect(clauses).to include('down a ladder')
      end

      it 'includes generic climbing when no climb method' do
        movement = { elevation_change: :climbed_up, climbed_via: nil }
        clauses = service.send(:movement_terrain_clauses, movement)
        expect(clauses).to include('climbing higher')
      end

      it 'includes water clause for swimming' do
        movement = { traversed_water: 'swimming' }
        clauses = service.send(:movement_terrain_clauses, movement)
        expect(clauses).to include('swimming through deep water')
      end

      it 'includes water clause for wading' do
        movement = { traversed_water: 'wading' }
        clauses = service.send(:movement_terrain_clauses, movement)
        expect(clauses).to include('wading through water')
      end

      it 'includes difficult terrain when no other clauses' do
        movement = { traversed_difficult: true }
        clauses = service.send(:movement_terrain_clauses, movement)
        expect(clauses).to include('picking through difficult terrain')
      end

      it 'skips difficult terrain when elevation clause present' do
        movement = { elevation_change: :climbed_up, climbed_via: nil, traversed_difficult: true }
        clauses = service.send(:movement_terrain_clauses, movement)
        expect(clauses).not_to include('picking through difficult terrain')
      end

      it 'returns empty array for level movement with no features' do
        movement = { elevation_change: :level }
        clauses = service.send(:movement_terrain_clauses, movement)
        expect(clauses).to be_empty
      end
    end

    describe '#movement_terrain_clause_short' do
      it 'prioritizes elevation over water' do
        movement = { moved: true, elevation_change: :climbed_up, traversed_water: 'wading' }
        result = service.send(:movement_terrain_clause_short, movement)
        expect(result).to eq('climbing higher')
      end

      it 'returns water clause when no elevation' do
        movement = { moved: true, traversed_water: 'swimming' }
        result = service.send(:movement_terrain_clause_short, movement)
        expect(result).to eq('splashing through water')
      end

      it 'returns cover entry clause' do
        movement = { moved: true, entered_cover: 'barrel' }
        result = service.send(:movement_terrain_clause_short, movement)
        expect(result).to eq('ducking behind a barrel')
      end

      it 'returns nil when no terrain features' do
        movement = { moved: true }
        result = service.send(:movement_terrain_clause_short, movement)
        expect(result).to be_nil
      end

      it 'returns nil when not moved' do
        movement = { moved: false, elevation_change: :climbed_up }
        result = service.send(:movement_terrain_clause_short, movement)
        expect(result).to be_nil
      end
    end

    describe '#movement_cover_clause' do
      it 'describes entering cover with object name' do
        movement = { entered_cover: 'barrel' }
        result = service.send(:movement_cover_clause, movement, 'Alpha')
        expect(result).to eq('Alpha takes cover behind a barrel.')
      end

      it 'describes entering cover without object name' do
        movement = { entered_cover: '' }
        result = service.send(:movement_cover_clause, movement, 'Alpha')
        expect(result).to eq('Alpha ducks into cover.')
      end

      it 'describes leaving cover with object name' do
        movement = { left_cover: 'pillar' }
        result = service.send(:movement_cover_clause, movement, 'Beta')
        expect(result).to eq('Beta breaks from the shelter of a pillar.')
      end

      it 'describes leaving cover without object name' do
        movement = { left_cover: '' }
        result = service.send(:movement_cover_clause, movement, 'Beta')
        expect(result).to eq('Beta leaves cover.')
      end

      it 'returns nil when no cover transition' do
        movement = {}
        result = service.send(:movement_cover_clause, movement, 'Alpha')
        expect(result).to be_nil
      end
    end

    describe '#describe_movement_only' do
      before do
        # Force participant loading
        participant1
        participant2
      end

      it 'includes terrain clauses when elevation changes' do
        FightEvent.create(
          fight: fight,
          round_number: 1,
          segment: 1,
          event_type: 'movement_step',
          actor_participant_id: participant1.id,
          details: Sequel.pg_json_wrap({
            direction: 'towards',
            target_name: 'Beta Warrior',
            old_x: 0, old_y: 0, new_x: 1, new_y: 0,
            old_elevation_level: 0,
            elevation_level: 2,
            is_stairs: true
          })
        )

        svc = described_class.new(fight, enhance_prose: false)
        text = svc.generate
        expect(text).to include('up the stairs')
      end

      it 'includes cover clause when entering cover' do
        FightEvent.create(
          fight: fight,
          round_number: 1,
          segment: 1,
          event_type: 'movement_step',
          actor_participant_id: participant1.id,
          details: Sequel.pg_json_wrap({
            direction: 'towards',
            target_name: 'Beta Warrior',
            old_x: 0, old_y: 0, new_x: 2, new_y: 0,
            has_cover: false
          })
        )
        FightEvent.create(
          fight: fight,
          round_number: 1,
          segment: 1,
          event_type: 'movement_step',
          actor_participant_id: participant1.id,
          details: Sequel.pg_json_wrap({
            direction: 'towards',
            target_name: 'Beta Warrior',
            old_x: 2, old_y: 0, new_x: 3, new_y: 0,
            has_cover: true,
            cover_object: 'barrel'
          })
        )

        svc = described_class.new(fight, enhance_prose: false)
        text = svc.generate
        expect(text).to include('cover behind a barrel')
      end
    end

    describe '#humanize_cover_object' do
      it 'converts underscore names to readable phrases' do
        result = service.send(:humanize_cover_object, 'wall_low')
        expect(result).to eq('a wall low')
      end

      it 'uses "an" for vowel-starting names' do
        result = service.send(:humanize_cover_object, 'overturned_table')
        expect(result).to eq('an overturned table')
      end

      it 'returns nil for nil input' do
        result = service.send(:humanize_cover_object, nil)
        expect(result).to be_nil
      end

      it 'returns nil for empty string' do
        result = service.send(:humanize_cover_object, '')
        expect(result).to be_nil
      end

      it 'handles simple names' do
        result = service.send(:humanize_cover_object, 'barrel')
        expect(result).to eq('a barrel')
      end
    end
  end

  describe 'terrain beat interlacing' do
    let(:service) { described_class.new(fight, enhance_prose: false) }

    describe '#build_movement_timeline' do
      it 'builds per-actor sorted movement_step events' do
        steps = [
          { event_type: 'movement_step', actor_id: 1, segment: 5, details: {} },
          { event_type: 'movement_step', actor_id: 1, segment: 2, details: {} },
          { event_type: 'movement_step', actor_id: 2, segment: 3, details: {} },
          { event_type: 'move', actor_id: 1, segment: 1, details: {} }
        ]
        timeline = service.send(:build_movement_timeline, steps)
        expect(timeline.keys).to contain_exactly(1, 2)
        expect(timeline[1].map { |s| s[:segment] }).to eq([2, 5])
        expect(timeline[2].length).to eq(1)
      end

      it 'excludes non-movement_step events' do
        steps = [
          { event_type: 'move', actor_id: 1, segment: 1, details: {} },
          { event_type: 'movement_step', actor_id: 1, segment: 2, details: {} }
        ]
        timeline = service.send(:build_movement_timeline, steps)
        expect(timeline[1].length).to eq(1)
      end
    end

    describe '#detect_terrain_beat' do
      it 'detects elevation increase' do
        prev = { details: { elevation_level: 0 } }
        curr = { details: { elevation_level: 2 }, segment: 5 }
        beat = service.send(:detect_terrain_beat, prev, curr)
        expect(beat).to include(type: :elevation_up, segment: 5)
      end

      it 'detects elevation decrease' do
        prev = { details: { elevation_level: 3 } }
        curr = { details: { elevation_level: 1 }, segment: 7 }
        beat = service.send(:detect_terrain_beat, prev, curr)
        expect(beat).to include(type: :elevation_down, segment: 7)
      end

      it 'detects cover entry' do
        prev = { details: { has_cover: false } }
        curr = { details: { has_cover: true, cover_object: 'barrel' }, segment: 4 }
        beat = service.send(:detect_terrain_beat, prev, curr)
        expect(beat).to include(type: :enter_cover, object: 'barrel', segment: 4)
      end

      it 'detects cover exit' do
        prev = { details: { has_cover: true, cover_object: 'crate' } }
        curr = { details: { has_cover: false }, segment: 6 }
        beat = service.send(:detect_terrain_beat, prev, curr)
        expect(beat).to include(type: :leave_cover, object: 'crate', segment: 6)
      end

      it 'detects water entry' do
        prev = { details: {} }
        curr = { details: { water_type: 'wading' }, segment: 3 }
        beat = service.send(:detect_terrain_beat, prev, curr)
        expect(beat).to include(type: :water, detail: 'wading', segment: 3)
      end

      it 'detects difficult terrain entry' do
        prev = { details: { difficult_terrain: false } }
        curr = { details: { difficult_terrain: true }, segment: 8 }
        beat = service.send(:detect_terrain_beat, prev, curr)
        expect(beat).to include(type: :difficult, segment: 8)
      end

      it 'returns nil for no transition' do
        prev = { details: { elevation_level: 1, has_cover: false } }
        curr = { details: { elevation_level: 1, has_cover: false }, segment: 2 }
        beat = service.send(:detect_terrain_beat, prev, curr)
        expect(beat).to be_nil
      end

      it 'prioritizes elevation over cover' do
        prev = { details: { elevation_level: 0, has_cover: false } }
        curr = { details: { elevation_level: 2, has_cover: true, cover_object: 'crate' }, segment: 5 }
        beat = service.send(:detect_terrain_beat, prev, curr)
        expect(beat[:type]).to eq(:elevation_up)
      end
    end

    describe '#detect_first_step_beat' do
      it 'detects entering cover on first step' do
        step = { details: { has_cover: true, cover_object: 'pillar', old_has_cover: false }, segment: 1 }
        beat = service.send(:detect_first_step_beat, step)
        expect(beat).to include(type: :enter_cover, object: 'pillar')
      end

      it 'detects elevation gain on first step' do
        step = { details: { old_elevation_level: 0, elevation_level: 2 }, segment: 1 }
        beat = service.send(:detect_first_step_beat, step)
        expect(beat).to include(type: :elevation_up)
      end

      it 'returns nil when no terrain change' do
        step = { details: { has_cover: false }, segment: 1 }
        beat = service.send(:detect_first_step_beat, step)
        expect(beat).to be_nil
      end
    end

    describe '#terrain_beats_for_actor' do
      it 'returns beats from movement timeline' do
        service.instance_variable_set(:@movement_timeline, {
          42 => [
            { segment: 1, details: { elevation_level: 0, has_cover: false } },
            { segment: 3, details: { elevation_level: 2, has_cover: false } },
            { segment: 5, details: { elevation_level: 2, has_cover: true, cover_object: 'barrel' } }
          ]
        })
        beats = service.send(:terrain_beats_for_actor, 42)
        expect(beats.length).to eq(2)
        expect(beats[0][:type]).to eq(:elevation_up)
        expect(beats[1][:type]).to eq(:enter_cover)
      end

      it 'returns empty for actor with no timeline' do
        service.instance_variable_set(:@movement_timeline, {})
        beats = service.send(:terrain_beats_for_actor, 99)
        expect(beats).to be_empty
      end
    end

    describe '#pending_terrain_beats' do
      it 'returns beats in segment range and consumes them' do
        service.instance_variable_set(:@movement_timeline, {
          42 => [
            { segment: 2, details: { elevation_level: 0 } },
            { segment: 5, details: { elevation_level: 2 } },
            { segment: 8, details: { elevation_level: 2, has_cover: true, cover_object: 'wall' } }
          ]
        })

        # Get beats between segments 1 and 6 (should get elevation_up at segment 5)
        beats = service.send(:pending_terrain_beats, 42, 1, 6)
        expect(beats.length).to eq(1)
        expect(beats[0][:type]).to eq(:elevation_up)

        # Same call again returns empty (consumed)
        beats2 = service.send(:pending_terrain_beats, 42, 1, 6)
        expect(beats2).to be_empty

        # Beats at segment 8 still available
        beats3 = service.send(:pending_terrain_beats, 42, 6, 10)
        expect(beats3.length).to eq(1)
        expect(beats3[0][:type]).to eq(:enter_cover)
      end
    end

    describe '#terrain_beat_narrative' do
      before { participant1; participant2 }

      it 'generates elevation_up narrative with object' do
        beat = { type: :elevation_up, object: 'crate' }
        text = service.send(:terrain_beat_narrative, participant1.id, beat)
        expect(text).to match(/climbs onto a crate/)
      end

      it 'generates elevation_up narrative without object' do
        beat = { type: :elevation_up, object: nil }
        text = service.send(:terrain_beat_narrative, participant1.id, beat)
        expect(text).to match(/climbs to higher ground/)
      end

      it 'generates elevation_down narrative' do
        beat = { type: :elevation_down }
        text = service.send(:terrain_beat_narrative, participant1.id, beat)
        expect(text).to match(/drops to lower ground/)
      end

      it 'generates enter_cover narrative' do
        beat = { type: :enter_cover, object: 'barrel' }
        text = service.send(:terrain_beat_narrative, participant1.id, beat)
        expect(text).to match(/ducks behind a barrel/)
      end

      it 'generates leave_cover narrative' do
        beat = { type: :leave_cover, object: 'pillar' }
        text = service.send(:terrain_beat_narrative, participant1.id, beat)
        expect(text).to match(/breaks from a pillar/)
      end

      it 'generates water narrative for swimming' do
        beat = { type: :water, detail: 'swimming' }
        text = service.send(:terrain_beat_narrative, participant1.id, beat)
        expect(text).to match(/plunges into deep water/)
      end

      it 'generates water narrative for wading' do
        beat = { type: :water, detail: 'wading' }
        text = service.send(:terrain_beat_narrative, participant1.id, beat)
        expect(text).to match(/splashes through water/)
      end

      it 'generates difficult terrain narrative' do
        beat = { type: :difficult }
        text = service.send(:terrain_beat_narrative, participant1.id, beat)
        expect(text).to match(/picks through rough terrain/)
      end

      it 'returns nil for unknown participant' do
        beat = { type: :elevation_up }
        text = service.send(:terrain_beat_narrative, 999999, beat)
        expect(text).to be_nil
      end
    end

    describe '#describe_shot_blocked' do
      it 'uses cover_object name when available' do
        event = {
          actor_name: 'Alpha Fighter', target_name: 'Beta Warrior',
          details: { actor_name: 'Alpha Fighter', target_name: 'Beta Warrior', cover_object: 'barrel' }
        }
        text = service.send(:describe_shot_blocked, event)
        expect(text).to include('a barrel')
      end

      it 'falls back to "cover" when no cover_object' do
        event = {
          actor_name: 'Alpha Fighter', target_name: 'Beta Warrior',
          details: { actor_name: 'Alpha Fighter', target_name: 'Beta Warrior' }
        }
        text = service.send(:describe_shot_blocked, event)
        expect(text).to include('cover')
      end
    end

    describe '#describe_partial_cover' do
      it 'generates narrative for hits with cover_damage_reduction' do
        hits = [
          { event_type: 'hit', target_name: 'Beta Warrior',
            details: { cover_damage_reduction: '50%', cover_object: 'crate' } }
        ]
        text = service.send(:describe_partial_cover, hits)
        expect(text).not_to be_nil
        expect(text).to include('crate')
      end

      it 'returns nil when no hits have cover reduction' do
        hits = [
          { event_type: 'hit', target_name: 'Beta Warrior', details: {} }
        ]
        text = service.send(:describe_partial_cover, hits)
        expect(text).to be_nil
      end

      it 'generates narrative without object name' do
        hits = [
          { event_type: 'hit', target_name: 'Beta Warrior',
            details: { cover_damage_reduction: '50%', cover_object: nil } }
        ]
        text = service.send(:describe_partial_cover, hits)
        expect(text).not_to be_nil
        expect(text.downcase).to include('cover')
      end

      it 'groups multiple hits behind same cover object' do
        hits = [
          { event_type: 'hit', target_name: 'Beta Warrior',
            details: { cover_damage_reduction: '50%', cover_object: 'barrel' } },
          { event_type: 'hit', target_name: 'Beta Warrior',
            details: { cover_damage_reduction: '50%', cover_object: 'barrel' } }
        ]
        text = service.send(:describe_partial_cover, hits)
        # Should only mention barrel once (grouped)
        expect(text.scan(/barrel/).length).to eq(1)
      end
    end

    describe 'integration: terrain beats interlaced with combat' do
      before do
        participant1
        participant2
        # Set participant2 to attack mode for combat events
        participant2.update(main_action: 'attack')
      end

      it 'interlaces terrain beats between combat exchanges' do
        # Movement steps for participant1: starts flat, climbs at segment 5, enters cover at segment 15
        FightEvent.create(
          fight: fight, round_number: 1, segment: 2,
          event_type: 'movement_step',
          actor_participant_id: participant1.id,
          details: Sequel.pg_json_wrap({
            direction: 'towards', target_name: 'Beta Warrior',
            old_x: 0, old_y: 0, new_x: 1, new_y: 0,
            elevation_level: 0, has_cover: false
          })
        )
        FightEvent.create(
          fight: fight, round_number: 1, segment: 5,
          event_type: 'movement_step',
          actor_participant_id: participant1.id,
          details: Sequel.pg_json_wrap({
            direction: 'towards', target_name: 'Beta Warrior',
            old_x: 1, old_y: 0, new_x: 2, new_y: 0,
            elevation_level: 2, has_cover: false
          })
        )
        FightEvent.create(
          fight: fight, round_number: 1, segment: 15,
          event_type: 'movement_step',
          actor_participant_id: participant1.id,
          details: Sequel.pg_json_wrap({
            direction: 'towards', target_name: 'Beta Warrior',
            old_x: 2, old_y: 0, new_x: 3, new_y: 0,
            elevation_level: 2, has_cover: true, cover_object: 'crate'
          })
        )

        # Combat events for participant1: attacks at segments 7 and 20
        FightEvent.create(
          fight: fight, round_number: 1, segment: 7,
          event_type: 'hit',
          actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({
            actor_name: 'Alpha Fighter', target_name: 'Beta Warrior',
            weapon_type: 'melee', hp_lost_this_attack: 1, threshold_crossed: true,
            damage_type: 'slashing'
          })
        )
        FightEvent.create(
          fight: fight, round_number: 1, segment: 20,
          event_type: 'hit',
          actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({
            actor_name: 'Alpha Fighter', target_name: 'Beta Warrior',
            weapon_type: 'melee', hp_lost_this_attack: 1, threshold_crossed: true,
            damage_type: 'slashing'
          })
        )

        svc = described_class.new(fight, enhance_prose: false)
        text = svc.generate

        # Terrain beats should appear in the narrative
        # The elevation beat at segment 5 should appear before the first attack at segment 7
        # The cover beat at segment 15 should appear between the two attacks
        expect(text).to include('higher ground').or include('climbs')
        expect(text).to include('crate').or include('cover')
      end

      it 'emits remaining terrain beats after last exchange' do
        # Movement step at segment 90 (after all combat)
        FightEvent.create(
          fight: fight, round_number: 1, segment: 3,
          event_type: 'movement_step',
          actor_participant_id: participant1.id,
          details: Sequel.pg_json_wrap({
            direction: 'towards', target_name: 'Beta Warrior',
            old_x: 0, old_y: 0, new_x: 1, new_y: 0,
            elevation_level: 0, has_cover: false
          })
        )
        FightEvent.create(
          fight: fight, round_number: 1, segment: 90,
          event_type: 'movement_step',
          actor_participant_id: participant1.id,
          details: Sequel.pg_json_wrap({
            direction: 'towards', target_name: 'Beta Warrior',
            old_x: 1, old_y: 0, new_x: 2, new_y: 0,
            elevation_level: 0, has_cover: true, cover_object: 'barrel'
          })
        )

        # Combat at segment 5
        FightEvent.create(
          fight: fight, round_number: 1, segment: 5,
          event_type: 'hit',
          actor_participant_id: participant1.id,
          target_participant_id: participant2.id,
          details: Sequel.pg_json_wrap({
            actor_name: 'Alpha Fighter', target_name: 'Beta Warrior',
            weapon_type: 'melee', hp_lost_this_attack: 1, threshold_crossed: true
          })
        )

        svc = described_class.new(fight, enhance_prose: false)
        text = svc.generate

        # Cover beat at segment 90 should appear after combat
        expect(text).to include('barrel').or include('cover')
      end
    end
  end
end
