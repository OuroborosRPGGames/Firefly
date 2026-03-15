# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveMapPanelService do
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
      started_at: Time.now,
      grid_width: 5,
      grid_height: 5,
      seed: 42
    )
  end

  # Create a small grid of rooms:
  #  [entrance] -- [corridor] -- [chamber]
  #                    |
  #               [monster]  -- [exit]
  let(:entrance_room) do
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

  let(:corridor_room) do
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

  let(:chamber_room) do
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

  let(:monster_room) do
    DelveRoom.create(
      delve_id: delve.id,
      room_type: 'corridor',
      depth: 2,
      level: 1,
      grid_x: 1,
      grid_y: 1,
      explored: false,
      monster_type: 'goblin'
    )
  end

  let(:exit_room) do
    DelveRoom.create(
      delve_id: delve.id,
      room_type: 'terminal',
      depth: 3,
      level: 1,
      grid_x: 2,
      grid_y: 1,
      is_exit: true,
      explored: false
    )
  end

  let(:participant) do
    DelveParticipant.create(
      delve_id: delve.id,
      character_instance_id: character_instance.id,
      current_delve_room_id: entrance_room.id,
      current_level: 1,
      status: 'active',
      loot_collected: 25,
      time_spent_minutes: 10,
      time_spent_seconds: 600
    )
  end

  # ============================================
  # Constants
  # ============================================

  describe 'constants' do
    it 'defines CELL_SIZE' do
      expect(described_class::CELL_SIZE).to eq(40)
    end

    it 'defines CELL_GAP' do
      expect(described_class::CELL_GAP).to eq(4)
    end

    it 'defines CELL_INNER' do
      expect(described_class::CELL_INNER).to eq(36)
    end

    it 'defines PADDING' do
      expect(described_class::PADDING).to eq(20)
    end

    it 'defines LOS_DEPTH' do
      expect(described_class::LOS_DEPTH).to eq(2)
    end

    it 'defines COLORS hash with expected keys' do
      colors = described_class::COLORS
      expect(colors).to have_key(:background)
      expect(colors).to have_key(:current)
      expect(colors).to have_key(:visible)
      expect(colors).to have_key(:memory)
      expect(colors).to have_key(:connection_memory)
      expect(colors).to have_key(:connection_open)
      expect(colors).to have_key(:monster)
      expect(colors).to have_key(:treasure)
      expect(colors).to have_key(:trap)
      expect(colors).to have_key(:stairs)
      expect(colors).to have_key(:entrance)
    end
  end

  # ============================================
  # .render
  # ============================================

  describe '.render' do
    before do
      # Create all rooms
      entrance_room
      corridor_room
      chamber_room
      monster_room
      exit_room
    end

    it 'returns a hash with svg key containing valid SVG' do
      result = described_class.render(participant: participant)
      expect(result).to have_key(:svg)
      expect(result[:svg]).to be_a(String)
      expect(result[:svg]).to include('<svg')
      expect(result[:svg]).to include('</svg>')
    end

    it 'includes the current room with class current-room' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to include('current-room')
    end

    it 'does not render rooms that are unexplored and outside LOS' do
      result = described_class.render(participant: participant)
      # exit_room at (2,1) is beyond LOS_DEPTH and unexplored - invisible
      expect(result[:svg]).not_to include("data-room-id=\"#{exit_room.id}\"")
    end

    it 'includes a current room with glow filter' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to include('filter="url(#glow-current)"')
    end

    it 'returns metadata with room count' do
      result = described_class.render(participant: participant)
      expect(result[:metadata]).to have_key(:room_count)
      expect(result[:metadata][:room_count]).to be > 0
    end

    it 'includes data-room-id attributes on room cells' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to include('data-room-id')
    end

    it 'includes connection lines between rooms' do
      result = described_class.render(participant: participant)
      # Connection lines use <line> SVG element
      expect(result[:svg]).to include('<line')
    end

    it 'returns metadata with current level' do
      result = described_class.render(participant: participant)
      expect(result[:metadata]).to have_key(:current_level)
      expect(result[:metadata][:current_level]).to eq(1)
    end

    context 'with no current room' do
      before do
        participant.update(current_delve_room_id: nil)
      end

      it 'returns a hash with nil svg' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).to be_nil
      end
    end

    context 'with rooms in line of sight' do
      it 'marks in-LOS rooms with visible class' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).to include('data-vis="visible"')
      end
    end

    context 'with explored rooms out of line of sight' do
      let(:far_room) do
        DelveRoom.create(
          delve_id: delve.id,
          room_type: 'corridor',
          depth: 5,
          level: 1,
          grid_x: 4,
          grid_y: 4,
          explored: true
        )
      end

      before do
        far_room
      end

      it 'marks explored out-of-LOS rooms with memory class' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).to include('data-vis="memory"')
      end
    end

    context 'with entrance room' do
      it 'shows entrance icon on the current room' do
        result = described_class.render(participant: participant)
        # Entrance room is current room, so it gets entrance indicator
        expect(result[:svg]).to include('entrance') # entrance color or label
      end
    end

    context 'with exit room visible' do
      before do
        # Make exit room explored and adjacent to explored rooms
        corridor_room.update(explored: true)
        monster_room.update(explored: true)
        exit_room.update(explored: true)
      end

      it 'shows stairs icon on exit rooms' do
        result = described_class.render(participant: participant)
        # The exit room should be rendered with stairs indicator
        expect(result[:svg]).to match(/stairs|exit/i)
      end
    end
  end

  # ============================================
  # Line of Sight BFS
  # ============================================

  describe 'line of sight calculation' do
    before do
      entrance_room
      corridor_room
      chamber_room
      monster_room
      exit_room
    end

    it 'current room is always visible' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to include('current-room')
    end

    it 'traverses all connected rooms for LOS regardless of explored state' do
      # BFS now traverses all rooms, not just explored ones.
      # corridor (explored) and chamber (unexplored) are both within LOS_DEPTH=2
      result = described_class.render(participant: participant)
      svg = result[:svg]

      # Both corridor and chamber should be rendered (in LOS)
      expect(svg).to include("data-room-id=\"#{corridor_room.id}\"")
      expect(svg).to include("data-room-id=\"#{chamber_room.id}\"")
      # No 'unexplored' class exists anymore
      expect(svg).not_to include('unexplored')
    end
  end

  # ============================================
  # SVG Structure
  # ============================================

  describe 'SVG structure' do
    before do
      entrance_room
      corridor_room
    end

    it 'has a valid viewBox attribute' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to match(/viewBox=/)
    end

    it 'has a background rectangle' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to include(described_class::COLORS[:background])
    end

    it 'includes room rectangles' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to include('<rect')
    end

    it 'includes SVG defs with gradients and glow filter' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to include('<defs>')
      expect(result[:svg]).to include('glow-current')
      expect(result[:svg]).to include('grad-current')
      expect(result[:svg]).to include('grad-visible')
    end
  end

  # ============================================
  # Data Attributes on Room Cells
  # ============================================

  describe 'data attributes on room cells' do
    before do
      entrance_room
      corridor_room
    end

    it 'includes data-grid-x attributes' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to include('data-grid-x=')
    end

    it 'includes data-grid-y attributes' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to include('data-grid-y=')
    end

    it 'includes data-vis attributes' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to include('data-vis=')
    end

    it 'includes room-cell CSS class on all room rects' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to include('room-cell')
    end

    it 'includes correct grid coordinates for entrance room' do
      result = described_class.render(participant: participant)
      expect(result[:svg]).to include("data-grid-x=\"#{entrance_room.grid_x}\"")
      expect(result[:svg]).to include("data-grid-y=\"#{entrance_room.grid_y}\"")
    end
  end

  # ============================================
  # Unicode Icons for Room Content
  # ============================================

  describe 'unicode icons for room content' do
    before do
      entrance_room
      corridor_room
    end

    it 'renders entrance icon as unicode arrow-up on entrance rooms' do
      result = described_class.render(participant: participant)
      # Entrance room is current, so its content renders
      expect(result[:svg]).to include('entrance-icon')
    end

    context 'with exit room visible' do
      before do
        corridor_room.update(explored: true)
        monster_room
        monster_room.update(explored: true)
        exit_room
        exit_room.update(explored: true)
      end

      it 'renders stairs icon as unicode arrow-down on exit rooms' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).to include('stairs-icon')
      end
    end

    context 'with treasure in current room' do
      before do
        DelveTreasure.create(
          delve_room_id: entrance_room.id,
          gold_value: 50,
          looted: false
        )
      end

      it 'renders treasure geometric icon' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).to include('treasure-icon')
        expect(result[:svg]).to match(/<g[^>]*class="treasure-icon"/)
      end
    end

    context 'with treasure in LOS room (not current)' do
      before do
        DelveTreasure.create(
          delve_room_id: corridor_room.id,
          gold_value: 50,
          looted: false
        )
      end

      it 'does not render treasure icon (not visible at distance)' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).not_to include('treasure-icon')
      end
    end

    context 'with unsolved puzzle in current room' do
      before do
        DelvePuzzle.create(
          delve_room_id: entrance_room.id,
          puzzle_type: 'symbol_grid',
          seed: 123,
          solved: false
        )
      end

      it 'does not render puzzle icon on current room (shown via action buttons instead)' do
        result = described_class.render(participant: participant)
        # Current room skips puzzle icon (skip_puzzle: true) - puzzle is shown in HUD actions
        expect(result[:svg]).not_to include('puzzle-icon')
      end
    end

    context 'with unsolved puzzle in LOS room (not current)' do
      before do
        DelvePuzzle.create(
          delve_room_id: corridor_room.id,
          puzzle_type: 'symbol_grid',
          seed: 123,
          solved: false
        )
      end

      it 'does not render puzzle icon (not visible at distance)' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).not_to include('puzzle-icon')
      end
    end

    context 'with monster in visible room' do
      before do
        DelveMonster.create(
          delve_id: delve.id,
          current_room_id: corridor_room.id,
          monster_type: 'goblin',
          hp: 6,
          max_hp: 6,
          is_active: true
        )
      end

      it 'renders monster geometric icon' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).to include('monster-icon')
        expect(result[:svg]).to match(/<g[^>]*class="monster-icon"/)
      end
    end

    it 'uses <g> elements with pointer-events: none for content icons' do
      result = described_class.render(participant: participant)
      # The entrance icon should be a g element with pointer-events: none
      expect(result[:svg]).to match(/<g[^>]*pointer-events: none/)
    end
  end

  # ============================================
  # Puzzle Room Purple Border
  # ============================================

  describe 'puzzle room purple border' do
    before do
      entrance_room
      corridor_room
    end

    context 'with unsolved puzzle on current room' do
      before do
        DelvePuzzle.create(
          delve_room_id: entrance_room.id,
          puzzle_type: 'toggle_matrix',
          seed: 456,
          solved: false
        )
      end

      it 'renders the current room with current_border stroke (not puzzle-specific)' do
        result = described_class.render(participant: participant)
        # Current room uses current_border color, puzzle is shown via action buttons
        expect(result[:svg]).to include("stroke=\"#{described_class::COLORS[:current_border]}\"")
      end

      it 'renders the current room with stroke-width 2' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).to match(/stroke="#d4b85c" stroke-width="2"/)
      end
    end

    context 'with unsolved puzzle on LOS room (not current)' do
      before do
        DelvePuzzle.create(
          delve_room_id: corridor_room.id,
          puzzle_type: 'toggle_matrix',
          seed: 456,
          solved: false
        )
      end

      it 'does not render purple border for LOS rooms' do
        result = described_class.render(participant: participant)
        # LOS rooms don't show puzzle borders (can't tell from a distance)
        expect(result[:svg]).not_to match(/stroke="#6a5acd" stroke-width="2"/)
      end
    end

    context 'with solved puzzle' do
      before do
        DelvePuzzle.create(
          delve_room_id: entrance_room.id,
          puzzle_type: 'toggle_matrix',
          seed: 456,
          solved: true
        )
      end

      it 'does not render purple border for solved puzzles' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).not_to match(/stroke="#6a5acd" stroke-width="2"/)
      end
    end
  end

  # ============================================
  # Connection Trap/Blocker Icons
  # ============================================

  describe 'connection trap and blocker icons' do
    before do
      entrance_room
      corridor_room
      chamber_room
      monster_room
      exit_room
    end

    context 'with trap on a connection' do
      before do
        DelveTrap.create(
          delve_room_id: entrance_room.id,
          direction: 'east',
          timing_a: 3,
          timing_b: 7,
          damage: 1,
          disabled: false
        )
      end

      it 'renders trap warning icon on the connection' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).to include('trap-conn-icon')
      end

      it 'renders the connection line in red' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).to include("stroke=\"#{described_class::COLORS[:connection_blocked]}\"")
      end

      it 'renders trap icon with pointer-events: auto and cursor: pointer' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).to match(/<polygon[^>]*class="trap-conn-icon"[^>]*pointer-events: auto; cursor: pointer/)
      end
    end

    context 'with blocker on a connection' do
      before do
        DelveBlocker.create(
          delve_room_id: entrance_room.id,
          direction: 'east',
          blocker_type: 'barricade',
          difficulty: 10,
          cleared: false
        )
      end

      it 'renders blocker lock icon on the connection' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).to include('blocker-conn-icon')
      end

      it 'renders the connection line in red' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).to include("stroke=\"#{described_class::COLORS[:connection_blocked]}\"")
      end
    end

    context 'with cleared blocker' do
      before do
        DelveBlocker.create(
          delve_room_id: entrance_room.id,
          direction: 'east',
          blocker_type: 'barricade',
          difficulty: 10,
          cleared: true
        )
      end

      it 'does not render blocker icon for cleared blockers' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).not_to include('blocker-conn-icon')
      end
    end

    context 'with disabled trap' do
      before do
        DelveTrap.create(
          delve_room_id: entrance_room.id,
          direction: 'east',
          timing_a: 3,
          timing_b: 7,
          damage: 1,
          disabled: true
        )
      end

      it 'does not render trap icon for disabled traps' do
        result = described_class.render(participant: participant)
        expect(result[:svg]).not_to include('trap-conn-icon')
      end
    end
  end
end
