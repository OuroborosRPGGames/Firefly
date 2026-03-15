# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcAttack do
  describe '#initialize' do
    it 'sets default values for missing attributes' do
      attack = described_class.new({})

      expect(attack.name).to eq('Attack')
      expect(attack.attack_type).to eq('melee')
      expect(attack.damage_dice).to eq('2d6')
      expect(attack.damage_type).to eq('physical')
      expect(attack.attack_speed).to eq(5)
      expect(attack.range_hexes).to eq(1)
    end

    it 'uses provided values' do
      attack = described_class.new(
        'name' => 'Fire Breath',
        'attack_type' => 'ranged',
        'damage_dice' => '4d8',
        'damage_type' => 'fire',
        'attack_speed' => 3,
        'range_hexes' => 6
      )

      expect(attack.name).to eq('Fire Breath')
      expect(attack.attack_type).to eq('ranged')
      expect(attack.damage_dice).to eq('4d8')
      expect(attack.damage_type).to eq('fire')
      expect(attack.attack_speed).to eq(3)
      expect(attack.range_hexes).to eq(6)
    end

    it 'accepts symbol keys' do
      attack = described_class.new(
        name: 'Claw',
        attack_type: 'melee',
        damage_dice: '2d8'
      )

      expect(attack.name).to eq('Claw')
      expect(attack.attack_type).to eq('melee')
      expect(attack.damage_dice).to eq('2d8')
    end

    it 'stores optional message attributes' do
      attack = described_class.new(
        'hit_message' => '%{attacker} bites %{target}!',
        'miss_message' => '%{attacker} misses %{target}.',
        'critical_message' => '%{attacker} critically bites %{target}!'
      )

      expect(attack.hit_message).to eq('%{attacker} bites %{target}!')
      expect(attack.miss_message).to eq('%{attacker} misses %{target}.')
      expect(attack.critical_message).to eq('%{attacker} critically bites %{target}!')
    end

    it 'stores weapon template reference' do
      attack = described_class.new('weapon_template' => 'sword')
      expect(attack.weapon_template).to eq('sword')
    end

    it 'uses default melee reach from game config' do
      attack = described_class.new({})
      expect(attack.melee_reach).to eq(GameConfig::Mechanics::REACH[:unarmed_reach])
    end

    it 'uses provided melee reach' do
      attack = described_class.new('melee_reach' => 3)
      expect(attack.melee_reach).to eq(3)
    end
  end

  describe '.from_template' do
    before do
      stub_const('GameConfig::NpcAttacks::WEAPON_TEMPLATES', {
        'sword' => {
          'attack_type' => 'melee',
          'damage_dice' => '2d8',
          'damage_type' => 'slashing',
          'attack_speed' => 4,
          'range_hexes' => 1
        },
        'bow' => {
          'attack_type' => 'ranged',
          'damage_dice' => '2d6',
          'damage_type' => 'piercing',
          'attack_speed' => 5,
          'range_hexes' => 8
        }
      })
    end

    it 'creates attack from known template' do
      attack = described_class.from_template('sword')

      expect(attack.name).to eq('Sword')
      expect(attack.attack_type).to eq('melee')
      expect(attack.damage_dice).to eq('2d8')
      expect(attack.weapon_template).to eq('sword')
    end

    it 'allows name override' do
      attack = described_class.from_template('sword', name: 'Rusty Blade')
      expect(attack.name).to eq('Rusty Blade')
    end

    it 'allows attribute overrides' do
      attack = described_class.from_template('sword', damage_dice: '3d8')
      expect(attack.damage_dice).to eq('3d8')
    end

    it 'raises error for unknown template' do
      expect { described_class.from_template('unknown') }.to raise_error(ArgumentError, /Unknown weapon template/)
    end
  end

  describe '#melee?' do
    it 'returns true for melee attacks' do
      attack = described_class.new('attack_type' => 'melee')
      expect(attack.melee?).to be true
    end

    it 'returns false for ranged attacks' do
      attack = described_class.new('attack_type' => 'ranged')
      expect(attack.melee?).to be false
    end
  end

  describe '#ranged?' do
    it 'returns true for ranged attacks' do
      attack = described_class.new('attack_type' => 'ranged')
      expect(attack.ranged?).to be true
    end

    it 'returns false for melee attacks' do
      attack = described_class.new('attack_type' => 'melee')
      expect(attack.ranged?).to be false
    end
  end

  describe '#dice_count' do
    it 'parses dice count from damage dice string' do
      attack = described_class.new('damage_dice' => '3d6')
      expect(attack.dice_count).to eq(3)
    end

    it 'handles single die' do
      attack = described_class.new('damage_dice' => '1d10')
      expect(attack.dice_count).to eq(1)
    end
  end

  describe '#dice_sides' do
    it 'parses dice sides from damage dice string' do
      attack = described_class.new('damage_dice' => '2d8')
      expect(attack.dice_sides).to eq(8)
    end

    it 'handles d20' do
      attack = described_class.new('damage_dice' => '1d20')
      expect(attack.dice_sides).to eq(20)
    end
  end

  describe '#expected_damage' do
    it 'calculates expected damage for 2d6' do
      attack = described_class.new('damage_dice' => '2d6')
      # 2 dice * (6+1)/2 average = 2 * 3.5 = 7
      expect(attack.expected_damage).to eq(7.0)
    end

    it 'calculates expected damage for 3d8' do
      attack = described_class.new('damage_dice' => '3d8')
      # 3 dice * (8+1)/2 average = 3 * 4.5 = 13.5
      expect(attack.expected_damage).to eq(13.5)
    end

    it 'calculates expected damage for 1d12' do
      attack = described_class.new('damage_dice' => '1d12')
      # 1 die * (12+1)/2 average = 6.5
      expect(attack.expected_damage).to eq(6.5)
    end
  end

  describe '#format_hit_message' do
    before do
      stub_const('GameConfig::NpcAttacks::DEFAULT_MESSAGES', {
        'default' => {
          hit: '%{attacker} hits %{target}.',
          miss: '%{attacker} misses %{target}.',
          critical: '%{attacker} critically hits %{target}!'
        }
      })
    end

    it 'formats provided hit message' do
      attack = described_class.new('hit_message' => '%{attacker} bites %{target}!')
      result = attack.format_hit_message(attacker_name: 'Wolf', target_name: 'Hero')
      expect(result).to eq('Wolf bites Hero!')
    end

    it 'uses default message when not provided' do
      attack = described_class.new({})
      result = attack.format_hit_message(attacker_name: 'Wolf', target_name: 'Hero')
      expect(result).to eq('Wolf hits Hero.')
    end
  end

  describe '#format_miss_message' do
    before do
      stub_const('GameConfig::NpcAttacks::DEFAULT_MESSAGES', {
        'default' => {
          hit: '%{attacker} hits %{target}.',
          miss: '%{attacker} misses %{target}.',
          critical: '%{attacker} critically hits %{target}!'
        }
      })
    end

    it 'formats provided miss message' do
      attack = described_class.new('miss_message' => '%{attacker} snaps at %{target} but misses!')
      result = attack.format_miss_message(attacker_name: 'Wolf', target_name: 'Hero')
      expect(result).to eq('Wolf snaps at Hero but misses!')
    end
  end

  describe '#format_critical_message' do
    before do
      stub_const('GameConfig::NpcAttacks::DEFAULT_MESSAGES', {
        'default' => {
          hit: '%{attacker} hits %{target}.',
          miss: '%{attacker} misses %{target}.',
          critical: '%{attacker} critically hits %{target}!'
        }
      })
    end

    it 'formats provided critical message' do
      attack = described_class.new('critical_message' => '%{attacker} savages %{target}!')
      result = attack.format_critical_message(attacker_name: 'Wolf', target_name: 'Hero')
      expect(result).to eq('Wolf savages Hero!')
    end
  end

  describe '#in_range?' do
    it 'returns true when target is within range' do
      attack = described_class.new('range_hexes' => 3)
      expect(attack.in_range?(2)).to be true
    end

    it 'returns true when target is at max range' do
      attack = described_class.new('range_hexes' => 3)
      expect(attack.in_range?(3)).to be true
    end

    it 'returns false when target is beyond range' do
      attack = described_class.new('range_hexes' => 3)
      expect(attack.in_range?(4)).to be false
    end
  end

  describe '#melee_reach_value' do
    it 'returns melee_reach for melee attacks' do
      attack = described_class.new('attack_type' => 'melee', 'melee_reach' => 2)
      expect(attack.melee_reach_value).to eq(2)
    end

    it 'returns nil for ranged attacks' do
      attack = described_class.new('attack_type' => 'ranged', 'melee_reach' => 2)
      expect(attack.melee_reach_value).to be_nil
    end
  end

  describe '#to_h' do
    it 'converts attack to hash for storage' do
      attack = described_class.new(
        'name' => 'Bite',
        'attack_type' => 'melee',
        'damage_dice' => '2d6',
        'damage_type' => 'piercing',
        'attack_speed' => 4,
        'range_hexes' => 1
      )

      hash = attack.to_h

      expect(hash['name']).to eq('Bite')
      expect(hash['attack_type']).to eq('melee')
      expect(hash['damage_dice']).to eq('2d6')
      expect(hash['damage_type']).to eq('piercing')
    end

    it 'excludes nil values' do
      attack = described_class.new('name' => 'Simple')
      hash = attack.to_h

      expect(hash).not_to have_key('weapon_template')
      expect(hash).not_to have_key('hit_message')
    end
  end

  describe '#==' do
    it 'returns true for equal attacks' do
      attack1 = described_class.new('name' => 'Bite', 'damage_dice' => '2d6')
      attack2 = described_class.new('name' => 'Bite', 'damage_dice' => '2d6')

      expect(attack1 == attack2).to be true
    end

    it 'returns false for different attacks' do
      attack1 = described_class.new('name' => 'Bite', 'damage_dice' => '2d6')
      attack2 = described_class.new('name' => 'Claw', 'damage_dice' => '2d8')

      expect(attack1 == attack2).to be false
    end

    it 'returns false when compared to non-NpcAttack' do
      attack = described_class.new('name' => 'Bite')
      expect(attack == 'not an attack').to be false
    end
  end
end
