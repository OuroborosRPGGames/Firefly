# frozen_string_literal: true

require 'spec_helper'
require_relative 'shared_context'

RSpec.describe AutoGm::AutoGmSynthesisService do
  include_context 'auto_gm_setup'

  let(:brainstorm_outputs) do
    {
      creative_a: 'A mysterious artifact has been discovered in an ancient temple...',
      creative_b: 'The village is threatened by a dark force awakening in the forest...'
    }
  end

  let(:context) do
    {
      room_context: { name: 'Village Square', description: 'A bustling square' },
      participant_context: [{ name: 'Hero', race: 'Human', char_class: 'Fighter', level: 5 }],
      nearby_locations: [
        { location_id: 1, room_id: 10, location_name: 'Temple', room_name: 'Entrance', type: 'temple', distance: 5 },
        { location_id: 2, room_id: 20, location_name: 'Forest', room_name: 'Edge', type: 'forest', distance: 3 }
      ]
    }
  end

  describe 'constants' do
    it 'has SYNTHESIS_MODEL' do
      expect(described_class::SYNTHESIS_MODEL[:provider]).to eq('anthropic')
      expect(described_class::SYNTHESIS_MODEL[:model]).to include('claude-opus')
    end

    it 'has NOUN_TYPES' do
      expect(described_class::NOUN_TYPES).to include('person')
      expect(described_class::NOUN_TYPES).to include('artefact')
      expect(described_class::NOUN_TYPES).to include('location')
      expect(described_class::NOUN_TYPES.length).to eq(5)
    end

    it 'has NOUN_ADJECTIVES' do
      expect(described_class::NOUN_ADJECTIVES).to include('dangerous')
      expect(described_class::NOUN_ADJECTIVES).to include('powerful')
      expect(described_class::NOUN_ADJECTIVES.length).to eq(5)
    end

    it 'has MISSION_TYPES' do
      expect(described_class::MISSION_TYPES).to include('discover')
      expect(described_class::MISSION_TYPES).to include('rescue')
      expect(described_class::MISSION_TYPES.length).to eq(6)
    end

    it 'has INCIDENT_TYPES' do
      expect(described_class::INCIDENT_TYPES).to include('attack')
      expect(described_class::INCIDENT_TYPES).to include('discovery')
      expect(described_class::INCIDENT_TYPES.length).to eq(5)
    end

    it 'has TWIST_TYPES' do
      expect(described_class::TWIST_TYPES).to include('betrayal')
      expect(described_class::TWIST_TYPES).to include('hidden_ally')
      expect(described_class::TWIST_TYPES.length).to eq(6)
    end

    it 'has STRUCTURE_TYPES' do
      expect(described_class::STRUCTURE_TYPES).to eq(%w[three_act countdown five_room])
    end

    it 'has NPC_ROLES' do
      expect(described_class::NPC_ROLES).to include('antagonist')
      expect(described_class::NPC_ROLES).to include('ally')
      expect(described_class::NPC_ROLES.length).to eq(6)
    end
  end

  describe '.synthesize' do
    let(:valid_sketch_response) do
      {
        'title' => 'The Lost Temple',
        'noun' => { 'type' => 'artefact', 'adjective' => 'powerful', 'name' => 'Crystal', 'description' => 'A glowing crystal' },
        'mission' => { 'type' => 'discover', 'objective' => 'Find the crystal', 'success_conditions' => ['Find it'], 'failure_conditions' => ['Die'] },
        'setting' => { 'flavor' => 'fantasy', 'mood' => 'mysterious' },
        'inciting_incident' => { 'type' => 'discovery', 'description' => 'A map is found' },
        'structure' => {
          'type' => 'three_act',
          'stages' => [
            { 'name' => 'Discovery', 'description' => 'Find clue' },
            { 'name' => 'Journey', 'description' => 'Travel' },
            { 'name' => 'Climax', 'description' => 'Final battle', 'is_climax' => true },
            { 'name' => 'Resolution', 'description' => 'Return' }
          ]
        },
        'secrets_twists' => { 'secrets' => ['Secret 1'], 'twist_type' => 'betrayal' },
        'rewards_perils' => { 'rewards' => ['Gold'], 'perils' => ['Traps'] },
        'locations_used' => [1, 2]
      }
    end

    context 'when synthesis succeeds' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: valid_sketch_response.to_json
        })
      end

      it 'returns success true' do
        result = described_class.synthesize(
          brainstorm_outputs: brainstorm_outputs,
          context: context
        )
        expect(result[:success]).to be true
      end

      it 'returns normalized sketch' do
        result = described_class.synthesize(
          brainstorm_outputs: brainstorm_outputs,
          context: context
        )
        expect(result[:sketch]).to be_a(Hash)
        expect(result[:sketch]['title']).to eq('The Lost Temple')
      end

      it 'returns locations_used' do
        result = described_class.synthesize(
          brainstorm_outputs: brainstorm_outputs,
          context: context
        )
        expect(result[:locations_used]).to eq([1, 2])
      end
    end

    context 'when LLM call fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'API timeout'
        })
      end

      it 'returns success false' do
        result = described_class.synthesize(
          brainstorm_outputs: brainstorm_outputs,
          context: context
        )
        expect(result[:success]).to be false
      end

      it 'returns error message' do
        result = described_class.synthesize(
          brainstorm_outputs: brainstorm_outputs,
          context: context
        )
        expect(result[:error]).to eq('API timeout')
      end
    end

    context 'when JSON parsing fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'not valid json'
        })
      end

      it 'returns success false' do
        result = described_class.synthesize(
          brainstorm_outputs: brainstorm_outputs,
          context: context
        )
        expect(result[:success]).to be false
      end

      it 'returns parse error message' do
        result = described_class.synthesize(
          brainstorm_outputs: brainstorm_outputs,
          context: context
        )
        expect(result[:error]).to include('JSON parse error')
      end
    end

    context 'when validation fails' do
      before do
        invalid_sketch = valid_sketch_response.dup
        invalid_sketch['noun']['type'] = 'invalid_type'
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: invalid_sketch.to_json
        })
      end

      it 'returns success false' do
        result = described_class.synthesize(
          brainstorm_outputs: brainstorm_outputs,
          context: context
        )
        expect(result[:success]).to be false
      end

      it 'returns validation error' do
        result = described_class.synthesize(
          brainstorm_outputs: brainstorm_outputs,
          context: context
        )
        expect(result[:error]).to include('Validation failed')
      end
    end
  end

  describe '.synthesize_with_fallback' do
    before do
      allow(LLM::Client).to receive(:generate).and_return({
        success: true,
        text: sketch.to_json
      })
    end

    context 'with only creative_a output' do
      let(:partial_outputs) { { creative_a: 'Only model A output' } }

      it 'fills in placeholder for creative_b' do
        result = described_class.synthesize_with_fallback(
          brainstorm_outputs: partial_outputs,
          context: context
        )
        expect(result[:success]).to be true
      end
    end

    context 'with only creative_b output' do
      let(:partial_outputs) { { creative_b: 'Only model B output' } }

      it 'fills in placeholder for creative_a' do
        result = described_class.synthesize_with_fallback(
          brainstorm_outputs: partial_outputs,
          context: context
        )
        expect(result[:success]).to be true
      end
    end
  end

  describe 'private methods' do
    describe '#validate_sketch' do
      it 'validates required fields' do
        invalid_sketch = {}
        result = described_class.send(:validate_sketch, invalid_sketch, context)

        expect(result[:valid]).to be false
        expect(result[:errors]).to include('Missing title')
        expect(result[:errors]).to include('Missing noun')
        expect(result[:errors]).to include('Missing mission')
        expect(result[:errors]).to include('Missing structure')
        expect(result[:errors]).to include('Missing inciting_incident')
      end

      it 'validates noun type' do
        invalid_sketch = {
          'title' => 'Test',
          'noun' => { 'type' => 'invalid', 'adjective' => 'powerful' },
          'mission' => { 'type' => 'discover' },
          'structure' => { 'type' => 'three_act', 'stages' => [{}, {}, {}] },
          'inciting_incident' => { 'type' => 'discovery' }
        }
        result = described_class.send(:validate_sketch, invalid_sketch, context)

        expect(result[:valid]).to be false
        expect(result[:errors]).to include('Invalid noun type')
      end

      it 'validates mission type' do
        invalid_sketch = {
          'title' => 'Test',
          'noun' => { 'type' => 'artefact', 'adjective' => 'powerful' },
          'mission' => { 'type' => 'invalid_mission' },
          'structure' => { 'type' => 'three_act', 'stages' => [{}, {}, {}] },
          'inciting_incident' => { 'type' => 'discovery' }
        }
        result = described_class.send(:validate_sketch, invalid_sketch, context)

        expect(result[:valid]).to be false
        expect(result[:errors]).to include('Invalid mission type')
      end

      it 'validates minimum stages' do
        invalid_sketch = {
          'title' => 'Test',
          'noun' => { 'type' => 'artefact', 'adjective' => 'powerful' },
          'mission' => { 'type' => 'discover' },
          'structure' => { 'type' => 'three_act', 'stages' => [{}, {}] },
          'inciting_incident' => { 'type' => 'discovery' }
        }
        result = described_class.send(:validate_sketch, invalid_sketch, context)

        expect(result[:valid]).to be false
        expect(result[:errors]).to include('Too few stages (need at least 3)')
      end

      it 'validates location IDs exist in context' do
        valid_sketch_with_bad_location = {
          'title' => 'Test',
          'noun' => { 'type' => 'artefact', 'adjective' => 'powerful' },
          'mission' => { 'type' => 'discover' },
          'structure' => { 'type' => 'three_act', 'stages' => [{}, {}, {}] },
          'inciting_incident' => { 'type' => 'discovery' },
          'locations_used' => [999]  # Invalid location ID
        }
        result = described_class.send(:validate_sketch, valid_sketch_with_bad_location, context)

        expect(result[:valid]).to be false
        expect(result[:errors].any? { |e| e.include?('Invalid location IDs') }).to be true
      end
    end

    describe '#normalize_sketch' do
      let(:minimal_sketch) do
        {
          'title' => 'Test Adventure',
          'structure' => {
            'stages' => [
              { 'name' => 'Act 1' },
              { 'name' => 'Act 2' },
              { 'name' => 'Act 3' }
            ]
          }
        }
      end

      it 'adds default game_elements' do
        result = described_class.send(:normalize_sketch, minimal_sketch)
        expect(result['game_elements']).to include('exploration')
      end

      it 'adds default locations_used' do
        result = described_class.send(:normalize_sketch, minimal_sketch)
        expect(result['locations_used']).to eq([])
      end

      it 'adds default npcs_to_spawn' do
        result = described_class.send(:normalize_sketch, minimal_sketch)
        expect(result['npcs_to_spawn']).to eq([])
      end

      it 'adds default rewards_perils' do
        result = described_class.send(:normalize_sketch, minimal_sketch)
        expect(result['rewards_perils']).to eq({ 'rewards' => [], 'perils' => [] })
      end

      it 'adds default secrets_twists' do
        result = described_class.send(:normalize_sketch, minimal_sketch)
        expect(result['secrets_twists']).to eq({ 'secrets' => [], 'twist_type' => nil })
      end

      it 'marks climax stage if not already marked' do
        result = described_class.send(:normalize_sketch, minimal_sketch)
        climax_stage = result['structure']['stages'].find { |s| s['is_climax'] }
        expect(climax_stage).not_to be_nil
      end

      it 'preserves existing climax marking' do
        sketch_with_climax = minimal_sketch.dup
        sketch_with_climax['structure']['stages'][0]['is_climax'] = true

        result = described_class.send(:normalize_sketch, sketch_with_climax)
        climax_count = result['structure']['stages'].count { |s| s['is_climax'] }
        expect(climax_count).to eq(1)
        expect(result['structure']['stages'][0]['is_climax']).to be true
      end
    end

    describe '#format_locations_for_synthesis' do
      it 'returns default message for empty array' do
        result = described_class.send(:format_locations_for_synthesis, [])
        expect(result).to eq('No nearby locations available.')
      end

      it 'includes location IDs for synthesis' do
        locations = [
          { location_id: 1, room_id: 10, location_name: 'Temple', room_name: 'Entrance', type: 'temple', distance: 5 }
        ]
        result = described_class.send(:format_locations_for_synthesis, locations)
        expect(result).to include('ID: 1')
        expect(result).to include('Room ID: 10')
      end
    end

    describe '#format_room_context' do
      it 'returns default message for empty hash' do
        result = described_class.send(:format_room_context, {})
        expect(result).to eq('No room context available.')
      end

      it 'formats room context' do
        room_context = {
          name: 'Main Hall',
          location_name: 'Castle',
          room_type: 'hall',
          description: 'A grand hall'
        }
        result = described_class.send(:format_room_context, room_context)
        expect(result).to include('Name: Main Hall')
        expect(result).to include('Location: Castle')
        expect(result).to include('Type: hall')
      end
    end

    describe '#format_participants' do
      it 'returns default message for empty array' do
        result = described_class.send(:format_participants, [])
        expect(result).to eq('No participants.')
      end

      it 'formats participant names' do
        participants = [
          { name: 'Hero', race: 'Human', char_class: 'Fighter', level: 5 }
        ]
        result = described_class.send(:format_participants, participants)
        expect(result).to include('Hero')
        expect(result).to include('Human')
        expect(result).to include('Fighter')
      end
    end
  end
end
