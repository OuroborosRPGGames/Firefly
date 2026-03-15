# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CombatInteractionClusterService do
  describe '.cluster' do
    it 'returns empty array for empty events' do
      expect(described_class.cluster([])).to eq([])
    end

    it 'clusters participants who attack each other' do
      events = [
        { actor_id: 1, target_id: 2, segment: 10 },
        { actor_id: 2, target_id: 1, segment: 20 }
      ]

      clusters = described_class.cluster(events)

      expect(clusters.length).to eq(1)
      expect(clusters.first).to contain_exactly(1, 2)
    end

    it 'separates unconnected participants into different clusters' do
      # A attacks B, B attacks A, C attacks D, D attacks C
      events = [
        { actor_id: 1, target_id: 2, segment: 10 },
        { actor_id: 2, target_id: 1, segment: 20 },
        { actor_id: 3, target_id: 4, segment: 15 },
        { actor_id: 4, target_id: 3, segment: 25 }
      ]

      clusters = described_class.cluster(events)

      expect(clusters.length).to eq(2)
      expect(clusters.map(&:sort)).to contain_exactly([1, 2], [3, 4])
    end

    it 'merges connected participants into one cluster (chain)' do
      # A attacks B, B attacks C, C attacks A
      events = [
        { actor_id: 1, target_id: 2, segment: 10 },
        { actor_id: 2, target_id: 3, segment: 20 },
        { actor_id: 3, target_id: 1, segment: 30 }
      ]

      clusters = described_class.cluster(events)

      expect(clusters.length).to eq(1)
      expect(clusters.first).to contain_exactly(1, 2, 3)
    end

    it 'sorts clusters by earliest segment' do
      # Cluster [3,4] has earlier segment than [1,2]
      events = [
        { actor_id: 1, target_id: 2, segment: 50 },
        { actor_id: 3, target_id: 4, segment: 10 }
      ]

      clusters = described_class.cluster(events)

      expect(clusters.first).to contain_exactly(3, 4)
      expect(clusters.last).to contain_exactly(1, 2)
    end

    it 'ignores self-targeting events' do
      events = [
        { actor_id: 1, target_id: 1, segment: 10 },
        { actor_id: 2, target_id: 3, segment: 20 }
      ]

      clusters = described_class.cluster(events)

      expect(clusters.length).to eq(1)
      expect(clusters.first).to contain_exactly(2, 3)
    end

    it 'handles events with target_id in details' do
      events = [
        { actor_id: 1, details: { target_participant_id: 2 }, segment: 10 }
      ]

      clusters = described_class.cluster(events)

      expect(clusters.length).to eq(1)
      expect(clusters.first).to contain_exactly(1, 2)
    end

    it 'handles complex multi-way fight' do
      # 5-way brawl where everyone attacks one central person
      events = [
        { actor_id: 1, target_id: 5, segment: 10 },
        { actor_id: 2, target_id: 5, segment: 20 },
        { actor_id: 3, target_id: 5, segment: 30 },
        { actor_id: 4, target_id: 5, segment: 40 },
        { actor_id: 5, target_id: 1, segment: 50 }
      ]

      clusters = described_class.cluster(events)

      expect(clusters.length).to eq(1)
      expect(clusters.first).to contain_exactly(1, 2, 3, 4, 5)
    end
  end
end
