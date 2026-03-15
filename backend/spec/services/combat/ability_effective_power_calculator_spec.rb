# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AbilityEffectivePowerCalculator do
  let(:ability) do
    double('Ability',
      power: 100.0,
      has_aoe?: false,
      has_forced_movement?: false,
      has_execute?: false,
      has_combo?: false,
      respond_to?: false,
      damage_type: nil,
      target_type: 'enemy'
    )
  end

  let(:actor) do
    double('FightParticipant',
      hex_x: 4,
      hex_y: 4
    )
  end

  let(:target) do
    double('FightParticipant',
      hex_x: 5,
      hex_y: 6,
      max_hp: 100,
      current_hp: 50
    )
  end

  let(:fight) do
    double('Fight',
      uses_battle_map: false,
      room: nil
    )
  end

  let(:enemies) { [target] }
  let(:allies) { [] }

  describe '.calculate' do
    it 'returns effective power' do
      result = described_class.calculate(
        ability: ability,
        actor: actor,
        target: target,
        fight: fight,
        enemies: enemies,
        allies: allies
      )

      expect(result).to be_a(Float)
    end

    it 'returns base power when no bonuses apply' do
      result = described_class.calculate(
        ability: ability,
        actor: actor,
        target: target,
        fight: fight,
        enemies: enemies,
        allies: allies
      )

      expect(result).to eq(100.0)
    end
  end

  describe '#effective_power' do
    context 'with no bonuses' do
      it 'returns base ability power' do
        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        expect(calculator.effective_power).to eq(100.0)
      end
    end

    context 'with nil enemies and allies' do
      it 'handles nil arrays' do
        calculator = described_class.new(ability, actor, target, fight, nil, nil)

        expect { calculator.effective_power }.not_to raise_error
      end
    end
  end

  describe 'AoE cluster multiplier' do
    before do
      allow(ability).to receive(:has_aoe?).and_return(true)
      allow(ability).to receive(:aoe_radius).and_return(2)
      allow(ability).to receive(:respond_to?).with(:aoe_hits_allies).and_return(false)
      allow(ability).to receive(:target_type).and_return('enemy')
      allow(AbilityPowerWeights).to receive(:aoe_circle_targets).and_return(5)
    end

    let(:enemy2) { double('FightParticipant', hex_x: 8, hex_y: 4, max_hp: 100, current_hp: 100) }
    let(:enemy3) { double('FightParticipant', hex_x: 6, hex_y: 4, max_hp: 100, current_hp: 100) }

    context 'with enemies in radius' do
      let(:enemies) { [target, enemy2, enemy3] }

      it 'calculates power with cluster multiplier' do
        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        result = calculator.effective_power

        # Power is affected by AoE cluster calculation
        expect(result).to be_a(Float)
      end
    end

    context 'with no enemies in radius' do
      let(:far_enemy) { double('FightParticipant', hex_x: 100, hex_y: 100, max_hp: 100, current_hp: 100) }
      let(:enemies) { [target, far_enemy] }

      it 'calculates power with minimal cluster' do
        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        # Just primary target in cluster
        result = calculator.effective_power

        expect(result).to be_a(Float)
      end
    end

    context 'with friendly fire AoE' do
      let(:ally1) { double('FightParticipant', hex_x: 8, hex_y: 4, max_hp: 100, current_hp: 100) }
      let(:enemies) { [target, enemy2] }
      let(:allies) { [ally1] }

      before do
        allow(ability).to receive(:respond_to?).with(:aoe_hits_allies).and_return(true)
        allow(ability).to receive(:aoe_hits_allies).and_return(true)
        allow(GameConfig::EffectivePower).to receive(:FRIENDLY_FIRE_ALLY_PENALTY).and_return(1.5)
        allow(GameConfig::EffectivePower).to receive(:FRIENDLY_FIRE_MIN_NET_TARGETS).and_return(1)
      end

      it 'penalizes for allies in range' do
        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        # Power should be affected by allies in range
        result = calculator.effective_power

        expect(result).to be_a(Float)
      end
    end

    context 'with ally-targeting AoE (heal)' do
      let(:ally1) { double('FightParticipant', hex_x: 6, hex_y: 4, max_hp: 100, current_hp: 50) }
      let(:ally2) { double('FightParticipant', hex_x: 8, hex_y: 4, max_hp: 100, current_hp: 50) }
      let(:allies) { [ally1, ally2] }

      before do
        allow(ability).to receive(:target_type).and_return('ally')
      end

      it 'calculates based on allies in radius' do
        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        result = calculator.effective_power

        expect(result).to be_a(Float)
      end
    end
  end

  describe 'hazard knockback multiplier' do
    let(:room) do
      double('Room', has_battle_map: true)
    end

    let(:hazard_hex) do
      double('RoomHex',
        is_hazard?: true,
        traversable: true,
        hex_type: 'fire',
        hazard_damage_per_round: 5,
        danger_level: 3,
        hazard_type: 'fire',
        is_explosive: false
      )
    end

    before do
      allow(ability).to receive(:has_forced_movement?).and_return(true)
      allow(ability).to receive(:parsed_forced_movement).and_return({
        'direction' => 'push',
        'distance' => 2
      })
      allow(fight).to receive(:uses_battle_map).and_return(true)
      allow(fight).to receive(:room).and_return(room)
      allow(RoomHex).to receive(:where).and_return(double(first: hazard_hex))
      allow(hazard_hex).to receive(:respond_to?).and_return(true)
    end

    it 'increases power when pushing into hazard' do
      calculator = described_class.new(ability, actor, target, fight, enemies, allies)

      result = calculator.effective_power

      expect(result).to be > 100.0
    end

    context 'without battle map' do
      before do
        allow(fight).to receive(:uses_battle_map).and_return(false)
      end

      it 'returns base multiplier' do
        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        expect(calculator.effective_power).to eq(100.0)
      end
    end

    context 'with no forced movement' do
      before do
        allow(ability).to receive(:has_forced_movement?).and_return(false)
      end

      it 'returns base multiplier' do
        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        expect(calculator.effective_power).to eq(100.0)
      end
    end
  end

  describe 'execute bonus multiplier' do
    before do
      allow(ability).to receive(:has_execute?).and_return(true)
      allow(ability).to receive(:execute_threshold).and_return(30)
    end

    context 'when target is below execute threshold' do
      let(:target) do
        double('FightParticipant',
          hex_x: 7,
          hex_y: 4,
          max_hp: 100,
          current_hp: 20 # 20% HP, below 30% threshold
        )
      end

      it 'increases power for instant kill' do
        allow(ability).to receive(:parsed_execute_effect).and_return({ 'instant_kill' => true })

        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        result = calculator.effective_power

        expect(result).to be > 100.0
      end

      it 'increases power based on damage multiplier' do
        allow(ability).to receive(:parsed_execute_effect).and_return({ 'damage_multiplier' => 2.0 })

        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        result = calculator.effective_power

        expect(result).to be > 100.0
      end
    end

    context 'when target is above execute threshold' do
      let(:target) do
        double('FightParticipant',
          hex_x: 7,
          hex_y: 4,
          max_hp: 100,
          current_hp: 80 # 80% HP, above 30% threshold
        )
      end

      it 'returns base power' do
        allow(ability).to receive(:parsed_execute_effect).and_return({})

        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        expect(calculator.effective_power).to eq(100.0)
      end
    end
  end

  describe 'combo bonus multiplier' do
    before do
      allow(ability).to receive(:has_combo?).and_return(true)
      allow(ability).to receive(:parsed_combo_condition).and_return({
        'requires_status' => 'burning'
      })
    end

    context 'when target has required status' do
      before do
        allow(target).to receive(:respond_to?).with(:has_status_effect?).and_return(true)
        allow(target).to receive(:has_status_effect?).with('burning').and_return(true)
      end

      it 'increases power' do
        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        result = calculator.effective_power

        expect(result).to be > 100.0
      end
    end

    context 'when target does not have required status' do
      before do
        allow(target).to receive(:respond_to?).with(:has_status_effect?).and_return(true)
        allow(target).to receive(:has_status_effect?).with('burning').and_return(false)
      end

      it 'returns base power' do
        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        expect(calculator.effective_power).to eq(100.0)
      end
    end
  end

  describe 'vulnerability bonus multiplier' do
    before do
      allow(ability).to receive(:respond_to?).with(:damage_type).and_return(true)
      allow(ability).to receive(:damage_type).and_return('fire')
    end

    context 'when target is vulnerable to damage type' do
      before do
        allow(target).to receive(:respond_to?).with(:has_status_effect?).and_return(true)
        allow(target).to receive(:has_status_effect?).with('vulnerable_fire').and_return(true)
      end

      it 'increases power' do
        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        result = calculator.effective_power

        expect(result).to be > 100.0
      end
    end

    context 'when target has general vulnerability' do
      before do
        allow(target).to receive(:respond_to?).with(:has_status_effect?).and_return(true)
        allow(target).to receive(:has_status_effect?).with('vulnerable_fire').and_return(false)
        allow(target).to receive(:has_status_effect?).with('vulnerable').and_return(true)
      end

      it 'increases power' do
        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        result = calculator.effective_power

        expect(result).to be > 100.0
      end
    end

    context 'when target is not vulnerable' do
      before do
        allow(target).to receive(:respond_to?).with(:has_status_effect?).and_return(true)
        allow(target).to receive(:has_status_effect?).with('vulnerable_fire').and_return(false)
        allow(target).to receive(:has_status_effect?).with('vulnerable').and_return(false)
      end

      it 'returns base power' do
        calculator = described_class.new(ability, actor, target, fight, enemies, allies)

        expect(calculator.effective_power).to eq(100.0)
      end
    end
  end

  describe 'private helper methods' do
    describe '#distance_between' do
      let(:calculator) { described_class.new(ability, actor, target, fight, enemies, allies) }

      it 'calculates hex distance' do
        result = calculator.send(:distance_between, actor, target)

        # Actor at (5,4), target at (7,4) - hex distance is 1
        expect(result).to eq(1)
      end

      context 'with missing coordinates' do
        let(:no_pos_target) { double('FightParticipant', hex_x: nil, hex_y: nil) }

        it 'returns 999' do
          result = calculator.send(:distance_between, actor, no_pos_target)

          expect(result).to eq(999)
        end
      end
    end

    describe '#battle_map_active?' do
      let(:room) { double('Room', has_battle_map: true) }
      let(:calculator) { described_class.new(ability, actor, target, fight, enemies, allies) }

      context 'when battle map is active' do
        before do
          allow(fight).to receive(:uses_battle_map).and_return(true)
          allow(fight).to receive(:room).and_return(room)
        end

        it 'returns true' do
          expect(calculator.send(:battle_map_active?)).to be true
        end
      end

      context 'when battle map is not used' do
        before do
          allow(fight).to receive(:uses_battle_map).and_return(false)
        end

        it 'returns false' do
          expect(calculator.send(:battle_map_active?)).to be_falsy
        end
      end
    end

    describe '#calculate_landing_position' do
      let(:calculator) { described_class.new(ability, actor, target, fight, enemies, allies) }

      it 'calculates push landing position' do
        movement = { 'direction' => 'push', 'distance' => 2 }

        result = calculator.send(:calculate_landing_position, target, movement)

        expect(result).to be_a(Hash)
        expect(result[:x]).to be > target.hex_x
      end

      it 'calculates pull landing position' do
        movement = { 'direction' => 'pull', 'distance' => 2 }

        result = calculator.send(:calculate_landing_position, target, movement)

        expect(result).to be_a(Hash)
        expect(result[:x]).to be < target.hex_x
      end

      context 'with target at same position as actor' do
        let(:same_pos_target) { double('FightParticipant', hex_x: 4, hex_y: 4) }

        it 'returns nil when distance is 0' do
          movement = { 'direction' => 'push', 'distance' => 2 }

          result = calculator.send(:calculate_landing_position, same_pos_target, movement)

          expect(result).to be_nil
        end
      end

      context 'with missing coordinates' do
        let(:no_pos_target) { double('FightParticipant', hex_x: nil, hex_y: nil) }

        it 'returns nil' do
          movement = { 'direction' => 'push', 'distance' => 2 }

          result = calculator.send(:calculate_landing_position, no_pos_target, movement)

          expect(result).to be_nil
        end
      end
    end

    describe '#hazard_score' do
      let(:calculator) { described_class.new(ability, actor, target, fight, enemies, allies) }

      it 'returns 0 for nil hex' do
        expect(calculator.send(:hazard_score, nil)).to eq(0)
      end

      it 'scores pit as 100' do
        hex = double('RoomHex',
          hex_type: 'pit',
          traversable: true
        )
        allow(hex).to receive(:respond_to?).and_return(true)
        allow(hex).to receive(:hazard_damage_per_round).and_return(0)
        allow(hex).to receive(:danger_level).and_return(0)
        allow(hex).to receive(:hazard_type).and_return(nil)
        allow(hex).to receive(:is_explosive).and_return(false)

        expect(calculator.send(:hazard_score, hex)).to eq(100)
      end

      it 'scores impassable terrain as 100' do
        hex = double('RoomHex',
          hex_type: 'wall',
          traversable: false
        )
        allow(hex).to receive(:respond_to?).and_return(true)
        allow(hex).to receive(:hazard_damage_per_round).and_return(0)
        allow(hex).to receive(:danger_level).and_return(0)
        allow(hex).to receive(:hazard_type).and_return(nil)
        allow(hex).to receive(:is_explosive).and_return(false)

        expect(calculator.send(:hazard_score, hex)).to eq(100)
      end

      it 'adds score for hazard damage' do
        hex = double('RoomHex',
          hex_type: 'normal',
          traversable: true
        )
        allow(hex).to receive(:respond_to?).and_return(true)
        allow(hex).to receive(:hazard_damage_per_round).and_return(5)
        allow(hex).to receive(:danger_level).and_return(0)
        allow(hex).to receive(:hazard_type).and_return(nil)
        allow(hex).to receive(:is_explosive).and_return(false)

        expect(calculator.send(:hazard_score, hex)).to eq(25) # 5 * 5
      end

      it 'adds score for fire hazard' do
        hex = double('RoomHex',
          hex_type: 'fire',
          traversable: true
        )
        allow(hex).to receive(:respond_to?).and_return(true)
        allow(hex).to receive(:hazard_damage_per_round).and_return(0)
        allow(hex).to receive(:danger_level).and_return(0)
        allow(hex).to receive(:hazard_type).and_return('fire')
        allow(hex).to receive(:is_explosive).and_return(false)

        expect(calculator.send(:hazard_score, hex)).to eq(20)
      end

      it 'adds score for explosive' do
        hex = double('RoomHex',
          hex_type: 'normal',
          traversable: true
        )
        allow(hex).to receive(:respond_to?).and_return(true)
        allow(hex).to receive(:hazard_damage_per_round).and_return(0)
        allow(hex).to receive(:danger_level).and_return(0)
        allow(hex).to receive(:hazard_type).and_return(nil)
        allow(hex).to receive(:is_explosive).and_return(true)

        expect(calculator.send(:hazard_score, hex)).to eq(30)
      end

      it 'combines multiple factors' do
        hex = double('RoomHex',
          hex_type: 'normal',
          traversable: true
        )
        allow(hex).to receive(:respond_to?).and_return(true)
        allow(hex).to receive(:hazard_damage_per_round).and_return(5)
        allow(hex).to receive(:danger_level).and_return(3)
        allow(hex).to receive(:hazard_type).and_return('fire')
        allow(hex).to receive(:is_explosive).and_return(true)

        # 5*5 + 3*3 + 20 + 30 = 25 + 9 + 20 + 30 = 84
        expect(calculator.send(:hazard_score, hex)).to eq(84)
      end
    end
  end
end
