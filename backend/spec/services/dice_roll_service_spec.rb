# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DiceRollService do
  describe '.roll' do
    it 'rolls the specified number of dice with the specified sides' do
      result = described_class.roll(2, 6)

      expect(result.count).to eq(2)
      expect(result.sides).to eq(6)
      expect(result.dice.length).to eq(2)
      expect(result.dice.all? { |d| d >= 1 && d <= 6 }).to be true
    end

    it 'calculates total correctly without modifier' do
      result = described_class.roll(2, 6)

      expect(result.total).to eq(result.dice.sum)
    end

    it 'adds modifier to total' do
      result = described_class.roll(2, 6, modifier: 3)

      expect(result.modifier).to eq(3)
      expect(result.total).to eq(result.dice.sum + 3)
    end

    it 'handles exploding dice' do
      # Run multiple times to ensure exploding works
      results_with_explosions = []

      100.times do
        result = described_class.roll(2, 8, explode_on: 8)
        results_with_explosions << result if result.explosions.any?
      end

      # With 100 tries, we should get some explosions (probability ~23% per roll)
      expect(results_with_explosions).not_to be_empty
    end

    it 'includes explosion dice in total' do
      result = described_class.roll(2, 8, explode_on: 8)

      # result.dice includes all dice (base + explosions)
      # result.explosions contains INDICES, not values
      expected_total = result.dice.sum + result.modifier
      expect(result.total).to eq(expected_total)
    end
  end

  describe '.roll_2d8_exploding' do
    it 'rolls 2d8 with exploding 8s' do
      result = described_class.roll_2d8_exploding

      expect(result.count).to eq(2)
      expect(result.sides).to eq(8)
      expect(result.explode_on).to eq(8)
      expect(result.base_dice.length).to eq(2)
      expect(result.base_dice.all? { |d| d >= 1 && d <= 8 }).to be true
    end

    it 'includes modifier in result' do
      result = described_class.roll_2d8_exploding(5)

      expect(result.modifier).to eq(5)
    end
  end

  describe '.generate_animation_data' do
    it 'generates properly formatted animation data' do
      roll_result = described_class.roll_2d8_exploding(3)

      animation_data = described_class.generate_animation_data(
        roll_result,
        character_name: 'Test Character',
        color: '#ff0000'
      )

      expect(animation_data).to be_a(String)
      expect(animation_data).to include('Test Character')
      expect(animation_data).to include('#ff0000')
      expect(animation_data).to include('|||')
    end

    it 'includes explosion data when dice explode' do
      # Force a roll with an explosion for testing
      exploding_result = DiceRollService::RollResult.new(
        dice: [8, 3, 5],
        base_dice: [8, 3],
        explosions: [0],
        modifier: 2,
        total: 18,
        count: 2,
        sides: 8,
        explode_on: 8
      )

      animation_data = described_class.generate_animation_data(
        exploding_result,
        character_name: 'Roller',
        color: '#00ff00'
      )

      # Should have 3 dice elements (2 base + 1 explosion)
      dice_count = animation_data.scan('(())').count + 1
      expect(dice_count).to eq(3)
    end
  end

  describe 'RollResult struct' do
    it 'has all expected attributes' do
      result = DiceRollService::RollResult.new(
        dice: [4, 5],
        base_dice: [4, 5],
        explosions: [],
        modifier: 0,
        total: 9,
        count: 2,
        sides: 6,
        explode_on: nil
      )

      expect(result.dice).to eq([4, 5])
      expect(result.base_dice).to eq([4, 5])
      expect(result.explosions).to eq([])
      expect(result.modifier).to eq(0)
      expect(result.total).to eq(9)
      expect(result.count).to eq(2)
      expect(result.sides).to eq(6)
      expect(result.explode_on).to be_nil
    end
  end
end
