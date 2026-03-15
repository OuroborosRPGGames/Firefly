# frozen_string_literal: true

require 'spec_helper'
require_relative 'shared_context'

RSpec.describe AutoGm::AutoGmInciteService do
  include_context 'auto_gm_setup'

  let(:incite_action) do
    double('AutoGmAction',
           id: 1,
           action_type: 'emit',
           emit_text: 'The adventure begins.',
           complete!: true)
  end

  before do
    allow(AutoGmAction).to receive(:create_emit).and_return(incite_action)
    allow(session).to receive(:current_room).and_return(room)
    allow(session).to receive(:world_state).and_return({})
    allow(session).to receive(:enter_combat!)
    allow(BroadcastService).to receive(:to_room)
  end

  describe '.deploy' do
    context 'when sketch is available' do
      it 'returns success true' do
        result = described_class.deploy(session)
        expect(result[:success]).to be true
      end

      it 'returns the created action' do
        result = described_class.deploy(session)
        expect(result[:action]).to eq(incite_action)
      end

      it 'creates an emit action' do
        expect(AutoGmAction).to receive(:create_emit).with(
          session,
          anything,
          hash_including(reasoning: /inciting incident/)
        )
        described_class.deploy(session)
      end

      it 'broadcasts the incident' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          anything,
          hash_including(type: :auto_gm_narration)
        )
        described_class.deploy(session)
      end

      it 'initializes world state' do
        expect(session).to receive(:update).with(hash_including(world_state: hash_including('incited_at')))
        described_class.deploy(session)
      end
    end

    context 'when no sketch available' do
      before do
        allow(session).to receive(:sketch).and_return(nil)
      end

      it 'returns success false' do
        result = described_class.deploy(session)
        expect(result[:success]).to be false
      end

      it 'returns error message' do
        result = described_class.deploy(session)
        expect(result[:error]).to eq('No sketch available')
      end
    end

    context 'when no inciting incident in sketch' do
      before do
        allow(session).to receive(:sketch).and_return({ 'title' => 'Test' })
      end

      it 'returns success false' do
        result = described_class.deploy(session)
        expect(result[:success]).to be false
      end

      it 'returns error message' do
        result = described_class.deploy(session)
        expect(result[:error]).to eq('No inciting incident in sketch')
      end
    end

    context 'when exception occurs' do
      before do
        allow(AutoGmAction).to receive(:create_emit).and_raise(StandardError.new('DB error'))
      end

      it 'returns success false' do
        result = described_class.deploy(session)
        expect(result[:success]).to be false
      end

      it 'includes error message' do
        result = described_class.deploy(session)
        expect(result[:error]).to include('Incite error')
      end
    end

    context 'when incident is an immediate attack with hostile NPCs' do
      let(:npc_instance) do
        double('CharacterInstance', id: 99, current_room_id: room.id)
      end
      let(:fight) { double('Fight', id: 123) }
      let(:fight_service) do
        double('FightService', fight: fight, add_participant: true)
      end

      before do
        allow(session).to receive(:sketch).and_return(
          sketch.merge(
            'inciting_incident' => {
              'type' => 'attack',
              'description' => 'Raiders strike from the alley.',
              'immediate_threat' => true
            }
          )
        )
        allow(described_class).to receive(:spawn_initial_npcs).and_return(
          [{ instance: npc_instance, disposition: 'hostile', archetype: double('NpcArchetype', id: 7) }]
        )
        allow(FightService).to receive(:start_fight).and_return(fight_service)
        allow(described_class).to receive(:apply_balancing_to_auto_gm_fight)
      end

      it 'starts combat via FightService' do
        expect(FightService).to receive(:start_fight).with(room: room, initiator: char_instance, target: npc_instance, mode: 'normal')
        described_class.deploy(session)
      end

      it 'puts the session into combat state' do
        expect(session).to receive(:enter_combat!).with(fight)
        described_class.deploy(session)
      end

      it 'applies battle balancing to the created fight' do
        expect(described_class).to receive(:apply_balancing_to_auto_gm_fight).with(
          fight, [char_instance], array_including(hash_including(instance: npc_instance)), session
        )
        described_class.deploy(session)
      end
    end
  end

  describe '.generate_inciting_narrative' do
    context 'when LLM call succeeds' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'A mysterious stranger arrives...'
        })
      end

      it 'returns generated narrative' do
        result = described_class.generate_inciting_narrative(session, {})
        expect(result).to eq('A mysterious stranger arrives...')
      end
    end

    context 'when LLM call fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({ success: false })
      end

      it 'returns incident description as fallback' do
        result = described_class.generate_inciting_narrative(session, {})
        expect(result).to eq('A map falls from an old book')
      end
    end

    context 'when no incident description' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({ success: false })
        allow(session).to receive(:sketch).and_return({
          'inciting_incident' => {}
        })
      end

      it 'returns default message' do
        result = described_class.generate_inciting_narrative(session, {})
        expect(result).to eq('The adventure begins...')
      end
    end
  end

  describe 'private methods' do
    describe '#build_incite_text' do
      let(:incident) { sketch['inciting_incident'] }

      it 'includes incident description' do
        result = described_class.send(:build_incite_text, session, incident)
        expect(result).to include('A map falls from an old book')
      end

      context 'with mood prefix' do
        it 'includes mysterious prefix' do
          result = described_class.send(:build_incite_text, session, incident)
          expect(result).to include('Something strange stirs')
        end

        it 'handles tense mood' do
          allow(session).to receive(:sketch).and_return(
            sketch.merge('setting' => { 'mood' => 'tense' })
          )
          result = described_class.send(:build_incite_text, session, incident)
          expect(result).to include('tension')
        end

        it 'handles urgent mood' do
          allow(session).to receive(:sketch).and_return(
            sketch.merge('setting' => { 'mood' => 'urgent' })
          )
          result = described_class.send(:build_incite_text, session, incident)
          expect(result).to include('Without warning')
        end
      end

      context 'with immediate threat' do
        let(:threat_incident) do
          { 'type' => 'attack', 'description' => 'Enemies attack!', 'immediate_threat' => true }
        end

        it 'includes urgency suffix' do
          result = described_class.send(:build_incite_text, session, threat_incident)
          expect(result).to include('no time to waste')
        end
      end
    end

    describe '#mood_prefix' do
      it 'returns tense prefix' do
        result = described_class.send(:mood_prefix, 'tense')
        expect(result).to include('tension')
      end

      it 'returns mysterious prefix' do
        result = described_class.send(:mood_prefix, 'mysterious')
        expect(result).to include('strange')
      end

      it 'returns urgent prefix' do
        result = described_class.send(:mood_prefix, 'urgent')
        expect(result).to include('Without warning')
      end

      it 'returns hopeful prefix' do
        result = described_class.send(:mood_prefix, 'hopeful')
        expect(result).to include('opportunity')
      end

      it 'returns dark prefix' do
        result = described_class.send(:mood_prefix, 'dark')
        expect(result).to include('ominous')
      end

      it 'returns chaotic prefix' do
        result = described_class.send(:mood_prefix, 'chaotic')
        expect(result).to include('Chaos')
      end

      it 'returns empty string for unknown mood' do
        result = described_class.send(:mood_prefix, 'unknown')
        expect(result).to eq('')
      end
    end

    describe '#urgency_suffix' do
      it 'returns attack suffix' do
        result = described_class.send(:urgency_suffix, 'attack')
        expect(result).to include('no time to waste')
      end

      it 'returns arrival suffix' do
        result = described_class.send(:urgency_suffix, 'arrival')
        expect(result).to include('immediate attention')
      end

      it 'returns discovery suffix' do
        result = described_class.send(:urgency_suffix, 'discovery')
        expect(result).to include('What will you do')
      end

      it 'returns distress suffix' do
        result = described_class.send(:urgency_suffix, 'distress')
        expect(result).to include('needs help')
      end

      it 'returns environmental suffix' do
        result = described_class.send(:urgency_suffix, 'environmental')
        expect(result).to include('deteriorating')
      end

      it 'returns default suffix for unknown type' do
        result = described_class.send(:urgency_suffix, 'unknown')
        expect(result).to include('What will you do')
      end
    end

    describe '#find_archetype' do
      context 'when NpcArchetype is defined' do
        let(:archetype) { double('NpcArchetype', id: 1, name: 'Guard') }

        before do
          stub_const('NpcArchetype', Class.new)
          allow(NpcArchetype).to receive(:where).and_return(double('Dataset', first: archetype))
        end

        it 'finds archetype by exact name' do
          expect(NpcArchetype).to receive(:where).with(name: 'Guard')
          described_class.send(:find_archetype, 'Guard')
        end

        it 'returns nil for nil hint' do
          result = described_class.send(:find_archetype, nil)
          expect(result).to be_nil
        end
      end
    end

    describe '#initialize_world_state' do
      let(:incident) { { 'type' => 'discovery', 'npc_involved' => 'Mysterious Stranger' } }

      it 'initializes npcs_spawned array' do
        expect(session).to receive(:update) do |args|
          expect(args[:world_state]['npcs_spawned']).to eq([])
        end
        described_class.send(:initialize_world_state, session, incident)
      end

      it 'initializes items_appeared array' do
        expect(session).to receive(:update) do |args|
          expect(args[:world_state]['items_appeared']).to eq([])
        end
        described_class.send(:initialize_world_state, session, incident)
      end

      it 'stores incident type' do
        expect(session).to receive(:update) do |args|
          expect(args[:world_state]['incident_type']).to eq('discovery')
        end
        described_class.send(:initialize_world_state, session, incident)
      end

      it 'stores incident NPC' do
        expect(session).to receive(:update) do |args|
          expect(args[:world_state]['incident_npc']).to eq('Mysterious Stranger')
        end
        described_class.send(:initialize_world_state, session, incident)
      end

      it 'stores incited_at timestamp' do
        expect(session).to receive(:update) do |args|
          expect(args[:world_state]['incited_at']).to be_a(String)
        end
        described_class.send(:initialize_world_state, session, incident)
      end
    end
  end
end
