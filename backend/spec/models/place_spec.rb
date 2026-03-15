# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Place do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:place) { create(:place, room: room) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(place).to be_valid
    end

    it 'requires name' do
      place = build(:place, room: room, name: nil)
      expect(place).not_to be_valid
    end

    it 'validates max length of name' do
      place = build(:place, room: room, name: 'x' * 101)
      expect(place).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to room' do
      expect(place.room).to eq(room)
    end
  end

  describe '#characters_here' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let(:reality) { create(:reality) }
    let!(:online_ci) { create(:character_instance, character: character, current_room: room, current_place: place, reality: reality, online: true) }
    let!(:offline_ci) { create(:character_instance, character: create(:character, user: user), current_room: room, current_place: place, reality: reality, online: false) }

    it 'returns only online character instances' do
      results = place.characters_here.all
      expect(results).to include(online_ci)
      expect(results).not_to include(offline_ci)
    end

    it 'filters by reality_id when provided' do
      other_reality = create(:reality)
      other_ci = create(:character_instance, character: create(:character, user: user), current_room: room, current_place: place, reality: other_reality, online: true)

      results = place.characters_here(reality.id).all
      expect(results).to include(online_ci)
      expect(results).not_to include(other_ci)
    end

    it 'returns all online characters without reality filter' do
      other_reality = create(:reality)
      other_ci = create(:character_instance, character: create(:character, user: user), current_room: room, current_place: place, reality: other_reality, online: true)

      results = place.characters_here.all
      expect(results).to include(online_ci)
      expect(results).to include(other_ci)
    end
  end

  describe '#full?' do
    context 'without capacity' do
      it 'returns false' do
        place.update(capacity: nil)
        expect(place.full?).to be false
      end
    end

    context 'with capacity' do
      it 'returns false when under capacity' do
        place.update(capacity: 4)
        expect(place.full?).to be false
      end
    end
  end

  describe '#display_name' do
    it 'returns the name' do
      place = create(:place, room: room, name: 'Test Spot')
      expect(place.display_name).to eq('Test Spot')
    end
  end

  describe '#furniture?' do
    it 'returns true when is_furniture is true' do
      place = create(:place, :furniture, room: room)
      expect(place.furniture?).to be true
    end

    it 'returns false when is_furniture is false' do
      expect(place.furniture?).to be false
    end
  end

  describe '#visible?' do
    it 'returns true when not invisible' do
      expect(place.visible?).to be true
    end

    it 'returns false when invisible' do
      place = create(:place, :invisible, room: room)
      expect(place.visible?).to be false
    end
  end

  describe '#has_image?' do
    it 'returns true when image_url is set' do
      place.update(image_url: 'http://example.com/image.png')
      expect(place.has_image?).to be true
    end

    it 'returns false when image_url is nil' do
      expect(place.has_image?).to be false
    end

    it 'returns false when image_url is empty' do
      place.update(image_url: '')
      expect(place.has_image?).to be false
    end
  end

  describe '.visible' do
    let!(:visible_place) { create(:place, room: room) }
    let!(:invisible_place) { create(:place, :invisible, room: room) }

    it 'returns only visible places' do
      results = described_class.visible.all
      expect(results).to include(visible_place)
      expect(results).not_to include(invisible_place)
    end
  end

  describe '.in_room' do
    let!(:my_place) { create(:place, room: room) }
    let(:other_room) { create(:room, location: location) }
    let!(:other_place) { create(:place, room: other_room) }

    it 'returns places in the specified room' do
      results = described_class.in_room(room.id).all
      expect(results).to include(my_place)
      expect(results).not_to include(other_place)
    end
  end
end
