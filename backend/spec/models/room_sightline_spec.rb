# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomSightline do
  let(:from_room) { create(:room, name: 'From Room') }
  let(:to_room) { create(:room, name: 'To Room') }

  describe 'associations' do
    it 'belongs to from_room' do
      sightline = create(:room_sightline, from_room: from_room, to_room: to_room)
      expect(sightline.from_room.id).to eq(from_room.id)
    end

    it 'belongs to to_room' do
      sightline = create(:room_sightline, from_room: from_room, to_room: to_room)
      expect(sightline.to_room.id).to eq(to_room.id)
    end
  end

  describe 'validations' do
    it 'requires from_room_id' do
      sightline = RoomSightline.new(to_room_id: to_room.id, has_sight: true, sight_quality: 0.8)
      expect(sightline.valid?).to be false
      expect(sightline.errors[:from_room_id]).not_to be_empty
    end

    it 'requires to_room_id' do
      sightline = RoomSightline.new(from_room_id: from_room.id, has_sight: true, sight_quality: 0.8)
      expect(sightline.valid?).to be false
      expect(sightline.errors[:to_room_id]).not_to be_empty
    end

    it 'requires has_sight' do
      sightline = RoomSightline.new(from_room_id: from_room.id, to_room_id: to_room.id, sight_quality: 0.8)
      expect(sightline.valid?).to be false
      expect(sightline.errors[:has_sight]).not_to be_empty
    end

    it 'requires sight_quality' do
      sightline = RoomSightline.new(from_room_id: from_room.id, to_room_id: to_room.id, has_sight: true)
      expect(sightline.valid?).to be false
      expect(sightline.errors[:sight_quality]).not_to be_empty
    end

    it 'validates sight_quality is numeric' do
      sightline = RoomSightline.new(
        from_room_id: from_room.id,
        to_room_id: to_room.id,
        has_sight: true,
        sight_quality: 0.8
      )
      expect(sightline.valid?).to be true
    end

    it 'validates sight_quality is numeric' do
      sightline = RoomSightline.new(
        from_room_id: from_room.id,
        to_room_id: to_room.id,
        has_sight: true,
        sight_quality: 0.5
      )
      expect(sightline.valid?).to be true
    end

    it 'allows sight_quality of 0.0' do
      sightline = RoomSightline.new(
        from_room_id: from_room.id,
        to_room_id: to_room.id,
        has_sight: true,
        sight_quality: 0.0
      )
      expect(sightline.valid?).to be true
    end

    it 'allows sight_quality of 1.0' do
      sightline = RoomSightline.new(
        from_room_id: from_room.id,
        to_room_id: to_room.id,
        has_sight: true,
        sight_quality: 1.0
      )
      expect(sightline.valid?).to be true
    end

    it 'prevents sightline to same room' do
      sightline = RoomSightline.new(
        from_room_id: from_room.id,
        to_room_id: from_room.id,
        has_sight: true,
        sight_quality: 0.8
      )
      expect(sightline.valid?).to be false
      expect(sightline.errors[:to_room_id]).not_to be_empty
    end

    it 'is valid with all required fields' do
      sightline = RoomSightline.new(
        from_room_id: from_room.id,
        to_room_id: to_room.id,
        has_sight: true,
        sight_quality: 0.8
      )
      expect(sightline.valid?).to be true
    end
  end

  describe '#allows_sight_between?' do
    let(:sightline) do
      create(:room_sightline, from_room: from_room, to_room: to_room, has_sight: true, sight_quality: 1.0)
    end

    it 'returns false when has_sight is false' do
      sightline.update(has_sight: false)
      expect(sightline.allows_sight_between?(0, 0, 0, 10, 10, 0)).to be false
    end

    it 'returns true for positions within range' do
      expect(sightline.allows_sight_between?(0, 0, 0, 10, 10, 0)).to be true
    end

    it 'returns false for positions beyond range' do
      # Base sight range is 30, so 100 distance should fail
      expect(sightline.allows_sight_between?(0, 0, 0, 100, 0, 0)).to be false
    end

    it 'considers sight_quality in distance calculation' do
      sightline.update(sight_quality: 0.5)
      # With 0.5 quality, effective distance is doubled
      # 20 distance becomes 40 effective, which is > 30 base range
      expect(sightline.allows_sight_between?(0, 0, 0, 20, 0, 0)).to be false
    end

    it 'handles 3D distance' do
      # sqrt(10^2 + 10^2 + 10^2) = sqrt(300) ~= 17.3
      expect(sightline.allows_sight_between?(0, 0, 0, 10, 10, 10)).to be true
    end

    it 'handles zero sight_quality without division by zero' do
      sightline.update(sight_quality: 0.0)
      # When sight_quality is 0, effective_distance should equal distance (no division)
      # Distance of 20 should be within 30 range when quality <= 0 uses distance directly
      expect(sightline.allows_sight_between?(0, 0, 0, 20, 0, 0)).to be true
    end

    it 'handles nil sight_quality by defaulting to 1.0' do
      sightline.this.update(sight_quality: nil)
      sightline.refresh
      # With default quality of 1.0, distance 20 should be within 30 range
      expect(sightline.allows_sight_between?(0, 0, 0, 20, 0, 0)).to be true
    end
  end

  describe '.calculate_sightline' do
    it 'returns existing sightline if present' do
      existing = create(:room_sightline, from_room: from_room, to_room: to_room)

      result = RoomSightline.calculate_sightline(from_room, to_room)

      expect(result.id).to eq(existing.id)
    end

    it 'creates new sightline when none exists' do
      # No connecting features, so should create sightline with no sight
      result = RoomSightline.calculate_sightline(from_room, to_room)

      expect(result).not_to be_nil
      expect(result.from_room_id).to eq(from_room.id)
      expect(result.to_room_id).to eq(to_room.id)
    end

    it 'sets bidirectional to true by default' do
      result = RoomSightline.calculate_sightline(from_room, to_room)
      expect(result.bidirectional).to be true
    end

    context 'with connecting features' do
      let!(:window) do
        create(:room_feature,
               room: from_room,
               connected_room_id: to_room.id,
               allows_sight: true,
               is_open: true,
               sight_range: 50)
      end

      it 'creates sightline with sight when feature allows' do
        result = RoomSightline.calculate_sightline(from_room, to_room)

        expect(result.has_sight).to be true
        expect(result.sight_quality).to eq(0.5) # 50/100
      end
    end

    context 'with closed feature' do
      let!(:closed_window) do
        create(:room_feature,
               room: from_room,
               connected_room_id: to_room.id,
               allows_sight: true,
               is_open: false,
               sight_range: 100)
      end

      it 'creates sightline without sight' do
        result = RoomSightline.calculate_sightline(from_room, to_room)

        expect(result.has_sight).to be false
        expect(result.sight_quality).to eq(0.0)
      end
    end

    context 'with feature exceeding max sight_range' do
      let!(:super_window) do
        create(:room_feature,
               room: from_room,
               connected_room_id: to_room.id,
               allows_sight: true,
               is_open: true,
               sight_range: 150) # > 100, should cap at 1.0
      end

      it 'caps sight_quality at 1.0' do
        result = RoomSightline.calculate_sightline(from_room, to_room)

        expect(result.has_sight).to be true
        expect(result.sight_quality).to eq(1.0)
      end
    end

    context 'with feature having zero sight_range' do
      let!(:zero_window) do
        create(:room_feature,
               room: from_room,
               connected_room_id: to_room.id,
               allows_sight: true,
               is_open: true,
               sight_range: 0) # Should default to 0.5
      end

      it 'defaults sight_quality to 0.5' do
        result = RoomSightline.calculate_sightline(from_room, to_room)

        expect(result.has_sight).to be true
        expect(result.sight_quality).to eq(0.5)
      end
    end

    context 'with poor lighting' do
      let!(:window) do
        create(:room_feature,
               room: from_room,
               connected_room_id: to_room.id,
               allows_sight: true,
               is_open: true,
               sight_range: 100)
      end

      it 'reduces sight_quality in dark rooms' do
        # Set up rooms with poor lighting
        from_room.update(lighting_level: 1) if from_room.respond_to?(:lighting_level=)
        to_room.update(lighting_level: 1) if to_room.respond_to?(:lighting_level=)

        result = RoomSightline.calculate_sightline(from_room, to_room)

        # Poor lighting (avg 1) should reduce quality by 1/3
        expect(result.has_sight).to be true
        if from_room.respond_to?(:lighting_level)
          # avg_lighting = 1, so quality *= (1/3.0) = 1.0 * 0.333 ~= 0.33
          expect(result.sight_quality).to be < 1.0
        end
      end
    end

    context 'with multiple connecting features' do
      let!(:poor_window) do
        create(:room_feature,
               room: from_room,
               connected_room_id: to_room.id,
               allows_sight: true,
               is_open: true,
               sight_range: 30)
      end

      let!(:better_door) do
        create(:room_feature,
               room: from_room,
               connected_room_id: to_room.id,
               allows_sight: true,
               is_open: true,
               sight_range: 80)
      end

      it 'uses the best sight quality among features' do
        result = RoomSightline.calculate_sightline(from_room, to_room)

        expect(result.has_sight).to be true
        expect(result.sight_quality).to eq(0.8) # Uses better_door's 80/100
      end
    end

    context 'with feature that does not allow sight' do
      let!(:wall) do
        create(:room_feature,
               room: from_room,
               connected_room_id: to_room.id,
               allows_sight: false,
               is_open: true,
               sight_range: 100)
      end

      it 'creates sightline without sight' do
        result = RoomSightline.calculate_sightline(from_room, to_room)

        expect(result.has_sight).to be false
      end
    end
  end
end
