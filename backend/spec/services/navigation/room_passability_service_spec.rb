# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomPassabilityService do
  let(:location) { create(:location) }

  describe '.can_pass?' do
    context 'outdoor to outdoor' do
      it 'always allows passage' do
        room_a = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 100, max_y: 200)

        expect(described_class.can_pass?(room_a, room_b, :north)).to be true
      end
    end

    context 'indoor to indoor' do
      it 'blocks passage when wall exists without opening' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')

        expect(described_class.can_pass?(room_a, room_b, :north)).to be false
      end

      it 'allows passage when door exists in wall direction and is open' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')
        create(:room_feature, room: room_a, feature_type: 'door', direction: 'north', is_open: true)

        expect(described_class.can_pass?(room_a, room_b, :north)).to be true
      end

      it 'blocks passage when door is closed' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')
        create(:room_feature, room: room_a, feature_type: 'door', direction: 'north', is_open: false)

        expect(described_class.can_pass?(room_a, room_b, :north)).to be false
      end

      it 'allows passage through archway' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')
        create(:room_feature, room: room_a, feature_type: 'archway', direction: 'north')

        expect(described_class.can_pass?(room_a, room_b, :north)).to be true
      end

      it 'allows passage through opening' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')
        create(:room_feature, room: room_a, feature_type: 'opening', direction: 'north')

        expect(described_class.can_pass?(room_a, room_b, :north)).to be true
      end

      it 'allows passage when no wall exists (open plan)' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        # No wall feature

        expect(described_class.can_pass?(room_a, room_b, :north)).to be true
      end

      it 'allows passage through open gate' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')
        create(:room_feature, room: room_a, feature_type: 'gate', direction: 'north', is_open: true)

        expect(described_class.can_pass?(room_a, room_b, :north)).to be true
      end

      it 'blocks passage through closed gate' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')
        create(:room_feature, room: room_a, feature_type: 'gate', direction: 'north', is_open: false)

        expect(described_class.can_pass?(room_a, room_b, :north)).to be false
      end

      it 'allows passage through open hatch' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')
        create(:room_feature, room: room_a, feature_type: 'hatch', direction: 'north', is_open: true)

        expect(described_class.can_pass?(room_a, room_b, :north)).to be true
      end

      it 'allows passage through open portal' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')
        create(:room_feature, room: room_a, feature_type: 'portal', direction: 'north', is_open: true)

        expect(described_class.can_pass?(room_a, room_b, :north)).to be true
      end
    end

    context 'mixed indoor/outdoor' do
      it 'requires opening when going from indoor to outdoor with wall' do
        room_indoor = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_outdoor = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_indoor, feature_type: 'wall', direction: 'north')

        expect(described_class.can_pass?(room_indoor, room_outdoor, :north)).to be false
      end

      it 'allows passage from indoor to outdoor with open door' do
        room_indoor = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_outdoor = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_indoor, feature_type: 'wall', direction: 'north')
        create(:room_feature, room: room_indoor, feature_type: 'door', direction: 'north', is_open: true)

        expect(described_class.can_pass?(room_indoor, room_outdoor, :north)).to be true
      end

      it 'allows passage from outdoor to indoor without wall' do
        room_outdoor = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_indoor = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        # No wall on outdoor room

        expect(described_class.can_pass?(room_outdoor, room_indoor, :north)).to be true
      end

      it 'blocks passage when destination side has wall and no opening' do
        room_outdoor = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_indoor = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_indoor, feature_type: 'wall', direction: 'south')

        expect(described_class.can_pass?(room_outdoor, room_indoor, :north)).to be false
      end

      it 'allows canonical one-sided connected door for bidirectional passage checks' do
        room_outdoor = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_indoor = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_indoor, feature_type: 'wall', direction: 'south')
        create(:room_feature, room: room_outdoor, feature_type: 'door', direction: 'north',
               connected_room_id: room_indoor.id, is_open: true)

        expect(described_class.can_pass?(room_outdoor, room_indoor, :north)).to be true
      end

      it 'does not use inbound openings from unrelated rooms' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        room_c = create(:room, location: location, indoors: true, min_x: 100, max_x: 200, min_y: 100, max_y: 200)
        create(:room_feature, room: room_b, feature_type: 'wall', direction: 'south')
        create(:room_feature, room: room_c, feature_type: 'door', direction: 'north',
               connected_room_id: room_b.id, is_open: true)

        expect(described_class.can_pass?(room_a, room_b, :north)).to be false
      end
    end

    context 'direction handling' do
      it 'handles string direction' do
        room_a = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 100, max_y: 200)

        expect(described_class.can_pass?(room_a, room_b, 'north')).to be true
      end

      it 'checks correct direction for wall' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        # Wall in a different direction
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'south')

        # Should allow passage north since wall is on south
        expect(described_class.can_pass?(room_a, room_b, :north)).to be true
      end
    end

    context 'windows' do
      it 'does not allow passage through window even if open' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')
        create(:room_feature, room: room_a, feature_type: 'window', direction: 'north', is_open: true)

        expect(described_class.can_pass?(room_a, room_b, :north)).to be false
      end
    end
  end

  describe '.wall_in_direction?' do
    it 'returns true when wall exists in direction' do
      room = create(:room, location: location)
      create(:room_feature, room: room, feature_type: 'wall', direction: 'north')

      expect(described_class.wall_in_direction?(room, :north)).to be true
    end

    it 'returns false when no wall exists in direction' do
      room = create(:room, location: location)
      create(:room_feature, room: room, feature_type: 'wall', direction: 'south')

      expect(described_class.wall_in_direction?(room, :north)).to be false
    end

    it 'returns false when no features exist' do
      room = create(:room, location: location)

      expect(described_class.wall_in_direction?(room, :north)).to be false
    end
  end

  describe '.opening_in_direction?' do
    it 'returns true for open door' do
      room = create(:room, location: location)
      create(:room_feature, room: room, feature_type: 'door', direction: 'north', is_open: true)

      expect(described_class.opening_in_direction?(room, :north)).to be true
    end

    it 'returns false for closed door' do
      room = create(:room, location: location)
      create(:room_feature, room: room, feature_type: 'door', direction: 'north', is_open: false)

      expect(described_class.opening_in_direction?(room, :north)).to be false
    end

    it 'returns true for archway regardless of is_open' do
      room = create(:room, location: location)
      create(:room_feature, room: room, feature_type: 'archway', direction: 'north', is_open: false)

      expect(described_class.opening_in_direction?(room, :north)).to be true
    end

    it 'returns true for opening regardless of is_open' do
      room = create(:room, location: location)
      create(:room_feature, room: room, feature_type: 'opening', direction: 'north', is_open: false)

      expect(described_class.opening_in_direction?(room, :north)).to be true
    end

    it 'returns false when no openings exist' do
      room = create(:room, location: location)
      create(:room_feature, room: room, feature_type: 'wall', direction: 'north')

      expect(described_class.opening_in_direction?(room, :north)).to be false
    end

    it 'ignores openings in different directions' do
      room = create(:room, location: location)
      create(:room_feature, room: room, feature_type: 'door', direction: 'south', is_open: true)

      expect(described_class.opening_in_direction?(room, :north)).to be false
    end
  end

  describe 'cross-room feature visibility' do
    context 'when door is defined on the adjacent room' do
      it 'allows passage through open door defined on adjacent room' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_b, feature_type: 'wall', direction: 'south')
        create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
               connected_room_id: room_b.id, is_open: true)

        expect(described_class.can_pass?(room_b, room_a, :south)).to be true
      end

      it 'blocks passage through closed door defined on adjacent room' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_b, feature_type: 'wall', direction: 'south')
        create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
               connected_room_id: room_b.id, is_open: false)

        expect(described_class.can_pass?(room_b, room_a, :south)).to be false
      end

      it 'allows passage through archway defined on adjacent room' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_b, feature_type: 'wall', direction: 'south')
        create(:room_feature, room: room_a, feature_type: 'archway', direction: 'north',
               connected_room_id: room_b.id)

        expect(described_class.can_pass?(room_b, room_a, :south)).to be true
      end

      it 'does not allow passage through window defined on adjacent room' do
        room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_b, feature_type: 'wall', direction: 'south')
        create(:room_feature, room: room_a, feature_type: 'window', direction: 'north',
               connected_room_id: room_b.id, is_open: true)

        expect(described_class.can_pass?(room_b, room_a, :south)).to be false
      end
    end

    describe '.opening_in_direction? with inbound features' do
      it 'finds open door from adjacent room' do
        room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
               connected_room_id: room_b.id, is_open: true)

        expect(described_class.opening_in_direction?(room_b, :south)).to be true
      end

      it 'returns false for closed door from adjacent room' do
        room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
               connected_room_id: room_b.id, is_open: false)

        expect(described_class.opening_in_direction?(room_b, :south)).to be false
      end

      it 'can scope inbound openings to a specific source room' do
        room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
        room_b = create(:room, location: location, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
        room_c = create(:room, location: location, min_x: 100, max_x: 200, min_y: 100, max_y: 200)
        create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
               connected_room_id: room_b.id, is_open: false)
        create(:room_feature, room: room_c, feature_type: 'door', direction: 'north',
               connected_room_id: room_b.id, is_open: true)

        expect(described_class.opening_in_direction?(room_b, :south)).to be true
        expect(described_class.opening_in_direction?(room_b, :south, connected_from_room_id: room_a.id)).to be false
      end
    end
  end
end
