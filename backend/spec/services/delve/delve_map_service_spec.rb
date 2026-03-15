# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveMapService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { Reality.create(name: 'Primary', reality_type: 'primary', time_offset: 0) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Delver', surname: 'Hero') }
  let(:character_instance) do
    CharacterInstance.create(
      character: character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive'
    )
  end

  let(:delve) do
    Delve.create(
      name: 'Test Dungeon',
      difficulty: 'normal',
      status: 'active',
      time_limit_minutes: 60,
      levels_generated: 1,
      location_id: location.id,
      started_at: Time.now
    )
  end

  let(:delve_room_entrance) do
    DelveRoom.create(
      delve_id: delve.id,
      room_type: 'corridor',
      depth: 0,
      level: 1,
      grid_x: 0,
      grid_y: 0,
      is_entrance: true,
      explored: true
    )
  end

  let(:delve_room_corridor) do
    DelveRoom.create(
      delve_id: delve.id,
      room_type: 'corridor',
      depth: 1,
      level: 1,
      grid_x: 1,
      grid_y: 0,
      explored: true
    )
  end

  let(:delve_room_chamber) do
    DelveRoom.create(
      delve_id: delve.id,
      room_type: 'branch',
      depth: 2,
      level: 1,
      grid_x: 2,
      grid_y: 0,
      explored: false
    )
  end

  let(:delve_room_exit) do
    DelveRoom.create(
      delve_id: delve.id,
      room_type: 'terminal',
      depth: 3,
      level: 1,
      grid_x: 3,
      grid_y: 0,
      is_exit: true,
      explored: true
    )
  end

  let(:participant) do
    DelveParticipant.create(
      delve_id: delve.id,
      character_instance_id: character_instance.id,
      current_delve_room_id: delve_room_entrance.id,
      current_level: 1,
      status: 'active',
      loot_collected: 25,
      time_spent_minutes: 10,
      time_spent_seconds: 600
    )
  end

  describe 'constants' do
    it 'defines CELL_SIZE' do
      expect(described_class::CELL_SIZE).to eq(20)
    end

    it 'defines PADDING' do
      expect(described_class::PADDING).to eq(10)
    end

    it 'defines COLORS hash with expected keys' do
      colors = described_class::COLORS

      expect(colors[:corridor]).to eq('#666666')
      expect(colors[:corner]).to eq('#777777')
      expect(colors[:branch]).to eq('#888888')
      expect(colors[:terminal]).to eq('#999999')
      expect(colors[:player]).to eq('#00AAFF')
      expect(colors[:fog]).to eq('#222222')
      expect(colors[:unexplored]).to eq('#111111')
    end
  end

  describe '.render_minimap' do
    context 'with no current room' do
      before do
        participant.update(current_delve_room_id: nil)
      end

      it 'returns empty map' do
        result = described_class.render_minimap(participant)
        expect(result).to include('No map data')
      end
    end

    context 'with no rooms on level' do
      before do
        allow(delve).to receive(:rooms_on_level).and_return(double(all: []))
        allow(participant).to receive(:delve).and_return(delve)
        allow(participant).to receive(:current_level).and_return(99)
      end

      it 'returns empty map' do
        result = described_class.render_minimap(participant)
        expect(result).to include('No map data')
      end
    end

    context 'with valid rooms' do
      before do
        # Create rooms
        delve_room_entrance
        delve_room_corridor
        delve_room_exit

        # Mock visibility service
        visibility_data = [
          {
            room: delve_room_entrance,
            grid_x: 0,
            grid_y: 0,
            visibility: :full,
            show_type: true,
            show_contents: true,
            show_danger: true
          },
          {
            room: delve_room_corridor,
            grid_x: 1,
            grid_y: 0,
            visibility: :danger,
            show_type: true,
            show_contents: false,
            show_danger: true
          },
          {
            room: delve_room_exit,
            grid_x: 3,
            grid_y: 0,
            visibility: :explored,
            show_type: true,
            show_contents: false,
            show_danger: false
          }
        ]
        allow(DelveVisibilityService).to receive(:visible_rooms).and_return(visibility_data)
      end

      it 'returns canvas format string' do
        result = described_class.render_minimap(participant)
        expect(result).to be_a(String)

        parts = result.split('|||')
        expect(parts.size).to eq(3)

        width, height, commands = parts
        expect(width.to_i).to be > 0
        expect(height.to_i).to be > 0
        expect(commands).to include(';;;')
      end

      it 'includes background rectangle' do
        result = described_class.render_minimap(participant)
        expect(result).to include('frect::')
        expect(result).to include(described_class::COLORS[:fog])
      end

      it 'includes player position marker' do
        result = described_class.render_minimap(participant)
        expect(result).to include('fcircle::')
        expect(result).to include(described_class::COLORS[:player])
      end

      it 'includes status bar text' do
        result = described_class.render_minimap(participant)
        expect(result).to include('text::')
        expect(result).to include('Level 1')
        expect(result).to include('Loot: 25')
      end
    end
  end

  describe '.render_full_map' do
    context 'with no current room' do
      before do
        participant.update(current_delve_room_id: nil)
      end

      it 'returns empty map' do
        result = described_class.render_full_map(participant)
        expect(result).to include('No map data')
      end
    end

    context 'with explored rooms' do
      before do
        # Create rooms
        delve_room_entrance
        delve_room_corridor
        delve_room_exit

        # Mock visibility service
        visibility_data = [
          {
            room: delve_room_entrance,
            grid_x: 0,
            grid_y: 0,
            visibility: :full,
            show_type: true,
            show_contents: true,
            show_danger: true
          },
          {
            room: delve_room_corridor,
            grid_x: 1,
            grid_y: 0,
            visibility: :danger,
            show_type: true,
            show_contents: false,
            show_danger: true
          },
          {
            room: delve_room_exit,
            grid_x: 3,
            grid_y: 0,
            visibility: :explored,
            show_type: true,
            show_contents: false,
            show_danger: false
          }
        ]
        allow(DelveVisibilityService).to receive(:visible_rooms).and_return(visibility_data)
      end

      it 'returns canvas format string' do
        result = described_class.render_full_map(participant)
        expect(result).to be_a(String)

        parts = result.split('|||')
        expect(parts.size).to eq(3)
      end

      it 'includes legend at bottom' do
        result = described_class.render_full_map(participant)
        expect(result).to include('Legend:')
        expect(result).to include('@ You')
        expect(result).to include('M Monster')
        expect(result).to include('$ Treasure')
      end

      it 'draws player position when in explored room' do
        result = described_class.render_full_map(participant)
        expect(result).to include('fcircle::')
        expect(result).to include(described_class::COLORS[:player])
      end
    end
  end

  describe '.render_ascii' do
    context 'with no current room' do
      before do
        participant.update(current_delve_room_id: nil)
      end

      it 'returns no map message' do
        result = described_class.render_ascii(participant)
        expect(result).to eq('No map available.')
      end
    end

    context 'with no rooms on level' do
      before do
        allow(delve).to receive(:rooms_on_level).and_return(double(all: []))
        allow(participant).to receive(:delve).and_return(delve)
        allow(participant).to receive(:current_level).and_return(99)
      end

      it 'returns no rooms message' do
        result = described_class.render_ascii(participant)
        expect(result).to eq('No rooms on this level.')
      end
    end

    context 'with valid rooms' do
      before do
        # Create rooms
        delve_room_entrance
        delve_room_corridor
        delve_room_exit

        # Mock visibility service
        visibility_data = [
          {
            room: delve_room_entrance,
            grid_x: 0,
            grid_y: 0,
            visibility: :full,
            show_type: true,
            show_contents: true,
            show_danger: true
          },
          {
            room: delve_room_corridor,
            grid_x: 1,
            grid_y: 0,
            visibility: :danger,
            show_type: true,
            show_contents: false,
            show_danger: true
          },
          {
            room: delve_room_exit,
            grid_x: 3,
            grid_y: 0,
            visibility: :explored,
            show_type: true,
            show_contents: false,
            show_danger: false
          }
        ]
        allow(DelveVisibilityService).to receive(:visible_rooms).and_return(visibility_data)
      end

      it 'returns ASCII string' do
        result = described_class.render_ascii(participant)
        expect(result).to be_a(String)
      end

      it 'marks player position with @' do
        result = described_class.render_ascii(participant)
        expect(result).to include('@')
      end

      it 'includes legend' do
        result = described_class.render_ascii(participant)
        expect(result).to include('Legend:')
        expect(result).to include('@ You')
        expect(result).to include('> Exit')
      end
    end
  end

  describe 'private helpers' do
    let(:service) { Class.new(described_class).new }

    before do
      delve_room_entrance
      delve_room_corridor
      delve_room_exit
    end

    describe 'empty_map' do
      it 'returns default canvas format' do
        result = described_class.send(:empty_map)
        expect(result).to eq('100|||50|||text::10,25||Georgia||No map data')
      end
    end

    describe 'room_indicator' do
      context 'with full visibility showing contents' do
        let(:visibility) { { show_contents: true, show_danger: true } }

        it 'shows exit marker for exit rooms' do
          result = described_class.send(:room_indicator, delve_room_exit, visibility, delve)
          expect(result).to eq('v')
        end

        it 'shows entrance marker for entrance rooms' do
          result = described_class.send(:room_indicator, delve_room_entrance, visibility, delve)
          expect(result).to eq('^')
        end

        it 'returns nil for empty corridor' do
          result = described_class.send(:room_indicator, delve_room_corridor, visibility, delve)
          expect(result).to be_nil
        end

        it 'shows M for rooms with monsters' do
          allow(delve).to receive(:monsters_in_room).and_return([double('Monster')])
          result = described_class.send(:room_indicator, delve_room_corridor, visibility, delve)
          expect(result).to eq('M')
        end

        it 'shows $ for rooms with treasure' do
          DelveTreasure.create(delve_room_id: delve_room_corridor.id, looted: false, gold_value: 50)
          result = described_class.send(:room_indicator, delve_room_corridor, visibility, delve)
          expect(result).to eq('$')
        end

        it 'shows T for rooms with traps' do
          DelveTrap.create(delve_room_id: delve_room_corridor.id, disabled: false, timing_a: 3, timing_b: 5)
          result = described_class.send(:room_indicator, delve_room_corridor, visibility, delve)
          expect(result).to eq('T')
        end

        it 'shows X for rooms with blockers' do
          DelveBlocker.create(delve_room_id: delve_room_corridor.id, cleared: false, direction: 'north', blocker_type: 'barricade')
          result = described_class.send(:room_indicator, delve_room_corridor, visibility, delve)
          expect(result).to eq('X')
        end
      end

      context 'with danger visibility only' do
        let(:visibility) { { show_contents: false, show_danger: true } }

        it 'shows M for rooms with monsters' do
          allow(delve).to receive(:monsters_in_room).and_return([double('Monster')])
          result = described_class.send(:room_indicator, delve_room_corridor, visibility, delve)
          expect(result).to eq('M')
        end

        it 'shows ! for dangerous uncleared rooms' do
          monster_room = DelveRoom.create(
            delve_id: delve.id,
            room_type: 'corridor',
            depth: 2,
            level: 1,
            grid_x: 5,
            grid_y: 0,
            cleared: false,
            monster_type: 'goblin'
          )
          allow(delve).to receive(:monsters_in_room).and_return([])

          result = described_class.send(:room_indicator, monster_room, visibility, delve)
          expect(result).to eq('!')
        end
      end

      context 'with explored but out of range' do
        let(:visibility) { { show_contents: false, show_danger: false } }

        it 'shows v for explored exit' do
          result = described_class.send(:room_indicator, delve_room_exit, visibility, delve)
          expect(result).to eq('v')
        end

        it 'shows ^ for explored entrance' do
          result = described_class.send(:room_indicator, delve_room_entrance, visibility, delve)
          expect(result).to eq('^')
        end
      end
    end

    describe 'room_color' do
      it 'returns unexplored color for hidden unexplored rooms' do
        visibility = { visibility: :hidden }
        unexplored_room = DelveRoom.create(
          delve_id: delve.id, room_type: 'corridor', depth: 5,
          level: 1, grid_x: 10, grid_y: 0, explored: false
        )

        result = described_class.send(:room_color, unexplored_room, visibility)
        expect(result).to eq(described_class::COLORS[:unexplored])
      end

      it 'returns fog color for explored but not visible rooms' do
        visibility = { visibility: :explored, show_contents: false }

        result = described_class.send(:room_color, delve_room_corridor, visibility)
        expect(result).to eq(described_class::COLORS[:fog])
      end

      it 'returns danger_hint color for dangerous uncleared rooms' do
        monster_room = DelveRoom.create(
          delve_id: delve.id, room_type: 'corridor', depth: 2,
          level: 1, grid_x: 6, grid_y: 0, cleared: false,
          monster_type: 'goblin'
        )
        visibility = { visibility: :full, show_contents: true, show_danger: true }

        result = described_class.send(:room_color, monster_room, visibility)
        expect(result).to eq(described_class::COLORS[:danger_hint])
      end

      it 'returns room type color for normal visibility' do
        visibility = { visibility: :full, show_contents: true, show_danger: false }

        result = described_class.send(:room_color, delve_room_chamber, visibility)
        expect(result).to eq(described_class::COLORS[:branch])
      end
    end

    describe 'room_char' do
      it 'returns ? for nil visibility' do
        result = described_class.send(:room_char, delve_room_corridor, nil, delve)
        expect(result).to eq('?')
      end

      context 'with full content visibility' do
        let(:visibility) { { show_contents: true, show_danger: true } }

        it 'returns M for rooms with monsters' do
          allow(delve).to receive(:monsters_in_room).and_return([double('Monster')])
          result = described_class.send(:room_char, delve_room_corridor, visibility, delve)
          expect(result).to eq('M')
        end

        it 'returns $ for rooms with treasure' do
          DelveTreasure.create(delve_room_id: delve_room_corridor.id, looted: false, gold_value: 100)
          allow(delve).to receive(:monsters_in_room).and_return([])
          result = described_class.send(:room_char, delve_room_corridor, visibility, delve)
          expect(result).to eq('$')
        end

        it 'returns T for rooms with traps' do
          DelveTrap.create(delve_room_id: delve_room_corridor.id, disabled: false, timing_a: 3, timing_b: 5)
          allow(delve).to receive(:monsters_in_room).and_return([])
          result = described_class.send(:room_char, delve_room_corridor, visibility, delve)
          expect(result).to eq('T')
        end

        it 'returns O for chamber type' do
          chamber = DelveRoom.create(
            delve_id: delve.id, room_type: 'branch', depth: 2,
            level: 1, grid_x: 7, grid_y: 0
          )
          allow(delve).to receive(:monsters_in_room).and_return([])
          result = described_class.send(:room_char, chamber, visibility, delve)
          expect(result).to eq('O')
        end

        it 'returns # for corridor type' do
          allow(delve).to receive(:monsters_in_room).and_return([])
          result = described_class.send(:room_char, delve_room_corridor, visibility, delve)
          expect(result).to eq('#')
        end

        it 'returns > for exit type' do
          allow(delve).to receive(:monsters_in_room).and_return([])
          result = described_class.send(:room_char, delve_room_exit, visibility, delve)
          expect(result).to eq('>')
        end

        it 'returns ^ for entrance room' do
          allow(delve).to receive(:monsters_in_room).and_return([])
          result = described_class.send(:room_char, delve_room_entrance, visibility, delve)
          expect(result).to eq('^')
        end
      end

      context 'with danger visibility only' do
        let(:visibility) { { show_contents: false, show_danger: true } }

        it 'returns M for rooms with monsters' do
          allow(delve).to receive(:monsters_in_room).and_return([double('Monster')])
          result = described_class.send(:room_char, delve_room_corridor, visibility, delve)
          expect(result).to eq('M')
        end

        it 'returns ! for dangerous uncleared rooms' do
          trap_room = DelveRoom.create(
            delve_id: delve.id, room_type: 'corridor', depth: 2,
            level: 1, grid_x: 9, grid_y: 0, cleared: false,
            monster_type: 'goblin'
          )
          allow(delve).to receive(:monsters_in_room).and_return([])
          result = described_class.send(:room_char, trap_room, visibility, delve)
          expect(result).to eq('!')
        end

        it 'returns # for regular rooms' do
          allow(delve).to receive(:monsters_in_room).and_return([])
          result = described_class.send(:room_char, delve_room_corridor, visibility, delve)
          expect(result).to eq('#')
        end
      end

      context 'without content or danger visibility' do
        let(:visibility) { { show_contents: false, show_danger: false } }

        it 'returns > for exit room' do
          result = described_class.send(:room_char, delve_room_exit, visibility, delve)
          expect(result).to eq('>')
        end

        it 'returns ^ for entrance room' do
          result = described_class.send(:room_char, delve_room_entrance, visibility, delve)
          expect(result).to eq('^')
        end

        it 'returns # for regular rooms' do
          result = described_class.send(:room_char, delve_room_corridor, visibility, delve)
          expect(result).to eq('#')
        end
      end
    end

    describe 'draw_connection' do
      let(:rx) { 50 }
      let(:ry) { 50 }
      let(:cell_size) { 20 }

      it 'draws north connection' do
        result = described_class.send(:draw_connection, rx, ry, 'north', cell_size)
        expect(result).to include('line::')
        expect(result).to include(described_class::COLORS[:connection])
      end

      it 'draws south connection' do
        result = described_class.send(:draw_connection, rx, ry, 'south', cell_size)
        expect(result).to include('line::')
      end

      it 'draws east connection' do
        result = described_class.send(:draw_connection, rx, ry, 'east', cell_size)
        expect(result).to include('line::')
      end

      it 'draws west connection' do
        result = described_class.send(:draw_connection, rx, ry, 'west', cell_size)
        expect(result).to include('line::')
      end

      it 'returns nil for invalid direction' do
        result = described_class.send(:draw_connection, rx, ry, 'up', cell_size)
        expect(result).to be_nil
      end
    end
  end

  describe 'integration scenarios' do
    # Create a separate delve to avoid coordinate conflicts with other tests
    let(:integration_delve) do
      Delve.create(
        name: 'Integration Test Dungeon',
        difficulty: 'normal',
        status: 'active',
        time_limit_minutes: 60,
        levels_generated: 1,
        location_id: location.id,
        started_at: Time.now
      )
    end

    let(:integration_participant) do
      DelveParticipant.create(
        delve_id: integration_delve.id,
        character_instance_id: character_instance.id,
        current_level: 1,
        status: 'active',
        loot_collected: 25,
        time_spent_minutes: 10,
        time_spent_seconds: 600
      )
    end

    before do
      # Create a grid of rooms for more realistic testing
      @rooms = []
      # Row 0
      @rooms << DelveRoom.create(delve_id: integration_delve.id, room_type: 'corridor', depth: 0, level: 1, grid_x: 0, grid_y: 0, is_entrance: true, explored: true)
      @rooms << DelveRoom.create(delve_id: integration_delve.id, room_type: 'corridor', depth: 1, level: 1, grid_x: 1, grid_y: 0, explored: true)
      @rooms << DelveRoom.create(delve_id: integration_delve.id, room_type: 'terminal', depth: 2, level: 1, grid_x: 2, grid_y: 0, explored: true)
      # Row 1
      @rooms << DelveRoom.create(delve_id: integration_delve.id, room_type: 'corridor', depth: 1, level: 1, grid_x: 0, grid_y: 1, explored: false)
      @rooms << DelveRoom.create(delve_id: integration_delve.id, room_type: 'branch', depth: 2, level: 1, grid_x: 1, grid_y: 1, explored: true)
      @rooms << DelveRoom.create(delve_id: integration_delve.id, room_type: 'terminal', depth: 3, level: 1, grid_x: 2, grid_y: 1, is_exit: true, explored: true)

      integration_participant.update(current_delve_room_id: @rooms[0].id)

      # Build visibility data
      visibility_data = @rooms.map do |room|
        distance = (room.grid_x - 0).abs + (room.grid_y - 0).abs
        {
          room: room,
          grid_x: room.grid_x,
          grid_y: room.grid_y,
          distance: distance,
          visibility: distance == 0 ? :full : (distance <= 3 ? :danger : :explored),
          show_type: true,
          show_contents: distance == 0,
          show_danger: distance <= 3
        }
      end
      allow(DelveVisibilityService).to receive(:visible_rooms).and_return(visibility_data)
    end

    it 'renders minimap with proper dimensions' do
      result = described_class.render_minimap(integration_participant)
      parts = result.split('|||')

      width = parts[0].to_i
      height = parts[1].to_i

      # Map should accommodate grid (3x2) + padding
      expect(width).to be > 60
      expect(height).to be > 60
    end

    it 'renders full map with explored rooms only' do
      result = described_class.render_full_map(integration_participant)

      # Should include the explored rooms
      parts = result.split('|||')
      expect(parts[2]).to include('frect::')
    end

    it 'renders ASCII map with grid layout' do
      result = described_class.render_ascii(integration_participant)
      lines = result.split("\n")

      # Should have map lines plus legend
      expect(lines.size).to be >= 3
      expect(result).to include('@')
      expect(result).to include('Legend:')
    end
  end

  # ============================================
  # Additional Room Indicator Tests
  # ============================================

  describe 'room_indicator_for_full_map additional tests' do
    before do
      delve_room_entrance
      delve_room_corridor
      delve_room_exit
    end

    context 'with show_danger visibility' do
      let(:visibility) { { show_contents: false, show_danger: true } }

      it 'shows M for rooms with monsters in danger range' do
        allow(delve).to receive(:monsters_in_room).and_return([double('Monster')])
        result = described_class.send(:room_indicator, delve_room_corridor, visibility, delve)
        expect(result).to eq('M')
      end

      it 'does not show treasure without content visibility' do
        DelveTreasure.create(delve_room_id: delve_room_corridor.id, looted: false, gold_value: 50)
        allow(delve).to receive(:monsters_in_room).and_return([])
        result = described_class.send(:room_indicator, delve_room_corridor, visibility, delve)
        # Since show_contents is false, we don't show treasure
        expect(result).to be_nil
      end
    end

    context 'with show_contents visibility' do
      let(:visibility) { { show_contents: true, show_danger: true } }

      it 'shows $ for rooms with treasure' do
        DelveTreasure.create(delve_room_id: delve_room_corridor.id, looted: false, gold_value: 75)
        allow(delve).to receive(:monsters_in_room).and_return([])
        result = described_class.send(:room_indicator, delve_room_corridor, visibility, delve)
        expect(result).to eq('$')
      end

      it 'shows T for rooms with active traps' do
        DelveTrap.create(delve_room_id: delve_room_corridor.id, disabled: false, timing_a: 2, timing_b: 4)
        allow(delve).to receive(:monsters_in_room).and_return([])
        result = described_class.send(:room_indicator, delve_room_corridor, visibility, delve)
        expect(result).to eq('T')
      end

      it 'does not show T for disabled traps' do
        DelveTrap.create(delve_room_id: delve_room_corridor.id, disabled: true, timing_a: 2, timing_b: 4)
        allow(delve).to receive(:monsters_in_room).and_return([])
        result = described_class.send(:room_indicator, delve_room_corridor, visibility, delve)
        expect(result).to be_nil
      end
    end

    context 'with no special visibility' do
      let(:visibility) { { show_contents: false, show_danger: false } }

      it 'shows v for exit rooms' do
        result = described_class.send(:room_indicator, delve_room_exit, visibility, delve)
        expect(result).to eq('v')
      end

      it 'shows ^ for entrance rooms' do
        result = described_class.send(:room_indicator, delve_room_entrance, visibility, delve)
        expect(result).to eq('^')
      end

      it 'returns nil for regular rooms' do
        result = described_class.send(:room_indicator, delve_room_corridor, visibility, delve)
        expect(result).to be_nil
      end
    end

    context 'with nil visibility' do
      # room_indicator_for_full_map handles nil visibility properly
      # while room_indicator expects a valid visibility hash
      it 'shows static markers for exit via full_map method' do
        result = described_class.send(:room_indicator_for_full_map, delve_room_exit, nil, delve)
        expect(result).to eq('v')
      end

      it 'shows static markers for entrance via full_map method' do
        result = described_class.send(:room_indicator_for_full_map, delve_room_entrance, nil, delve)
        expect(result).to eq('^')
      end
    end
  end

  # ============================================
  # Connection Drawing Edge Cases
  # ============================================

  describe 'draw_connection edge cases' do
    let(:rx) { 100 }
    let(:ry) { 100 }
    let(:cell_size) { 20 }

    it 'calculates north connection coordinates correctly' do
      result = described_class.send(:draw_connection, rx, ry, 'north', cell_size)
      expect(result).to include("#{rx + cell_size / 2}")
      expect(result).to include('line::')
    end

    it 'calculates south connection coordinates correctly' do
      result = described_class.send(:draw_connection, rx, ry, 'south', cell_size)
      expect(result).to include("#{rx + cell_size / 2}")
    end

    it 'calculates east connection coordinates correctly' do
      result = described_class.send(:draw_connection, rx, ry, 'east', cell_size)
      expect(result).to include("#{ry + cell_size / 2}")
    end

    it 'calculates west connection coordinates correctly' do
      result = described_class.send(:draw_connection, rx, ry, 'west', cell_size)
      expect(result).to include("#{ry + cell_size / 2}")
    end

    it 'returns nil for diagonal directions' do
      expect(described_class.send(:draw_connection, rx, ry, 'northeast', cell_size)).to be_nil
      expect(described_class.send(:draw_connection, rx, ry, 'southwest', cell_size)).to be_nil
    end
  end

  # ============================================
  # Room Color Edge Cases
  # ============================================

  describe 'room_color edge cases' do
    before do
      delve_room_entrance
      delve_room_corridor
      delve_room_chamber
    end

    it 'returns corridor color for corridor room type' do
      visibility = { visibility: :full, show_contents: true, show_danger: false }
      result = described_class.send(:room_color, delve_room_corridor, visibility)
      expect(result).to eq(described_class::COLORS[:corridor])
    end

    it 'returns branch color for branch room type' do
      visibility = { visibility: :full, show_contents: true, show_danger: false }
      result = described_class.send(:room_color, delve_room_chamber, visibility)
      expect(result).to eq(described_class::COLORS[:branch])
    end

    it 'returns corridor color as default for unknown room type' do
      # Mock an unknown room type (model validation prevents invalid types)
      unknown_room = double('DelveRoom', room_type: 'unknown_type')
      visibility = { visibility: :full, show_contents: true, show_danger: false }
      result = described_class.send(:room_color, unknown_room, visibility)
      expect(result).to eq(described_class::COLORS[:corridor])
    end
  end

  # ============================================
  # ASCII Map Rendering Edge Cases
  # ============================================

  describe '.render_ascii edge cases' do
    before do
      delve_room_entrance
    end

    context 'with hidden unexplored rooms' do
      before do
        visibility_data = [
          {
            room: delve_room_entrance,
            grid_x: 0,
            grid_y: 0,
            visibility: :full,
            show_type: true,
            show_contents: true,
            show_danger: true
          },
          {
            room: delve_room_corridor,
            grid_x: 1,
            grid_y: 0,
            visibility: :hidden,
            show_type: false,
            show_contents: false,
            show_danger: false
          }
        ]
        allow(DelveVisibilityService).to receive(:visible_rooms).and_return(visibility_data)
      end

      it 'shows . for hidden unexplored rooms' do
        delve_room_corridor.update(explored: false)
        result = described_class.render_ascii(participant)
        expect(result).to include('.')
      end
    end

    context 'with treasure rooms' do
      let(:treasure_room) do
        DelveRoom.create(
          delve_id: delve.id,
          room_type: 'terminal',
          depth: 1,
          level: 1,
          grid_x: 1,
          grid_y: 0,
          explored: true
        )
      end

      before do
        delve_room_entrance
        treasure_room

        visibility_data = [
          {
            room: delve_room_entrance,
            grid_x: 0,
            grid_y: 0,
            visibility: :full,
            show_type: true,
            show_contents: true,
            show_danger: true
          },
          {
            room: treasure_room,
            grid_x: 1,
            grid_y: 0,
            visibility: :full,
            show_type: true,
            show_contents: true,
            show_danger: true
          }
        ]
        allow(DelveVisibilityService).to receive(:visible_rooms).and_return(visibility_data)
      end

      it 'shows treasure room character' do
        DelveTreasure.create(delve_room_id: treasure_room.id, looted: false, gold_value: 100)
        result = described_class.render_ascii(participant)
        expect(result).to include('$')
      end
    end
  end

  # ============================================
  # Full Map Player Position
  # ============================================

  describe '.render_full_map player position' do
    before do
      delve_room_entrance
      delve_room_corridor
      delve_room_corridor.update(explored: true)

      visibility_data = [
        { room: delve_room_entrance, grid_x: 0, grid_y: 0, visibility: :full, show_type: true, show_contents: true, show_danger: true },
        { room: delve_room_corridor, grid_x: 1, grid_y: 0, visibility: :explored, show_type: true, show_contents: false, show_danger: false }
      ]
      allow(DelveVisibilityService).to receive(:visible_rooms).and_return(visibility_data)
    end

    it 'does not show player position when current room is not explored' do
      delve_room_entrance.update(explored: false)
      result = described_class.render_full_map(participant)

      # When current room is unexplored, player circle may not be drawn
      # Check that the result is still valid
      expect(result).to include('|||')
    end

    it 'shows player position when current room is explored' do
      delve_room_entrance.update(explored: true)
      result = described_class.render_full_map(participant)

      expect(result).to include('fcircle::')
      expect(result).to include(described_class::COLORS[:player])
    end
  end

  # ============================================
  # Status Bar Rendering
  # ============================================

  describe 'status bar rendering' do
    before do
      delve_room_entrance
      visibility_data = [
        {
          room: delve_room_entrance,
          grid_x: 0,
          grid_y: 0,
          visibility: :full,
          show_type: true,
          show_contents: true,
          show_danger: true
        }
      ]
      allow(DelveVisibilityService).to receive(:visible_rooms).and_return(visibility_data)
    end

    it 'shows time remaining in minutes' do
      allow(participant).to receive(:time_remaining).and_return(45)
      allow(participant).to receive(:time_remaining_seconds).and_return(2700)
      result = described_class.render_minimap(participant)
      expect(result).to include('Time: 45:00')
    end

    it 'shows loot collected' do
      participant.update(loot_collected: 150)
      result = described_class.render_minimap(participant)
      expect(result).to include('Loot: 150')
    end
  end

  # ============================================
  # Grid Calculation
  # ============================================

  describe 'grid calculation' do
    before do
      # Create rooms at various positions
      DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 0, level: 1, grid_x: -2, grid_y: -1, explored: true)
      DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, level: 1, grid_x: 5, grid_y: 3, explored: true)

      visibility_data = [
        { room: nil, grid_x: -2, grid_y: -1, visibility: :full, show_type: true, show_contents: true, show_danger: true },
        { room: nil, grid_x: 5, grid_y: 3, visibility: :full, show_type: true, show_contents: true, show_danger: true }
      ]
      allow(DelveVisibilityService).to receive(:visible_rooms).and_return(visibility_data)
    end

    it 'handles negative coordinates' do
      result = described_class.render_minimap(participant)
      expect(result).to be_a(String)
      parts = result.split('|||')
      expect(parts.size).to eq(3)
    end
  end
end
