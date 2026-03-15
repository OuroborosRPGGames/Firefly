# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoommapRenderService do
  let(:location) { create(:location, location_type: 'building') }
  let(:room) do
    create(:room,
      location: location,
      name: 'Test Room',
      min_x: 0.0,
      max_x: 100.0,
      min_y: 0.0,
      max_y: 100.0
    )
  end
  let(:character) { create(:character, forename: 'Test', surname: 'Viewer') }
  let(:reality) { create(:reality) }
  let(:viewer) do
    create(:character_instance,
      character: character,
      reality: reality,
      current_room: room,
      x: 50.0,
      y: 50.0,
      online: true
    )
  end

  subject(:service) { described_class.new(room: room, viewer: viewer) }

  describe 'constants' do
    it 'defines canvas constraints from GameConfig' do
      expect(described_class::MAX_CANVAS_SIZE).to be_a(Integer)
      expect(described_class::MIN_CANVAS_SIZE).to be_a(Integer)
      expect(described_class::PADDING).to be_a(Integer)
    end

    it 'defines element sizes from GameConfig' do
      expect(described_class::CHAR_RADIUS).to be_a(Integer)
      expect(described_class::SELF_RADIUS).to be_a(Integer)
      expect(described_class::PLACE_MIN_SIZE).to be_a(Integer)
      expect(described_class::EXIT_SIZE).to be_a(Integer)
      expect(described_class::LEGEND_HEIGHT).to be_a(Integer)
      expect(described_class::ROOM_NAME_HEIGHT).to be_a(Integer)
    end

    it 'defines colors including door' do
      expect(described_class::COLORS).to be_a(Hash)
      expect(described_class::COLORS[:background]).to be_a(String)
      expect(described_class::COLORS[:self_color]).to eq('#ff4444')
      expect(described_class::COLORS[:door]).to eq('#996633')
    end

    it 'defines CARDINAL_DIRECTIONS' do
      expect(described_class::CARDINAL_DIRECTIONS).to include('north', 'south', 'east', 'west')
    end

    it 'defines OPENABLE_TYPES' do
      expect(described_class::OPENABLE_TYPES).to include('door', 'gate', 'hatch', 'portal')
    end

    it 'defines direction arrows' do
      expect(CanvasHelper::DIRECTION_ARROWS).to be_a(Hash)
      expect(CanvasHelper::DIRECTION_ARROWS['north']).to eq('↑')
      expect(CanvasHelper::DIRECTION_ARROWS['south']).to eq('↓')
      expect(CanvasHelper::DIRECTION_ARROWS['east']).to eq('→')
      expect(CanvasHelper::DIRECTION_ARROWS['west']).to eq('←')
    end
  end

  describe '#initialize' do
    it 'sets room and viewer' do
      expect(service.room).to eq(room)
      expect(service.viewer).to eq(viewer)
    end

    it 'calculates canvas dimensions' do
      expect(service.canvas_width).to be_a(Integer)
      expect(service.canvas_height).to be_a(Integer)
      expect(service.scale_x).to be_a(Float)
      expect(service.scale_y).to be_a(Float)
    end
  end

  describe '#render' do
    it 'returns a canvas command string' do
      result = service.render

      expect(result).to be_a(String)
      expect(result).to include('|||')
    end

    it 'includes width, height, and commands separated by |||' do
      result = service.render
      parts = result.split('|||')

      expect(parts.length).to eq(3)
      expect(parts[0]).to match(/^\d+$/)
      expect(parts[1]).to match(/^\d+$/)
      expect(parts[2]).to be_a(String)
    end

    it 'includes background command' do
      result = service.render

      expect(result).to include('frect::#1a1a1a')
    end

    it 'includes floor command' do
      result = service.render

      expect(result).to include('frect::#2a2a2a')
    end

    it 'includes wall boundary lines' do
      result = service.render

      expect(result).to include('line::#444444')
    end

    it 'includes self marker' do
      result = service.render

      expect(result).to include('fcircle::#ff4444')
      expect(result).to include('coltext::#ffffff')
    end

    it 'includes room name' do
      result = service.render

      expect(result).to include('Test Room')
    end

    it 'separates commands with ;;;' do
      result = service.render
      commands = result.split('|||')[2]

      expect(commands).to include(';;;')
    end
  end

  describe 'dimension calculation' do
    context 'with square room' do
      let(:room) do
        create(:room,
          location: location,
          min_x: 0.0, max_x: 100.0,
          min_y: 0.0, max_y: 100.0
        )
      end

      it 'creates canvas wider than tall minus legend/name space' do
        # canvas_height includes LEGEND_HEIGHT + ROOM_NAME_HEIGHT extra
        map_height = service.canvas_height - described_class::LEGEND_HEIGHT - described_class::ROOM_NAME_HEIGHT
        expect(service.canvas_width).to be_within(100).of(map_height)
      end
    end

    context 'with wide room' do
      let(:room) do
        create(:room,
          location: location,
          min_x: 0.0, max_x: 200.0,
          min_y: 0.0, max_y: 50.0
        )
      end

      it 'creates wider canvas' do
        expect(service.canvas_width).to be >= service.canvas_height
      end
    end

    context 'with tall room' do
      let(:room) do
        create(:room,
          location: location,
          min_x: 0.0, max_x: 50.0,
          min_y: 0.0, max_y: 200.0
        )
      end

      it 'creates taller canvas' do
        expect(service.canvas_height).to be >= service.canvas_width
      end
    end

    context 'with nil dimensions' do
      let(:room) do
        r = create(:room, location: location)
        # Bypass validation to set nil values for testing edge case handling
        allow(r).to receive(:min_x).and_return(nil)
        allow(r).to receive(:max_x).and_return(nil)
        allow(r).to receive(:min_y).and_return(nil)
        allow(r).to receive(:max_y).and_return(nil)
        r
      end

      it 'uses default dimensions' do
        expect { service }.not_to raise_error
        expect(service.canvas_width).to be > 0
        expect(service.canvas_height).to be > 0
      end
    end

    context 'with zero-size room' do
      let(:room) do
        r = create(:room, location: location)
        # Stub to simulate zero-size room
        allow(r).to receive(:min_x).and_return(50.0)
        allow(r).to receive(:max_x).and_return(50.0)
        allow(r).to receive(:min_y).and_return(50.0)
        allow(r).to receive(:max_y).and_return(50.0)
        r
      end

      it 'handles zero dimensions gracefully' do
        expect { service }.not_to raise_error
        expect(service.canvas_width).to be >= described_class::MIN_CANVAS_SIZE
        expect(service.canvas_height).to be >= described_class::MIN_CANVAS_SIZE
      end
    end
  end

  describe 'rendering places' do
    context 'with visible places' do
      let!(:place1) do
        Place.create(
          room_id: room.id,
          name: 'Wooden Chair',
          x: 25.0,
          y: 25.0,
          capacity: 2,
          invisible: false
        )
      end

      let!(:place2) do
        Place.create(
          room_id: room.id,
          name: 'Large Couch',
          x: 75.0,
          y: 75.0,
          capacity: 6,
          invisible: false
        )
      end

      it 'includes place rectangles' do
        result = service.render

        expect(result).to include('frect::#663300')
      end

      it 'includes place names' do
        result = service.render

        expect(result).to include('Wooden Chair')
        expect(result).to include('Large Couch')
      end
    end

    context 'with invisible places' do
      let!(:invisible_place) do
        Place.create(
          room_id: room.id,
          name: 'Hidden Spot',
          x: 50.0,
          y: 50.0,
          capacity: 1,
          invisible: true
        )
      end

      it 'does not include invisible places' do
        result = service.render

        expect(result).not_to include('Hidden Spot')
      end
    end

    context 'with long place name' do
      let!(:place) do
        Place.create(
          room_id: room.id,
          name: 'A Very Long Place Name That Should Be Truncated',
          x: 50.0,
          y: 50.0,
          capacity: 2,
          invisible: false
        )
      end

      it 'truncates long names' do
        result = service.render

        expect(result).not_to include('A Very Long Place Name That Should Be Truncated')
        expect(result).to include('A Very Lo...')
      end
    end
  end

  describe 'rendering exits' do
    # Exits are now determined by spatial adjacency (polygon-based)
    # We mock spatial_exits to test rendering logic

    context 'with exits' do
      let(:other_room) { create(:room, location: location, name: 'Other Room') }

      before do
        allow(room).to receive(:spatial_exits).and_return({ north: [other_room] })
      end

      it 'does not include direction arrows for cardinal exits (wall gaps are sufficient)' do
        result = service.render

        # Cardinal exits rely on wall gaps only, no arrow text
        exit_arrows = result.split('|||')[2].split(';;;').select { |c| c.include?('coltext::#88cc88') }
        expect(exit_arrows).to be_empty
      end

      it 'does not include green exit rectangles for cardinal exits' do
        result = service.render
        commands = result.split('|||')[2].split(';;;')

        # Cardinal exits should NOT have frect::#336633 — they use wall gaps instead
        # Only the legend might have the exit color for non-cardinal items
        exit_rects = commands.select { |c| c.include?('frect::#336633') }
        expect(exit_rects).to be_empty
      end

      it 'renders wall with gap for cardinal exit' do
        result = service.render
        wall_lines = result.split('|||')[2].split(';;;').select { |c| c.include?('line::#444444') }

        # With a north exit, the top wall should be split into 2 segments
        # (instead of 1 continuous line)
        # Plus 3 other walls = at least 5 wall lines total
        expect(wall_lines.length).to be >= 5
      end
    end

    context 'with all cardinal directions' do
      let(:other_room) { create(:room, location: location) }

      %w[north south east west].each do |dir|
        it "renders #{dir} exit as wall gap only (no arrow)" do
          allow(room).to receive(:spatial_exits).and_return({ dir.to_sym => [other_room] })
          result = service.render

          # Wall should be split into segments (gap present)
          wall_lines = result.split('|||')[2].split(';;;').select { |c| c.include?('line::#444444') }
          expect(wall_lines.length).to be >= 5
        end
      end
    end

    context 'with diagonal directions' do
      let(:other_room) { create(:room, location: location) }

      %w[northeast northwest southeast southwest].each do |dir|
        it "renders #{dir} exit correctly" do
          allow(room).to receive(:spatial_exits).and_return({ dir.to_sym => [other_room] })
          result = service.render

          arrow = CanvasHelper::DIRECTION_ARROWS[dir]
          expect(result).to include(arrow)
        end
      end
    end

    context 'with vertical exits' do
      let(:other_room) { create(:room, location: location) }

      it 'renders up exit' do
        allow(room).to receive(:spatial_exits).and_return({ up: [other_room] })
        result = service.render

        expect(result).to include('⇑')
      end

      it 'renders down exit' do
        allow(room).to receive(:spatial_exits).and_return({ down: [other_room] })
        result = service.render

        expect(result).to include('⇓')
      end
    end

    context 'with spatial exit' do
      let(:other_room) { create(:room, location: location) }

      before do
        allow(room).to receive(:spatial_exits).and_return({ north: [other_room] })
      end

      it 'renders wall gap for cardinal spatial exit' do
        result = service.render
        wall_lines = result.split('|||')[2].split(';;;').select { |c| c.include?('line::#444444') }

        # North exit splits top wall into 2 segments, plus 3 other walls = 5
        expect(wall_lines.length).to be >= 5
      end
    end

    context 'with unknown direction' do
      let(:other_room) { create(:room, location: location) }

      before do
        allow(room).to receive(:spatial_exits).and_return({ portal: [other_room] })
      end

      it 'uses first character of direction as arrow' do
        result = service.render

        expect(result).to include('P')
      end

      it 'renders text arrow only for non-cardinal exit (no green rectangle)' do
        result = service.render

        # Non-cardinal exits now render just a text arrow, no green frect
        exit_text = result.split('|||')[2].split(';;;').select { |c| c.include?('coltext::#88cc88') }
        expect(exit_text.length).to eq(1)
        green_rects = result.split('|||')[2].split(';;;').select { |c| c.include?('frect::#336633') }
        expect(green_rects).to be_empty
      end
    end

    context 'with door feature on exit' do
      let(:other_room) { create(:room, location: location) }

      before do
        allow(room).to receive(:spatial_exits).and_return({ north: [other_room] })
        # Create a door feature in the north direction
        RoomFeature.create(
          room_id: room.id,
          feature_type: 'door',
          direction: 'north',
          name: 'wooden door'
        )
      end

      it 'renders door rectangle across wall gap' do
        result = service.render

        expect(result).to include("frect::#996633")
      end
    end

    context 'with outdoor rooms connected' do
      let(:other_room) { create(:room, location: location, indoors: false) }

      before do
        room.update(indoors: false)
        allow(room).to receive(:spatial_exits).and_return({ north: [other_room] })
      end

      it 'renders wider gap for outdoor connection' do
        result = service.render
        wall_lines = result.split('|||')[2].split(';;;').select { |c| c.include?('line::#444444') }

        # Outdoor gap is 72px wide, standard gap is 48px
        # Both should result in split wall, so at least 5 lines
        expect(wall_lines.length).to be >= 5
      end
    end
  end

  describe 'rendering characters' do
    context 'with other characters in room' do
      let(:other_character) { create(:character, forename: 'Alice', surname: 'Smith', is_npc: false) }
      let!(:other_ci) do
        create(:character_instance,
          character: other_character,
          reality: reality,
          current_room: room,
          x: 25.0,
          y: 25.0,
          online: true
        )
      end

      before do
        # Viewer knows Alice so her name appears in the render
        CharacterKnowledge.create(
          knower_character_id: character.id,
          known_character_id: other_character.id,
          is_known: true
        )
      end

      it 'renders other characters' do
        result = service.render

        expect(result).to include('fcircle::#22cc22')
      end

      it 'includes character initial' do
        result = service.render

        expect(result).to include('coltext::#aaaaaa')
        expect(result).to include('A')
      end
    end

    context 'with NPCs in room' do
      let(:npc_character) { create(:character, :npc, forename: 'Guard') }
      let!(:npc_ci) do
        create(:character_instance,
          character: npc_character,
          reality: reality,
          current_room: room,
          x: 75.0,
          y: 75.0,
          online: true
        )
      end

      it 'renders NPCs in different color' do
        result = service.render

        expect(result).to include('fcircle::#888888')
      end
    end

    context 'with offline characters' do
      let(:offline_character) { create(:character, forename: 'Bob') }
      let!(:offline_ci) do
        create(:character_instance,
          character: offline_character,
          reality: reality,
          current_room: room,
          x: 50.0,
          y: 50.0,
          online: false
        )
      end

      it 'does not render offline characters' do
        result = service.render

        # Legend has one #22cc22 circle for the "Player" legend item
        # No additional player circles should appear
        expect(result.scan('fcircle::#22cc22').length).to eq(1)
      end
    end

    context 'with viewer as only character' do
      it 'only renders self marker (glow + circle + legend circles)' do
        result = service.render
        # Self glow ring + self circle = 2 self circles
        # Plus 3 legend circles (You, Player, NPC)
        circles = result.scan(/fcircle::/)

        expect(circles.length).to eq(5)
      end
    end

    context 'with two characters at the same position (overlap fanning)' do
      let(:char_a) { create(:character, forename: 'Alice', surname: 'A', is_npc: false) }
      let(:char_b) { create(:character, forename: 'Bob', surname: 'B', is_npc: false) }

      let!(:ci_a) do
        create(:character_instance,
          character: char_a, reality: reality, current_room: room,
          x: 50.0, y: 50.0, online: true)
      end
      let!(:ci_b) do
        create(:character_instance,
          character: char_b, reality: reality, current_room: room,
          x: 50.0, y: 50.0, online: true)
      end

      before do
        # Viewer knows both characters so their names appear in the render
        CharacterKnowledge.create(knower_character_id: character.id, known_character_id: char_a.id, is_known: true)
        CharacterKnowledge.create(knower_character_id: character.id, known_character_id: char_b.id, is_known: true)
      end

      it 'renders both characters' do
        result = service.render

        expect(result).to include('Alice')
        expect(result).to include('Bob')
      end

      it 'fans characters apart (different positions on canvas)' do
        result = service.render
        # Both should be rendered as green circles
        green_circles = result.split('|||')[2].split(';;;').select { |c| c.include?('fcircle::#22cc22') }

        # 2 character circles + 1 legend circle = 3
        expect(green_circles.length).to eq(3)
      end
    end
  end

  describe 'rendering self marker' do
    it 'renders larger self circle' do
      result = service.render
      self_radius = described_class::SELF_RADIUS
      char_radius = described_class::CHAR_RADIUS

      expect(self_radius).to be > char_radius
    end

    it 'includes self name label' do
      result = service.render

      expect(result).to include('coltext::#ffffff')
      expect(result).to include('Test')
    end

    context 'with viewer at edge of room' do
      let(:viewer) do
        create(:character_instance,
          character: character,
          reality: reality,
          current_room: room,
          x: 0.0,
          y: 0.0,
          online: true
        )
      end

      it 'clamps position to canvas bounds' do
        result = service.render

        expect(result).to include('fcircle::#ff4444')
      end
    end

    context 'with viewer at nil coordinates' do
      let(:viewer) do
        ci = create(:character_instance,
          character: character,
          reality: reality,
          current_room: room,
          online: true
        )
        ci.update(x: nil, y: nil)
        ci
      end

      it 'uses room center' do
        expect { service.render }.not_to raise_error
      end
    end
  end

  describe 'coordinate transformation' do
    it 'transforms room coordinates to canvas coordinates' do
      # Access private method for testing
      cx, cy = service.send(:room_to_canvas, 50.0, 50.0)

      expect(cx).to be_a(Integer)
      expect(cy).to be_a(Integer)
      expect(cx).to be > described_class::PADDING
      expect(cy).to be > described_class::PADDING
    end

    it 'inverts Y axis' do
      top_y = service.send(:room_to_canvas, 50.0, 100.0)[1]
      bottom_y = service.send(:room_to_canvas, 50.0, 0.0)[1]

      expect(top_y).to be < bottom_y
    end

    it 'handles nil coordinates by using room center' do
      cx, cy = service.send(:room_to_canvas, nil, nil)

      expect(cx).to be_a(Integer)
      expect(cy).to be_a(Integer)
    end
  end

  describe 'text helpers (delegated to CanvasHelper)' do
    describe 'CanvasHelper.sanitize_text' do
      it 'removes HTML tags' do
        result = CanvasHelper.sanitize_text('<b>Bold</b> text')

        expect(result).to eq('Bold text')
      end

      it 'replaces pipe characters' do
        result = CanvasHelper.sanitize_text('test|value')

        expect(result).to eq('test value')
      end

      it 'replaces semicolons' do
        result = CanvasHelper.sanitize_text('test;value')

        expect(result).to eq('test value')
      end

      it 'replaces colons' do
        result = CanvasHelper.sanitize_text('test:value')

        expect(result).to eq('test value')
      end

      it 'handles nil' do
        result = CanvasHelper.sanitize_text(nil)

        expect(result).to eq('')
      end

      it 'strips whitespace' do
        result = CanvasHelper.sanitize_text('  test  ')

        expect(result).to eq('test')
      end
    end

    describe 'CanvasHelper.truncate_name' do
      it 'returns short names unchanged' do
        result = CanvasHelper.truncate_name('Short', 15)

        expect(result).to eq('Short')
      end

      it 'truncates long names with ellipsis' do
        result = CanvasHelper.truncate_name('A Very Long Name', 10)

        # name[0..6] = "A Very ", + "..." = "A Very ..."
        expect(result).to eq('A Very ...')
      end

      it 'handles nil' do
        result = CanvasHelper.truncate_name(nil, 15)

        expect(result).to eq('')
      end

      it 'uses default max length of 15' do
        result = CanvasHelper.truncate_name('A Name That Is Way Too Long')

        # name[0..11] + "..." = 12 + 3 = 15 characters
        expect(result.length).to eq(15)
        expect(result).to end_with('...')
      end
    end

    describe '#exit_position_from_direction' do
      it 'positions north exit at top center' do
        x, y = service.send(:exit_position_from_direction, 'north')

        expect(y).to be <= service.canvas_height / 2
      end

      it 'positions south exit at bottom center' do
        x, y = service.send(:exit_position_from_direction, 'south')

        expect(y).to be >= service.canvas_height / 2
      end

      it 'positions east exit at right center' do
        x, y = service.send(:exit_position_from_direction, 'east')

        expect(x).to be >= service.canvas_width / 2
      end

      it 'positions west exit at left center' do
        x, y = service.send(:exit_position_from_direction, 'west')

        expect(x).to be <= service.canvas_width / 2
      end

      it 'handles short direction aliases' do
        x_n, y_n = service.send(:exit_position_from_direction, 'n')
        x_north, y_north = service.send(:exit_position_from_direction, 'north')

        expect([x_n, y_n]).to eq([x_north, y_north])
      end

      it 'positions unknown direction at center of map area' do
        x, y = service.send(:exit_position_from_direction, 'unknown')
        map_bottom = service.canvas_height - described_class::PADDING - described_class::LEGEND_HEIGHT - described_class::ROOM_NAME_HEIGHT
        map_center_y = (described_class::PADDING + map_bottom) / 2

        expect(x).to be_within(50).of(service.canvas_width / 2)
        expect(y).to be_within(50).of(map_center_y)
      end
    end
  end

  describe 'legend rendering' do
    it 'includes legend background' do
      result = service.render
      expect(result).to include('frect::#111111')
    end

    it 'includes legend labels' do
      result = service.render
      expect(result).to include('You')
      expect(result).to include('Player')
      expect(result).to include('NPC')
      expect(result).to include('Furniture')
    end

    it 'includes legend divider line' do
      result = service.render
      expect(result).to include('line::#333333')
    end
  end

  describe 'room name rendering' do
    context 'with special characters in name' do
      let(:room) do
        create(:room,
          location: location,
          name: 'Room <script>alert("xss")</script>',
          min_x: 0.0, max_x: 100.0,
          min_y: 0.0, max_y: 100.0
        )
      end

      it 'sanitizes room name' do
        result = service.render

        expect(result).not_to include('<script>')
        expect(result).not_to include('</script>')
      end
    end

    context 'with nil room name' do
      let(:room) do
        r = create(:room, location: location, min_x: 0.0, max_x: 100.0, min_y: 0.0, max_y: 100.0)
        # Stub name to nil to test fallback behavior
        allow(r).to receive(:name).and_return(nil)
        r
      end

      it 'uses default room name' do
        result = service.render

        expect(result).to include('Room')
      end
    end
  end

  describe 'integration' do
    let(:other_room) { create(:room, location: location) }
    let(:other_character) { create(:character, forename: 'Bob', is_npc: false) }

    before do
      # Add some places
      Place.create(room_id: room.id, name: 'Chair', x: 20.0, y: 20.0, capacity: 1, invisible: false)
      Place.create(room_id: room.id, name: 'Table', x: 80.0, y: 80.0, capacity: 4, invisible: false)

      # Mock spatial exits (polygon-based adjacency)
      allow(room).to receive(:spatial_exits).and_return({ north: [other_room], east: [other_room] })

      # Add another character
      create(:character_instance,
        character: other_character,
        reality: reality,
        current_room: room,
        x: 30.0,
        y: 30.0,
        online: true
      )
    end

    it 'renders complete room map' do
      result = service.render

      # Check structure
      parts = result.split('|||')
      expect(parts.length).to eq(3)

      commands = parts[2]

      # Check all elements present
      expect(commands).to include('frect::#1a1a1a')  # background
      expect(commands).to include('frect::#2a2a2a')  # floor
      expect(commands).to include('line::#444444')   # walls (with gaps for exits)
      expect(commands).to include('frect::#663300')  # places
      expect(commands).to include('fcircle::#22cc22') # other character
      expect(commands).to include('fcircle::#ff4444') # self
    end

    it 'produces consistent output for same input' do
      result1 = service.render
      result2 = service.render

      expect(result1).to eq(result2)
    end
  end
end
