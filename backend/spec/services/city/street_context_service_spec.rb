# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StreetContextService do
  let(:location) { create(:location) }

  # Street running north-south
  let(:street) do
    create(:room,
           name: '1st Avenue', short_description: 'A city street', location: location,
           room_type: 'street', city_role: 'street', indoors: false,
           min_x: 100, max_x: 200, min_y: 100, max_y: 200)
  end

  # Building to the east of the street
  let(:tavern) do
    create(:room,
           name: 'The Rusty Sword', short_description: 'A tavern', location: location,
           room_type: 'bar', city_role: 'building', indoors: true,
           min_x: 200, max_x: 300, min_y: 100, max_y: 200)
  end

  # Building to the west of the street
  let(:shop) do
    create(:room,
           name: 'General Store', short_description: 'A shop', location: location,
           room_type: 'shop', city_role: 'building', indoors: true,
           min_x: 0, max_x: 100, min_y: 100, max_y: 200)
  end

  describe '.buildings_along_street' do
    context 'when walking north with buildings on both sides' do
      before do
        tavern
        shop
      end

      it 'identifies buildings on left and right' do
        messages = described_class.buildings_along_street(street, 'north')

        expect(messages).to include(a_string_matching(/The Rusty Sword.*right/))
        expect(messages).to include(a_string_matching(/General Store.*left/))
      end
    end

    context 'when walking south (sides reverse)' do
      before do
        tavern
        shop
      end

      it 'reverses left and right' do
        messages = described_class.buildings_along_street(street, 'south')

        # East is now left, west is now right when walking south
        expect(messages).to include(a_string_matching(/The Rusty Sword.*left/))
        expect(messages).to include(a_string_matching(/General Store.*right/))
      end
    end

    context 'when no buildings are adjacent' do
      it 'returns empty array' do
        messages = described_class.buildings_along_street(street, 'north')

        expect(messages).to be_empty
      end
    end

    context 'with interior rooms (name contains " - ")' do
      before do
        create(:room,
               name: 'The Rusty Sword - Kitchen', short_description: 'A kitchen', location: location,
               room_type: 'standard', city_role: 'building', indoors: true,
               min_x: 200, max_x: 300, min_y: 100, max_y: 200)
      end

      it 'excludes interior rooms' do
        messages = described_class.buildings_along_street(street, 'north')

        expect(messages).not_to include(a_string_matching(/Kitchen/))
      end
    end

    context 'with invalid direction' do
      it 'returns empty array for up/down' do
        messages = described_class.buildings_along_street(street, 'up')

        expect(messages).to be_empty
      end
    end
  end
end
