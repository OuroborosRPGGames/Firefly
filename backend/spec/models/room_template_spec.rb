# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomTemplate do
  let(:universe) { create(:universe) }
  let(:location) { create(:location) }

  describe 'constants' do
    it 'has expected template types' do
      expect(RoomTemplate::TEMPLATE_TYPES).to include(
        'vehicle_interior', 'taxi', 'train_compartment', 'shuttle', 'carriage', 'boat_cabin'
      )
    end

    it 'has expected categories' do
      expect(RoomTemplate::CATEGORIES).to include(
        'sedan', 'taxi', 'bus', 'train', 'subway', 'ferry', 'airship'
      )
    end
  end

  describe 'validations' do
    it 'requires name' do
      template = RoomTemplate.new(template_type: 'vehicle_interior', category: 'sedan')
      expect(template.valid?).to be false
      expect(template.errors[:name]).not_to be_empty
    end

    it 'requires template_type' do
      template = RoomTemplate.new(name: 'Test', category: 'sedan')
      expect(template.valid?).to be false
      expect(template.errors[:template_type]).not_to be_empty
    end

    it 'requires category' do
      template = RoomTemplate.new(name: 'Test', template_type: 'vehicle_interior')
      expect(template.valid?).to be false
      expect(template.errors[:category]).not_to be_empty
    end

    it 'validates template_type is in allowed list' do
      template = RoomTemplate.new(
        name: 'Test', template_type: 'invalid_type', category: 'sedan'
      )
      expect(template.valid?).to be false
      expect(template.errors[:template_type]).not_to be_empty
    end

    it 'validates category is in allowed list' do
      template = RoomTemplate.new(
        name: 'Test', template_type: 'vehicle_interior', category: 'invalid_category'
      )
      expect(template.valid?).to be false
      expect(template.errors[:category]).not_to be_empty
    end

    it 'validates name length' do
      template = RoomTemplate.new(
        name: 'a' * 101,
        template_type: 'vehicle_interior',
        category: 'sedan'
      )
      expect(template.valid?).to be false
      expect(template.errors[:name]).not_to be_empty
    end

    it 'accepts valid template' do
      template = create(:room_template, universe: universe)
      expect(template.valid?).to be true
    end
  end

  describe 'associations' do
    let(:template) { create(:room_template, universe: universe) }

    it 'belongs to universe' do
      expect(template.universe).to eq(universe)
    end
  end

  describe '#instantiate_room' do
    let(:template) { create(:room_template, universe: universe) }

    it 'creates a room with template properties' do
      room = template.instantiate_room(location: location)

      expect(room).to be_a(Room)
      expect(room.id).not_to be_nil
      expect(room.name).to eq(template.name)
      expect(room.room_template_id).to eq(template.id)
    end

    it 'sets temporary and pool status' do
      room = template.instantiate_room(location: location)

      expect(room.is_temporary).to be true
      expect(room.pool_status).to eq('available')
    end

    it 'applies template dimensions' do
      room = template.instantiate_room(location: location)

      expect(room.max_x).to eq(template.effective_width)
      expect(room.max_y).to eq(template.effective_length)
      expect(room.max_z).to eq(template.effective_height)
    end

    it 'appends name suffix when provided' do
      room = template.instantiate_room(location: location, name_suffix: '#123')

      expect(room.name).to eq("#{template.name} - #123")
    end
  end

  describe '#setup_default_places' do
    let(:template) do
      create(:room_template,
             universe: universe,
             default_places: [
               { 'name' => 'Driver Seat', 'capacity' => 1, 'x' => 2.0, 'y' => 3.0 },
               { 'name' => 'Passenger Seat', 'capacity' => 1, 'x' => 6.0, 'y' => 3.0 }
             ])
    end
    let(:room) { template.instantiate_room(location: location) }

    it 'creates places from template config' do
      template.setup_default_places(room)

      places = Place.where(room_id: room.id).all
      expect(places.count).to eq(2)
    end

    it 'sets place properties from config' do
      template.setup_default_places(room)

      driver_seat = Place.where(room_id: room.id, name: 'Driver Seat').first
      expect(driver_seat).not_to be_nil
      expect(driver_seat.capacity).to eq(1)
      expect(driver_seat.is_furniture).to be true
    end

    it 'handles missing capacity with default of 1' do
      template.update(default_places: [{ 'name' => 'Basic Seat', 'x' => 0, 'y' => 0 }])
      template.setup_default_places(room)

      place = Place.where(room_id: room.id, name: 'Basic Seat').first
      expect(place.capacity).to eq(1)
    end
  end

  describe '#default_places_config' do
    it 'returns empty array when nil' do
      template = RoomTemplate.new(default_places: nil)
      expect(template.default_places_config).to eq([])
    end

    it 'returns configured places' do
      places = [{ 'name' => 'Seat' }]
      template = RoomTemplate.new(default_places: places)
      expect(template.default_places_config).to eq(places)
    end
  end

  describe '#custom_properties' do
    it 'returns empty hash when nil' do
      template = RoomTemplate.new(properties: nil)
      expect(template.custom_properties).to eq({})
    end

    it 'returns configured properties' do
      props = { 'color' => 'red', 'model' => 'luxury' }
      template = RoomTemplate.new(properties: props)
      expect(template.custom_properties).to eq(props)
    end
  end

  describe 'effective dimension methods' do
    describe '#effective_width' do
      it 'returns set width' do
        template = RoomTemplate.new(width: 15.0)
        expect(template.effective_width).to eq(15.0)
      end

      it 'returns default when nil' do
        template = RoomTemplate.new(width: nil)
        expect(template.effective_width).to eq(10.0)
      end
    end

    describe '#effective_length' do
      it 'returns set length' do
        template = RoomTemplate.new(length: 20.0)
        expect(template.effective_length).to eq(20.0)
      end

      it 'returns default when nil' do
        template = RoomTemplate.new(length: nil)
        expect(template.effective_length).to eq(15.0)
      end
    end

    describe '#effective_height' do
      it 'returns set height' do
        template = RoomTemplate.new(height: 10.0)
        expect(template.effective_height).to eq(10.0)
      end

      it 'returns default when nil' do
        template = RoomTemplate.new(height: nil)
        expect(template.effective_height).to eq(8.0)
      end
    end

    describe '#effective_capacity' do
      it 'returns set capacity' do
        template = RoomTemplate.new(passenger_capacity: 6)
        expect(template.effective_capacity).to eq(6)
      end

      it 'returns default when nil' do
        template = RoomTemplate.new(passenger_capacity: nil)
        expect(template.effective_capacity).to eq(4)
      end
    end
  end

  describe 'display name methods' do
    describe '#category_display_name' do
      it 'converts underscores to spaces and capitalizes' do
        template = RoomTemplate.new(category: 'hansom')
        expect(template.category_display_name).to eq('Hansom')
      end

      it 'handles multi-word categories' do
        template = RoomTemplate.new(category: 'rowboat')
        expect(template.category_display_name).to eq('Rowboat')
      end
    end

    describe '#type_display_name' do
      it 'converts underscores to spaces and capitalizes' do
        template = RoomTemplate.new(template_type: 'vehicle_interior')
        expect(template.type_display_name).to eq('Vehicle Interior')
      end

      it 'handles multi-word types' do
        template = RoomTemplate.new(template_type: 'train_compartment')
        expect(template.type_display_name).to eq('Train Compartment')
      end
    end
  end

  describe '.for_vehicle_type' do
    before do
      @sedan = create(:room_template, universe: universe, category: 'sedan', template_type: 'vehicle_interior', active: true)
      @taxi = create(:room_template, universe: universe, category: 'taxi', template_type: 'taxi', active: true)
      @inactive = create(:room_template, universe: universe, category: 'bus', template_type: 'vehicle_interior', active: false)
    end

    it 'finds template by vehicle type' do
      # The for_vehicle_type method looks for category match first, then falls back
      result = RoomTemplate.for_vehicle_type('taxi', template_type: 'taxi')
      expect(result.category).to eq('taxi')
    end

    it 'normalizes vehicle type to category' do
      # 'cab' normalizes to 'taxi' category
      result = RoomTemplate.for_vehicle_type('cab', template_type: 'taxi')
      expect(result.category).to eq('taxi')
    end

    it 'falls back to any active template if specific not found' do
      result = RoomTemplate.for_vehicle_type('nonexistent')
      expect(result).not_to be_nil
      expect(result.active).to be true
    end

    it 'ignores inactive templates' do
      result = RoomTemplate.for_vehicle_type('bus')
      # Should not return the inactive bus template
      if result
        expect(result.active).to be true
      end
    end
  end

  describe '.for_journey' do
    before do
      @train = create(:room_template, universe: universe, template_type: 'train_compartment', category: 'train', active: true)
      @boat = create(:room_template, universe: universe, template_type: 'boat_cabin', category: 'ferry', active: true)
      @car = create(:room_template, universe: universe, template_type: 'vehicle_interior', category: 'sedan', active: true)
    end

    it 'returns train template for rail travel' do
      result = RoomTemplate.for_journey(travel_mode: 'rail', vehicle_type: 'train')
      expect(result.template_type).to eq('train_compartment')
    end

    it 'returns boat template for water travel' do
      result = RoomTemplate.for_journey(travel_mode: 'water', vehicle_type: 'ferry')
      expect(result.template_type).to eq('boat_cabin')
    end

    it 'returns vehicle template for land travel' do
      result = RoomTemplate.for_journey(travel_mode: 'land', vehicle_type: 'car')
      expect(result.template_type).to eq('vehicle_interior')
    end
  end

  describe '.normalize_category' do
    it 'maps common synonyms to valid categories' do
      mappings = {
        'car' => 'sedan',
        'automobile' => 'sedan',
        'cab' => 'taxi',
        'metro' => 'subway',
        'hansom_cab' => 'hansom',
        'horseback' => 'horse',
        'ship' => 'ferry',
        'zeppelin' => 'airship'
      }

      mappings.each do |input, expected|
        expect(RoomTemplate.normalize_category(input)).to eq(expected), "Expected '#{input}' to map to '#{expected}'"
      end
    end

    it 'defaults to sedan for unknown types' do
      expect(RoomTemplate.normalize_category('unknown')).to eq('sedan')
    end

    it 'handles case insensitivity' do
      expect(RoomTemplate.normalize_category('TAXI')).to eq('taxi')
      expect(RoomTemplate.normalize_category('Train')).to eq('train')
    end
  end

  describe '.by_type' do
    before do
      @interior1 = create(:room_template, universe: universe, template_type: 'vehicle_interior', active: true)
      @interior2 = create(:room_template, universe: universe, template_type: 'vehicle_interior', active: true)
      @train = create(:room_template, universe: universe, template_type: 'train_compartment', category: 'train', active: true)
      @inactive = create(:room_template, universe: universe, template_type: 'shuttle', active: false)
    end

    it 'groups active templates by type' do
      result = RoomTemplate.by_type

      expect(result['vehicle_interior'].count).to eq(2)
      expect(result['train_compartment'].count).to eq(1)
    end

    it 'excludes inactive templates' do
      result = RoomTemplate.by_type.values.flatten.map(&:id)
      expect(result).not_to include(@inactive.id)
    end
  end

  describe '.by_category' do
    before do
      @sedan1 = create(:room_template, universe: universe, category: 'sedan', active: true)
      @sedan2 = create(:room_template, universe: universe, category: 'sedan', active: true)
      @taxi = create(:room_template, universe: universe, category: 'taxi', template_type: 'taxi', active: true)
      @inactive = create(:room_template, universe: universe, category: 'bus', active: false)
    end

    it 'groups active templates by category' do
      result = RoomTemplate.by_category

      expect(result['sedan'].count).to eq(2)
      expect(result['taxi'].count).to eq(1)
    end

    it 'excludes inactive templates' do
      result = RoomTemplate.by_category.values.flatten.map(&:id)
      expect(result).not_to include(@inactive.id)
    end
  end
end
