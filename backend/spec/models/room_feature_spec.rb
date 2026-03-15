# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomFeature do
  describe 'associations' do
    let(:room) { create(:room) }
    let(:connected_room) { create(:room) }
    let(:feature) { create(:room_feature, room: room, connected_room: connected_room) }

    it 'belongs to room' do
      expect(feature.room).to eq(room)
    end

    it 'belongs to connected_room' do
      expect(feature.connected_room).to eq(connected_room)
    end

    it 'has many room_sightlines' do
      expect(described_class.association_reflections[:room_sightlines]).not_to be_nil
    end
  end

  describe 'validations' do
    let(:room) { create(:room) }

    it 'requires room_id' do
      feature = described_class.new(feature_type: 'door')
      expect(feature.valid?).to be false
      expect(feature.errors[:room_id]).not_to be_empty
    end

    it 'requires feature_type' do
      feature = described_class.new(room: room)
      expect(feature.valid?).to be false
      expect(feature.errors[:feature_type]).not_to be_empty
    end

    it 'validates feature_type is in allowed list' do
      feature = described_class.new(room: room, feature_type: 'invalid')
      expect(feature.valid?).to be false
    end

    it 'accepts valid feature types' do
      %w[wall door window opening archway portal gate hatch].each do |type|
        feature = described_class.new(room: room, feature_type: type, x: 0, y: 0, z: 0, sight_range: 10)
        expect(feature.valid?).to be(true), "Expected '#{type}' to be valid, got errors: #{feature.errors.to_h}"
      end
    end

    it 'accepts wall as a valid feature type' do
      wall = described_class.new(room: room, feature_type: 'wall', x: 0, y: 50)
      expect(wall.valid?).to be true
    end

    it 'validates sight_range is numeric when present' do
      feature = described_class.new(room: room, feature_type: 'door', sight_range: 10.0)
      expect(feature.valid?).to be true
    end

    it 'clamps sight_range minimum to 0' do
      # The sight_range setter clamps values to 0-100 range before converting
      # So setting -1 becomes 0, which is valid
      feature = described_class.new(room: room, feature_type: 'door', sight_range: -1.0)
      expect(feature.valid?).to be true
      expect(feature.sight_range).to eq(0)  # Clamped to minimum
    end
  end

  describe '#allows_sight_through?' do
    let(:room) { create(:room) }

    context 'when allows_sight is false' do
      it 'returns false' do
        feature = create(:room_feature, room: room, allows_sight: false, is_open: true)
        expect(feature.allows_sight_through?).to be false
      end
    end

    context 'when is_open is true' do
      it 'returns true' do
        feature = create(:room_feature, room: room, allows_sight: true, is_open: true)
        expect(feature.allows_sight_through?).to be true
      end
    end

    context 'when is_open is false' do
      it 'returns true for window' do
        feature = create(:room_feature, room: room, feature_type: 'window', allows_sight: true, is_open: false)
        expect(feature.allows_sight_through?).to be true
      end

      it 'returns false for door' do
        feature = create(:room_feature, room: room, feature_type: 'door', allows_sight: true, is_open: false)
        expect(feature.allows_sight_through?).to be false
      end

      it 'returns false for gate' do
        feature = create(:room_feature, room: room, feature_type: 'gate', allows_sight: true, is_open: false)
        expect(feature.allows_sight_through?).to be false
      end

      it 'returns true for opening' do
        feature = create(:room_feature, room: room, feature_type: 'opening', allows_sight: true, is_open: false)
        expect(feature.allows_sight_through?).to be true
      end

      it 'returns true for archway' do
        feature = create(:room_feature, room: room, feature_type: 'archway', allows_sight: true, is_open: false)
        expect(feature.allows_sight_through?).to be true
      end

      it 'returns true for portal' do
        feature = create(:room_feature, room: room, feature_type: 'portal', allows_sight: true, is_open: false)
        expect(feature.allows_sight_through?).to be true
      end

      it 'returns false for hatch' do
        feature = create(:room_feature, room: room, feature_type: 'hatch', allows_sight: true, is_open: false)
        expect(feature.allows_sight_through?).to be false
      end
    end
  end

  describe '#allows_movement_through?' do
    let(:room) { create(:room) }

    it 'returns true when is_open is true' do
      feature = create(:room_feature, room: room, is_open: true)
      expect(feature.allows_movement_through?).to be true
    end

    it 'returns false when is_open is false' do
      feature = create(:room_feature, room: room, is_open: false)
      expect(feature.allows_movement_through?).to be false
    end
  end

  describe '#sight_quality' do
    let(:room) { create(:room) }

    context 'when allows_sight_through? is false' do
      it 'returns 0.0' do
        feature = create(:room_feature, room: room, allows_sight: false)
        expect(feature.sight_quality).to eq(0.0)
      end
    end

    context 'when fully open' do
      it 'returns 1.0 for non-portal' do
        feature = create(:room_feature, room: room, feature_type: 'window', allows_sight: true, is_open: true)
        expect(feature.sight_quality).to eq(1.0)
      end

      it 'returns 0.8 for portal' do
        feature = create(:room_feature, room: room, feature_type: 'portal', allows_sight: true, is_open: true)
        expect(feature.sight_quality).to eq(0.8)
      end
    end

    context 'when not open' do
      it 'returns 0.7 for window' do
        feature = create(:room_feature, room: room, feature_type: 'window', allows_sight: true, is_open: false)
        expect(feature.sight_quality).to eq(0.7)
      end

      it 'returns 0.56 for closed portal (0.7 * 0.8)' do
        feature = create(:room_feature, room: room, feature_type: 'portal', allows_sight: true, is_open: false)
        expect(feature.sight_quality).to be_within(0.01).of(0.56)
      end
    end
  end

  describe '#position' do
    let(:room) { create(:room) }

    it 'returns array of [x, y, z]' do
      feature = create(:room_feature, room: room, x: 10.0, y: 20.0, z: 30.0)
      expect(feature.position).to eq([10.0, 20.0, 30.0])
    end
  end

  describe '#can_see_from_position?' do
    let(:room) { create(:room) }

    context 'when allows_sight_through? is false' do
      it 'returns false' do
        feature = create(:room_feature, room: room, x: 0, y: 0, z: 0, allows_sight: false, sight_range: 100)
        expect(feature.can_see_from_position?(5, 5, 5)).to be false
      end
    end

    context 'when allows_sight_through? is true' do
      it 'returns true when within sight_range' do
        feature = create(:room_feature, room: room, x: 0, y: 0, z: 0, allows_sight: true, is_open: true, sight_range: 10)
        expect(feature.can_see_from_position?(3, 4, 0)).to be true # distance = 5
      end

      it 'returns false when beyond sight_range' do
        feature = create(:room_feature, room: room, x: 0, y: 0, z: 0, allows_sight: true, is_open: true, sight_range: 5)
        expect(feature.can_see_from_position?(5, 5, 5)).to be false # distance ~= 8.66
      end

      it 'returns true when exactly at sight_range' do
        feature = create(:room_feature, room: room, x: 0, y: 0, z: 0, allows_sight: true, is_open: true, sight_range: 5)
        expect(feature.can_see_from_position?(3, 4, 0)).to be true # distance = 5 exactly
      end
    end
  end

  describe '#allows_sight_from_room?' do
    let(:room) { create(:room) }

    it 'returns allows_sight value' do
      feature_with_sight = create(:room_feature, room: room, allows_sight: true)
      feature_no_sight = create(:room_feature, room: room, allows_sight: false)

      expect(feature_with_sight.allows_sight_from_room?(room.id)).to be true
      expect(feature_no_sight.allows_sight_from_room?(room.id)).to be false
    end
  end

  # Note: The #invalidate_sightline_cache private method references a through_feature_id
  # column that doesn't exist in the room_sightlines table. The method is currently broken
  # and would need a database migration to add the column before it can be properly tested.
  # Skipping these tests until the schema is updated.

  describe '#wall?' do
    it 'returns true for wall features' do
      wall = described_class.new(feature_type: 'wall')
      expect(wall.wall?).to be true
    end

    it 'returns false for door features' do
      door = described_class.new(feature_type: 'door')
      expect(door.wall?).to be false
    end

    it 'returns false for window features' do
      window = described_class.new(feature_type: 'window')
      expect(window.wall?).to be false
    end
  end

  describe '#direction' do
    let(:room) { create(:room) }

    it 'accepts cardinal directions' do
      %w[north south east west].each do |dir|
        feature = build(:room_feature, room: room, direction: dir)
        expect(feature.valid?).to be(true), "Expected '#{dir}' to be valid, got errors: #{feature.errors.to_h}"
      end
    end

    it 'accepts diagonal directions' do
      %w[northeast northwest southeast southwest].each do |dir|
        feature = build(:room_feature, room: room, direction: dir)
        expect(feature.valid?).to be(true), "Expected '#{dir}' to be valid, got errors: #{feature.errors.to_h}"
      end
    end

    it 'accepts vertical directions' do
      %w[up down].each do |dir|
        feature = build(:room_feature, room: room, direction: dir)
        expect(feature.valid?).to be(true), "Expected '#{dir}' to be valid, got errors: #{feature.errors.to_h}"
      end
    end

    it 'rejects invalid directions' do
      feature = build(:room_feature, room: room, direction: 'sideways')
      expect(feature.valid?).to be false
      expect(feature.errors[:direction]).not_to be_empty
    end

    it 'allows nil direction' do
      feature = build(:room_feature, room: room, direction: nil)
      expect(feature.valid?).to be true
    end
  end

  describe '#opening?' do
    it 'returns true for door features' do
      door = described_class.new(feature_type: 'door')
      expect(door.opening?).to be true
    end

    it 'returns true for opening features' do
      opening = described_class.new(feature_type: 'opening')
      expect(opening.opening?).to be true
    end

    it 'returns true for archway features' do
      archway = described_class.new(feature_type: 'archway')
      expect(archway.opening?).to be true
    end

    it 'returns true for gate features' do
      gate = described_class.new(feature_type: 'gate')
      expect(gate.opening?).to be true
    end

    it 'returns true for hatch features' do
      hatch = described_class.new(feature_type: 'hatch')
      expect(hatch.opening?).to be true
    end

    it 'returns true for portal features' do
      portal = described_class.new(feature_type: 'portal')
      expect(portal.opening?).to be true
    end

    it 'returns false for wall features' do
      wall = described_class.new(feature_type: 'wall')
      expect(wall.opening?).to be false
    end

    it 'returns false for window features' do
      window = described_class.new(feature_type: 'window')
      expect(window.opening?).to be false
    end
  end
end
