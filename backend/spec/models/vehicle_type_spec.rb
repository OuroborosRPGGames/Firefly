# frozen_string_literal: true

require 'spec_helper'

RSpec.describe VehicleType do
  let(:universe) { create(:universe) }

  describe 'validations' do
    it 'requires name' do
      vtype = VehicleType.new(name: nil, category: 'ground')
      expect(vtype.valid?).to be false
      expect(vtype.errors[:name]).not_to be_empty
    end

    it 'requires category' do
      vtype = VehicleType.new(name: 'Test Vehicle', category: nil)
      expect(vtype.valid?).to be false
      expect(vtype.errors[:category]).not_to be_empty
    end

    it 'validates max length of name' do
      vtype = VehicleType.new(name: 'x' * 101, category: 'ground')
      expect(vtype.valid?).to be false
      expect(vtype.errors[:name]).not_to be_empty
    end

    it 'validates category is in allowed values' do
      vtype = VehicleType.new(name: 'Test', category: 'invalid')
      expect(vtype.valid?).to be false
      expect(vtype.errors[:category]).not_to be_empty
    end

    it 'accepts all valid categories' do
      VehicleType::CATEGORIES.each do |cat|
        vtype = VehicleType.new(name: "Test #{cat}", category: cat, universe: universe)
        expect(vtype.valid?).to eq(true), "Expected category '#{cat}' to be valid"
      end
    end

    it 'validates uniqueness of name within universe' do
      VehicleType.create(name: 'Motorcycle', category: 'ground', universe: universe)
      vtype = VehicleType.new(name: 'Motorcycle', category: 'ground', universe: universe)
      expect(vtype.valid?).to be false
    end
  end

  describe 'defaults' do
    it 'defaults category to ground in before_save' do
      vtype = VehicleType.new(name: 'Test', category: 'ground', universe: universe)
      vtype.category = nil
      vtype.before_save
      expect(vtype.category).to eq('ground')
    end

    it 'defaults passenger_capacity to 1' do
      vtype = VehicleType.create(name: 'Test', category: 'ground', universe: universe)
      expect(vtype.passenger_capacity).to eq(1)
    end

    it 'defaults speed_modifier to 1.0' do
      vtype = VehicleType.create(name: 'Test', category: 'ground', universe: universe)
      expect(vtype.speed_modifier).to eq(1.0)
    end
  end

  describe '#ground?' do
    it 'returns true for ground category' do
      vtype = VehicleType.new(name: 'Car', category: 'ground')
      expect(vtype.ground?).to be true
    end

    it 'returns false for other categories' do
      vtype = VehicleType.new(name: 'Boat', category: 'water')
      expect(vtype.ground?).to be false
    end
  end

  describe '#mount?' do
    it 'returns true for mount category' do
      vtype = VehicleType.new(name: 'Horse', category: 'mount')
      expect(vtype.mount?).to be true
    end

    it 'returns false for other categories' do
      vtype = VehicleType.new(name: 'Car', category: 'ground')
      expect(vtype.mount?).to be false
    end
  end

  describe '#can_carry_passengers?' do
    it 'returns true when passenger_capacity > 1' do
      vtype = VehicleType.new(name: 'Bus', category: 'ground')
      vtype.passenger_capacity = 40
      expect(vtype.can_carry_passengers?).to be true
    end

    it 'returns false when passenger_capacity is 1' do
      vtype = VehicleType.create(name: 'Motorcycle', category: 'ground', universe: universe)
      expect(vtype.can_carry_passengers?).to be false
    end
  end

  describe '#always_open?' do
    it 'returns true for motorcycle type' do
      vtype = VehicleType.create(name: 'Motorcycle', category: 'ground', always_open: true, universe: universe)
      expect(vtype.always_open?).to be true
    end

    it 'returns false by default' do
      vtype = VehicleType.create(name: 'Sedan', category: 'ground', universe: universe)
      expect(vtype.always_open?).to be false
    end
  end
end
