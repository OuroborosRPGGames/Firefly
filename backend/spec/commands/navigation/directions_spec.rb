# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Direction Commands', type: :command do
  let(:location) { create(:location) }

  # Create spatially adjacent rooms using polygon geometry
  # Rooms are laid out on a grid where each room is 100x100 feet
  # Start room is at center (100, 100) to (200, 200)
  let(:start_room) do
    create(:room,
           name: 'Start Room', short_description: 'Starting room.',
           location: location, room_type: 'standard', indoors: false,
           min_x: 100, max_x: 200, min_y: 100, max_y: 200)
  end

  # North room shares edge at y=200
  let(:north_room) do
    create(:room,
           name: 'North Room', short_description: 'North room.',
           location: location, room_type: 'standard', indoors: false,
           min_x: 100, max_x: 200, min_y: 200, max_y: 300)
  end

  # South room shares edge at y=100
  let(:south_room) do
    create(:room,
           name: 'South Room', short_description: 'South room.',
           location: location, room_type: 'standard', indoors: false,
           min_x: 100, max_x: 200, min_y: 0, max_y: 100)
  end

  # East room shares edge at x=200
  let(:east_room) do
    create(:room,
           name: 'East Room', short_description: 'East room.',
           location: location, room_type: 'standard', indoors: false,
           min_x: 200, max_x: 300, min_y: 100, max_y: 200)
  end

  # West room shares edge at x=100
  let(:west_room) do
    create(:room,
           name: 'West Room', short_description: 'West room.',
           location: location, room_type: 'standard', indoors: false,
           min_x: 0, max_x: 100, min_y: 100, max_y: 200)
  end

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: start_room)
  end

  describe Commands::Navigation::North do
    before { north_room } # Ensure adjacent room exists

    subject(:command) { described_class.new(character_instance) }

    it 'starts movement toward the north room' do
      result = command.execute('north')
      expect(result[:success]).to be true
      expect(result[:moving]).to be true
    end

    it 'has correct command name' do
      expect(described_class.command_name).to eq('north')
    end

    it 'has "n" as alias' do
      expect(described_class.alias_names).to include('n')
    end
  end

  describe Commands::Navigation::South do
    before { south_room } # Ensure adjacent room exists

    subject(:command) { described_class.new(character_instance) }

    it 'starts movement toward the south room' do
      result = command.execute('south')
      expect(result[:success]).to be true
      expect(result[:moving]).to be true
    end

    it 'has correct command name' do
      expect(described_class.command_name).to eq('south')
    end

    it 'has "s" as alias' do
      expect(described_class.alias_names).to include('s')
    end
  end

  describe Commands::Navigation::East do
    before { east_room } # Ensure adjacent room exists

    subject(:command) { described_class.new(character_instance) }

    it 'starts movement toward the east room' do
      result = command.execute('east')
      expect(result[:success]).to be true
      expect(result[:moving]).to be true
    end

    it 'has "e" as alias' do
      expect(described_class.alias_names).to include('e')
    end
  end

  describe Commands::Navigation::West do
    before { west_room } # Ensure adjacent room exists

    subject(:command) { described_class.new(character_instance) }

    it 'starts movement toward the west room' do
      result = command.execute('west')
      expect(result[:success]).to be true
      expect(result[:moving]).to be true
    end

    it 'has "w" as alias' do
      expect(described_class.alias_names).to include('w')
    end
  end

  describe Commands::Navigation::Up do
    # Up/down without exits will cause wall movement (moving toward ceiling/floor)
    subject(:command) { described_class.new(character_instance) }

    it 'returns error when no upward exit exists' do
      result = command.execute('up')
      expect(result[:success]).to be false
    end

    it 'has "u" as alias' do
      expect(described_class.alias_names).to include('u')
    end
  end

  describe Commands::Navigation::Down do
    # Up/down without exits will cause wall movement (moving toward ceiling/floor)
    subject(:command) { described_class.new(character_instance) }

    it 'returns error when no downward exit exists' do
      result = command.execute('down')
      expect(result[:success]).to be false
    end

    it 'has "d" as alias' do
      expect(described_class.alias_names).to include('d')
    end
  end

  describe 'all direction commands' do
    it 'all have category :navigation' do
      [
        Commands::Navigation::North,
        Commands::Navigation::South,
        Commands::Navigation::East,
        Commands::Navigation::West,
        Commands::Navigation::Up,
        Commands::Navigation::Down,
        Commands::Navigation::Northeast,
        Commands::Navigation::Northwest,
        Commands::Navigation::Southeast,
        Commands::Navigation::Southwest
      ].each do |command_class|
        expect(command_class.category).to eq(:navigation)
      end
    end
  end
end
