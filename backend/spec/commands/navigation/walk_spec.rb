# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Walk, type: :command do
  let(:location) { create(:location) }

  # Room A with defined bounds for spatial adjacency
  let(:room_a) do
    create(:room,
           name: 'Room A', short_description: 'Start', location: location,
           room_type: 'standard', indoors: false,
           min_x: 100, max_x: 200, min_y: 100, max_y: 200)
  end

  # Room B is spatially adjacent to room_a (shares north edge)
  let(:room_b) do
    create(:room,
           name: 'Room B', short_description: 'North', location: location,
           room_type: 'standard', indoors: false,
           min_x: 100, max_x: 200, min_y: 200, max_y: 300)
  end

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room_a)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    before { room_b } # Ensure north room exists

    def complete_latest_movement!
      action = TimedAction.where(
        character_instance_id: character_instance.id,
        action_name: 'movement',
        status: 'active'
      ).order(:id).last
      expect(action).not_to be_nil

      action.update(completes_at: Time.now - 1)
      expect(action.finish!).to be true
    end

    context 'with direction target' do
      it 'starts walking movement' do
        result = command.execute('walk north')

        expect(result[:success]).to be true
        expect(result[:message]).to include('walking')
        expect(result[:moving]).to be true
      end

      it 'sets movement state to moving' do
        command.execute('walk north')

        expect(character_instance.reload.movement_state).to eq('moving')
      end
    end

    context 'with different movement verbs' do
      it 'handles run command' do
        result = command.execute('run north')

        expect(result[:success]).to be true
        expect(result[:message]).to include('running')
      end

      it 'handles crawl command' do
        result = command.execute('crawl north')

        expect(result[:success]).to be true
        expect(result[:message]).to include('crawling')
      end

      it 'handles sprint command' do
        result = command.execute('sprint north')

        expect(result[:success]).to be true
        expect(result[:message]).to include('sprinting')
      end
    end

    context 'with no target' do
      it 'returns error asking for destination' do
        result = command.execute('walk')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Where')
      end
    end

    context 'with invalid target' do
      it 'returns error' do
        result = command.execute('walk nowhere')

        expect(result[:success]).to be false
      end
    end

    context 'when already moving' do
      before do
        character_instance.update(movement_state: 'moving')
      end

      it 'returns error' do
        result = command.execute('walk north')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Already moving')
      end
    end

    context 'with outdoor building entry/exit through a single door edge' do
      let(:south_street) do
        create(:room,
               name: 'South Street', short_description: 'Street south of building', location: location,
               room_type: 'street', indoors: false,
               min_x: 5000, max_x: 5100, min_y: 5000, max_y: 5100)
      end

      let(:building) do
        create(:room,
               name: 'Corner Shop', short_description: 'A small shop', location: location,
               room_type: 'building', city_role: 'building', indoors: true,
               min_x: 5000, max_x: 5100, min_y: 5100, max_y: 5200)
      end

      let(:north_street) do
        create(:room,
               name: 'North Street', short_description: 'Street north of building', location: location,
               room_type: 'street', indoors: false,
               min_x: 5000, max_x: 5100, min_y: 5200, max_y: 5300)
      end

      let(:character_instance) do
        create(:character_instance, character: character, current_room: south_street)
      end

      before do
        north_street
        building

        %w[north south east west].each do |dir|
          create(:room_feature, room: building, feature_type: 'wall', direction: dir)
        end
        create(:room_feature, room: building, feature_type: 'door', direction: 'south', is_open: true)
      end

      it 'walks north into the building and walk out returns to the same street edge' do
        enter_result = command.execute('walk north')
        expect(enter_result[:success]).to be true
        expect(enter_result[:moving]).to be true

        complete_latest_movement!
        expect(character_instance.reload.current_room_id).to eq(building.id)

        out_result = command.execute('walk out')
        expect(out_result[:success]).to be true
        expect(out_result[:moving]).to be true

        complete_latest_movement!
        expect(character_instance.reload.current_room_id).to eq(south_street.id)
      end

      it 'does not allow entering from the north wall where no door exists' do
        character_instance.update(
          current_room_id: north_street.id,
          movement_state: 'idle',
          movement_direction: nil,
          final_destination_id: nil
        )

        result = command.execute('walk south')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/can't go|can't find|no exit|blocked/i)
      end
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('walk')
    end

    it 'has movement verb aliases' do
      aliases = described_class.alias_names
      expect(aliases).to include('run', 'jog', 'crawl', 'sprint')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:navigation)
    end
  end
end
