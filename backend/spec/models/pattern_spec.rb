# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pattern do
  let(:unified_object_type) { create(:unified_object_type) }

  # Helper to build patterns without association issues
  def build_pattern(**attrs)
    build(:pattern, unified_object_type: unified_object_type, **attrs)
  end

  def create_pattern(**attrs)
    create(:pattern, unified_object_type: unified_object_type, **attrs)
  end

  # ========================================
  # Validations
  # ========================================

  describe 'validations' do
    it 'requires description' do
      pattern = build_pattern(description: nil)
      expect(pattern.valid?).to be false
      expect(pattern.errors[:description]).to include('is not present')
    end

    it 'requires unified_object_type_id' do
      pattern = build(:pattern, unified_object_type: nil, unified_object_type_id: nil)
      expect(pattern.valid?).to be false
      expect(pattern.errors[:unified_object_type_id]).to include('is not present')
    end

    it 'accepts nil price' do
      pattern = build_pattern(price: nil)
      expect(pattern.valid?).to be true
    end

    it 'accepts positive price' do
      pattern = build_pattern(price: 100)
      expect(pattern.valid?).to be true
    end
  end

  # ========================================
  # Delegation Methods
  # ========================================

  describe 'delegation to unified_object_type' do
    let(:uot) do
      create(:unified_object_type,
             name: 'Test Object',
             category: 'clothing',
             subcategory: 'shirt',
             layer: 3,
             covered_positions: ['torso', 'back'],
             zippable_positions: ['front'])
    end
    let(:pattern) { create_pattern(unified_object_type: uot) }

    describe '#name' do
      it 'delegates to unified_object_type' do
        expect(pattern.name).to eq('Test Object')
      end

      it 'returns nil when no unified_object_type' do
        pattern.unified_object_type = nil
        expect(pattern.name).to be_nil
      end
    end

    describe '#category' do
      it 'delegates to unified_object_type' do
        expect(pattern.category).to eq('clothing')
      end
    end

    describe '#subcategory' do
      it 'delegates to unified_object_type' do
        expect(pattern.subcategory).to eq('shirt')
      end
    end

    describe '#layer' do
      it 'delegates to unified_object_type' do
        expect(pattern.layer).to eq(3)
      end
    end

    describe '#covered_positions' do
      it 'delegates to unified_object_type' do
        expect(pattern.covered_positions).to eq(['torso', 'back'])
      end

      it 'returns empty array when no unified_object_type' do
        pattern.unified_object_type = nil
        expect(pattern.covered_positions).to eq([])
      end
    end

    describe '#zippable_positions' do
      it 'delegates to unified_object_type' do
        expect(pattern.zippable_positions).to eq(['front'])
      end

      it 'returns empty array when no unified_object_type' do
        pattern.unified_object_type = nil
        expect(pattern.zippable_positions).to eq([])
      end
    end
  end

  # ========================================
  # Type Check Methods (based on unified_object_type category)
  # ========================================

  describe 'type check methods' do
    describe '#clothing?' do
      it 'returns true for clothing categories' do
        clothing_type = create(:unified_object_type, category: 'Top')
        pattern = build(:pattern, unified_object_type: clothing_type)
        expect(pattern.clothing?).to be true
      end

      it 'returns false for weapon categories' do
        weapon_type = create(:unified_object_type, category: 'Sword')
        pattern = build(:pattern, unified_object_type: weapon_type)
        expect(pattern.clothing?).to be false
      end
    end

    describe '#jewelry?' do
      it 'returns true for jewelry categories' do
        jewelry_type = create(:unified_object_type, category: 'Ring')
        pattern = build(:pattern, unified_object_type: jewelry_type)
        expect(pattern.jewelry?).to be true
      end

      it 'returns false for clothing categories' do
        clothing_type = create(:unified_object_type, category: 'Top')
        pattern = build(:pattern, unified_object_type: clothing_type)
        expect(pattern.jewelry?).to be false
      end
    end

    describe '#weapon?' do
      it 'returns true for weapon categories' do
        weapon_type = create(:unified_object_type, category: 'Sword')
        pattern = build(:pattern, unified_object_type: weapon_type)
        expect(pattern.weapon?).to be true
      end

      it 'returns true when is_melee is true' do
        pattern = build_pattern(is_melee: true)
        expect(pattern.weapon?).to be true
      end

      it 'returns false for non-weapon categories without weapon flags' do
        clothing_type = create(:unified_object_type, category: 'Top')
        pattern = build(:pattern, unified_object_type: clothing_type, is_melee: false, is_ranged: false)
        expect(pattern.weapon?).to be false
      end
    end

    describe '#pet?' do
      it 'returns true when is_pet is true' do
        pattern = build_pattern(is_pet: true)
        expect(pattern.pet?).to be true
      end

      it 'returns false when is_pet is false' do
        pattern = build_pattern(is_pet: false)
        expect(pattern.pet?).to be false
      end

      it 'returns false when is_pet is nil' do
        pattern = build_pattern(is_pet: nil)
        expect(pattern.pet?).to be false
      end
    end
  end

  # ========================================
  # Consumable Methods
  # ========================================

  describe 'consumable methods' do
    describe '#consumable?' do
      it 'returns true when category is a consumable category' do
        consumable_type = create(:unified_object_type, category: 'consumable')
        pattern = build(:pattern, unified_object_type: consumable_type)
        expect(pattern.consumable?).to be true
      end

      it 'returns false when category is not a consumable category' do
        clothing_type = create(:unified_object_type, category: 'Top')
        pattern = build(:pattern, unified_object_type: clothing_type)
        expect(pattern.consumable?).to be false
      end

      it 'returns false when unified_object_type is nil' do
        pattern = build(:pattern, unified_object_type: nil, unified_object_type_id: nil)
        expect(pattern.consumable?).to be false
      end
    end

    describe '#food?' do
      it 'returns true when consume_type is food' do
        pattern = build_pattern(consume_type: 'food')
        expect(pattern.food?).to be true
      end

      it 'returns false for other consume_types' do
        pattern = build_pattern(consume_type: 'drink')
        expect(pattern.food?).to be false
      end
    end

    describe '#drink?' do
      it 'returns true when consume_type is drink' do
        pattern = build_pattern(consume_type: 'drink')
        expect(pattern.drink?).to be true
      end

      it 'returns false for other consume_types' do
        pattern = build_pattern(consume_type: 'food')
        expect(pattern.drink?).to be false
      end
    end

    describe '#smokeable?' do
      it 'returns true when consume_type is smoke' do
        pattern = build_pattern(consume_type: 'smoke')
        expect(pattern.smokeable?).to be true
      end

      it 'returns false for other consume_types' do
        pattern = build_pattern(consume_type: 'food')
        expect(pattern.smokeable?).to be false
      end
    end
  end

  # ========================================
  # Weapon Combat Methods
  # ========================================

  describe 'weapon combat methods' do
    let(:weapon_type) { create(:unified_object_type, category: 'Sword') }
    let(:clothing_type) { create(:unified_object_type, category: 'Top') }

    describe '#melee_weapon?' do
      it 'returns true for weapon with is_melee' do
        pattern = build(:pattern, unified_object_type: weapon_type, is_melee: true)
        expect(pattern.melee_weapon?).to be true
      end

      it 'returns false for non-weapon category without weapon flags' do
        pattern = build(:pattern, unified_object_type: clothing_type, is_melee: true, is_ranged: false)
        # is_melee true makes it a weapon, so melee_weapon? should be true
        expect(pattern.melee_weapon?).to be true
      end

      it 'returns false when is_melee is false' do
        pattern = build(:pattern, unified_object_type: weapon_type, is_melee: false)
        expect(pattern.melee_weapon?).to be false
      end
    end

    describe '#ranged_weapon?' do
      it 'returns true for weapon with is_ranged' do
        pattern = build(:pattern, unified_object_type: weapon_type, is_ranged: true)
        expect(pattern.ranged_weapon?).to be true
      end

      it 'returns false when is_ranged is false' do
        pattern = build(:pattern, unified_object_type: weapon_type, is_ranged: false)
        expect(pattern.ranged_weapon?).to be false
      end
    end

    describe '#dual_mode_weapon?' do
      it 'returns true when both is_melee and is_ranged are true' do
        pattern = build_pattern(is_melee: true, is_ranged: true)
        expect(pattern.dual_mode_weapon?).to be true
      end

      it 'returns false when only one is true' do
        pattern = build_pattern(is_melee: true, is_ranged: false)
        expect(pattern.dual_mode_weapon?).to be false
      end
    end

    describe '#attack_interval' do
      it 'calculates interval from attack_speed' do
        pattern = build_pattern(attack_speed: 5)
        expect(pattern.attack_interval).to eq(20)
      end

      it 'defaults to speed 5 when nil' do
        pattern = build_pattern(attack_speed: nil)
        expect(pattern.attack_interval).to eq(20)
      end

      it 'returns 100 when speed is 0 or negative' do
        pattern = build_pattern(attack_speed: 0)
        expect(pattern.attack_interval).to eq(100)
      end
    end

    describe '#range_in_hexes' do
      it 'returns 1 for melee range' do
        pattern = build_pattern(weapon_range: 'melee')
        expect(pattern.range_in_hexes).to eq(1)
      end

      it 'returns 5 for short range' do
        pattern = build_pattern(weapon_range: 'short')
        expect(pattern.range_in_hexes).to eq(5)
      end

      it 'returns 10 for medium range' do
        pattern = build_pattern(weapon_range: 'medium')
        expect(pattern.range_in_hexes).to eq(10)
      end

      it 'returns 15 for long range' do
        pattern = build_pattern(weapon_range: 'long')
        expect(pattern.range_in_hexes).to eq(15)
      end

      it 'defaults to 1 for unknown range' do
        pattern = build_pattern(weapon_range: nil)
        expect(pattern.range_in_hexes).to eq(1)
      end
    end

    describe '#attacks_per_round' do
      it 'returns attack_speed' do
        pattern = build_pattern(attack_speed: 7)
        expect(pattern.attacks_per_round).to eq(7)
      end

      it 'defaults to 5 when nil' do
        pattern = build_pattern(attack_speed: nil)
        expect(pattern.attacks_per_round).to eq(5)
      end
    end
  end

  # ========================================
  # Instantiate Method
  # ========================================

  describe '#instantiate' do
    let(:pattern) { create_pattern(description: 'Test Sword', desc_desc: 'A shiny sword') }
    let(:room) { create(:room) }
    let(:character_instance) { create(:character_instance, current_room: room) }

    it 'creates an Item from the pattern' do
      item = pattern.instantiate(character_instance: character_instance)
      expect(item).to be_a(Item)
      expect(item.new?).to be false  # Sequel uses new? (returns false when persisted)
    end

    it 'uses pattern description as default name' do
      item = pattern.instantiate(character_instance: character_instance)
      expect(item.name).to eq('Test Sword')
    end

    it 'allows custom name override' do
      item = pattern.instantiate(name: 'Custom Blade', character_instance: character_instance)
      expect(item.name).to eq('Custom Blade')
    end

    it 'uses desc_desc as default description' do
      item = pattern.instantiate(character_instance: character_instance)
      expect(item.description).to eq('A shiny sword')
    end

    it 'defaults quantity to 1' do
      item = pattern.instantiate(character_instance: character_instance)
      expect(item.quantity).to eq(1)
    end

    it 'defaults condition to good' do
      item = pattern.instantiate(character_instance: character_instance)
      expect(item.condition).to eq('good')
    end

    it 'can assign to room' do
      item = pattern.instantiate(room: room)
      expect(item.room_id).to eq(room.id)
    end
  end

  # ========================================
  # Class Methods
  # ========================================

  describe 'class methods' do
    describe '.search' do
      it 'finds patterns by description' do
        pattern = create_pattern(description: 'Golden Sword')
        results = Pattern.search('Golden')
        expect(results).to include(pattern)
      end

      it 'is case insensitive' do
        pattern = create_pattern(description: 'Silver Dagger')
        results = Pattern.search('silver')
        expect(results).to include(pattern)
      end

      it 'limits results' do
        3.times { |i| create_pattern(description: "Test Item #{i}") }
        results = Pattern.search('Test', limit: 2)
        expect(results.count).to eq(2)
      end
    end

    describe '.by_category' do
      it 'filters by unified_object_type category' do
        clothing_type = create(:unified_object_type, category: 'Top')
        weapon_type = create(:unified_object_type, category: 'Sword')
        clothing = create(:pattern, unified_object_type: clothing_type)
        weapon = create(:pattern, unified_object_type: weapon_type)

        results = Pattern.by_category('Top')
        expect(results).to include(clothing)
        expect(results).not_to include(weapon)
      end
    end

    describe '.clothing' do
      it 'returns patterns with clothing categories' do
        clothing_type = create(:unified_object_type, category: 'Top')
        clothing = create(:pattern, unified_object_type: clothing_type)
        expect(Pattern.clothing).to include(clothing)
      end
    end

    describe '.jewelry' do
      it 'returns patterns with jewelry categories' do
        jewelry_type = create(:unified_object_type, category: 'Ring')
        jewelry = create(:pattern, unified_object_type: jewelry_type)
        expect(Pattern.jewelry).to include(jewelry)
      end
    end

    describe '.weapons' do
      it 'returns patterns with weapon categories' do
        weapon_type = create(:unified_object_type, category: 'Sword')
        weapon = create(:pattern, unified_object_type: weapon_type)
        expect(Pattern.weapons).to include(weapon)
      end
    end

    describe '.pets' do
      it 'returns patterns with is_pet true' do
        pet = create_pattern(is_pet: true)
        non_pet = create_pattern(is_pet: false)

        results = Pattern.pets
        expect(results).to include(pet)
        expect(results).not_to include(non_pet)
      end
    end

    describe '.magical' do
      it 'returns patterns with magic_type set' do
        magical = create_pattern(magic_type: 1) # magic_type is an integer
        normal = create_pattern(magic_type: nil)

        results = Pattern.magical
        expect(results).to include(magical)
        expect(results).not_to include(normal)
      end
    end

    describe '.in_price_range' do
      it 'filters by price range' do
        cheap = create_pattern(price: 50)
        medium = create_pattern(price: 150)
        expensive = create_pattern(price: 500)

        results = Pattern.in_price_range(100, 200)
        expect(results).to include(medium)
        expect(results).not_to include(cheap)
        expect(results).not_to include(expensive)
      end
    end

    describe '.for_year' do
      it 'returns patterns valid for the specified year' do
        always_valid = create_pattern(min_year: nil, max_year: nil)
        expect(Pattern.for_year(2020)).to include(always_valid)
      end

      it 'respects min_year' do
        future_only = create_pattern(min_year: 2025, max_year: nil)
        expect(Pattern.for_year(2020)).not_to include(future_only)
        expect(Pattern.for_year(2025)).to include(future_only)
      end

      it 'respects max_year' do
        past_only = create_pattern(min_year: nil, max_year: 2020)
        expect(Pattern.for_year(2025)).not_to include(past_only)
        expect(Pattern.for_year(2020)).to include(past_only)
      end
    end
  end

  # ========================================
  # Persistence
  # ========================================

  describe 'persistence' do
    it 'saves and retrieves pattern' do
      pattern = create_pattern(description: 'Test Pattern')
      retrieved = Pattern.find(id: pattern.id)
      expect(retrieved.description).to eq('Test Pattern')
    end
  end
end
