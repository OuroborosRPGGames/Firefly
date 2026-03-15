# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterInstance, '#combat_preferences' do
  let(:character_instance) { create(:character_instance) }

  describe '#combat_preference' do
    it 'returns nil for unset key' do
      expect(character_instance.combat_preference(:melee_weapon_id)).to be_nil
    end

    it 'returns stored value' do
      character_instance.update(combat_preferences: Sequel.pg_jsonb_wrap({ 'melee_weapon_id' => 42 }))
      character_instance.refresh
      expect(character_instance.combat_preference(:melee_weapon_id)).to eq(42)
    end
  end

  describe '#set_combat_preference' do
    it 'sets a single preference' do
      character_instance.set_combat_preference(:melee_weapon_id, 99)
      character_instance.refresh
      expect(character_instance.combat_preference(:melee_weapon_id)).to eq(99)
    end

    it 'preserves other preferences when setting one' do
      character_instance.set_combat_preference(:melee_weapon_id, 99)
      character_instance.set_combat_preference(:ranged_weapon_id, 55)
      character_instance.refresh
      expect(character_instance.combat_preference(:melee_weapon_id)).to eq(99)
      expect(character_instance.combat_preference(:ranged_weapon_id)).to eq(55)
    end

    it 'handles nil value (clear preference)' do
      character_instance.set_combat_preference(:melee_weapon_id, 99)
      character_instance.set_combat_preference(:melee_weapon_id, nil)
      character_instance.refresh
      expect(character_instance.combat_preference(:melee_weapon_id)).to be_nil
    end
  end
end
