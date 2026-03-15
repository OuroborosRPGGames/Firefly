# frozen_string_literal: true

require 'spec_helper'

RSpec.describe UnifiedObjectType do
  # ========================================
  # Validations
  # ========================================

  describe 'validations' do
    it 'requires name' do
      uot = build(:unified_object_type, name: nil)
      expect(uot.valid?).to be false
      expect(uot.errors[:name]).to include('is not present')
    end

    it 'requires category' do
      uot = build(:unified_object_type, category: nil)
      expect(uot.valid?).to be false
      expect(uot.errors[:category]).to include('is not present')
    end

    it 'validates uniqueness of name' do
      create(:unified_object_type, name: 'Test Type')
      duplicate = build(:unified_object_type, name: 'Test Type')
      expect(duplicate.valid?).to be false
    end

    it 'validates name max length' do
      uot = build(:unified_object_type, name: 'A' * 101)
      expect(uot.valid?).to be false
      expect(uot.errors[:name]).not_to be_empty
    end

    it 'validates category max length' do
      uot = build(:unified_object_type, category: 'A' * 51)
      expect(uot.valid?).to be false
      expect(uot.errors[:category]).not_to be_empty
    end

    it 'validates subcategory max length when present' do
      uot = build(:unified_object_type, subcategory: 'A' * 51)
      expect(uot.valid?).to be false
      expect(uot.errors[:subcategory]).not_to be_empty
    end

    it 'accepts nil subcategory' do
      uot = build(:unified_object_type, subcategory: nil)
      expect(uot.valid?).to be true
    end
  end

  # ========================================
  # Covered Positions
  # ========================================

  describe 'covered positions' do
    let(:uot) { create(:unified_object_type) }

    describe '#covered_positions' do
      it 'returns array of covered positions' do
        uot.covered_position_1 = 'torso'
        uot.covered_position_2 = 'back'
        uot.save
        expect(uot.covered_positions).to eq(['torso', 'back'])
      end

      it 'excludes nil and empty positions' do
        uot.covered_position_1 = 'torso'
        uot.covered_position_2 = nil
        uot.covered_position_3 = ''
        uot.covered_position_4 = 'arms'
        uot.save
        expect(uot.covered_positions).to eq(['torso', 'arms'])
      end

      it 'returns empty array when no positions set' do
        expect(uot.covered_positions).to eq([])
      end
    end

    describe '#covered_positions=' do
      it 'sets positions from array' do
        uot.covered_positions = ['torso', 'back', 'arms']
        expect(uot.covered_position_1).to eq('torso')
        expect(uot.covered_position_2).to eq('back')
        expect(uot.covered_position_3).to eq('arms')
      end

      it 'clears existing positions' do
        uot.covered_position_1 = 'old_position'
        uot.covered_positions = ['new_position']
        expect(uot.covered_position_1).to eq('new_position')
        expect(uot.covered_position_2).to be_nil
      end

      it 'limits to 20 positions' do
        positions = (1..25).map { |i| "position_#{i}" }
        uot.covered_positions = positions
        expect(uot.covered_position_20).to eq('position_20')
        # Position 21+ are not set (not accessible as covered_position_21)
      end

      it 'skips empty strings at their index' do
        uot.covered_positions = ['torso', '', 'back']
        expect(uot.covered_position_1).to eq('torso')
        expect(uot.covered_position_2).to be_nil  # empty string skipped
        expect(uot.covered_position_3).to eq('back')
      end
    end
  end

  # ========================================
  # Zippable Positions
  # ========================================

  describe 'zippable positions' do
    let(:uot) { create(:unified_object_type) }

    describe '#zippable_positions' do
      it 'returns array of zippable positions' do
        uot.zone_1 = 'front'
        uot.zone_2 = 'side'
        uot.save
        expect(uot.zippable_positions).to eq(['front', 'side'])
      end

      it 'excludes nil and empty positions' do
        uot.zone_1 = 'front'
        uot.zone_2 = nil
        uot.zone_3 = ''
        uot.save
        expect(uot.zippable_positions).to eq(['front'])
      end
    end

    describe '#zippable_positions=' do
      it 'sets positions from array' do
        uot.zippable_positions = ['front', 'back']
        expect(uot.zone_1).to eq('front')
        expect(uot.zone_2).to eq('back')
      end

      it 'clears existing positions' do
        uot.zone_1 = 'old_zone'
        uot.zippable_positions = ['new_zone']
        expect(uot.zone_1).to eq('new_zone')
        expect(uot.zone_2).to be_nil
      end

      it 'limits to 10 positions' do
        positions = (1..15).map { |i| "zone_#{i}" }
        uot.zippable_positions = positions
        expect(uot.zone_10).to eq('zone_10')
      end
    end
  end

  # ========================================
  # Type Check Methods (based on category)
  # ========================================

  describe 'type check methods' do
    describe '#clothing?' do
      it 'returns true for clothing categories' do
        uot = build(:unified_object_type, category: 'Top')
        expect(uot.clothing?).to be true
      end

      it 'returns false for weapon categories' do
        uot = build(:unified_object_type, category: 'Sword')
        expect(uot.clothing?).to be false
      end
    end

    describe '#jewelry?' do
      it 'returns true for jewelry categories' do
        uot = build(:unified_object_type, category: 'Ring')
        expect(uot.jewelry?).to be true
      end

      it 'returns false for clothing categories' do
        uot = build(:unified_object_type, category: 'Top')
        expect(uot.jewelry?).to be false
      end
    end

    describe '#weapon?' do
      it 'returns true for weapon categories' do
        uot = build(:unified_object_type, category: 'Sword')
        expect(uot.weapon?).to be true
      end

      it 'returns false for clothing categories' do
        uot = build(:unified_object_type, category: 'Top')
        expect(uot.weapon?).to be false
      end
    end

    describe '#pet?' do
      it 'returns true for Pet category' do
        uot = build(:unified_object_type, category: 'Pet')
        expect(uot.pet?).to be true
      end

      it 'returns false for other categories' do
        uot = build(:unified_object_type, category: 'Top')
        expect(uot.pet?).to be false
      end
    end
  end

  # ========================================
  # Class Methods (based on category)
  # ========================================

  describe 'class methods' do
    describe '.clothing_types' do
      it 'returns types with clothing categories' do
        clothing = create(:unified_object_type, category: 'Top')
        weapon = create(:unified_object_type, category: 'Sword')

        results = UnifiedObjectType.clothing_types
        expect(results).to include(clothing)
        expect(results).not_to include(weapon)
      end
    end

    describe '.jewelry_types' do
      it 'returns types with jewelry categories' do
        jewelry = create(:unified_object_type, category: 'Ring')
        expect(UnifiedObjectType.jewelry_types).to include(jewelry)
      end
    end

    describe '.weapon_types' do
      it 'returns types with weapon categories' do
        weapon = create(:unified_object_type, category: 'Sword')
        expect(UnifiedObjectType.weapon_types).to include(weapon)
      end
    end

    describe '.pet_types' do
      it 'returns types with Pet category' do
        pet = create(:unified_object_type, category: 'Pet')
        expect(UnifiedObjectType.pet_types).to include(pet)
      end
    end

    describe '.by_category' do
      it 'filters by category' do
        shirt = create(:unified_object_type, category: 'Top')
        pants = create(:unified_object_type, category: 'Pants')

        results = UnifiedObjectType.by_category('Top')
        expect(results).to include(shirt)
        expect(results).not_to include(pants)
      end
    end

    describe '.by_layer' do
      it 'filters by layer' do
        layer1 = create(:unified_object_type, layer: 1, dorder: 1)
        layer2 = create(:unified_object_type, layer: 2, dorder: 1)

        results = UnifiedObjectType.by_layer(1)
        expect(results).to include(layer1)
        expect(results).not_to include(layer2)
      end

      it 'orders by dorder' do
        first = create(:unified_object_type, layer: 1, dorder: 1)
        second = create(:unified_object_type, layer: 1, dorder: 2)
        third = create(:unified_object_type, layer: 1, dorder: 3)

        results = UnifiedObjectType.by_layer(1).all
        expect(results).to eq([first, second, third])
      end
    end
  end

  # ========================================
  # Persistence
  # ========================================

  describe 'persistence' do
    it 'saves and retrieves unified object type' do
      uot = create(:unified_object_type, name: 'Test Type', category: 'testing')
      retrieved = UnifiedObjectType.find(id: uot.id)
      expect(retrieved.name).to eq('Test Type')
      expect(retrieved.category).to eq('testing')
    end
  end
end
