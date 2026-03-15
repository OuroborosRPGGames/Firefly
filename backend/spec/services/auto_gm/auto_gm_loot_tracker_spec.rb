# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AutoGm::LootTracker do
  let(:character) { create(:character, forename: 'Test', surname: 'Looter') }
  let(:mock_redis) { instance_double(Redis) }

  before do
    allow(REDIS_POOL).to receive(:with).and_yield(mock_redis)
    allow(mock_redis).to receive(:get).and_return(nil)
    allow(mock_redis).to receive(:setex).and_return('OK')
  end

  describe 'constants' do
    it 'has REDIS_KEY_PREFIX' do
      expect(described_class::REDIS_KEY_PREFIX).to eq('autogm:loot:hourly:')
    end

    it 'has WINDOW_SECONDS as 1 hour' do
      expect(described_class::WINDOW_SECONDS).to eq(3600)
    end
  end

  describe '.remaining_allowance' do
    context 'when no loot given yet' do
      it 'returns max allowance' do
        max = GameConfig::AutoGm::LOOT[:max_per_hour]
        expect(described_class.remaining_allowance(character)).to eq(max)
      end
    end

    context 'when some loot already given' do
      before do
        allow(mock_redis).to receive(:get).and_return('200')
      end

      it 'returns remaining allowance' do
        max = GameConfig::AutoGm::LOOT[:max_per_hour]
        expect(described_class.remaining_allowance(character)).to eq(max - 200)
      end
    end

    context 'when max loot already given' do
      before do
        max = GameConfig::AutoGm::LOOT[:max_per_hour]
        allow(mock_redis).to receive(:get).and_return(max.to_s)
      end

      it 'returns zero' do
        expect(described_class.remaining_allowance(character)).to eq(0)
      end
    end

    context 'when over max given (edge case)' do
      before do
        max = GameConfig::AutoGm::LOOT[:max_per_hour]
        allow(mock_redis).to receive(:get).and_return((max + 100).to_s)
      end

      it 'returns zero not negative' do
        expect(described_class.remaining_allowance(character)).to eq(0)
      end
    end
  end

  describe '.record_loot' do
    it 'stores loot amount in redis' do
      expect(mock_redis).to receive(:setex).with(
        "autogm:loot:hourly:#{character.id}",
        3600,
        '100'
      )

      described_class.record_loot(character, 100)
    end

    it 'returns true on success' do
      expect(described_class.record_loot(character, 100)).to be true
    end

    context 'when adding to existing loot' do
      before do
        allow(mock_redis).to receive(:get).and_return('50')
      end

      it 'adds to existing total' do
        expect(mock_redis).to receive(:setex).with(
          "autogm:loot:hourly:#{character.id}",
          3600,
          '150'
        )

        described_class.record_loot(character, 100)
      end
    end

    context 'when redis fails' do
      before do
        allow(mock_redis).to receive(:setex).and_raise(Redis::BaseError.new('Connection failed'))
      end

      it 'returns false' do
        expect(described_class.record_loot(character, 100)).to be false
      end

      it 'logs warning' do
        expect { described_class.record_loot(character, 100) }.to output(/Failed to record loot/).to_stderr
      end
    end
  end

  describe '.loot_given_this_hour' do
    context 'when no loot recorded' do
      before do
        allow(mock_redis).to receive(:get).and_return(nil)
      end

      it 'returns 0' do
        expect(described_class.loot_given_this_hour(character)).to eq(0)
      end
    end

    context 'when loot recorded' do
      before do
        allow(mock_redis).to receive(:get).and_return('350')
      end

      it 'returns the recorded amount' do
        expect(described_class.loot_given_this_hour(character)).to eq(350)
      end
    end

    context 'when redis fails' do
      before do
        allow(mock_redis).to receive(:get).and_raise(Redis::BaseError.new('Connection failed'))
      end

      it 'returns 0' do
        expect(described_class.loot_given_this_hour(character)).to eq(0)
      end
    end
  end

  describe '.can_receive?' do
    context 'when remaining allowance covers amount' do
      before do
        allow(mock_redis).to receive(:get).and_return('0')
      end

      it 'returns true' do
        expect(described_class.can_receive?(character, 100)).to be true
      end
    end

    context 'when remaining allowance equals amount' do
      before do
        max = GameConfig::AutoGm::LOOT[:max_per_hour]
        allow(mock_redis).to receive(:get).and_return((max - 100).to_s)
      end

      it 'returns true' do
        expect(described_class.can_receive?(character, 100)).to be true
      end
    end

    context 'when remaining allowance less than amount' do
      before do
        max = GameConfig::AutoGm::LOOT[:max_per_hour]
        allow(mock_redis).to receive(:get).and_return((max - 50).to_s)
      end

      it 'returns false' do
        expect(described_class.can_receive?(character, 100)).to be false
      end
    end

    context 'when no allowance remaining' do
      before do
        max = GameConfig::AutoGm::LOOT[:max_per_hour]
        allow(mock_redis).to receive(:get).and_return(max.to_s)
      end

      it 'returns false for any amount' do
        expect(described_class.can_receive?(character, 1)).to be false
      end
    end
  end
end
