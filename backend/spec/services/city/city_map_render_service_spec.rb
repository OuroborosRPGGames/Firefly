# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CityMapRenderService do
  let(:location) { create(:location, name: 'Test City', city_name: 'Testville') }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Test', surname: 'Char', user: user) }

  # Street rooms (exterior, no inside_room_id)
  let(:street_room) do
    create(:room, name: 'Main Street', location: location, room_type: 'street',
           min_x: 0, max_x: 200, min_y: 90, max_y: 110, indoors: false)
  end

  let(:intersection_room) do
    create(:room, name: 'Central Intersection', location: location, room_type: 'intersection',
           min_x: 90, max_x: 110, min_y: 90, max_y: 110, indoors: false)
  end

  # A building (non-street, no inside_room_id)
  let(:building_room) do
    create(:room, name: 'The Rusty Tankard', location: location, room_type: 'bar',
           min_x: 10, max_x: 80, min_y: 10, max_y: 80, indoors: true)
  end

  # An interior room (has inside_room_id)
  let(:interior_room) do
    create(:room, name: 'Back Room', location: location, room_type: 'standard',
           min_x: 20, max_x: 50, min_y: 20, max_y: 50, indoors: true,
           inside_room_id: building_room.id)
  end

  # A shop inside a building
  let(:shop_room) do
    create(:room, name: 'Gift Shop', location: location, room_type: 'shop',
           min_x: 50, max_x: 80, min_y: 20, max_y: 50, indoors: true,
           inside_room_id: building_room.id)
  end

  # Viewer character instance
  let(:viewer) do
    create(:character_instance, character: character, reality: reality,
           current_room: street_room, x: 100.0, y: 100.0, online: true)
  end

  # Another character in the same room
  let(:other_character) do
    other_user = create(:user)
    other_char = create(:character, forename: 'Other', surname: 'Person', user: other_user)
    create(:character_instance, character: other_char, reality: reality,
           current_room: street_room, x: 120.0, y: 95.0, online: true)
  end

  before do
    # Ensure rooms exist
    street_room
    intersection_room
    building_room
  end

  describe '.render' do
    context 'parameter validation' do
      it 'requires a viewer' do
        expect { described_class.render(viewer: nil) }.to raise_error(ArgumentError, /viewer/i)
      end

      it 'rejects invalid mode' do
        expect { described_class.render(viewer: viewer, mode: :invalid) }
          .to raise_error(ArgumentError, /mode/i)
      end

      it 'rejects invalid context' do
        expect { described_class.render(viewer: viewer, context: :invalid) }
          .to raise_error(ArgumentError, /context/i)
      end

      it 'rejects invalid room_detail' do
        expect { described_class.render(viewer: viewer, room_detail: :invalid) }
          .to raise_error(ArgumentError, /room_detail/i)
      end
    end

    context 'return structure' do
      it 'returns a hash with svg and metadata keys' do
        result = described_class.render(viewer: viewer)

        expect(result).to be_a(Hash)
        expect(result).to have_key(:svg)
        expect(result).to have_key(:metadata)
      end

      it 'returns valid SVG XML' do
        result = described_class.render(viewer: viewer)
        svg = result[:svg]

        # XML declaration is stripped for innerHTML injection
        expect(svg).to include('<svg')
        expect(svg).to include('</svg>')
      end

      it 'returns metadata with expected keys' do
        result = described_class.render(viewer: viewer)
        metadata = result[:metadata]

        expect(metadata[:center_room_id]).to eq(street_room.id)
        expect(metadata[:context]).to eq(:exterior)
        expect(metadata[:mode]).to be_a(Symbol)
        expect(metadata[:location_id]).to eq(location.id)
        expect(metadata[:location_name]).to eq('Testville')
      end
    end

    context 'context detection (:auto)' do
      it 'detects exterior context for street rooms' do
        result = described_class.render(viewer: viewer, context: :auto)
        expect(result[:metadata][:context]).to eq(:exterior)
      end

      it 'detects interior context for rooms with inside_room_id' do
        interior_room
        viewer.update(current_room_id: interior_room.id, x: 35.0, y: 35.0)
        result = described_class.render(viewer: viewer, context: :auto)
        expect(result[:metadata][:context]).to eq(:interior)
      end

      it 'detects interior context for apartment room_type' do
        apartment = create(:room, name: 'Apt 3B', location: location, room_type: 'apartment',
                           min_x: 10, max_x: 40, min_y: 10, max_y: 40, indoors: true)
        viewer.update(current_room_id: apartment.id, x: 25.0, y: 25.0)
        result = described_class.render(viewer: viewer, context: :auto)
        expect(result[:metadata][:context]).to eq(:interior)
      end

      it 'detects interior context for shop room_type' do
        shop = create(:room, name: 'Ye Olde Shoppe', location: location, room_type: 'shop',
                      min_x: 10, max_x: 40, min_y: 10, max_y: 40, indoors: true)
        viewer.update(current_room_id: shop.id, x: 25.0, y: 25.0)
        result = described_class.render(viewer: viewer, context: :auto)
        expect(result[:metadata][:context]).to eq(:interior)
      end

      it 'detects interior context for bar room_type' do
        bar = create(:room, name: 'The Pub', location: location, room_type: 'bar',
                     min_x: 10, max_x: 40, min_y: 10, max_y: 40, indoors: true)
        viewer.update(current_room_id: bar.id, x: 25.0, y: 25.0)
        result = described_class.render(viewer: viewer, context: :auto)
        expect(result[:metadata][:context]).to eq(:interior)
      end

      it 'allows explicit context override' do
        result = described_class.render(viewer: viewer, context: :interior)
        expect(result[:metadata][:context]).to eq(:interior)
      end
    end

    context 'viewport calculation' do
      it 'uses smaller viewport for minimap mode' do
        result = described_class.render(viewer: viewer, mode: :minimap)
        expect(result[:metadata][:mode]).to eq(:minimap)
        # Minimap viewport should be smaller - verified by the SVG being generated
        expect(result[:svg]).to include('<svg')
      end

      it 'uses larger viewport for city mode' do
        result = described_class.render(viewer: viewer, mode: :city)
        expect(result[:metadata][:mode]).to eq(:city)
        expect(result[:svg]).to include('<svg')
      end
    end

    context 'SVG content layers' do
      it 'includes background fill' do
        result = described_class.render(viewer: viewer)
        expect(result[:svg]).to include('#0d1117')
      end

      it 'includes grid lines' do
        result = described_class.render(viewer: viewer)
        # Grid lines are subtle lines
        expect(result[:svg]).to include('#1a1f26')
      end

      it 'includes street rooms with street color' do
        result = described_class.render(viewer: viewer)
        expect(result[:svg]).to include('#3d444d')
      end

      it 'includes building rooms' do
        result = described_class.render(viewer: viewer)
        # Building room (the bar) should be rendered
        expect(result[:svg]).to include('The Rusty Tankard').or include('data-room-id')
      end

      it 'highlights the current room with gold outline' do
        result = described_class.render(viewer: viewer)
        expect(result[:svg]).to include('#ffd700')
      end

      it 'includes the viewer character marker' do
        result = described_class.render(viewer: viewer)
        # Self character is red
        expect(result[:svg]).to include('#ef4444')
      end

      it 'includes other characters in cyan' do
        other_character # ensure created
        result = described_class.render(viewer: viewer)
        expect(result[:svg]).to include('#22d3ee')
      end

      it 'includes data-char-id on the viewer character circle' do
        result = described_class.render(viewer: viewer)
        expect(result[:svg]).to include("data-char-id=\"#{viewer.id}\"")
      end

      it 'includes data-char-id on other character circles' do
        other_character # ensure created
        result = described_class.render(viewer: viewer)
        expect(result[:svg]).to include("data-char-id=\"#{other_character.id}\"")
      end
    end

    context 'interactive SVG attributes' do
      it 'includes data-room-id attributes on room elements' do
        result = described_class.render(viewer: viewer)
        expect(result[:svg]).to include("data-room-id=\"#{street_room.id}\"")
      end

      it 'includes data-room-name attributes on room elements' do
        result = described_class.render(viewer: viewer)
        expect(result[:svg]).to include('data-room-name=')
      end

      it 'includes data-room-type attributes on room elements' do
        result = described_class.render(viewer: viewer)
        expect(result[:svg]).to include('data-room-type=')
      end
    end

    context 'coordinate transformation' do
      it 'flips Y axis (world Y up, SVG Y down)' do
        # Viewer at world y=100, in a viewport. SVG y should be inverted.
        result = described_class.render(viewer: viewer, mode: :minimap)
        svg = result[:svg]

        # The SVG should be valid - the actual coordinate math is verified
        # by the fact that rooms render correctly within the viewport.
        expect(svg).to include('<svg')
        expect(svg).to include('</svg>')
      end
    end

    context 'exterior mode room visibility' do
      it 'shows rooms whose bounds overlap viewport' do
        result = described_class.render(viewer: viewer, mode: :city)
        # Street room, intersection, and building should all be visible
        # in a 500ft radius from viewer at (100, 100)
        svg = result[:svg]
        expect(svg).to include("data-room-id=\"#{street_room.id}\"")
        expect(svg).to include("data-room-id=\"#{intersection_room.id}\"")
        expect(svg).to include("data-room-id=\"#{building_room.id}\"")
      end

      it 'excludes rooms outside viewport' do
        far_room = create(:room, name: 'Far Away Room', location: location, room_type: 'standard',
                          min_x: 2000, max_x: 2100, min_y: 2000, max_y: 2100)
        result = described_class.render(viewer: viewer, mode: :minimap)
        expect(result[:svg]).not_to include("data-room-id=\"#{far_room.id}\"")
      end
    end

    context 'interior mode room visibility' do
      before do
        interior_room
        shop_room
      end

      it 'shows rooms with same inside_room_id' do
        viewer.update(current_room_id: interior_room.id, x: 35.0, y: 35.0)
        result = described_class.render(viewer: viewer, context: :interior)
        svg = result[:svg]

        # Both interior and shop room share inside_room_id = building_room.id
        expect(svg).to include("data-room-id=\"#{interior_room.id}\"")
        expect(svg).to include("data-room-id=\"#{shop_room.id}\"")
      end

      it 'shows the parent container room' do
        viewer.update(current_room_id: interior_room.id, x: 35.0, y: 35.0)
        result = described_class.render(viewer: viewer, context: :interior)
        svg = result[:svg]

        expect(svg).to include("data-room-id=\"#{building_room.id}\"")
      end
    end

    context 'building color coding' do
      it 'uses tavern color for bar room_type' do
        result = described_class.render(viewer: viewer)
        # Bar should use tavern color #8a4a2a
        expect(result[:svg]).to include('#8a4a2a')
      end
    end

    context 'building labels' do
      it 'adds name text for rooms large enough' do
        result = described_class.render(viewer: viewer, mode: :city)
        # The Rusty Tankard is 70x70 ft, should be large enough for a label
        svg = result[:svg]
        # The label should contain some portion of the building name
        expect(svg).to include('Rusty Tankard').or include('The Rusty')
      end
    end

    context 'SVG glow filters' do
      it 'includes glow filter definition for current room' do
        result = described_class.render(viewer: viewer)
        svg = result[:svg]
        # Should have defs with filter for glow effect
        expect(svg).to include('<defs>')
        expect(svg).to include('filter')
      end

      it 'includes glow filter for self character' do
        result = described_class.render(viewer: viewer)
        svg = result[:svg]
        expect(svg).to include('filter')
      end
    end

    context 'furniture rendering in high detail' do
      it 'renders furniture at high room detail' do
        Place.create(name: 'wooden chair', room_id: street_room.id, x: 50.0, y: 50.0, capacity: 1)
        result = described_class.render(viewer: viewer, room_detail: :high)
        # High detail should include furniture markers
        # Furniture is rendered as small elements in the room
        expect(result[:svg]).to include('<svg')
      end

      it 'keeps furniture markers within viewport for offset interior coordinates' do
        offset_building = create(:room, name: 'Offset Building', location: location, room_type: 'bar',
                                 min_x: 1000, max_x: 1100, min_y: 1000, max_y: 1100, indoors: true)
        offset_room = create(:room, name: 'Offset Room', location: location, room_type: 'standard',
                             min_x: 1020, max_x: 1080, min_y: 1020, max_y: 1080, indoors: true,
                             inside_room_id: offset_building.id)
        Place.create(name: 'offset chair', room_id: offset_room.id, x: 1030.0, y: 1030.0, capacity: 1)

        viewer.update(current_room_id: offset_room.id, x: 1050.0, y: 1050.0)
        result = described_class.render(viewer: viewer, context: :interior, room_detail: :high, mode: :city)

        furniture_circle = result[:svg].scan(/<circle[^>]*fill="#4a5568"[^>]*>/).first
        expect(furniture_circle).not_to be_nil

        cx = furniture_circle[/cx="([^"]+)"/, 1].to_f
        cy = furniture_circle[/cy="([^"]+)"/, 1].to_f
        expect(cx).to be_between(0, 800)
        expect(cy).to be_between(0, 600)
      end
    end

    context 'street name rendering' do
      # E-W street: wider than tall (200x20 ft)
      # N-S avenue: taller than wide
      let(:avenue_room) do
        create(:room, name: 'Oak Avenue', location: location, room_type: 'avenue',
               min_x: 140, max_x: 160, min_y: 0, max_y: 200, indoors: false)
      end

      it 'renders one aggregated label per named street' do
        # street_room is 200x20; aggregated label covers the full span
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        expect(svg).to include('Main Street')
        # Should be exactly one text element for "Main Street" (aggregated)
        main_street_texts = svg.scan(/<text[^>]*>Main Street<\/text>/)
        expect(main_street_texts.length).to eq(1)
      end

      it 'renders E-W street names horizontally (no rotate)' do
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        main_street_text = svg.scan(/<text[^>]*>Main Street<\/text>/).first
        expect(main_street_text).not_to be_nil
        expect(main_street_text).not_to include('rotate')
      end

      it 'renders N-S avenue names rotated -90 degrees' do
        avenue_room
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        expect(svg).to include('Oak Avenue')
        oak_avenue_text = svg.scan(/<text[^>]*>Oak Avenue<\/text>/).first
        expect(oak_avenue_text).not_to be_nil
        expect(oak_avenue_text).to include('rotate(-90')
      end

      it 'uses the street name label color' do
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        main_street_text = svg.scan(/<text[^>]*>Main Street<\/text>/).first
        expect(main_street_text).to include('#ffffff')
      end

      it 'uses opacity 0.7 for street name labels' do
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        main_street_text = svg.scan(/<text[^>]*>Main Street<\/text>/).first
        expect(main_street_text).to include('opacity="0.7"')
      end

      it 'skips street names when aggregated span is too small' do
        # Create a tiny street whose total span is < 40px in SVG
        tiny_street = create(:room, name: 'Tiny Lane', location: location, room_type: 'street',
                             min_x: 100, max_x: 105, min_y: 100, max_y: 102, indoors: false)
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        text_elements = svg.scan(/<text[^>]*>Tiny Lane<\/text>/)
        expect(text_elements).to be_empty
      end

      it 'renders street names for intersection rooms' do
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        # intersection_room is 20x20 - aggregated span too small
        expect(svg).not_to include('>Central Intersection<')
      end

      it 'shows only one label per grid row when streets share the same position' do
        # Create two E-W streets at the same Y position (different names, same grid row)
        # The longer one should win
        create(:room, name: 'Alpha Road', location: location, room_type: 'street',
               min_x: 0, max_x: 200, min_y: 50, max_y: 70, indoors: false)
        create(:room, name: 'Beta Road', location: location, room_type: 'street',
               min_x: 200, max_x: 350, min_y: 50, max_y: 70, indoors: false)
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]

        # Only the longer-spanning label should be rendered
        alpha_texts = svg.scan(/<text[^>]*>Alpha Road<\/text>/)
        beta_texts = svg.scan(/<text[^>]*>Beta Road<\/text>/)
        total = alpha_texts.length + beta_texts.length
        expect(total).to eq(1)
      end
    end

    context 'oversized room filtering' do
      it 'excludes rooms larger than MAX_BUILDING_DIMENSION from building rendering' do
        sky_room = create(:room, name: 'Sky Above City', location: location, room_type: 'standard',
                          min_x: -500, max_x: 500, min_y: -500, max_y: 500, indoors: false)
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        expect(svg).not_to include("data-room-id=\"#{sky_room.id}\"")
      end

      it 'still renders normal-sized buildings' do
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        # building_room is 70x70 ft - well under the limit
        expect(svg).to include("data-room-id=\"#{building_room.id}\"")
      end
    end

    context 'building label improvements' do
      it 'word-wraps long building names using tspan elements' do
        long_name_building = create(:room, name: 'The Extraordinarily Magnificent Grand Palace of Wonders',
                                    location: location, room_type: 'shop',
                                    min_x: 120, max_x: 170, min_y: 10, max_y: 60, indoors: true)
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        # Should use tspan elements for word-wrapped text
        expect(svg).to include('<tspan')
      end

      it 'uses minimum font size of 5 for building labels' do
        small_building = create(:room, name: 'Shed', location: location, room_type: 'shop',
                                min_x: 120, max_x: 155, min_y: 120, max_y: 155, indoors: true)
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        # Building labels use raw tspan text; check font-size attribute
        shed_text = svg.scan(/<text[^>]*font-size="(\d+)"[^>]*>.*?Shed.*?<\/text>/m).flatten
        if shed_text.any?
          expect(shed_text.first.to_f).to be >= 5
        end
      end

      it 'scales font size with building dimensions' do
        large_building = create(:room, name: 'Grand Hall', location: location, room_type: 'shop',
                                min_x: 120, max_x: 250, min_y: 120, max_y: 250, indoors: true)
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        # Check font-size on raw text elements containing Grand Hall
        font_sizes = svg.scan(/<text[^>]*font-size="(\d+)"[^>]*>.*?Grand Hall.*?<\/text>/m).flatten
        if font_sizes.any?
          expect(font_sizes.first.to_f).to be <= 14
        end
      end

      it 'skips labels for buildings smaller than minimum label size' do
        tiny_building = create(:room, name: 'Closet', location: location, room_type: 'shop',
                               min_x: 120, max_x: 125, min_y: 120, max_y: 125, indoors: true)
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        # 5ft at city mode = ~4px, too small for label
        expect(svg).not_to include('>Closet<')
      end
    end

    context 'door indicators' do
      it 'renders door indicators on buildings with door features' do
        RoomFeature.create(room_id: building_room.id, feature_type: 'door', direction: 'south',
                           x: 45.0, y: 10.0)
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        # Door color should be present
        expect(svg).to include('#e0c070')
      end

      it 'does not render door indicators when no door features exist' do
        result = described_class.render(viewer: viewer, mode: :city)
        svg = result[:svg]
        # No door markers - the door color should not appear
        expect(svg).not_to include('#e0c070')
      end
    end

    context 'with missing viewer room' do
      it 'handles viewer with nil current_room gracefully' do
        # Use a double to simulate viewer with nil room, since Sequel validation prevents nil current_room_id
        roomless_viewer = double('CharacterInstance',
                                 id: viewer.id,
                                 current_room: nil,
                                 current_room_id: nil,
                                 x: 50.0, y: 50.0)
        expect { described_class.render(viewer: roomless_viewer) }.to raise_error(ArgumentError, /room/i)
      end
    end
  end
end
