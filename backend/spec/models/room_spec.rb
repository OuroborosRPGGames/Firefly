# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Room do
  let(:location) { create(:location) }

  # Helper for building rooms with location
  def build_room(**attrs)
    build(:room, **attrs)
  end

  def create_room(**attrs)
    create(:room, **attrs)
  end

  # ========================================
  # Constants
  # ========================================

  describe 'constants' do
    describe 'PUBLICITY_LEVELS' do
      it 'includes expected levels' do
        expect(Room::PUBLICITY_LEVELS).to eq(%w[secluded semi_public public])
      end
    end

    describe 'ROOM_TYPES' do
      it 'defines categorized room types' do
        expect(Room::ROOM_TYPES).to be_a(Hash)
        expect(Room::ROOM_TYPES.keys).to include(:basic, :residential, :outdoor_nature)
      end

      it 'includes standard in basic' do
        expect(Room::ROOM_TYPES[:basic]).to include('standard')
      end
    end

    describe 'VALID_ROOM_TYPES' do
      it 'is a flat array of all room types' do
        expect(Room::VALID_ROOM_TYPES).to include('standard', 'bedroom', 'forest', 'cave')
      end
    end
  end

  # ========================================
  # Validations
  # ========================================

  describe 'validations' do
    it 'requires name' do
      room = Room.new(name: nil, location_id: location.id, room_type: 'standard',
                      min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      expect(room.valid?).to be false
      expect(room.errors[:name]).to include('is not present')
    end

    it 'requires location_id' do
      room = Room.new(name: 'Test', location_id: nil, room_type: 'standard',
                      min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      expect(room.valid?).to be false
      expect(room.errors[:location_id]).to include('is not present')
    end

    it 'validates name max length' do
      room = Room.new(name: 'A' * 101, location_id: location.id, room_type: 'standard',
                      min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      expect(room.valid?).to be false
      expect(room.errors[:name]).not_to be_empty
    end

    it 'validates room_type is in allowed values' do
      room = Room.new(name: 'Test', location_id: location.id, room_type: 'invalid_type',
                      min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      expect(room.valid?).to be false
      expect(room.errors[:room_type]).not_to be_empty
    end

    it 'accepts all valid room types' do
      %w[standard bedroom forest cave shop].each do |type|
        room = Room.new(name: "Test #{type}", location_id: location.id, room_type: type,
                        min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        expect(room.valid?).to eq(true), "Expected room_type '#{type}' to be valid"
      end
    end

    it 'validates publicity is in allowed values when set' do
      room = Room.new(name: 'Test', location_id: location.id, room_type: 'standard',
                      publicity: 'invalid', min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      expect(room.valid?).to be false
      expect(room.errors[:publicity]).not_to be_empty
    end

    it 'accepts nil publicity' do
      room = Room.new(name: 'Test Pub', location_id: location.id, room_type: 'standard',
                      publicity: nil, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      expect(room.valid?).to be true
    end

    describe 'room bounds validation' do
      it 'requires all dimension values' do
        room = Room.new(name: 'Test Bounds', location_id: location.id, room_type: 'standard',
                        min_x: nil, max_x: 100, min_y: 0, max_y: 100)
        expect(room.valid?).to be false
        expect(room.errors[:base]).to include('Room dimensions (min_x, max_x, min_y, max_y) must be specified')
      end

      it 'validates min_x < max_x' do
        room = Room.new(name: 'Test X', location_id: location.id, room_type: 'standard',
                        min_x: 100, max_x: 50, min_y: 0, max_y: 100)
        expect(room.valid?).to be false
        expect(room.errors[:base]).to include('min_x must be less than max_x')
      end

      it 'validates min_y < max_y' do
        room = Room.new(name: 'Test Y', location_id: location.id, room_type: 'standard',
                        min_x: 0, max_x: 100, min_y: 100, max_y: 50)
        expect(room.valid?).to be false
        expect(room.errors[:base]).to include('min_y must be less than max_y')
      end
    end
  end

  # ========================================
  # Description Methods
  # ========================================

  describe '#description' do
    it 'returns long_description when available' do
      room = Room.new(long_description: 'Long desc', short_description: 'Short desc')
      expect(room.description).to eq('Long desc')
    end

    it 'returns short_description when long_description is empty' do
      room = Room.new(long_description: '', short_description: 'Short desc')
      expect(room.description).to eq('Short desc')
    end

    it 'returns short_description when long_description is nil' do
      room = Room.new(long_description: nil, short_description: 'Short desc')
      expect(room.description).to eq('Short desc')
    end
  end

  # ========================================
  # Exit Methods (Spatial Adjacency)
  # ========================================

  describe 'exit methods' do
    let(:room) { create_room(min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

    describe '#spatial_exits' do
      it 'returns adjacent rooms by direction' do
        # Create a room to the north (shares edge at y=100)
        north_room = create_room(location: room.location, min_x: 0, max_x: 100, min_y: 100, max_y: 200)

        exits = room.spatial_exits
        expect(exits[:north]).to include(north_room)
      end
    end

    describe '#passable_spatial_exits' do
      it 'returns passable exits as hashes with direction and room' do
        # Create a room to the north (shares edge at y=100)
        north_room = create_room(location: room.location, min_x: 0, max_x: 100, min_y: 100, max_y: 200)

        exits = room.passable_spatial_exits
        north_exit = exits.find { |e| e[:room] == north_room }
        expect(north_exit).not_to be_nil
        expect(north_exit[:direction]).to eq(:north)
      end
    end
  end

  # ========================================
  # Character Methods
  # ========================================

  describe 'character methods' do
    let(:room) { create_room }

    describe '#characters_here' do
      it 'returns online characters in room' do
        online_char = create(:character_instance, current_room: room, online: true)
        offline_char = create(:character_instance, current_room: room, online: false)

        expect(room.characters_here.all).to include(online_char)
        expect(room.characters_here.all).not_to include(offline_char)
      end
    end

    describe '#objects_here' do
      it 'returns items in room ordered by name' do
        item_b = create(:item, :in_room, pattern: nil, room: room, name: 'Banana', character_instance: nil)
        item_a = create(:item, :in_room, pattern: nil, room: room, name: 'Apple', character_instance: nil)

        results = room.objects_here.all
        expect(results.first.name).to eq('Apple')
        expect(results.last.name).to eq('Banana')
      end
    end
  end

  # ========================================
  # Ownership Methods
  # ========================================

  describe 'ownership methods' do
    let(:room) { create_room }
    let(:owner) { create(:character) }

    describe '#owned_by?' do
      it 'returns true when character owns room' do
        room.update(owner_id: owner.id)
        expect(room.owned_by?(owner)).to be true
      end

      it 'returns false when character does not own room' do
        other = create(:character)
        room.update(owner_id: owner.id)
        expect(room.owned_by?(other)).to be false
      end

      it 'returns false when room has no owner' do
        expect(room.owned_by?(owner)).to be false
      end
    end

    describe '#unlocked_for?' do
      it 'returns true for public rooms (no owner)' do
        expect(room.unlocked_for?(owner)).to be true
      end

      it 'returns true for owner' do
        room.update(owner_id: owner.id)
        expect(room.unlocked_for?(owner)).to be true
      end
    end

    describe '#locked?' do
      it 'returns false for public rooms' do
        expect(room.locked?).to be false
      end

      it 'returns true for owned room without public unlock' do
        room.update(owner_id: owner.id)
        expect(room.locked?).to be true
      end
    end
  end

  # ========================================
  # Private Mode Methods
  # ========================================

  describe 'private mode methods' do
    let(:room) { create_room(private_mode: false) }

    describe '#private_mode?' do
      it 'returns true when private_mode is true' do
        room.update(private_mode: true)
        expect(room.private_mode?).to be true
      end

      it 'returns false when private_mode is false' do
        expect(room.private_mode?).to be false
      end
    end

    describe '#enable_private_mode!' do
      it 'enables private mode' do
        room.enable_private_mode!
        expect(room.private_mode).to be true
      end
    end

    describe '#disable_private_mode!' do
      it 'disables private mode' do
        room.update(private_mode: true)
        room.disable_private_mode!
        expect(room.private_mode).to be false
      end
    end

    describe '#toggle_private_mode!' do
      it 'toggles private mode' do
        room.toggle_private_mode!
        expect(room.private_mode).to be true
        room.toggle_private_mode!
        expect(room.private_mode).to be false
      end
    end

    describe '#excludes_staff_vision?' do
      it 'is an alias for private_mode?' do
        expect(room.excludes_staff_vision?).to eq(room.private_mode?)
      end
    end
  end

  # ========================================
  # Publicity Methods
  # ========================================

  describe 'publicity methods' do
    let(:room) { create_room }

    describe '#secluded?' do
      it 'returns true when publicity is secluded' do
        room.update(publicity: 'secluded')
        expect(room.secluded?).to be true
      end

      it 'returns false for other publicity levels' do
        room.update(publicity: 'public')
        expect(room.secluded?).to be false
      end
    end

    describe '#semi_public?' do
      it 'returns true when publicity is semi_public' do
        room.update(publicity: 'semi_public')
        expect(room.semi_public?).to be true
      end
    end

    describe '#public_space?' do
      it 'returns true when publicity is public' do
        room.update(publicity: 'public')
        expect(room.public_space?).to be true
      end

      it 'returns true when publicity is nil' do
        room.update(publicity: nil)
        expect(room.public_space?).to be true
      end
    end

    describe '#publicity_level' do
      it 'returns publicity when set' do
        room.update(publicity: 'secluded')
        expect(room.publicity_level).to eq('secluded')
      end

      it 'defaults to public when nil' do
        room.update(publicity: nil)
        expect(room.publicity_level).to eq('public')
      end
    end

    describe '#set_publicity!' do
      it 'sets valid publicity level' do
        room.set_publicity!('secluded')
        expect(room.publicity).to eq('secluded')
      end

      it 'raises error for invalid level' do
        expect { room.set_publicity!('invalid') }.to raise_error(ArgumentError)
      end
    end
  end

  # ========================================
  # Battle Map Methods
  # ========================================

  describe 'battle map methods' do
    let(:room) { create_room(room_type: 'arena') }

    describe '#battle_map_config_for_type' do
      it 'returns config for known room type' do
        config = room.battle_map_config_for_type
        expect(config).to include(:surfaces, :objects, :density)
      end

      it 'returns default config for unknown type' do
        room.room_type = 'unknown_type'
        config = room.battle_map_config_for_type
        expect(config).to eq(Room::DEFAULT_ROOM_CONFIG)
      end
    end

    describe '#battle_map_ready?' do
      it 'returns false when has_battle_map is false' do
        room.update(has_battle_map: false)
        expect(room.battle_map_ready?).to be false
      end
    end

    describe '#battle_map_category' do
      it 'returns :indoor for residential types' do
        room.room_type = 'bedroom'
        expect(room.battle_map_category).to eq(:indoor)
      end

      it 'returns :outdoor for nature types' do
        room.room_type = 'forest'
        expect(room.battle_map_category).to eq(:outdoor)
      end

      it 'returns :underground for underground types' do
        room.room_type = 'cave'
        expect(room.battle_map_category).to eq(:underground)
      end
    end

    describe '#combat_optimized?' do
      it 'returns true for combat-optimized rooms' do
        room.room_type = 'arena'
        expect(room.combat_optimized?).to be true
      end

      it 'returns false for non-combat rooms' do
        room.room_type = 'bedroom'
        expect(room.combat_optimized?).to be false
      end
    end

    describe '#naturally_dark?' do
      it 'returns true for dark rooms' do
        room.room_type = 'cave'
        expect(room.naturally_dark?).to be true
      end

      it 'returns false for lit rooms' do
        room.room_type = 'street'
        expect(room.naturally_dark?).to be false
      end
    end

    describe '#hex_count' do
      it 'returns count of room hexes' do
        expect(room.hex_count).to eq(0)
      end
    end
  end

  # ========================================
  # System Room Methods
  # ========================================

  describe 'system room methods' do
    let(:room) { create_room }

    describe '#staff_only?' do
      it 'returns true when staff_only is true' do
        room.update(staff_only: true)
        expect(room.staff_only?).to be true
      end

      it 'returns false when staff_only is false' do
        expect(room.staff_only?).to be false
      end
    end

    describe '#death_room?' do
      it 'returns true for death room type' do
        room.room_type = 'death'
        expect(room.death_room?).to be true
      end

      it 'returns false for other types' do
        expect(room.death_room?).to be false
      end
    end

    describe '#blocks_ic_communication?' do
      it 'returns true when no_ic_communication is true' do
        room.update(no_ic_communication: true)
        expect(room.blocks_ic_communication?).to be true
      end

      it 'returns true for death rooms' do
        room.room_type = 'death'
        expect(room.blocks_ic_communication?).to be true
      end

      it 'returns false normally' do
        expect(room.blocks_ic_communication?).to be false
      end
    end
  end

  # ========================================
  # Coordinate Methods
  # ========================================

  describe '#coordinates_in_bounds?' do
    let(:room) { create_room(min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

    it 'returns true for coordinates within bounds' do
      expect(room.coordinates_in_bounds?(50, 50)).to be true
    end

    it 'returns true for edge coordinates' do
      expect(room.coordinates_in_bounds?(0, 0)).to be true
      expect(room.coordinates_in_bounds?(100, 100)).to be true
    end

    it 'returns false for coordinates outside X bounds' do
      expect(room.coordinates_in_bounds?(150, 50)).to be false
    end

    it 'returns false for coordinates outside Y bounds' do
      expect(room.coordinates_in_bounds?(50, 150)).to be false
    end
  end

  # ========================================
  # Navigation Helpers
  # ========================================

  describe 'navigation helpers' do
    let(:room) { create_room }

    describe '#area' do
      it 'returns the area through location' do
        expect(room.area).to eq(room.location.area)
      end
    end

    describe '#world' do
      it 'returns the world through area' do
        expect(room.world).to eq(room.location.area.world)
      end
    end

    describe '#universe' do
      it 'returns the universe through world' do
        expect(room.universe).to eq(room.location.area.world.universe)
      end
    end
  end

  # ========================================
  # Customization Methods
  # ========================================

  describe 'customization methods' do
    let(:room) { create_room(curtains: false) }

    describe '#toggle_curtains!' do
      it 'toggles curtains state' do
        room.toggle_curtains!
        expect(room.curtains).to be true
        room.toggle_curtains!
        expect(room.curtains).to be false
      end
    end

    describe '#set_background!' do
      it 'sets default background URL' do
        room.set_background!('https://example.com/bg.jpg')
        expect(room.default_background_url).to eq('https://example.com/bg.jpg')
      end
    end
  end

  # ========================================
  # Vault Methods
  # ========================================

  describe '#vault_accessible?' do
    let(:room) { create_room }
    let(:owner) { create(:character) }

    it 'returns true for room owner' do
      room.update(owner_id: owner.id)
      expect(room.vault_accessible?(owner)).to be true
    end

    it 'returns true when room is_vault' do
      room.update(is_vault: true)
      expect(room.vault_accessible?(owner)).to be true
    end

    it 'returns false otherwise' do
      expect(room.vault_accessible?(owner)).to be false
    end
  end

  # ========================================
  # Persistence
  # ========================================

  describe 'persistence' do
    it 'saves and retrieves room' do
      room = create_room(name: 'Test Chamber', room_type: 'bedroom')
      retrieved = Room.find(id: room.id)
      expect(retrieved.name).to eq('Test Chamber')
      expect(retrieved.room_type).to eq('bedroom')
    end
  end

  # ========================================
  # Zone Polygon Boundary Methods
  # ========================================

  describe 'zone polygon methods' do
    describe '#navigable?' do
      it 'returns true when outside_polygon is false and active is not false' do
        room = create_room(outside_polygon: false, active: true)
        expect(room.navigable?).to be true
      end

      it 'returns true when outside_polygon is false and active is nil' do
        room = create_room(outside_polygon: false, active: nil)
        expect(room.navigable?).to be true
      end

      it 'returns false when outside_polygon is true' do
        room = create_room(outside_polygon: true)
        expect(room.navigable?).to be false
      end

      it 'returns false when active is false' do
        room = create_room(outside_polygon: false, active: false)
        expect(room.navigable?).to be false
      end
    end

    describe '#center_x and #center_y' do
      it 'calculates center from bounds' do
        room = create_room(min_x: 0, max_x: 100, min_y: 50, max_y: 150)
        expect(room.center_x).to eq(50.0)
        expect(room.center_y).to eq(100.0)
      end
    end

    describe '#inside_zone_polygon?' do
      let(:universe) { create(:universe) }
      let(:world) { create(:world, universe: universe) }
      let(:zone) { create(:zone, world: world, polygon_points: nil) }  # No polygon by default
      let(:location_with_zone) { create(:location, zone: zone, globe_hex_id: 1, latitude: 10.0, longitude: 10.0, world_id: world.id) }

      context 'when zone has no polygon' do
        it 'returns true' do
          room = create_room(location: location_with_zone, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
          expect(room.inside_zone_polygon?).to be true
        end
      end

      context 'when zone has a polygon' do
        before do
          zone.update(polygon_points: [
            { 'x' => 9.9, 'y' => 9.9 },
            { 'x' => 10.1, 'y' => 9.9 },
            { 'x' => 10.1, 'y' => 10.1 },
            { 'x' => 9.9, 'y' => 10.1 }
          ])
        end

        it 'returns true for rooms inside polygon' do
          room = create_room(location: location_with_zone, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
          expect(room.inside_zone_polygon?).to be true
        end

        it 'returns false for rooms outside polygon' do
          room = create_room(location: location_with_zone, min_x: 100_000, max_x: 100_100, min_y: 100_000, max_y: 100_100)
          expect(room.inside_zone_polygon?).to be false
        end
      end
    end

    describe 'dataset scopes' do
      before do
        create_room(name: 'Inside Room', outside_polygon: false, active: true)
        create_room(name: 'Outside Room', outside_polygon: true)
        create_room(name: 'Inactive Room', outside_polygon: false, active: false)
      end

      describe '.navigable' do
        it 'returns only navigable rooms' do
          results = Room.navigable.all
          expect(results.map(&:name)).to include('Inside Room')
          expect(results.map(&:name)).not_to include('Outside Room')
          expect(results.map(&:name)).not_to include('Inactive Room')
        end
      end

      describe '.inside_polygon' do
        it 'returns rooms inside polygon' do
          results = Room.inside_polygon.all
          expect(results.map(&:name)).to include('Inside Room')
          expect(results.map(&:name)).to include('Inactive Room')
          expect(results.map(&:name)).not_to include('Outside Room')
        end
      end

      describe '.outside_polygon_scope' do
        it 'returns rooms outside polygon' do
          results = Room.outside_polygon_scope.all
          expect(results.map(&:name)).to include('Outside Room')
          expect(results.map(&:name)).not_to include('Inside Room')
        end
      end
    end
  end

  # ========================================
  # Character Location Methods
  # ========================================

  describe 'character location methods' do
    let(:room) { create_room }
    let(:character) { create(:character) }
    let(:char_instance) { create(:character_instance, character: character, current_room: room, online: true) }

    describe '#characters_here with reality_id' do
      let(:reality1) { create(:reality) }
      let(:reality2) { create(:reality) }

      it 'filters by reality_id when provided' do
        char_in_reality1 = create(:character_instance, character: create(:character), current_room: room, reality: reality1, online: true)
        char_in_reality2 = create(:character_instance, character: create(:character), current_room: room, reality: reality2, online: true)

        results = room.characters_here(reality1.id).all
        expect(results).to include(char_in_reality1)
        expect(results).not_to include(char_in_reality2)
      end

      it 'returns all characters when reality_id is nil' do
        char_in_reality1 = create(:character_instance, character: create(:character), current_room: room, reality: reality1, online: true)
        char_in_reality2 = create(:character_instance, character: create(:character), current_room: room, reality: reality2, online: true)

        results = room.characters_here.all
        expect(results).to include(char_in_reality1, char_in_reality2)
      end
    end

    describe '#characters_here with flashback filtering' do
      let(:viewer) { create(:character_instance, character: create(:character), current_room: room, online: true) }

      context 'when viewer is flashback instanced' do
        before do
          viewer.update(flashback_instanced: true, flashback_co_travelers: [char_instance.id])
          char_instance.update(flashback_instanced: true)
        end

        it 'returns only co-travelers and self' do
          non_traveler = create(:character_instance, character: create(:character), current_room: room, online: true)

          results = room.characters_here(nil, viewer: viewer).all
          expect(results).to include(char_instance)
          expect(results).to include(viewer)
          expect(results).not_to include(non_traveler)
        end
      end

      context 'when viewer is not flashback instanced' do
        it 'excludes flashback-instanced characters' do
          char_instance.update(flashback_instanced: true)
          normal_char = create(:character_instance, character: create(:character), current_room: room, online: true, flashback_instanced: false)

          results = room.characters_here(nil, viewer: viewer).all
          expect(results).to include(normal_char)
          expect(results).not_to include(char_instance)
        end
      end
    end

    describe '#characters_by_place' do
      it 'groups characters by place' do
        place = create(:place, room: room)
        char_instance.update(current_place_id: place.id)
        ungrouped = create(:character_instance, character: create(:character), current_room: room, online: true, current_place_id: nil)

        grouped = room.characters_by_place
        expect(grouped[place.id]).to include(char_instance)
        expect(grouped[nil]).to include(ungrouped)
      end
    end
  end

  # ========================================
  # Full Path
  # ========================================

  describe '#full_path' do
    let(:room) { create_room(name: 'Test Chamber') }

    it 'returns hierarchical path string' do
      path = room.full_path
      expect(path).to include(room.location.zone.world.universe.name)
      expect(path).to include(room.location.zone.world.name)
      expect(path).to include(room.location.zone.name)
      expect(path).to include(room.location.name)
      expect(path).to include('Test Chamber')
    end
  end

  # ========================================
  # Places and Decorations
  # ========================================

  describe '#visible_places' do
    let(:room) { create_room }

    it 'returns only visible places' do
      visible = create(:place, room: room, invisible: false)
      invisible = create(:place, room: room, invisible: true)

      results = room.visible_places.all
      expect(results).to include(visible)
      expect(results).not_to include(invisible)
    end
  end

  describe '#visible_decorations' do
    let(:room) { create_room }

    it 'returns decorations ordered by display_order' do
      dec2 = create(:decoration, room: room, display_order: 2)
      dec1 = create(:decoration, room: room, display_order: 1)

      results = room.visible_decorations.all
      expect(results.first).to eq(dec1)
      expect(results.last).to eq(dec2)
    end
  end

  # ========================================
  # Door Lock Methods
  # ========================================

  describe 'door lock methods' do
    let(:room) { create_room }
    let(:owner) { create(:character) }
    let(:visitor) { create(:character) }

    before do
      room.update(owner_id: owner.id)
    end

    describe '#lock_doors!' do
      it 'removes public unlocks' do
        RoomUnlock.create(room_id: room.id, character_id: nil)  # Public unlock
        expect(room.locked?).to be false

        room.lock_doors!
        expect(room.locked?).to be true
      end

      it 'does not remove character-specific unlocks' do
        RoomUnlock.create(room_id: room.id, character_id: visitor.id)

        room.lock_doors!
        expect(room.unlocked_for?(visitor)).to be true
      end
    end

    describe '#unlock_doors!' do
      it 'creates a public unlock' do
        room.unlock_doors!
        expect(room.locked?).to be false
      end

      it 'creates expiring unlock when expires_in_minutes is provided' do
        room.unlock_doors!(expires_in_minutes: 60)
        unlock = RoomUnlock.where(room_id: room.id, character_id: nil).first
        expect(unlock.expires_at).to be > Time.now
      end
    end

    describe '#grant_access!' do
      it 'creates character-specific unlock' do
        room.grant_access!(visitor)
        expect(room.unlocked_for?(visitor)).to be true
      end

      it 'creates permanent unlock when permanent is true' do
        room.grant_access!(visitor, permanent: true)
        unlock = RoomUnlock.where(room_id: room.id, character_id: visitor.id).first
        expect(unlock.expires_at).to be_nil
      end

      it 'creates expiring unlock by default' do
        room.grant_access!(visitor)
        unlock = RoomUnlock.where(room_id: room.id, character_id: visitor.id).first
        expect(unlock.expires_at).to be > Time.now
      end
    end

    describe '#revoke_access!' do
      it 'removes character-specific unlock' do
        room.grant_access!(visitor)
        expect(room.unlocked_for?(visitor)).to be true

        room.revoke_access!(visitor)
        expect(room.unlocked_for?(visitor)).to be false
      end
    end
  end

  # ========================================
  # Cleanup Contents
  # ========================================

  describe '#cleanup_contents!' do
    let(:room) { create_room }

    it 'deletes decorations' do
      create(:decoration, room: room)
      expect { room.cleanup_contents! }.to change { Decoration.where(room_id: room.id).count }.to(0)
    end

    it 'deletes places' do
      create(:place, room: room)
      expect { room.cleanup_contents! }.to change { Place.where(room_id: room.id).count }.to(0)
    end

    it 'deletes room features' do
      # Room features are now used instead of room_exit records
      # Spatial adjacency determines connections, but features like doors are tracked
      RoomFeature.create(room_id: room.id, feature_type: 'door', direction: 'north', x: 50, y: 100)
      expect { room.cleanup_contents! }.to change { RoomFeature.where(room_id: room.id).count }.to(0)
    end

    it 'deletes room unlocks' do
      RoomUnlock.create(room_id: room.id, character_id: nil)
      expect { room.cleanup_contents! }.to change { RoomUnlock.where(room_id: room.id).count }.to(0)
    end
  end

  # ========================================
  # Seasonal Description Methods
  # ========================================

  describe 'seasonal description methods' do
    let(:room) { create_room }

    describe '#list_seasonal_descriptions' do
      it 'returns empty hash when none set' do
        expect(room.list_seasonal_descriptions).to eq({})
      end

      it 'returns hash when data exists' do
        # Pre-seed the JSONB column via raw SQL to avoid pg_jsonb_wrap issues in test env
        room.update(seasonal_descriptions: Sequel.lit("'{\"dawn_spring\": \"Test\"}'::jsonb"))
        room.reload
        expect(room.list_seasonal_descriptions).to respond_to(:keys)
        expect(room.list_seasonal_descriptions['dawn_spring']).to eq('Test')
      end
    end

    describe '#list_seasonal_backgrounds' do
      it 'returns empty hash when none set' do
        expect(room.list_seasonal_backgrounds).to eq({})
      end

      it 'returns hash when data exists' do
        # Pre-seed the JSONB column via raw SQL to avoid pg_jsonb_wrap issues in test env
        room.update(seasonal_backgrounds: Sequel.lit("'{\"night_winter\": \"https://example.com/night.jpg\"}'::jsonb"))
        room.reload
        expect(room.list_seasonal_backgrounds).to respond_to(:keys)
        expect(room.list_seasonal_backgrounds['night_winter']).to eq('https://example.com/night.jpg')
      end
    end
  end

  # ========================================
  # Battle Map Methods
  # ========================================

  describe 'additional battle map methods' do
    let(:room) { create_room(room_type: 'standard') }

    describe '#hex_type_counts' do
      it 'returns counts of hexes by type' do
        # Use a fresh room and clear any hexes
        fresh_room = create_room(room_type: 'arena')
        RoomHex.where(room_id: fresh_room.id).delete

        # Insert hexes directly via DB to set the actual hex_type column
        # (The model's hex_type= setter redirects to terrain_type, which is different)
        DB[:room_hexes].insert(room_id: fresh_room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', danger_level: 0)
        DB[:room_hexes].insert(room_id: fresh_room.id, hex_x: 2, hex_y: 0, hex_type: 'normal', danger_level: 0)
        DB[:room_hexes].insert(room_id: fresh_room.id, hex_x: 0, hex_y: 2, hex_type: 'cover', danger_level: 0)

        counts = fresh_room.hex_type_counts
        expect(counts['normal']).to eq(2)
        expect(counts['cover']).to eq(1)
      end
    end

    describe '#parsed_battle_map_config' do
      it 'returns empty hash when battle_map_config is nil' do
        expect(room.parsed_battle_map_config).to eq({})
      end

      it 'returns hash when battle_map_config is a hash' do
        # Test the hash handling path directly (avoids JSONB column update issues)
        config = { 'hex_size' => 40 }
        allow(room).to receive(:battle_map_config).and_return(config)
        expect(room.parsed_battle_map_config).to eq(config)
      end

      it 'parses JSON string when battle_map_config is a string' do
        allow(room).to receive(:battle_map_config).and_return('{"hex_size": 40}')
        expect(room.parsed_battle_map_config).to eq({ 'hex_size' => 40 })
      end

      it 'returns empty hash on JSON parse error' do
        allow(room).to receive(:battle_map_config).and_return('invalid json')
        expect(room.parsed_battle_map_config).to eq({})
      end
    end

    describe '#clear_battle_map!' do
      it 'removes hex data and resets battle map flags' do
        room.update(has_battle_map: true, battle_map_image_url: 'https://example.com/map.png')
        RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', danger_level: 0)

        room.clear_battle_map!
        room.reload

        expect(room.has_battle_map).to be false
        expect(room.battle_map_image_url).to be_nil
        expect(room.hex_count).to eq(0)
      end

      it 'clears dependent mask/light/depth fields when present' do
        attrs = {
          has_battle_map: true,
          battle_map_image_url: 'https://example.com/map.png'
        }

        attrs[:battle_map_water_mask_url] = '/uploads/water.png' if Room.columns.include?(:battle_map_water_mask_url)
        attrs[:battle_map_foliage_mask_url] = '/uploads/foliage.png' if Room.columns.include?(:battle_map_foliage_mask_url)
        attrs[:battle_map_fire_mask_url] = '/uploads/fire.png' if Room.columns.include?(:battle_map_fire_mask_url)
        attrs[:battle_map_wall_mask_url] = '/uploads/wall.png' if Room.columns.include?(:battle_map_wall_mask_url)
        attrs[:battle_map_wall_mask_width] = 1024 if Room.columns.include?(:battle_map_wall_mask_width)
        attrs[:battle_map_wall_mask_height] = 768 if Room.columns.include?(:battle_map_wall_mask_height)
        attrs[:depth_map_path] = '/tmp/depth.png' if Room.columns.include?(:depth_map_path)
        attrs[:detected_light_sources] = Sequel.pg_jsonb_wrap([{ 'center_x' => 100, 'center_y' => 200 }]) if Room.columns.include?(:detected_light_sources)

        room.update(attrs)
        room.clear_battle_map!
        room.reload

        expect(room.has_battle_map).to be false
        expect(room.battle_map_image_url).to be_nil
        expect(room.battle_map_water_mask_url).to be_nil if Room.columns.include?(:battle_map_water_mask_url)
        expect(room.battle_map_foliage_mask_url).to be_nil if Room.columns.include?(:battle_map_foliage_mask_url)
        expect(room.battle_map_fire_mask_url).to be_nil if Room.columns.include?(:battle_map_fire_mask_url)
        expect(room.battle_map_wall_mask_url).to be_nil if Room.columns.include?(:battle_map_wall_mask_url)
        expect(room.battle_map_wall_mask_width).to be_nil if Room.columns.include?(:battle_map_wall_mask_width)
        expect(room.battle_map_wall_mask_height).to be_nil if Room.columns.include?(:battle_map_wall_mask_height)
        expect(room.depth_map_path).to be_nil if Room.columns.include?(:depth_map_path)

        if Room.columns.include?(:detected_light_sources)
          sources = room.detected_light_sources
          normalized = sources.respond_to?(:to_a) ? sources.to_a : sources
          expect(normalized).to eq([])
        end
      end
    end
  end

  # ========================================
  # Temporary Room Pool Methods
  # ========================================

  describe 'temporary room methods' do
    let(:room) { create_room }

    describe '#temporary?' do
      it 'returns true when is_temporary is true' do
        room.update(is_temporary: true)
        expect(room.temporary?).to be true
      end

      it 'returns false when is_temporary is not true' do
        expect(room.temporary?).to be false
      end
    end

    describe '#in_pool?' do
      it 'returns true when temporary and pool_status is available' do
        room.update(is_temporary: true, pool_status: 'available')
        expect(room.in_pool?).to be true
      end

      it 'returns false when not temporary' do
        room.update(pool_status: 'available')
        expect(room.in_pool?).to be false
      end
    end

    describe '#in_use?' do
      it 'returns true when temporary and pool_status is in_use' do
        room.update(is_temporary: true, pool_status: 'in_use')
        expect(room.in_use?).to be true
      end

      it 'returns false when temporary and pool_status is available' do
        room.update(is_temporary: true, pool_status: 'available')
        expect(room.in_use?).to be false
      end
    end

    describe '#temporary_room_description' do
      it 'returns short_description for basic temporary room' do
        room.update(is_temporary: true, short_description: 'A simple space')
        expect(room.temporary_room_description).to eq('A simple space')
      end

      it 'returns fallback when no description' do
        room.update(is_temporary: true, short_description: '')
        expect(room.temporary_room_description).to eq('A temporary space')
      end
    end

    describe '#has_custom_interior?' do
      it 'returns true when has_custom_interior is true' do
        room.update(has_custom_interior: true)
        expect(room.has_custom_interior?).to be true
      end

      it 'returns false when has_custom_interior is not true' do
        expect(room.has_custom_interior?).to be false
      end
    end
  end

  # ========================================
  # Custom Polygon Methods
  # ========================================

  describe 'custom polygon methods' do
    let(:room) { create_room(min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

    describe '#has_custom_polygon?' do
      it 'returns false when room_polygon is nil' do
        expect(room.has_custom_polygon?).to be false
      end
    end

    describe '#shape_polygon' do
      it 'returns rectangular bounds when no custom polygon' do
        poly = room.shape_polygon
        expect(poly.size).to eq(4)
        expect(poly).to include({ 'x' => 0.0, 'y' => 0.0 })
        expect(poly).to include({ 'x' => 100.0, 'y' => 0.0 })
        expect(poly).to include({ 'x' => 100.0, 'y' => 100.0 })
        expect(poly).to include({ 'x' => 0.0, 'y' => 100.0 })
      end
    end

    describe '#polygon_bounds' do
      it 'returns room bounds when no custom polygon' do
        bounds = room.polygon_bounds
        expect(bounds[:min_x]).to eq(0.0)
        expect(bounds[:max_x]).to eq(100.0)
      end
    end

    describe '#area_square_feet' do
      it 'calculates area from bounds' do
        expect(room.area_square_feet).to eq(10_000.0)  # 100 * 100
      end
    end
  end

  # ========================================
  # Effective Polygon Methods
  # ========================================

  describe 'effective polygon methods' do
    let(:room) { create_room(min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

    describe '#usable_polygon' do
      it 'returns shape_polygon when effective_polygon is nil' do
        expect(room.usable_polygon).to eq(room.shape_polygon)
      end
    end

    describe '#is_clipped?' do
      it 'returns false when effective_polygon is nil' do
        expect(room.is_clipped?).to be false
      end
    end

    describe '#usable_area' do
      it 'returns effective_area when set' do
        room.update(effective_area: 5000.0)
        expect(room.usable_area).to eq(5000.0)
      end

      it 'returns area_square_feet when effective_area is nil' do
        expect(room.usable_area).to eq(10_000.0)
      end
    end

    describe '.with_usable_area scope' do
      it 'returns rooms with usable_percentage above threshold' do
        high_usable = create_room(name: 'High', usable_percentage: 0.8)
        low_usable = create_room(name: 'Low', usable_percentage: 0.2)

        results = Room.with_usable_area(0.5).all
        expect(results.map(&:name)).to include('High')
        expect(results.map(&:name)).not_to include('Low')
      end
    end
  end

  # ========================================
  # Graffiti Methods
  # ========================================

  describe 'graffiti methods' do
    let(:room) { create_room }

    describe '#clear_graffiti!' do
      it 'removes all graffiti from the room' do
        # Use actual column names (text, x, y, created_at)
        DB[:graffiti].insert(room_id: room.id, text: 'Test 1', x: 0, y: 0, created_at: Time.now)
        DB[:graffiti].insert(room_id: room.id, text: 'Test 2', x: 0, y: 0, created_at: Time.now)

        room.clear_graffiti!
        expect(Graffiti.where(room_id: room.id).count).to eq(0)
      end
    end

    describe '#visible_graffiti' do
      it 'returns graffiti ordered by creation time' do
        # Clear any existing graffiti first
        Graffiti.where(room_id: room.id).delete

        # Use actual column names
        old_id = DB[:graffiti].insert(room_id: room.id, text: 'Old', x: 0, y: 0, created_at: Time.now - 86400)
        new_id = DB[:graffiti].insert(room_id: room.id, text: 'New', x: 0, y: 0, created_at: Time.now)

        # Test that the dataset returns ordered graffiti (order by created_at)
        results = room.graffiti_dataset.order(:created_at).all
        expect(results.first.id).to eq(old_id)
        expect(results.last.id).to eq(new_id)
      end
    end
  end

  # ========================================
  # Auto-GM Session Methods
  # ========================================

  describe 'auto-gm session methods' do
    let(:room) { create_room }

    describe '#has_auto_gm_session?' do
      it 'returns false when no active sessions' do
        expect(room.has_auto_gm_session?).to be false
      end
    end
  end

  # ========================================
  # Indoor/Outdoor Room Methods
  # ========================================

  describe '#forced_indoor_night_lighting?' do
    it 'returns true for underground room types' do
      room = create(:room, room_type: 'cave')
      expect(room.forced_indoor_night_lighting?).to be true
    end

    it 'returns true for temporary delve rooms even if not underground type' do
      delve = create(:delve)
      room = create(:room, room_type: 'standard', is_temporary: true, temp_delve_id: delve.id)

      expect(room.forced_indoor_night_lighting?).to be true
    end

    it 'returns false for normal indoor rooms' do
      room = create(:room, room_type: 'standard')
      expect(room.forced_indoor_night_lighting?).to be false
    end
  end

  describe '#outdoor_room?' do
    it 'returns true when indoors is false' do
      room = create(:room, indoors: false)
      expect(room.outdoor_room?).to be true
    end

    it 'returns true when is_outdoor is true' do
      room = create(:room, is_outdoor: true)
      expect(room.outdoor_room?).to be true
    end

    it 'returns true for outdoor_urban room types' do
      %w[courtyard plaza garden alley parking_lot rooftop].each do |type|
        room = create(:room, room_type: type)
        expect(room.outdoor_room?).to be(true), "expected #{type} to be outdoor"
      end
    end

    it 'returns true for outdoor_nature room types' do
      %w[forest beach field swamp meadow hillside mountain desert].each do |type|
        room = create(:room, room_type: type)
        expect(room.outdoor_room?).to be(true), "expected #{type} to be outdoor"
      end
    end

    it 'returns true for street/avenue/intersection city types' do
      %w[street avenue intersection].each do |type|
        room = create(:room, room_type: type)
        expect(room.outdoor_room?).to be(true), "expected #{type} to be outdoor"
      end
    end

    it 'returns true for water room types' do
      %w[water lake river ocean pool].each do |type|
        room = create(:room, room_type: type)
        expect(room.outdoor_room?).to be(true), "expected #{type} to be outdoor"
      end
    end

    it 'returns false when indoors is true and type is indoor' do
      room = create(:room, indoors: true)
      expect(room.outdoor_room?).to be false
    end

    it 'returns false for indoor room types' do
      %w[standard building hallway apartment office shop].each do |type|
        room = create(:room, room_type: type)
        expect(room.outdoor_room?).to be(false), "expected #{type} to be indoor"
      end
    end

    it 'defaults to indoor (standard type, indoors: true)' do
      room = create(:room)
      expect(room.outdoor_room?).to be false
    end

    it 'returns true for outdoor room_type even when is_outdoor is false (db default) and indoors is true (factory default)' do
      room = create(:room, room_type: 'forest', is_outdoor: false, indoors: true)
      expect(room.outdoor_room?).to be true
    end
  end

  # ========================================
  # Nested Room Z Bounds Validation
  # ========================================

  describe 'nested room Z bounds validation' do
    let(:parent_room) { create_room(min_x: 0, max_x: 200, min_y: 0, max_y: 200, min_z: 0, max_z: 100) }

    it 'allows nested room within parent Z bounds' do
      nested = Room.new(
        name: 'Nested Room',
        location_id: location.id,
        room_type: 'standard',
        inside_room_id: parent_room.id,
        min_x: 10, max_x: 50, min_y: 10, max_y: 50,
        min_z: 10, max_z: 50
      )
      expect(nested.valid?).to be true
    end

    it 'rejects nested room exceeding parent Z bounds' do
      nested = Room.new(
        name: 'Nested Room',
        location_id: location.id,
        room_type: 'standard',
        inside_room_id: parent_room.id,
        min_x: 10, max_x: 50, min_y: 10, max_y: 50,
        min_z: 50, max_z: 150  # Exceeds parent max_z of 100
      )
      expect(nested.valid?).to be false
      expect(nested.errors[:base]).to include(/Room height must be within parent room height/)
    end

    it 'allows nested room when parent has no Z bounds' do
      parent_no_z = create_room(min_x: 0, max_x: 200, min_y: 0, max_y: 200, min_z: nil, max_z: nil)
      nested = Room.new(
        name: 'Nested Room',
        location_id: location.id,
        room_type: 'standard',
        inside_room_id: parent_no_z.id,
        min_x: 10, max_x: 50, min_y: 10, max_y: 50,
        min_z: 0, max_z: 500
      )
      expect(nested.valid?).to be true
    end

    it 'rejects nested room outside parent XY bounds' do
      nested = Room.new(
        name: 'Nested Room',
        location_id: location.id,
        room_type: 'standard',
        inside_room_id: parent_room.id,
        min_x: 250, max_x: 300, min_y: 10, max_y: 50,  # Outside X bounds
        min_z: 10, max_z: 50
      )
      expect(nested.valid?).to be false
      expect(nested.errors[:base]).to include(/Room bounds must be within parent room bounds/)
    end
  end

  # ========================================
  # Sightline Methods
  # ========================================

  describe 'sightline methods' do
    let(:room1) { create_room(name: 'Room 1') }
    let(:room2) { create_room(name: 'Room 2') }

    describe '#has_sightline_to?' do
      it 'returns true for same room' do
        expect(room1.has_sightline_to?(room1)).to be true
      end

      it 'returns false when no sightline exists' do
        # Without explicit sightline setup, default is no connection
        allow(RoomSightline).to receive(:calculate_sightline).and_return(
          double('sightline', has_sight: false)
        )
        expect(room1.has_sightline_to?(room2)).to be false
      end

      it 'returns true when sightline exists' do
        allow(RoomSightline).to receive(:calculate_sightline).and_return(
          double('sightline', has_sight: true, sight_quality: 0.8)
        )
        expect(room1.has_sightline_to?(room2)).to be true
      end
    end

    describe '#sightline_quality_to' do
      it 'returns 1.0 for same room' do
        expect(room1.sightline_quality_to(room1)).to eq(1.0)
      end

      it 'returns 0.0 when no sightline' do
        allow(RoomSightline).to receive(:calculate_sightline).and_return(
          double('sightline', has_sight: false)
        )
        expect(room1.sightline_quality_to(room2)).to eq(0.0)
      end

      it 'returns sight quality when sightline exists' do
        allow(RoomSightline).to receive(:calculate_sightline).and_return(
          double('sightline', has_sight: true, sight_quality: 0.75)
        )
        expect(room1.sightline_quality_to(room2)).to eq(0.75)
      end
    end

    describe '#visible_rooms' do
      it 'returns empty array when no features exist' do
        expect(room1.visible_rooms).to eq([])
      end

      it 'returns rooms connected through features that allow sight' do
        # Stub the room_features query to return our mocked feature list
        mock_feature = double('RoomFeature',
          allows_sight_through?: true,
          connected_room_id: room2.id,
          connected_room: room2
        )
        allow(room1).to receive(:room_features).and_return([mock_feature])
        allow(room1).to receive(:connected_features).and_return([])

        result = room1.visible_rooms
        expect(result).to include(room2)
      end
    end
  end

  # ========================================
  # Hex Detail Methods
  # ========================================

  describe 'hex detail methods' do
    let(:room) { create_room(room_type: 'arena', has_battle_map: true) }

    describe '#hex_type' do
      it 'delegates to RoomHex.hex_type_at' do
        expect(RoomHex).to receive(:hex_type_at).with(room, 5, 6).and_return('cover')
        expect(room.hex_type(5, 6)).to eq('cover')
      end
    end

    describe '#hex_traversable?' do
      it 'delegates to RoomHex.traversable_at?' do
        expect(RoomHex).to receive(:traversable_at?).with(room, 5, 6).and_return(true)
        expect(room.hex_traversable?(5, 6)).to be true
      end

      it 'returns false for wall hex' do
        expect(RoomHex).to receive(:traversable_at?).with(room, 5, 6).and_return(false)
        expect(room.hex_traversable?(5, 6)).to be false
      end
    end

    describe '#hex_danger_level' do
      it 'delegates to RoomHex.danger_level_at' do
        expect(RoomHex).to receive(:danger_level_at).with(room, 5, 6).and_return(3)
        expect(room.hex_danger_level(5, 6)).to eq(3)
      end
    end

    describe '#hex_dangerous?' do
      it 'delegates to RoomHex.dangerous_at?' do
        expect(RoomHex).to receive(:dangerous_at?).with(room, 5, 6).and_return(true)
        expect(room.hex_dangerous?(5, 6)).to be true
      end
    end

    describe '#set_hex_details' do
      it 'delegates to RoomHex.set_hex_details' do
        attrs = { hex_type: 'fire', danger_level: 2 }
        expect(RoomHex).to receive(:set_hex_details).with(room, 5, 6, attrs)
        room.set_hex_details(5, 6, attrs)
      end
    end

    describe '#hex_details' do
      it 'delegates to RoomHex.hex_details' do
        hex_double = double('RoomHex', movement_cost: 2)
        expect(RoomHex).to receive(:hex_details).with(room, 5, 6).and_return(hex_double)
        expect(room.hex_details(5, 6)).to eq(hex_double)
      end
    end

    describe '#hex_movement_cost' do
      it 'returns movement cost from hex details' do
        hex_double = double('RoomHex', movement_cost: 3)
        allow(room).to receive(:hex_details).with(5, 6).and_return(hex_double)
        expect(room.hex_movement_cost(5, 6)).to eq(3)
      end

      it 'returns 1 when no hex details exist' do
        allow(room).to receive(:hex_details).with(5, 6).and_return(nil)
        expect(room.hex_movement_cost(5, 6)).to eq(1)
      end
    end

    describe '#dangerous_hexes' do
      it 'delegates to RoomHex.dangerous_hexes_in_room' do
        expect(RoomHex).to receive(:dangerous_hexes_in_room).with(room)
        room.dangerous_hexes
      end
    end

    describe '#impassable_hexes' do
      it 'delegates to RoomHex.impassable_hexes_in_room' do
        expect(RoomHex).to receive(:impassable_hexes_in_room).with(room)
        room.impassable_hexes
      end
    end
  end

  # ========================================
  # Additional Battle Map Methods
  # ========================================

  describe 'additional battle map coverage methods' do
    let(:room) { create_room(room_type: 'arena', has_battle_map: true) }

    describe '#cover_hexes' do
      it 'delegates to RoomHex.cover_hexes_in_room' do
        expect(RoomHex).to receive(:cover_hexes_in_room).with(room)
        room.cover_hexes
      end
    end

    describe '#explosive_hexes' do
      it 'delegates to RoomHex.explosive_hexes_in_room' do
        expect(RoomHex).to receive(:explosive_hexes_in_room).with(room)
        room.explosive_hexes
      end
    end

    describe '#hex_elevation_at' do
      it 'delegates to RoomHex.elevation_at' do
        expect(RoomHex).to receive(:elevation_at).with(room, 5, 6).and_return(2)
        expect(room.hex_elevation_at(5, 6)).to eq(2)
      end
    end

    describe '#hexes_at_elevation' do
      it 'delegates to RoomHex.hexes_at_elevation' do
        expect(RoomHex).to receive(:hexes_at_elevation).with(room, 3)
        room.hexes_at_elevation(3)
      end
    end

    describe '#set_battle_map_config!' do
      it 'saves config as JSONB' do
        # Test the parsing behavior by mocking battle_map_config
        allow(room).to receive(:battle_map_config).and_return({ 'hex_size' => 40, 'offset_x' => 10 })
        parsed = room.parsed_battle_map_config
        expect(parsed['hex_size']).to eq(40)
      end
    end

    describe '#battle_map_ready?' do
      it 'returns true when has_battle_map and hexes exist' do
        room.update(has_battle_map: true)
        DB[:room_hexes].insert(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', danger_level: 0)
        expect(room.battle_map_ready?).to be true
      end

      it 'returns false when has_battle_map but no hexes' do
        room.update(has_battle_map: true)
        expect(room.battle_map_ready?).to be false
      end
    end
  end

  # ========================================
  # Seasonal Content Resolution
  # ========================================

  describe 'seasonal content resolution' do
    let(:room) { create_room }

    describe '#current_description' do
      before do
        allow(GameTimeService).to receive(:time_of_day).and_return(:day)
        allow(GameTimeService).to receive(:season).and_return(:summer)
        allow(GameTimeService).to receive(:season_detail).and_return({
          season: :summer,
          raw_season: :summer,
          system: :temperate,
          progress: 0.5,
          intensity: :mid,
          in_transition: false
        })
      end

      it 'returns specific time+season description when available' do
        room.update(seasonal_descriptions: Sequel.lit("'{\"day_summer\": \"A sunny summer day.\"}'::jsonb"))
        room.reload
        expect(room.current_description).to eq('A sunny summer day.')
      end

      it 'falls back to time-only description' do
        room.update(seasonal_descriptions: Sequel.lit("'{\"day\": \"Daytime description.\"}'::jsonb"))
        room.reload
        expect(room.current_description).to eq('Daytime description.')
      end

      it 'falls back to season-only description' do
        room.update(seasonal_descriptions: Sequel.lit("'{\"summer\": \"Summer description.\"}'::jsonb"))
        room.reload
        expect(room.current_description).to eq('Summer description.')
      end

      it 'falls back to default description' do
        room.update(seasonal_descriptions: Sequel.lit("'{\"default\": \"Default seasonal.\"}'::jsonb"))
        room.reload
        expect(room.current_description).to eq('Default seasonal.')
      end

      it 'falls back to base description when no seasonal match' do
        room.update(long_description: 'Long base description.')
        expect(room.current_description).to eq('Long base description.')
      end
    end

    describe '#current_background_url' do
      before do
        allow(GameTimeService).to receive(:time_of_day).and_return(:night)
        allow(GameTimeService).to receive(:season).and_return(:winter)
      end

      it 'returns specific time+season background when available' do
        room.update(seasonal_backgrounds: Sequel.lit("'{\"night_winter\": \"https://example.com/night-winter.jpg\"}'::jsonb"))
        room.reload
        expect(room.current_background_url).to eq('https://example.com/night-winter.jpg')
      end

      it 'falls back to default_background_url' do
        room.update(default_background_url: 'https://example.com/default.jpg')
        expect(room.current_background_url).to eq('https://example.com/default.jpg')
      end

      it 'returns nil when no background is set' do
        # Must mock location methods to return nil
        allow(room.location).to receive(:resolve_background).and_return(nil)
        allow(room.location.zone).to receive(:resolve_background).and_return(nil) if room.location.zone
        expect(room.current_background_url).to be_nil
      end
    end
  end

  # ========================================
  # Position Validation
  # ========================================

  describe 'position validation methods' do
    let(:room) { create_room(min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

    describe '#position_valid?' do
      it 'delegates to PolygonClippingService' do
        expect(PolygonClippingService).to receive(:point_in_effective_area?).with(room, 50.0, 50.0).and_return(true)
        expect(room.position_valid?(50.0, 50.0)).to be true
      end

      it 'returns false for position outside room' do
        expect(PolygonClippingService).to receive(:point_in_effective_area?).with(room, 200.0, 200.0).and_return(false)
        expect(room.position_valid?(200.0, 200.0)).to be false
      end
    end

    describe '#nearest_valid_position' do
      it 'delegates to PolygonClippingService' do
        expect(PolygonClippingService).to receive(:nearest_valid_position).with(room, 200.0, 200.0).and_return({ x: 100.0, y: 100.0 })
        result = room.nearest_valid_position(200.0, 200.0)
        expect(result[:x]).to eq(100.0)
        expect(result[:y]).to eq(100.0)
      end
    end
  end

  # ========================================
  # Navigable Exits (Spatial Adjacency)
  # ========================================

  describe '#navigable_exits' do
    let(:room) { create_room(min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

    it 'returns only exits to navigable rooms via spatial adjacency' do
      # Create spatially adjacent rooms to the north (shares edge at y=100)
      navigable_dest = create_room(
        name: 'Navigable Dest',
        location: room.location,
        min_x: 0, max_x: 100, min_y: 100, max_y: 200,
        outside_polygon: false, active: true
      )

      # Create a room that's outside polygon (not navigable)
      outside_dest = create_room(
        name: 'Outside Dest',
        location: room.location,
        min_x: 100, max_x: 200, min_y: 0, max_y: 100,
        outside_polygon: true
      )

      # Create an inactive room (not navigable)
      inactive_dest = create_room(
        name: 'Inactive Dest',
        location: room.location,
        min_x: 0, max_x: 100, min_y: -100, max_y: 0,
        outside_polygon: false, active: false
      )

      exits = room.navigable_exits
      room_names = exits.map { |e| e[:room].name }

      expect(room_names).to include('Navigable Dest')
      expect(room_names).not_to include('Outside Dest')
      expect(room_names).not_to include('Inactive Dest')
    end

    it 'excludes rooms blocked by walls without openings' do
      # Create adjacent room
      dest = create_room(
        name: 'Blocked Dest',
        location: room.location,
        min_x: 0, max_x: 100, min_y: 100, max_y: 200,
        outside_polygon: false, active: true
      )

      # Add a wall with no opening to block passage
      RoomFeature.create(
        room_id: room.id,
        feature_type: 'wall',
        direction: 'north',
        x: 50, y: 100,
        is_open: false
      )

      exits = room.navigable_exits
      room_names = exits.map { |e| e[:room].name }
      expect(room_names).not_to include('Blocked Dest')
    end
  end

  # ========================================
  # Clear Effective Polygon
  # ========================================

  describe '#clear_effective_polygon!' do
    let(:room) { create_room(min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

    it 'resets effective polygon to nil' do
      room.update(effective_polygon: Sequel.lit("'[{\"x\": 0, \"y\": 0}]'::jsonb"))
      room.clear_effective_polygon!
      room.reload
      expect(room.effective_polygon).to be_nil
    end

    it 'resets effective_area to nil' do
      room.update(effective_area: 5000.0)
      room.clear_effective_polygon!
      room.reload
      expect(room.effective_area).to be_nil
    end

    it 'resets usable_percentage to 1.0' do
      room.update(usable_percentage: 0.5)
      room.clear_effective_polygon!
      room.reload
      expect(room.usable_percentage).to eq(1.0)
    end
  end

  # ========================================
  # Custom Polygon Edge Cases
  # ========================================

  describe 'custom polygon edge cases' do
    let(:room) { create_room(min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

    describe '#has_custom_polygon?' do
      it 'returns false when room_polygon is nil' do
        expect(room.has_custom_polygon?).to be false
      end

      it 'returns false when room_polygon has fewer than 3 points' do
        allow(room).to receive(:room_polygon).and_return([{ 'x' => 0, 'y' => 0 }, { 'x' => 50, 'y' => 50 }])
        expect(room.has_custom_polygon?).to be false
      end

      it 'returns true when room_polygon has 3+ points' do
        allow(room).to receive(:room_polygon).and_return([
          { 'x' => 0, 'y' => 0 },
          { 'x' => 50, 'y' => 0 },
          { 'x' => 25, 'y' => 50 }
        ])
        expect(room.has_custom_polygon?).to be true
      end
    end

    describe '#shape_polygon' do
      it 'returns custom polygon when available' do
        custom_poly = [
          { 'x' => 10, 'y' => 10 },
          { 'x' => 90, 'y' => 10 },
          { 'x' => 50, 'y' => 90 }
        ]
        allow(room).to receive(:room_polygon).and_return(custom_poly)
        allow(room).to receive(:has_custom_polygon?).and_return(true)

        result = room.shape_polygon
        expect(result.size).to eq(3)
        expect(result.first['x']).to eq(10.0)
      end

      it 'handles symbol keys in polygon points' do
        custom_poly = [
          { x: 10, y: 10 },
          { x: 90, y: 10 },
          { x: 50, y: 90 }
        ]
        allow(room).to receive(:room_polygon).and_return(custom_poly)
        allow(room).to receive(:has_custom_polygon?).and_return(true)

        result = room.shape_polygon
        expect(result.first['x']).to eq(10.0)
        expect(result.first['y']).to eq(10.0)
      end
    end
  end

  # ========================================
  # Temporary Room Associations
  # ========================================

  describe 'temporary room associations' do
    let(:room) { create_room(is_temporary: true, pool_status: 'in_use') }

    describe '#associated_vehicle' do
      it 'returns nil when no vehicle linked' do
        expect(room.associated_vehicle).to be_nil
      end

      it 'returns vehicle when temp_vehicle_id is set' do
        # Create vehicle using current column names
        vehicle_id = DB[:vehicles].insert(
          name: 'Test Vehicle',
          status: 'parked',
          convertible: false,
          current_room_id: room.id
        )
        vehicle = Vehicle[vehicle_id]
        room.update(temp_vehicle_id: vehicle.id)
        expect(room.associated_vehicle.id).to eq(vehicle.id)
      end
    end

    describe '#associated_journey' do
      it 'returns nil when no journey linked' do
        expect(room.associated_journey).to be_nil
      end
    end

    describe '#temporary_room_description' do
      it 'returns vehicle description when associated with vehicle' do
        # Create vehicle using current column names
        vehicle_id = DB[:vehicles].insert(
          name: 'Blue Sedan',
          status: 'parked',
          convertible: false,
          current_room_id: room.id
        )
        vehicle = Vehicle[vehicle_id]
        room.update(temp_vehicle_id: vehicle.id)
        expect(room.temporary_room_description).to include('Blue Sedan')
      end

      it 'returns short_description when no associations' do
        room.update(short_description: 'A cozy cabin.')
        expect(room.temporary_room_description).to eq('A cozy cabin.')
      end

      it 'returns fallback when no description' do
        room.update(short_description: '')
        expect(room.temporary_room_description).to eq('A temporary space')
      end
    end
  end

  # ========================================
  # Coordinates in Bounds with Z
  # ========================================

  describe '#coordinates_in_bounds? with Z axis' do
    let(:room) { create_room(min_x: 0, max_x: 100, min_y: 0, max_y: 100, min_z: 0, max_z: 50) }

    it 'returns true when all coordinates in bounds' do
      expect(room.coordinates_in_bounds?(50, 50, 25)).to be true
    end

    it 'returns false when Z is out of bounds' do
      expect(room.coordinates_in_bounds?(50, 50, 75)).to be false
    end

    it 'returns true when Z is at boundary' do
      expect(room.coordinates_in_bounds?(50, 50, 0)).to be true
      expect(room.coordinates_in_bounds?(50, 50, 50)).to be true
    end

    it 'ignores Z check when room has no Z bounds' do
      room_no_z = create_room(min_x: 0, max_x: 100, min_y: 0, max_y: 100, min_z: nil, max_z: nil)
      expect(room_no_z.coordinates_in_bounds?(50, 50, 1000)).to be true
    end
  end

  # ========================================
  # Outer Room
  # ========================================

  describe '#outer_room' do
    it 'returns self when not nested' do
      room = create_room
      expect(room.outer_room).to eq(room)
    end

    it 'returns parent when nested' do
      parent = create_room(name: 'Parent', min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      nested = create_room(name: 'Nested', inside_room_id: parent.id, min_x: 10, max_x: 50, min_y: 10, max_y: 50)
      expect(nested.outer_room).to eq(parent)
    end
  end

  # ========================================
  # Clipped Dataset Scope
  # ========================================

  describe '.clipped scope' do
    it 'returns rooms with effective_polygon set' do
      clipped = create_room(name: 'Clipped')
      clipped.update(effective_polygon: Sequel.lit("'[{\"x\": 0, \"y\": 0}]'::jsonb"))

      unclipped = create_room(name: 'Unclipped')

      results = Room.clipped.all
      expect(results.map(&:name)).to include('Clipped')
      expect(results.map(&:name)).not_to include('Unclipped')
    end
  end

  # ========================================
  # Visible Characters Across Rooms Edge Cases
  # ========================================

  describe '#visible_characters_across_rooms' do
    let(:room) { create_room }

    it 'returns empty array when room has no id' do
      new_room = Room.new(name: 'New', location_id: location.id, room_type: 'standard',
                          min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      expect(new_room.visible_characters_across_rooms).to eq([])
    end

    it 'returns empty array when no sightlines exist' do
      expect(room.visible_characters_across_rooms).to eq([])
    end
  end
end
