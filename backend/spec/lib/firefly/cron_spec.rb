# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Firefly::Cron do
  describe '.matches?' do
    context 'with empty spec (wildcard all)' do
      let(:spec) { { minutes: [], hours: [], days: [], weekdays: [] } }

      it 'matches any time' do
        expect(described_class.matches?(spec, Time.new(2025, 1, 15, 14, 30))).to be true
        expect(described_class.matches?(spec, Time.new(2025, 7, 4, 0, 0))).to be true
      end
    end

    context 'with specific minutes' do
      let(:spec) { { minutes: [0, 30], hours: [], days: [], weekdays: [] } }

      it 'matches when minute is in list' do
        expect(described_class.matches?(spec, Time.new(2025, 1, 15, 14, 0))).to be true
        expect(described_class.matches?(spec, Time.new(2025, 1, 15, 14, 30))).to be true
      end

      it 'does not match when minute is not in list' do
        expect(described_class.matches?(spec, Time.new(2025, 1, 15, 14, 15))).to be false
        expect(described_class.matches?(spec, Time.new(2025, 1, 15, 14, 45))).to be false
      end
    end

    context 'with specific hours' do
      let(:spec) { { minutes: [0], hours: [3, 15], days: [], weekdays: [] } }

      it 'matches when hour is in list' do
        expect(described_class.matches?(spec, Time.new(2025, 1, 15, 3, 0))).to be true
        expect(described_class.matches?(spec, Time.new(2025, 1, 15, 15, 0))).to be true
      end

      it 'does not match when hour is not in list' do
        expect(described_class.matches?(spec, Time.new(2025, 1, 15, 12, 0))).to be false
      end
    end

    context 'with specific days' do
      let(:spec) { { minutes: [0], hours: [0], days: [1, 15], weekdays: [] } }

      it 'matches on specified days of month' do
        expect(described_class.matches?(spec, Time.new(2025, 1, 1, 0, 0))).to be true
        expect(described_class.matches?(spec, Time.new(2025, 3, 15, 0, 0))).to be true
      end

      it 'does not match other days' do
        expect(described_class.matches?(spec, Time.new(2025, 1, 10, 0, 0))).to be false
      end
    end

    context 'with specific weekdays' do
      let(:spec) { { minutes: [0], hours: [0], days: [], weekdays: [0, 6] } } # Sunday, Saturday

      it 'matches on weekends' do
        saturday = Time.new(2025, 1, 4, 0, 0) # Jan 4, 2025 is Saturday
        sunday = Time.new(2025, 1, 5, 0, 0)   # Jan 5, 2025 is Sunday
        expect(described_class.matches?(spec, saturday)).to be true
        expect(described_class.matches?(spec, sunday)).to be true
      end

      it 'does not match weekdays' do
        monday = Time.new(2025, 1, 6, 0, 0)
        expect(described_class.matches?(spec, monday)).to be false
      end
    end
  end

  describe '.next_occurrence' do
    it 'finds next minute for wildcard spec' do
      spec = { minutes: [], hours: [], days: [], weekdays: [] }
      from = Time.new(2025, 1, 15, 14, 30, 45)
      result = described_class.next_occurrence(spec, from)

      expect(result).to be > from
      expect(result.min).to eq(31)
    end

    it 'finds next hour for hourly spec' do
      spec = { minutes: [0], hours: [], days: [], weekdays: [] }
      from = Time.new(2025, 1, 15, 14, 30)
      result = described_class.next_occurrence(spec, from)

      expect(result.hour).to eq(15)
      expect(result.min).to eq(0)
    end

    it 'finds next day for daily spec' do
      spec = { minutes: [0], hours: [3], days: [], weekdays: [] }
      from = Time.new(2025, 1, 15, 14, 30)
      result = described_class.next_occurrence(spec, from)

      expect(result.day).to eq(16)
      expect(result.hour).to eq(3)
      expect(result.min).to eq(0)
    end
  end

  describe '.parse' do
    it 'parses "every minute"' do
      result = described_class.parse('every minute')
      expect(result[:minutes]).to eq([])
      expect(result[:hours]).to eq([])
    end

    it 'parses "every hour"' do
      result = described_class.parse('every hour')
      expect(result[:minutes]).to eq([0])
      expect(result[:hours]).to eq([])
    end

    it 'parses "daily at 3am"' do
      result = described_class.parse('daily at 3am')
      expect(result[:hours]).to eq([3])
      expect(result[:minutes]).to eq([0])
    end

    it 'parses "daily at 3pm"' do
      result = described_class.parse('daily at 3pm')
      expect(result[:hours]).to eq([15])
    end

    it 'parses standard cron format' do
      result = described_class.parse('0 3 * * *')
      expect(result[:minutes]).to eq([0])
      expect(result[:hours]).to eq([3])
      expect(result[:days]).to eq([])
      expect(result[:weekdays]).to eq([])
    end
  end
end
