# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MapVisibilityService do
  let(:location) { create(:location) }

  # Room A at (0,0)-(100,100), Room B north at (0,100)-(100,200)
  let(:room_a) do
    create(:room, name: 'Room A', location: location, indoors: false,
           min_x: 0, max_x: 100, min_y: 0, max_y: 100)
  end
  let(:room_b) do
    create(:room, name: 'Room B', location: location, indoors: false,
           min_x: 0, max_x: 100, min_y: 100, max_y: 200)
  end

  before { room_a; room_b }

  describe '.visible_rooms' do
    it 'always includes the current room with :current relationship' do
      result = described_class.visible_rooms(room_a)

      current = result.find { |r| r[:relationship] == :current }
      expect(current).not_to be_nil
      expect(current[:room].id).to eq(room_a.id)
      expect(current[:passable]).to be true
    end

    it 'includes adjacent passable rooms' do
      result = described_class.visible_rooms(room_a)

      adjacent = result.select { |r| r[:relationship] == :adjacent }
      adjacent_ids = adjacent.map { |r| r[:room].id }
      expect(adjacent_ids).to include(room_b.id)
    end

    it 'marks adjacent rooms as passable' do
      result = described_class.visible_rooms(room_a)

      adj = result.find { |r| r[:room].id == room_b.id }
      expect(adj[:passable]).to be true
    end

    it 'includes direction for adjacent rooms' do
      result = described_class.visible_rooms(room_a)

      adj = result.find { |r| r[:room].id == room_b.id }
      expect(adj[:direction]).to eq('north')
    end

    context 'with sibling rooms (same inside_room_id)' do
      let!(:container) do
        create(:room, name: 'Building', location: location, indoors: true,
               min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      end
      let!(:sibling_a) do
        create(:room, name: 'Office A', location: location, indoors: true,
               min_x: 0, max_x: 100, min_y: 0, max_y: 100,
               inside_room_id: container.id)
      end
      let!(:sibling_b) do
        create(:room, name: 'Office B', location: location, indoors: true,
               min_x: 100, max_x: 200, min_y: 0, max_y: 100,
               inside_room_id: container.id)
      end

      it 'includes sibling rooms (may be adjacent or sibling relationship)' do
        result = described_class.visible_rooms(sibling_a)

        room_ids = result.map { |r| r[:room].id }
        expect(room_ids).to include(sibling_b.id)
      end
    end

    context 'with contained rooms' do
      let!(:outer) do
        create(:room, name: 'Hall', location: location, indoors: true,
               min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      end
      let!(:inner) do
        create(:room, name: 'Closet', location: location, indoors: true,
               min_x: 10, max_x: 50, min_y: 10, max_y: 50,
               inside_room_id: outer.id)
      end

      it 'includes contained rooms' do
        result = described_class.visible_rooms(outer)

        room_ids = result.map { |r| r[:room].id }
        expect(room_ids).to include(inner.id)
      end
    end

    context 'with container room' do
      let!(:container) do
        create(:room, name: 'Building', location: location, indoors: true,
               min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      end
      let!(:inner) do
        create(:room, name: 'Office', location: location, indoors: true,
               min_x: 10, max_x: 90, min_y: 10, max_y: 90,
               inside_room_id: container.id)
      end

      it 'includes container room' do
        result = described_class.visible_rooms(inner)

        room_ids = result.map { |r| r[:room].id }
        expect(room_ids).to include(container.id)
      end
    end

    context 'z-level filtering' do
      let(:room_ground) do
        create(:room, name: 'Ground', location: location, indoors: false,
               min_x: 0, max_x: 100, min_y: 0, max_y: 100,
               min_z: 0, max_z: 10)
      end
      let(:room_upper) do
        create(:room, name: 'Upper', location: location, indoors: false,
               min_x: 0, max_x: 100, min_y: 100, max_y: 200,
               min_z: 20, max_z: 30)
      end

      before { room_ground; room_upper }

      it 'excludes rooms on different z-levels' do
        result = described_class.visible_rooms(room_ground)

        room_ids = result.map { |r| r[:room].id }
        expect(room_ids).not_to include(room_upper.id)
      end
    end

    context 'with radius filter' do
      let(:nearby) do
        create(:room, name: 'Nearby', location: location, indoors: false,
               min_x: 0, max_x: 100, min_y: 100, max_y: 150)
      end
      let(:far_away) do
        create(:room, name: 'Far Away', location: location, indoors: false,
               min_x: 0, max_x: 100, min_y: 900, max_y: 1000)
      end

      before { nearby; far_away }

      it 'excludes rooms beyond the radius' do
        result = described_class.visible_rooms(room_a, radius: 200)

        room_ids = result.map { |r| r[:room].id }
        expect(room_ids).to include(nearby.id)
        expect(room_ids).not_to include(far_away.id)
      end
    end

    context 'with non-navigable rooms' do
      let(:outside_polygon_room) do
        create(:room, name: 'Outside', location: location, indoors: false,
               min_x: 0, max_x: 100, min_y: 100, max_y: 200,
               outside_polygon: true)
      end

      before { outside_polygon_room }

      it 'excludes non-navigable rooms' do
        result = described_class.visible_rooms(room_a)

        room_ids = result.map { |r| r[:room].id }
        expect(room_ids).not_to include(outside_polygon_room.id)
      end
    end

    it 'does not include duplicate rooms' do
      result = described_class.visible_rooms(room_a)

      room_ids = result.map { |r| r[:room].id }
      expect(room_ids.uniq.length).to eq(room_ids.length)
    end
  end
end
