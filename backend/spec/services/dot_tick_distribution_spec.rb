# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'DOT Tick Distribution' do
  describe StatusEffectService do
    describe '.calculate_dot_tick_segments' do
      it 'distributes 10 damage evenly across 100 segments' do
        segments = StatusEffectService.calculate_dot_tick_segments(10)
        expect(segments).to eq([10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
      end

      it 'distributes 5 damage evenly' do
        segments = StatusEffectService.calculate_dot_tick_segments(5)
        expect(segments).to eq([20, 40, 60, 80, 100])
      end

      it 'distributes 3 damage evenly' do
        segments = StatusEffectService.calculate_dot_tick_segments(3)
        expect(segments).to eq([33, 67, 100])
      end

      it 'distributes 7 damage evenly' do
        segments = StatusEffectService.calculate_dot_tick_segments(7)
        expect(segments).to eq([14, 29, 43, 57, 71, 86, 100])
      end

      it 'handles 1 damage (single tick at end)' do
        segments = StatusEffectService.calculate_dot_tick_segments(1)
        expect(segments).to eq([100])
      end

      it 'returns empty array for 0 damage' do
        segments = StatusEffectService.calculate_dot_tick_segments(0)
        expect(segments).to eq([])
      end

      it 'returns empty array for negative damage' do
        segments = StatusEffectService.calculate_dot_tick_segments(-5)
        expect(segments).to eq([])
      end

      context 'with mid-round application' do
        it 'only returns ticks AFTER application segment' do
          # 10 damage applied at segment 45 = only ticks 50,60,70,80,90,100
          segments = StatusEffectService.calculate_dot_tick_segments(10, 45)
          expect(segments).to eq([50, 60, 70, 80, 90, 100])
        end

        it 'returns no ticks when applied at segment 100' do
          segments = StatusEffectService.calculate_dot_tick_segments(10, 100)
          expect(segments).to eq([])
        end

        it 'returns all ticks when applied at segment 0' do
          segments = StatusEffectService.calculate_dot_tick_segments(10, 0)
          expect(segments).to eq([10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
        end

        it 'handles 10 damage applied at segment 25' do
          # Ticks at 10,20 are skipped, 30-100 remain
          segments = StatusEffectService.calculate_dot_tick_segments(10, 25)
          expect(segments).to eq([30, 40, 50, 60, 70, 80, 90, 100])
        end

        it 'handles edge case of application at tick segment' do
          # 10 damage applied at segment 50 = ticks at 60,70,80,90,100 (5 ticks)
          segments = StatusEffectService.calculate_dot_tick_segments(10, 50)
          expect(segments).to eq([60, 70, 80, 90, 100])
        end
      end
    end
  end

  describe Ability do
    describe '#effective_timing_coefficient' do
      let(:ability) { Ability.new(name: 'Test', ability_type: 'combat', activation_segment: 50) }

      context 'when apply_timing_coefficient is false' do
        before { ability.apply_timing_coefficient = false }

        it 'returns 1.0 regardless of activation segment' do
          expect(ability.effective_timing_coefficient).to eq(1.0)
        end
      end

      context 'when apply_timing_coefficient is true' do
        before { ability.apply_timing_coefficient = true }

        it 'returns 0.5 for segment 50' do
          ability.activation_segment = 50
          expect(ability.effective_timing_coefficient).to eq(0.5)
        end

        it 'returns 0.1 for segment 10' do
          ability.activation_segment = 10
          expect(ability.effective_timing_coefficient).to eq(0.1)
        end

        it 'returns 1.0 for segment 100' do
          ability.activation_segment = 100
          expect(ability.effective_timing_coefficient).to eq(1.0)
        end

        it 'uses stored timing_coefficient if set' do
          ability.activation_segment = 50
          ability.timing_coefficient = 0.75
          expect(ability.effective_timing_coefficient).to eq(0.75)
        end
      end
    end

    describe '#base_timing_coefficient' do
      let(:ability) { Ability.new(name: 'Test', ability_type: 'combat') }

      it 'calculates coefficient from activation_segment' do
        ability.activation_segment = 25
        expect(ability.base_timing_coefficient).to eq(0.25)
      end

      it 'defaults to 0.5 when segment is nil' do
        ability.activation_segment = nil
        expect(ability.base_timing_coefficient).to eq(0.5)
      end

      it 'clamps minimum to 0.01' do
        ability.activation_segment = 0
        expect(ability.base_timing_coefficient).to eq(0.01)
      end
    end

    describe '#timing_coefficient_manually_set?' do
      let(:ability) { Ability.new(name: 'Test', ability_type: 'combat', activation_segment: 50) }

      it 'returns false when timing_coefficient is nil' do
        ability.timing_coefficient = nil
        expect(ability.timing_coefficient_manually_set?).to be false
      end

      it 'returns false when coefficient matches calculated' do
        ability.timing_coefficient = 0.5
        expect(ability.timing_coefficient_manually_set?).to be false
      end

      it 'returns true when coefficient differs from calculated' do
        ability.timing_coefficient = 0.75
        expect(ability.timing_coefficient_manually_set?).to be true
      end
    end
  end
end
