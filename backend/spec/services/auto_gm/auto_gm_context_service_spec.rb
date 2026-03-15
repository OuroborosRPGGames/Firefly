# frozen_string_literal: true

require 'spec_helper'
require_relative 'shared_context'

RSpec.describe AutoGm::AutoGmContextService do
  include_context 'auto_gm_setup'

  describe 'constants' do
    it 'has MAX_NEARBY_MEMORIES from config' do
      expect(described_class::MAX_NEARBY_MEMORIES).to eq(GameConfig::AutoGm::CONTEXT[:max_nearby_memories])
    end

    it 'has MAX_CHARACTER_MEMORIES from config' do
      expect(described_class::MAX_CHARACTER_MEMORIES).to eq(GameConfig::AutoGm::CONTEXT[:max_character_memories])
    end

    it 'has MAX_LOCATION_SEARCH_DEPTH from config' do
      expect(described_class::MAX_LOCATION_SEARCH_DEPTH).to eq(GameConfig::AutoGm::CONTEXT[:max_location_search_depth])
    end

    it 'has MAX_NEARBY_LOCATIONS from config' do
      expect(described_class::MAX_NEARBY_LOCATIONS).to eq(GameConfig::AutoGm::CONTEXT[:max_nearby_locations])
    end

    it 'has INTERESTING_ROOM_TYPES array' do
      expect(described_class::INTERESTING_ROOM_TYPES).to be_an(Array)
      expect(described_class::INTERESTING_ROOM_TYPES).to include('cave')
      expect(described_class::INTERESTING_ROOM_TYPES).to include('dungeon')
    end
  end

  describe '.gather' do
    let(:mock_memory_scope) { double('Scope', all: []) }
    let(:chainable_dataset) do
      double('Dataset').tap do |d|
        allow(d).to receive(:where).and_return(d)
        allow(d).to receive(:eager).and_return(d)
        allow(d).to receive(:all).and_return([])
      end
    end

    before do
      allow(session).to receive(:starting_room).and_return(room)
      allow(session).to receive(:participant_instances).and_return([char_instance])
      allow(WorldMemory).to receive(:for_location).and_return(mock_memory_scope)
      allow(WorldMemory).to receive(:for_characters).and_return(mock_memory_scope)
      allow(room).to receive(:navigable_exits).and_return([])
      allow(CharacterInstance).to receive(:where).and_return(chainable_dataset)
      allow(room).to receive(:navigable_exits).and_return([])
      allow(room).to receive(:location).and_return(double('Location', id: 1, name: 'Test Location'))
      allow(room).to receive(:location_id).and_return(1)
      allow(room).to receive(:character_instances_dataset).and_return(chainable_dataset)
      allow(NarrativeQueryService).to receive(:active_threads).and_return([]) if defined?(NarrativeQueryService)
    end

    it 'returns hash with all context keys' do
      result = described_class.gather(session)

      expect(result).to have_key(:nearby_memories)
      expect(result).to have_key(:character_memories)
      expect(result).to have_key(:nearby_locations)
      expect(result).to have_key(:local_npcs)
      expect(result).to have_key(:participant_context)
      expect(result).to have_key(:room_context)
      expect(result).to have_key(:gathered_at)
    end

    it 'includes gathered_at timestamp' do
      result = described_class.gather(session)
      expect(result[:gathered_at]).to be_a(Time)
    end
  end

  describe '.gather_for_room' do
    # Create a chainable dataset double that responds to multiple .where calls
    let(:chainable_dataset) do
      double('Dataset').tap do |d|
        allow(d).to receive(:where).and_return(d)
        allow(d).to receive(:eager).and_return(d)
        allow(d).to receive(:all).and_return([])
      end
    end

    before do
      allow(WorldMemory).to receive(:for_location).and_return(double('Scope', all: []))
      allow(WorldMemory).to receive(:for_characters).and_return(double('Scope', all: []))
      allow(room).to receive(:navigable_exits).and_return([])
      allow(CharacterInstance).to receive(:where).and_return(chainable_dataset)
      allow(room).to receive(:navigable_exits).and_return([])
      allow(room).to receive(:location).and_return(double('Location', id: 1, name: 'Test Location'))
      allow(room).to receive(:location_id).and_return(1)
      allow(room).to receive(:character_instances_dataset).and_return(chainable_dataset)
      allow(NarrativeQueryService).to receive(:active_threads).and_return([]) if defined?(NarrativeQueryService)
    end

    it 'gathers context for a room without session' do
      result = described_class.gather_for_room(room, [char_instance])

      expect(result).to have_key(:nearby_memories)
      expect(result).to have_key(:room_context)
    end

    it 'works with no participants' do
      result = described_class.gather_for_room(room, [])

      expect(result[:participant_context]).to eq([])
    end
  end

  describe 'private methods' do
    describe '#gather_nearby_memories' do
      let(:memory) do
        double('WorldMemory',
               id: 1,
               summary: 'A battle happened here',
               importance: 7,
               characters: [character],
               primary_room: room,
               publicity_level: 'public',
               memory_at: Time.now - 86400,
               relevance_score: 0.8)
      end

      before do
        allow(room).to receive(:location).and_return(double('Location', id: 1))
        allow(WorldMemory).to receive(:for_location).and_return(double('Scope', all: [memory]))
        allow(DisplayHelper).to receive(:display_name).and_return('Test Hero')
      end

      it 'returns array of memory hashes' do
        result = described_class.send(:gather_nearby_memories, room)

        expect(result).to be_an(Array)
        expect(result.first[:id]).to eq(1)
        expect(result.first[:summary]).to eq('A battle happened here')
      end

      it 'returns empty array if room has no location' do
        allow(room).to receive(:location).and_return(nil)
        result = described_class.send(:gather_nearby_memories, room)
        expect(result).to eq([])
      end

      it 'returns empty array if room is nil' do
        result = described_class.send(:gather_nearby_memories, nil)
        expect(result).to eq([])
      end

      it 'handles errors gracefully' do
        allow(WorldMemory).to receive(:for_location).and_raise(StandardError.new('DB error'))
        expect { described_class.send(:gather_nearby_memories, room) }.to output(/gather_nearby_memories error/).to_stderr
        result = described_class.send(:gather_nearby_memories, room)
        expect(result).to eq([])
      end
    end

    describe '#gather_character_memories' do
      let(:memory) do
        double('WorldMemory',
               id: 2,
               summary: 'Character saved a village',
               importance: 6,
               characters: [character],
               primary_room: room,
               memory_at: Time.now - 172800)
      end

      before do
        allow(WorldMemory).to receive(:for_characters).and_return(double('Scope', all: [memory]))
        allow(DisplayHelper).to receive(:display_name).and_return('Test Hero')
        allow(room).to receive(:location).and_return(double('Location', name: 'Village'))
      end

      it 'returns array of memory hashes' do
        result = described_class.send(:gather_character_memories, [char_instance])

        expect(result).to be_an(Array)
        expect(result.first[:id]).to eq(2)
        expect(result.first[:summary]).to eq('Character saved a village')
      end

      it 'returns empty array for nil participants' do
        result = described_class.send(:gather_character_memories, nil)
        expect(result).to eq([])
      end

      it 'returns empty array for empty participants' do
        result = described_class.send(:gather_character_memories, [])
        expect(result).to eq([])
      end
    end

    describe '#discover_nearby_locations' do
      it 'returns empty array if room is nil' do
        result = described_class.send(:discover_nearby_locations, nil)
        expect(result).to eq([])
      end

      context 'with navigable neighbors' do
        let(:target_room) do
          double('Room',
                 id: 2,
                 name: 'Dark Cave',
                 description: 'A mysterious cave entrance',
                 location_id: 2,
                 location: double('Location', name: 'Mountain'),
                 room_type: 'cave',
                 navigable_exits: [])
        end

        before do
          allow(room).to receive(:navigable_exits).and_return([
            { direction: 'north', room: target_room, distance: 10.0 }
          ])
        end

        it 'returns discovered locations' do
          result = described_class.send(:discover_nearby_locations, room)

          expect(result).to be_an(Array)
          expect(result.first[:type]).to eq('cave')
          expect(result.first[:room_id]).to eq(2)
          expect(result.first[:distance]).to eq(1)
        end

        it 'sorts by distance' do
          result = described_class.send(:discover_nearby_locations, room)
          expect(result).to eq(result.sort_by { |l| l[:distance] })
        end
      end
    end

    describe '#gather_local_npcs' do
      it 'returns empty array if room is nil' do
        result = described_class.send(:gather_local_npcs, nil)
        expect(result).to eq([])
      end

      context 'with NPCs present' do
        let(:npc_char) { create(:character, forename: 'Guard', surname: 'NPC') }
        let(:npc_instance) do
          double('CharacterInstance',
                 id: 100,
                 character: npc_char,
                 current_room_id: room.id,
                 current_room: room)
        end

        before do
          allow(room).to receive(:navigable_exits).and_return([])
          allow(CharacterInstance).to receive(:where).and_return(
            double('Dataset', where: double('Dataset', eager: double('EagerDataset', all: [npc_instance])))
          )
          allow(npc_char).to receive(:npc?).and_return(true)
          allow(npc_char).to receive(:respond_to?).with(:npc_archetype).and_return(false)
          allow(DisplayHelper).to receive(:display_name).and_return('Guard NPC')
        end

        it 'returns NPC data' do
          result = described_class.send(:gather_local_npcs, room)

          expect(result).to be_an(Array)
          expect(result.first[:id]).to eq(100)
          expect(result.first[:name]).to eq('Guard NPC')
          expect(result.first[:is_in_starting_room]).to be true
        end
      end
    end

    describe '#build_participant_context' do
      it 'returns empty array for nil' do
        result = described_class.send(:build_participant_context, nil)
        expect(result).to eq([])
      end

      it 'returns empty array for empty array' do
        result = described_class.send(:build_participant_context, [])
        expect(result).to eq([])
      end

      context 'with participants' do
        before do
          allow(DisplayHelper).to receive(:display_name).and_return('Test Hero')
          allow(character).to receive(:respond_to?).and_return(false)
        end

        it 'builds context for each participant' do
          result = described_class.send(:build_participant_context, [char_instance])

          expect(result).to be_an(Array)
          expect(result.first[:instance_id]).to eq(char_instance.id)
          expect(result.first[:character_id]).to eq(character.id)
          expect(result.first[:name]).to eq('Test Hero')
        end

        it 'includes optional fields when available' do
          allow(character).to receive(:respond_to?).with(:level).and_return(true)
          allow(character).to receive(:respond_to?).with(:char_class).and_return(true)
          allow(character).to receive(:respond_to?).with(:race).and_return(true)
          allow(character).to receive(:respond_to?).with(:background).and_return(false)
          allow(character).to receive(:respond_to?).with(:top_skills).and_return(false)
          allow(character).to receive(:respond_to?).with(:significant_relationships).and_return(false)
          allow(character).to receive(:level).and_return(5)
          allow(character).to receive(:char_class).and_return('Fighter')
          allow(character).to receive(:race).and_return('Human')

          result = described_class.send(:build_participant_context, [char_instance])

          expect(result.first[:level]).to eq(5)
          expect(result.first[:char_class]).to eq('Fighter')
          expect(result.first[:race]).to eq('Human')
        end
      end
    end

    describe '#build_room_context' do
      it 'returns empty hash for nil room' do
        result = described_class.send(:build_room_context, nil)
        expect(result).to eq({})
      end

      context 'with valid room' do
        before do
          allow(room).to receive(:location).and_return(double('Location', name: 'Test Location'))
          allow(room).to receive(:location_id).and_return(1)
          allow(room).to receive(:navigable_exits).and_return([])
          allow(room).to receive(:character_instances_dataset).and_return(
            double('Dataset', where: double('Dataset', eager: double('EagerDataset', all: [])))
          )
          allow(room).to receive(:respond_to?).with(:visible_places).and_return(false)
        end

        it 'returns room context hash' do
          result = described_class.send(:build_room_context, room)

          expect(result[:id]).to eq(room.id)
          expect(result[:name]).to eq(room.name)
          expect(result[:room_type]).to eq(room.room_type)
        end

        it 'includes location info' do
          result = described_class.send(:build_room_context, room)

          expect(result[:location_name]).to eq('Test Location')
          expect(result[:location_id]).to eq(1)
        end

        it 'includes exits' do
          north_room = double('Room', name: 'North Room', room_type: 'street')
          allow(room).to receive(:navigable_exits).and_return([
            { direction: 'north', room: north_room, distance: 10.0 }
          ])

          result = described_class.send(:build_room_context, room)

          expect(result[:exits]).to be_an(Array)
          expect(result[:exits].first[:direction]).to eq('north')
          expect(result[:exits].first[:to_room_name]).to eq('North Room')
        end
      end
    end

    describe '#truncate_text' do
      it 'returns empty string for nil' do
        result = described_class.send(:truncate_text, nil, 100)
        expect(result).to eq('')
      end

      it 'returns empty string for empty text' do
        result = described_class.send(:truncate_text, '', 100)
        expect(result).to eq('')
      end

      it 'returns text unchanged if under max length' do
        text = 'Short text'
        result = described_class.send(:truncate_text, text, 100)
        expect(result).to eq(text)
      end

      it 'truncates text over max length with ellipsis' do
        text = 'A' * 200
        result = described_class.send(:truncate_text, text, 100)
        expect(result.length).to eq(100)
        expect(result).to end_with('...')
      end
    end
  end
end
