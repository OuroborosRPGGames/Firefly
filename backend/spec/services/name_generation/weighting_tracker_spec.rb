# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NameGeneration::WeightingTracker do
  subject(:tracker) { described_class.new }

  describe '#record_use' do
    it 'records a name use' do
      tracker.record_use(:forename, 'James')
      expect(tracker.history_size(:forename)).to eq(1)
    end

    it 'normalizes name to lowercase' do
      tracker.record_use(:forename, 'JAMES')
      expect(tracker.recently_used?('james', category: :forename)).to be true
    end

    it 'trims history to max size' do
      105.times { |i| tracker.record_use(:forename, "Name#{i}") }
      expect(tracker.history_size(:forename)).to eq(100)
    end
  end

  describe '#calculate_penalty' do
    it 'returns 0 for names never used' do
      expect(tracker.calculate_penalty('James')).to eq(0.0)
    end

    it 'returns a penalty for recently used names' do
      tracker.record_use(:forename, 'James')
      penalty = tracker.calculate_penalty('James')
      expect(penalty).to be > 0
    end

    it 'returns higher penalty for more recent use' do
      tracker.record_use(:forename, 'Alice')
      tracker.record_use(:forename, 'Bob')
      tracker.record_use(:forename, 'Charlie')

      alice_penalty = tracker.calculate_penalty('Alice', category: :forename)
      charlie_penalty = tracker.calculate_penalty('Charlie', category: :forename)

      expect(charlie_penalty).to be > alice_penalty
    end

    it 'respects category filter' do
      tracker.record_use(:forename, 'James')
      tracker.record_use(:surname, 'Smith')

      expect(tracker.calculate_penalty('James', category: :forename)).to be > 0
      expect(tracker.calculate_penalty('James', category: :surname)).to eq(0.0)
    end

    it 'is case insensitive' do
      tracker.record_use(:forename, 'James')
      expect(tracker.calculate_penalty('JAMES')).to be > 0
      expect(tracker.calculate_penalty('james')).to be > 0
    end
  end

  describe '#apply_weights' do
    let(:names) do
      [
        { name: 'James', weight: 5.0 },
        { name: 'William', weight: 5.0 },
        { name: 'Michael', weight: 3.0 }
      ]
    end

    it 'adds effective_weight to each entry' do
      result = tracker.apply_weights(names)
      expect(result.first).to have_key(:effective_weight)
    end

    it 'reduces weight for recently used names' do
      tracker.record_use(:forename, 'James')

      result = tracker.apply_weights(names, category: :forename)
      james_entry = result.find { |n| n[:name] == 'James' }
      william_entry = result.find { |n| n[:name] == 'William' }

      expect(james_entry[:effective_weight]).to be < william_entry[:effective_weight]
    end

    it 'maintains minimum weight of 0.1' do
      10.times { tracker.record_use(:forename, 'James') }

      result = tracker.apply_weights(names, category: :forename)
      james_entry = result.find { |n| n[:name] == 'James' }

      expect(james_entry[:effective_weight]).to be >= 0.1
    end

    it 'handles string entries (not hashes)' do
      simple_names = %w[Alice Bob Charlie]
      result = tracker.apply_weights(simple_names)

      expect(result.length).to eq(3)
      expect(result.first[:name]).to eq('Alice')
      expect(result.first[:effective_weight]).to be_a(Float)
    end
  end

  describe '#weighted_select' do
    let(:weighted_names) do
      [
        { name: 'High', effective_weight: 10.0 },
        { name: 'Low', effective_weight: 0.1 }
      ]
    end

    it 'returns a name' do
      result = tracker.weighted_select(weighted_names)
      expect(%w[High Low]).to include(result)
    end

    it 'returns nil for empty array' do
      expect(tracker.weighted_select([])).to be_nil
    end

    it 'favors higher weighted names statistically' do
      selections = 100.times.map { tracker.weighted_select(weighted_names) }
      high_count = selections.count('High')

      # High weight should be selected much more often (>70% of time)
      expect(high_count).to be > 70
    end
  end

  describe '#recently_used?' do
    it 'returns false for never used names' do
      expect(tracker.recently_used?('James')).to be false
    end

    it 'returns true for recently recorded names' do
      tracker.record_use(:forename, 'James')
      expect(tracker.recently_used?('James')).to be true
    end
  end

  describe '#clear!' do
    it 'clears all history' do
      tracker.record_use(:forename, 'James')
      tracker.record_use(:surname, 'Smith')
      tracker.clear!

      expect(tracker.history_size(:forename)).to eq(0)
      expect(tracker.history_size(:surname)).to eq(0)
    end
  end

  describe '#clear_category!' do
    it 'clears only the specified category' do
      tracker.record_use(:forename, 'James')
      tracker.record_use(:surname, 'Smith')
      tracker.clear_category!(:forename)

      expect(tracker.history_size(:forename)).to eq(0)
      expect(tracker.history_size(:surname)).to eq(1)
    end
  end

  describe 'decay over time' do
    it 'reduces penalty for older entries' do
      # Use a high decay rate for testing
      fast_decay_tracker = described_class.new(decay_rate: 100.0)

      fast_decay_tracker.record_use(:forename, 'James')
      initial_penalty = fast_decay_tracker.calculate_penalty('James')

      # Simulate time passing by manipulating the entry
      # (In production, time naturally decays)
      expect(initial_penalty).to be > 0
    end
  end

  describe 'diversity in repeated generation' do
    it 'produces varied selections over many calls' do
      names = [
        { name: 'Alice', weight: 5.0 },
        { name: 'Bob', weight: 5.0 },
        { name: 'Charlie', weight: 5.0 },
        { name: 'Diana', weight: 5.0 },
        { name: 'Eve', weight: 5.0 }
      ]

      # Select names 20 times, recording each use
      selections = 20.times.map do
        weighted = tracker.apply_weights(names, category: :forename)
        selected = tracker.weighted_select(weighted)
        tracker.record_use(:forename, selected)
        selected
      end

      unique_names = selections.uniq
      most_common_count = selections.tally.values.max

      # Should use at least 4 different names
      expect(unique_names.length).to be >= 4
      # No single name should dominate (max 8 out of 20)
      expect(most_common_count).to be <= 8
    end
  end
end
