# frozen_string_literal: true

require 'spec_helper'
require_relative '../../config/room_type_config'

RSpec.describe RoomTypeConfig do
  describe '.valid?' do
    it 'returns true for known types' do
      expect(described_class.valid?('shop')).to be true
      expect(described_class.valid?('forest')).to be true
      expect(described_class.valid?('standard')).to be true
    end

    it 'returns false for unknown types' do
      expect(described_class.valid?('nonexistent')).to be false
      expect(described_class.valid?('')).to be false
    end
  end

  describe '.all_types' do
    it 'returns all 84 room types' do
      expect(described_class.all_types.count).to eq(84)
    end

    it 'includes types from every category' do
      expect(described_class.all_types).to include('standard', 'shop', 'street', 'cave', 'forge')
    end
  end

  describe '.categories' do
    it 'returns all 12 categories' do
      expect(described_class.categories.keys).to match_array(
        %i[basic services water city residential commercial indoor_special
           outdoor_urban outdoor_nature underground system fabrication]
      )
    end

    it 'includes display names' do
      expect(described_class.categories[:services][:display_name]).to eq('Services')
    end

    it 'includes type lists per category' do
      expect(described_class.categories[:basic][:types]).to match_array(%w[standard safe combat])
    end
  end

  describe '.category_for' do
    it 'returns the category for a type' do
      expect(described_class.category_for('shop')).to eq(:services)
      expect(described_class.category_for('cave')).to eq(:underground)
      expect(described_class.category_for('street')).to eq(:city)
    end

    it 'returns nil for unknown types' do
      expect(described_class.category_for('nonexistent')).to be_nil
    end
  end

  describe '.types_in_category' do
    it 'returns types for a valid category' do
      expect(described_class.types_in_category(:water)).to match_array(%w[water lake river ocean pool])
    end

    it 'returns empty array for unknown category' do
      expect(described_class.types_in_category(:nonexistent)).to eq([])
    end
  end

  describe '.grouped_types' do
    it 'matches Room::ROOM_TYPES format' do
      grouped = described_class.grouped_types
      expect(grouped).to be_a(Hash)
      expect(grouped[:basic]).to match_array(%w[standard safe combat])
      expect(grouped[:services]).to include('shop', 'guild', 'temple')
    end
  end

  describe '.environment' do
    it 'returns :outdoor for nature types' do
      expect(described_class.environment('forest')).to eq(:outdoor)
      expect(described_class.environment('beach')).to eq(:outdoor)
    end

    it 'returns :outdoor for street types' do
      expect(described_class.environment('street')).to eq(:outdoor)
      expect(described_class.environment('avenue')).to eq(:outdoor)
    end

    it 'returns :outdoor for water types' do
      expect(described_class.environment('ocean')).to eq(:outdoor)
    end

    it 'returns :underground for underground types' do
      expect(described_class.environment('cave')).to eq(:underground)
      expect(described_class.environment('sewer')).to eq(:underground)
    end

    it 'returns :indoor for indoor types' do
      expect(described_class.environment('shop')).to eq(:indoor)
      expect(described_class.environment('bedroom')).to eq(:indoor)
    end

    it 'returns :indoor for unknown types' do
      expect(described_class.environment('nonexistent')).to eq(:indoor)
    end
  end

  describe '.badge_color' do
    it 'returns danger for combat types' do
      expect(described_class.badge_color('combat')).to eq('danger')
      expect(described_class.badge_color('arena')).to eq('danger')
    end

    it 'returns warning for training types' do
      expect(described_class.badge_color('dojo')).to eq('warning')
      expect(described_class.badge_color('gym')).to eq('warning')
    end

    it 'returns success for safe' do
      expect(described_class.badge_color('safe')).to eq('success')
    end

    it 'returns info for service types' do
      expect(described_class.badge_color('shop')).to eq('info')
      expect(described_class.badge_color('guild')).to eq('info')
      expect(described_class.badge_color('temple')).to eq('info')
    end

    it 'returns secondary for generic types' do
      expect(described_class.badge_color('standard')).to eq('secondary')
      expect(described_class.badge_color('nonexistent')).to eq('secondary')
    end
  end

  describe '.icon' do
    it 'returns type-specific icons' do
      expect(described_class.icon('shop')).to eq('[Shop]')
      expect(described_class.icon('bank')).to eq('[Bank]')
      expect(described_class.icon('water')).to eq('[Water]')
      expect(described_class.icon('street')).to eq('[Street]')
    end

    it 'returns [Place] for types without specific icons' do
      expect(described_class.icon('standard')).to eq('[Place]')
    end
  end

  describe '.battle_map' do
    it 'returns type-specific config merged with defaults' do
      config = described_class.battle_map('forest')
      expect(config[:surfaces]).to eq(%w[dirt grass])
      expect(config[:objects]).to include('tree', 'bush')
      expect(config[:difficult_terrain]).to be true
      # Defaults merged in
      expect(config[:dark]).to be false
      expect(config[:combat_optimized]).to be false
    end

    it 'returns type-specific config for standard' do
      config = described_class.battle_map('standard')
      expect(config[:surfaces]).to eq(%w[floor])
      expect(config[:objects]).to include('table', 'chair')
      expect(config[:density]).to be > 0
    end

    it 'returns defaults for unknown types' do
      config = described_class.battle_map('nonexistent')
      expect(config[:surfaces]).to eq(%w[floor])
      expect(config[:density]).to eq(0.10)
    end
  end

  describe '.tagged' do
    it 'returns street types' do
      expect(described_class.tagged(:street)).to match_array(%w[street avenue intersection])
    end

    it 'returns building entrance types' do
      entrances = described_class.tagged(:building_entrance)
      expect(entrances).to include('shop', 'temple', 'building')
    end

    it 'returns interior types' do
      interiors = described_class.tagged(:interior)
      expect(interiors).to include('shop', 'bedroom', 'arena', 'forge')
      expect(interiors).not_to include('street', 'forest', 'cave')
    end

    it 'returns interesting types' do
      interesting = described_class.tagged(:interesting)
      expect(interesting).to include('cave', 'dungeon', 'forest')
    end

    it 'returns excluded from atmosphere types' do
      excluded = described_class.tagged(:excluded_from_atmosphere)
      expect(excluded).to match_array(%w[staff death limbo tutorial])
    end

    it 'returns combat zone types' do
      zones = described_class.tagged(:combat_zone)
      expect(zones).to match_array(%w[combat arena dojo gym])
    end

    it 'returns empty array for unknown tags' do
      expect(described_class.tagged(:nonexistent)).to eq([])
    end
  end

  describe '.tagged?' do
    it 'returns true when type has tag' do
      expect(described_class.tagged?('street', :street)).to be true
      expect(described_class.tagged?('shop', :interior)).to be true
    end

    it 'returns false when type lacks tag' do
      expect(described_class.tagged?('street', :interior)).to be false
      expect(described_class.tagged?('shop', :street)).to be false
    end
  end

  describe 'convenience predicates' do
    it '.outdoor? checks environment' do
      expect(described_class.outdoor?('forest')).to be true
      expect(described_class.outdoor?('shop')).to be false
    end

    it '.indoor? checks environment' do
      expect(described_class.indoor?('shop')).to be true
      expect(described_class.indoor?('forest')).to be false
    end

    it '.underground? checks environment' do
      expect(described_class.underground?('cave')).to be true
      expect(described_class.underground?('forest')).to be false
    end

    it '.street? checks tag' do
      expect(described_class.street?('street')).to be true
      expect(described_class.street?('shop')).to be false
    end

    it '.building_entrance? checks tag' do
      expect(described_class.building_entrance?('shop')).to be true
      expect(described_class.building_entrance?('bedroom')).to be false
    end

    it '.combat_zone? checks tag' do
      expect(described_class.combat_zone?('arena')).to be true
      expect(described_class.combat_zone?('shop')).to be false
    end
  end

  describe '.reload!' do
    it 'clears cached data and reloads' do
      # Access data to populate cache
      described_class.all_types
      described_class.categories

      # Reload should not raise
      expect { described_class.reload! }.not_to raise_error

      # Data should still be accessible after reload
      expect(described_class.all_types.count).to eq(84)
    end
  end
end
