# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomDisplayService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A test room') }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Viewer') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  subject { described_class.new(room, character_instance) }

  describe '#initialize' do
    it 'sets the room' do
      expect(subject.room).to eq(room)
    end

    it 'sets the viewer' do
      expect(subject.viewer).to eq(character_instance)
    end

    it 'defaults mode to :full' do
      expect(subject.mode).to eq(:full)
    end

    it 'accepts valid modes' do
      service = described_class.new(room, character_instance, mode: :arrival)
      expect(service.mode).to eq(:arrival)

      service = described_class.new(room, character_instance, mode: :transit)
      expect(service.mode).to eq(:transit)
    end

    it 'defaults invalid mode to :full' do
      service = described_class.new(room, character_instance, mode: :invalid)
      expect(service.mode).to eq(:full)
    end
  end

  describe '#build_display' do
    context 'in full mode' do
      it 'includes room info' do
        display = subject.build_display
        expect(display[:room]).to be_a(Hash)
        expect(display[:room][:name]).to eq('Test Room')
      end

      it 'includes display_mode' do
        display = subject.build_display
        expect(display[:display_mode]).to eq(:full)
      end

      it 'includes places array' do
        display = subject.build_display
        expect(display[:places]).to be_an(Array)
      end

      it 'includes exits array' do
        display = subject.build_display
        expect(display[:exits]).to be_an(Array)
      end

      it 'includes decorations array' do
        display = subject.build_display
        expect(display[:decorations]).to be_an(Array)
      end

      it 'includes objects array' do
        display = subject.build_display
        expect(display[:objects]).to be_an(Array)
      end

      it 'includes characters_ungrouped array' do
        display = subject.build_display
        expect(display[:characters_ungrouped]).to be_an(Array)
      end

      it 'includes thumbnails array' do
        display = subject.build_display
        expect(display[:thumbnails]).to be_an(Array)
      end

      it 'includes context_hints array' do
        display = subject.build_display
        expect(display[:context_hints]).to be_an(Array)
      end

      it 'includes locations array' do
        display = subject.build_display
        expect(display[:locations]).to be_an(Array)
      end
    end

    context 'in arrival mode' do
      subject { described_class.new(room, character_instance, mode: :arrival) }

      it 'includes display_mode :arrival' do
        display = subject.build_display
        expect(display[:display_mode]).to eq(:arrival)
      end

      it 'includes room info' do
        display = subject.build_display
        expect(display[:room]).to be_a(Hash)
        expect(display[:room][:name]).to eq('Test Room')
      end

      it 'does not include decorations' do
        display = subject.build_display
        expect(display).not_to have_key(:decorations)
      end

      it 'does not include objects' do
        display = subject.build_display
        expect(display).not_to have_key(:objects)
      end
    end

    context 'in transit mode' do
      subject { described_class.new(room, character_instance, mode: :transit) }

      it 'includes display_mode :transit' do
        display = subject.build_display
        expect(display[:display_mode]).to eq(:transit)
      end

      it 'includes minimal room info' do
        display = subject.build_display
        expect(display[:room]).to eq({ id: room.id, name: room.name })
      end

      it 'does not include exits' do
        display = subject.build_display
        expect(display).not_to have_key(:exits)
      end

      it 'does not include places' do
        display = subject.build_display
        expect(display).not_to have_key(:places)
      end
    end
  end

  describe 'DISPLAY_MODES constant' do
    it 'contains all valid modes' do
      expect(described_class::DISPLAY_MODES).to eq(%i[full arrival transit])
    end
  end

  describe 'visible exits with exit info' do
    # Create adjacent_room to the north (shares edge at y=100)
    let!(:adjacent_room) do
      create(:room,
             location: location,
             name: 'North Room',
             indoors: false,
             min_x: 0,
             max_x: 100,
             min_y: 100,
             max_y: 200)
    end

    it 'includes spatial exit details in full mode' do
      display = subject.build_display
      # Find the spatial exit to the north
      north_exit = display[:exits].find { |e| e[:direction] == 'north' }

      expect(north_exit).not_to be_nil
      expect(north_exit[:to_room_name]).to eq('North Room')
      expect(north_exit[:direction_arrow]).to eq('↑')
      expect(north_exit[:exit_type]).to eq(:spatial)
    end
  end

  describe 'character display in room' do
    let(:other_user) { create(:user) }
    let(:other_char) { create(:character, user: other_user, forename: 'Alice') }
    let!(:other_instance) do
      create(:character_instance,
             character: other_char,
             reality: reality,
             current_room: room,
             current_place_id: nil,
             online: true,
             status: 'alive')
    end

    it 'excludes the viewer from characters_ungrouped' do
      display = subject.build_display
      char_ids = display[:characters_ungrouped].map { |c| c[:id] }
      expect(char_ids).not_to include(character_instance.id)
    end

    it 'includes other characters in the room' do
      display = subject.build_display
      char_ids = display[:characters_ungrouped].map { |c| c[:id] }
      expect(char_ids).to include(other_instance.id)
    end

    it 'includes character details' do
      display = subject.build_display
      char_data = display[:characters_ungrouped].find { |c| c[:id] == other_instance.id }

      expect(char_data[:name]).not_to be_nil
      expect(char_data[:character_id]).to eq(other_instance.id)
      expect(char_data[:is_npc]).to eq(false)
    end
  end

  describe 'status line building' do
    let(:other_user) { create(:user) }
    let(:other_char) { create(:character, user: other_user, forename: 'Bob') }
    let!(:other_instance) do
      create(:character_instance,
             character: other_char,
             reality: reality,
             current_room: room,
             current_place_id: nil,
             online: true,
             status: 'alive',
             health: 50,
             max_health: 100)
    end

    it 'shows injury state based on health' do
      display = subject.build_display
      char_data = display[:characters_ungrouped].find { |c| c[:id] == other_instance.id }

      # 50/100 = 50% health = badly wounded
      expect(char_data[:status_line]).to include('badly wounded')
    end

    context 'with critical health' do
      before do
        other_instance.update(health: 20)
      end

      it 'shows critically injured' do
        display = subject.build_display
        char_data = display[:characters_ungrouped].find { |c| c[:id] == other_instance.id }
        expect(char_data[:status_line]).to include('critically injured')
      end
    end

    context 'with full health' do
      before do
        other_instance.update(health: 100)
      end

      it 'does not include injury state' do
        display = subject.build_display
        char_data = display[:characters_ungrouped].find { |c| c[:id] == other_instance.id }
        # Status line may be nil or not include injury terms
        if char_data[:status_line]
          expect(char_data[:status_line]).not_to include('injured')
          expect(char_data[:status_line]).not_to include('wounded')
        end
      end
    end
  end

  describe 'spatial exits display' do
    # Use a separate location for spatial exit tests to avoid interference
    let(:spatial_location) { create(:location, zone: area) }

    # Set up rooms with spatial relationships via polygon geometry
    # Room at south: (0,0) to (200,200)
    let(:outer_room) do
      create(:room,
             location: spatial_location,
             name: 'Lobby',
             indoors: false,
             min_x: 0,
             max_x: 200,
             min_y: 0,
             max_y: 200,
             short_description: 'A spacious lobby')
    end

    # Room directly north: shares edge at y=200
    let(:north_room) do
      create(:room,
             location: spatial_location,
             name: 'North Room',
             indoors: false,
             min_x: 0,
             max_x: 200,
             min_y: 200,
             max_y: 400,
             short_description: 'A room to the north')
    end

    # Room contained within outer_room
    let(:inner_room) do
      create(:room,
             location: spatial_location,
             name: 'Shop',
             indoors: true,
             min_x: 50,
             max_x: 150,
             min_y: 50,
             max_y: 150,
             short_description: 'A cozy shop')
    end

    let(:viewer_in_outer) do
      create(:character_instance,
             character: character,
             reality: reality,
             current_room: outer_room,
             x: 100,
             y: 100,
             online: true,
             status: 'alive')
    end

    let(:viewer_in_inner) do
      create(:character_instance,
             character: character,
             reality: reality,
             current_room: inner_room,
             x: 100,
             y: 100,
             online: true,
             status: 'alive')
    end

    describe '#build_spatial_exits' do
      context 'when rooms are spatially adjacent' do
        it 'shows adjacent rooms as exits' do
          # Create both rooms to establish adjacency
          outer_room
          north_room

          service = described_class.new(outer_room, viewer_in_outer)
          display = service.build_display

          # Should find north_room as a spatial exit
          # Note: RoomAdjacencyService may return the same room under multiple directions
          # (this happens when edges share corner points). We just need to verify the room is reachable.
          north_room_exits = display[:exits].select { |e| e[:to_room_name] == 'North Room' }
          expect(north_room_exits).not_to be_empty, "Expected to find exit to 'North Room'. Got: #{display[:exits].map { |e| e[:to_room_name] }}"

          # Verify at least one exit exists and is spatial
          expect(north_room_exits.first[:exit_type]).to eq(:spatial)
          expect(north_room_exits.first[:direction_arrow]).not_to be_nil
        end

        it 'calculates distance to adjacent rooms' do
          outer_room
          north_room

          service = described_class.new(outer_room, viewer_in_outer)
          display = service.build_display

          north_exit = display[:exits].find { |e| e[:to_room_name] == 'North Room' }
          expect(north_exit).not_to be_nil
          # Distance should be numeric (calculated from viewer position to room center)
          expect(north_exit[:distance]).to be_a(Integer)
        end
      end

      context 'when room has containing room' do
        before do
          # Create an opening in the inner room to allow exit
          create(:room_feature,
                 room: inner_room,
                 feature_type: 'door',
                 direction: 'south',
                 is_open: true)
        end

        it 'shows exit to containing room via opening' do
          outer_room
          inner_room

          service = described_class.new(inner_room, viewer_in_inner)
          display = service.build_display

          # Should have an exit to the containing room
          exit_to_lobby = display[:exits].find { |e| e[:to_room_name] == 'Lobby' }
          expect(exit_to_lobby).not_to be_nil
          expect(exit_to_lobby[:direction]).to include('exit')
          expect(exit_to_lobby[:exit_type]).to eq(:spatial)
        end
      end
    end

    describe '#build_locations_data' do
      it 'shows contained rooms as locations' do
        outer_room
        inner_room

        service = described_class.new(outer_room, viewer_in_outer)
        display = service.build_display

        expect(display[:locations]).to be_an(Array)
        shop_location = display[:locations].find { |l| l[:name] == 'Shop' }
        expect(shop_location).not_to be_nil
        expect(shop_location[:id]).to eq(inner_room.id)
        expect(shop_location[:type]).to eq(inner_room.room_type)
        expect(shop_location[:description]).to eq('A cozy shop')
      end

      it 'returns empty array when no contained rooms' do
        north_room # Room with no contained rooms

        viewer_in_north = create(:character_instance,
                                 character: character,
                                 reality: reality,
                                 current_room: north_room,
                                 online: true,
                                 status: 'alive')

        service = described_class.new(north_room, viewer_in_north)
        display = service.build_display

        expect(display[:locations]).to eq([])
      end
    end

    describe 'spatial exit deduplication' do
      it 'shows each destination room only once (in closest direction)' do
        outer_room
        north_room

        service = described_class.new(outer_room, viewer_in_outer)
        display = service.build_display

        # Should have exactly one exit to north_room
        north_room_exits = display[:exits].select { |e| e[:to_room_name] == 'North Room' }
        expect(north_room_exits.length).to eq(1), "Expected 1 exit to North Room, got #{north_room_exits.length}"
        expect(north_room_exits.first[:exit_type]).to eq(:spatial)
      end

      it 'includes exits in multiple directions when rooms are adjacent' do
        outer_room
        # Create a room to the east (shares edge at x=200)
        east_room = create(:room,
                           location: spatial_location,
                           name: 'East Room',
                           indoors: false,
                           min_x: 200,
                           max_x: 400,
                           min_y: 0,
                           max_y: 200)
        north_room

        service = described_class.new(outer_room, viewer_in_outer)
        display = service.build_display

        # Should have both north and east exits
        exit_directions = display[:exits].map { |e| e[:direction].to_s.downcase }
        expect(exit_directions).to include('north')

        # East room should also be accessible
        east_exit = display[:exits].find { |e| e[:to_room_name] == 'East Room' }
        expect(east_exit).not_to be_nil
        expect(east_exit[:exit_type]).to eq(:spatial)
      end
    end

    describe 'locations in arrival mode' do
      it 'includes locations in arrival mode display' do
        outer_room
        inner_room

        service = described_class.new(outer_room, viewer_in_outer, mode: :arrival)
        display = service.build_display

        expect(display).to have_key(:locations)
        expect(display[:locations]).to be_an(Array)
      end
    end
  end

  describe '#calculate_distance_to_room' do
    let(:target_room) do
      create(:room,
             location: location,
             name: 'Target',
             min_x: 100,
             max_x: 200,
             min_y: 100,
             max_y: 200)
    end

    it 'calculates distance from viewer position to room center' do
      # Viewer at origin, room center at (150, 150)
      character_instance.update(x: 0, y: 0)
      service = described_class.new(room, character_instance)

      # Use send to access private method
      distance = service.send(:calculate_distance_to_room, target_room)

      # Distance from (0,0) to (150,150) = sqrt(150^2 + 150^2) = ~212
      expect(distance).to be_within(5).of(212)
    end

    it 'handles viewer with nil coordinates' do
      character_instance.update(x: nil, y: nil)
      service = described_class.new(room, character_instance)

      # Should default to (0,0)
      distance = service.send(:calculate_distance_to_room, target_room)
      expect(distance).to be_a(Integer)
    end
  end

  describe 'presence indicator in character_brief' do
    let(:other_character) { create(:character, forename: 'Other') }
    let(:other_instance) do
      create(:character_instance,
             character: other_character,
             reality: reality,
             current_room: room,
             online: true,
             status: 'alive')
    end

    subject { described_class.new(room, character_instance) }

    # Force creation of other_instance before tests
    before { other_instance }

    context 'when character has no presence status' do
      it 'includes nil presence in character brief' do
        display = subject.build_display
        other_char = display[:characters_ungrouped].find { |c| c[:character_id] == other_instance.id }
        expect(other_char[:presence]).to be_nil
      end
    end

    context 'when character has GTG status' do
      before { other_instance.set_gtg!(15) }

      it 'includes presence indicator with gtg status' do
        display = subject.build_display
        other_char = display[:characters_ungrouped].find { |c| c[:character_id] == other_instance.id }

        expect(other_char[:presence]).not_to be_nil
        expect(other_char[:presence][:status]).to eq('gtg')
        expect(other_char[:presence][:minutes]).to be_between(14, 15)
        expect(other_char[:presence][:until_timestamp]).not_to be_nil
      end
    end

    context 'when character has AFK status' do
      before { other_instance.set_afk!(30) }

      it 'includes presence indicator with afk status' do
        display = subject.build_display
        other_char = display[:characters_ungrouped].find { |c| c[:character_id] == other_instance.id }

        expect(other_char[:presence]).not_to be_nil
        expect(other_char[:presence][:status]).to eq('afk')
        expect(other_char[:presence][:minutes]).to be_between(29, 30)
      end
    end

    context 'when character has semi-AFK status' do
      before { other_instance.set_semiafk!(20) }

      it 'includes presence indicator with semi-afk status' do
        display = subject.build_display
        other_char = display[:characters_ungrouped].find { |c| c[:character_id] == other_instance.id }

        expect(other_char[:presence]).not_to be_nil
        expect(other_char[:presence][:status]).to eq('semi-afk')
        expect(other_char[:presence][:minutes]).to be_between(19, 20)
      end
    end

    context 'when character has indefinite AFK' do
      before { other_instance.set_afk! }

      it 'includes presence indicator without minutes' do
        display = subject.build_display
        other_char = display[:characters_ungrouped].find { |c| c[:character_id] == other_instance.id }

        expect(other_char[:presence]).not_to be_nil
        expect(other_char[:presence][:status]).to eq('afk')
        expect(other_char[:presence][:minutes]).to be_nil
      end
    end
  end

  describe 'weather display' do
    let(:weather_location) { create(:location, zone: area) }
    let!(:weather) { create(:weather, location: weather_location, condition: 'rain', intensity: 'moderate') }

    # Outdoor room shows weather directly
    let(:outdoor_room) do
      create(:room,
             location: weather_location,
             name: 'Garden',
             indoors: false,
             room_type: 'garden',
             min_x: 0,
             max_x: 100,
             min_y: 0,
             max_y: 100)
    end

    # Indoor room for testing window/door visibility
    # Shares edge with outdoor_room at x=100 (both have min_y=0, max_y=100)
    let(:indoor_room) do
      create(:room,
             location: weather_location,
             name: 'Living Room',
             indoors: true,
             room_type: 'living_room',
             min_x: 100,
             max_x: 200,
             min_y: 0,
             max_y: 100)
    end

    let(:viewer_outdoor) do
      create(:character_instance,
             character: character,
             reality: reality,
             current_room: outdoor_room,
             online: true,
             status: 'alive')
    end

    let(:viewer_indoor) do
      create(:character_instance,
             character: character,
             reality: reality,
             current_room: indoor_room,
             online: true,
             status: 'alive')
    end

    before do
      # Stub WeatherProseService to return predictable prose
      allow(WeatherProseService).to receive(:prose_for).and_return('Rain falls steadily from the sky.')
    end

    describe 'outdoor room weather' do
      it 'includes weather data without prefix' do
        service = described_class.new(outdoor_room, viewer_outdoor)
        display = service.build_display

        expect(display[:weather]).not_to be_nil
        expect(display[:weather][:prefix]).to be_nil
        expect(display[:weather][:prose]).to eq('Rain falls steadily from the sky.')
        expect(display[:weather][:condition]).to eq('rain')
      end

      it 'includes weather in arrival mode' do
        service = described_class.new(outdoor_room, viewer_outdoor, mode: :arrival)
        display = service.build_display

        expect(display[:weather]).not_to be_nil
        expect(display[:weather][:prefix]).to be_nil
      end
    end

    describe 'indoor room with window' do
      let!(:window_feature) do
        create(:room_feature,
               room: indoor_room,
               connected_room: outdoor_room,
               feature_type: 'window',
               curtain_state: 'open',
               allows_sight: true)
      end

      it 'shows weather with Outside prefix when curtains are open' do
        service = described_class.new(indoor_room, viewer_indoor)
        display = service.build_display

        expect(display[:weather]).not_to be_nil
        expect(display[:weather][:prefix]).to eq('Outside')
        expect(display[:weather][:prose]).to eq('Rain falls steadily from the sky.')
      end

      it 'does not show weather when curtains are closed' do
        window_feature.update(curtain_state: 'closed')

        service = described_class.new(indoor_room, viewer_indoor)
        display = service.build_display

        expect(display[:weather]).to be_nil
      end

      it 'shows weather when curtains are partially open' do
        window_feature.update(curtain_state: 'partially_open')

        service = described_class.new(indoor_room, viewer_indoor)
        display = service.build_display

        expect(display[:weather]).not_to be_nil
        expect(display[:weather][:prefix]).to eq('Outside')
      end
    end

    describe 'indoor room with door' do
      let!(:door_feature) do
        create(:room_feature,
               room: indoor_room,
               connected_room: outdoor_room,
               feature_type: 'door',
               is_open: true,
               allows_sight: true)
      end

      it 'shows weather when door is open' do
        service = described_class.new(indoor_room, viewer_indoor)
        display = service.build_display

        expect(display[:weather]).not_to be_nil
        expect(display[:weather][:prefix]).to eq('Outside')
      end

      it 'does not show weather when door is closed' do
        door_feature.update(is_open: false)

        service = described_class.new(indoor_room, viewer_indoor)
        display = service.build_display

        expect(display[:weather]).to be_nil
      end
    end

    describe 'indoor room with spatial adjacency to outdoor' do
      # Indoor room is already adjacent to outdoor room via shared edge at y=100
      # (indoor_room: y=100-200, outdoor_room: y=0-100)

      it 'shows weather via spatial adjacency when no features connect to outdoor' do
        # Ensure outdoor_room exists before checking adjacency
        outdoor_room

        service = described_class.new(indoor_room, viewer_indoor)
        display = service.build_display

        expect(display[:weather]).not_to be_nil
        expect(display[:weather][:prefix]).to eq('Outside')
      end
    end

    describe 'indoor room with no outdoor connection' do
      let(:isolated_indoor) do
        create(:room,
               location: weather_location,
               name: 'Basement',
               indoors: true,
               room_type: 'basement',
               min_x: 400,
               max_x: 500,
               min_y: 0,
               max_y: 100)
      end

      let(:viewer_isolated) do
        create(:character_instance,
               character: character,
               reality: reality,
               current_room: isolated_indoor,
               online: true,
               status: 'alive')
      end

      it 'does not show weather' do
        service = described_class.new(isolated_indoor, viewer_isolated)
        display = service.build_display

        expect(display[:weather]).to be_nil
      end
    end

    describe 'indoor room with opening/archway' do
      let!(:archway_feature) do
        create(:room_feature,
               room: indoor_room,
               connected_room: outdoor_room,
               feature_type: 'archway',
               allows_sight: true)
      end

      it 'always shows weather through opening' do
        service = described_class.new(indoor_room, viewer_indoor)
        display = service.build_display

        expect(display[:weather]).not_to be_nil
        expect(display[:weather][:prefix]).to eq('Outside')
      end
    end

    describe 'feature priority' do
      # Create a second outdoor room with different location (snowy weather)
      # This room is spatially adjacent to indoor_room via northern edge (y=100)
      let(:other_location) { create(:location, zone: area) }
      let!(:other_weather) { create(:weather, location: other_location, condition: 'snow') }
      let(:other_outdoor) do
        create(:room,
               location: other_location,
               name: 'Snowy Garden',
               indoors: false,
               min_x: 100,
               max_x: 200,
               min_y: 100,
               max_y: 200)
      end

      let!(:window_to_rain) do
        create(:room_feature,
               room: indoor_room,
               connected_room: outdoor_room,
               feature_type: 'window',
               curtain_state: 'open',
               allows_sight: true)
      end

      it 'uses feature connection before spatial exits' do
        # Force the other_outdoor to exist (triggers lazy let)
        other_outdoor

        service = described_class.new(indoor_room, viewer_indoor)
        display = service.build_display

        # Should use the window connection (rain) not the spatial exit (snow)
        expect(display[:weather]).not_to be_nil
        expect(display[:weather][:condition]).to eq('rain')
      end
    end
  end
end
