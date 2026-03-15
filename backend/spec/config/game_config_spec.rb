# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe GameConfig::Mechanics do
  describe 'MOVEMENT constants' do
    it 'scales base movement to 6 hexes' do
      expect(GameConfig::Mechanics::MOVEMENT[:base]).to eq(6)
    end

    it 'scales sprint bonus to 5 hexes' do
      expect(GameConfig::Mechanics::MOVEMENT[:sprint_bonus]).to eq(5)
    end

    it 'scales quick tactic bonus to 2 hexes' do
      expect(GameConfig::Mechanics::MOVEMENT[:quick_tactic_bonus]).to eq(2)
    end
  end
end

RSpec.describe GameConfig::Tactics do
  describe 'MOVEMENT constants' do
    it 'scales quick tactic movement bonus to 2 hexes' do
      expect(GameConfig::Tactics::MOVEMENT['quick']).to eq(2)
    end

    it 'matches quick_tactic_bonus in Mechanics::MOVEMENT' do
      expect(GameConfig::Tactics::MOVEMENT['quick']).to eq(
        GameConfig::Mechanics::MOVEMENT[:quick_tactic_bonus]
      )
    end
  end
end

RSpec.describe GameConfig::Combat do
  describe 'AI_POSITIONING constants' do
    it 'scales optimal_ranged_distance to 6 hexes (4 × 1.5)' do
      expect(GameConfig::Combat::AI_POSITIONING[:optimal_ranged_distance]).to eq(6)
    end

    it 'scales min_ranged_distance to 5 hexes (3 × 1.5, rounded up)' do
      expect(GameConfig::Combat::AI_POSITIONING[:min_ranged_distance]).to eq(5)
    end

    it 'scales max_reposition_hexes to 5 hexes (3 × 1.5, rounded up)' do
      expect(GameConfig::Combat::AI_POSITIONING[:max_reposition_hexes]).to eq(5)
    end

    it 'does not change ranged_focus_threshold (ratio)' do
      expect(GameConfig::Combat::AI_POSITIONING[:ranged_focus_threshold]).to eq(0.7)
    end

    it 'does not change melee_focus_threshold (ratio)' do
      expect(GameConfig::Combat::AI_POSITIONING[:melee_focus_threshold]).to eq(0.7)
    end
  end
end

RSpec.describe GameConfig::NpcAttacks do
  describe 'WEAPON_TEMPLATES' do
    describe 'melee weapons' do
      it 'all require adjacency (1 hex)' do
        melee_weapons = %w[sword dagger greataxe mace spear staff greatsword rapier
                          bite claw tail horns slam sting]

        melee_weapons.each do |weapon|
          template = GameConfig::NpcAttacks::WEAPON_TEMPLATES[weapon]
          expect(template[:range_hexes]).to eq(1),
            "#{weapon} should have range 1 (adjacency)"
        end
      end
    end

    describe 'ranged weapons' do
      it 'scales bow range to 15 hexes' do
        expect(GameConfig::NpcAttacks::WEAPON_TEMPLATES['bow'][:range_hexes]).to eq(15)
      end

      it 'scales crossbow range to 23 hexes' do
        expect(GameConfig::NpcAttacks::WEAPON_TEMPLATES['crossbow'][:range_hexes]).to eq(23)
      end

      it 'scales throwing_knife range to 8 hexes' do
        expect(GameConfig::NpcAttacks::WEAPON_TEMPLATES['throwing_knife'][:range_hexes]).to eq(8)
      end

      it 'scales javelin range to 12 hexes' do
        expect(GameConfig::NpcAttacks::WEAPON_TEMPLATES['javelin'][:range_hexes]).to eq(12)
      end

      it 'scales breath weapons to 6 hexes' do
        expect(GameConfig::NpcAttacks::WEAPON_TEMPLATES['breath_fire'][:range_hexes]).to eq(6)
        expect(GameConfig::NpcAttacks::WEAPON_TEMPLATES['breath_ice'][:range_hexes]).to eq(6)
      end

      it 'scales spit range to 9 hexes' do
        expect(GameConfig::NpcAttacks::WEAPON_TEMPLATES['spit'][:range_hexes]).to eq(9)
      end
    end
  end
end

RSpec.describe GameConfig::AbilityDefaults do
  describe 'DEFAULT_RANGE_HEXES' do
    it 'scales to 8 hexes (5 × 1.5, rounded up)' do
      expect(GameConfig::AbilityDefaults::DEFAULT_RANGE_HEXES).to eq(8)
    end
  end
end

RSpec.describe GameConfig::Navigation do
  describe 'SMART_NAV constants' do
    it 'scales max_direct_walk to 23 hexes (15 × 1.5, rounded up)' do
      expect(GameConfig::Navigation::SMART_NAV[:max_direct_walk]).to eq(23)
    end

    it 'scales max_building_path to 30 hexes (20 × 1.5)' do
      expect(GameConfig::Navigation::SMART_NAV[:max_building_path]).to eq(30)
    end
  end

  describe 'COMBAT_PATHFINDING constants' do
    it 'scales max_path_length to 75 hexes (50 × 1.5)' do
      expect(GameConfig::Navigation::COMBAT_PATHFINDING[:max_path_length]).to eq(75)
    end
  end
end

RSpec.describe GameConfig::Pathfinding do
  describe 'MAX_PATH_LENGTH' do
    it 'scales to 75 hexes (50 × 1.5)' do
      expect(GameConfig::Pathfinding::MAX_PATH_LENGTH).to eq(75)
    end

    it 'matches Navigation::COMBAT_PATHFINDING[:max_path_length]' do
      expect(GameConfig::Pathfinding::MAX_PATH_LENGTH).to eq(
        GameConfig::Navigation::COMBAT_PATHFINDING[:max_path_length]
      )
    end
  end
end
