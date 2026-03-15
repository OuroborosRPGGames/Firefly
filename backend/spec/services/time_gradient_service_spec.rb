# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TimeGradientService do
  describe 'COLORS' do
    it 'defines colors for all time periods' do
      expect(described_class::COLORS).to have_key(:dawn)
      expect(described_class::COLORS).to have_key(:morning)
      expect(described_class::COLORS).to have_key(:noon)
      expect(described_class::COLORS).to have_key(:afternoon)
      expect(described_class::COLORS).to have_key(:dusk)
      expect(described_class::COLORS).to have_key(:night)
    end

    it 'has start and end colors for each period' do
      described_class::COLORS.each do |period, colors|
        expect(colors).to have_key(:start), "#{period} should have :start color"
        expect(colors).to have_key(:end), "#{period} should have :end color"
        expect(colors[:start]).to match(/^#[0-9A-Fa-f]{6}$/)
        expect(colors[:end]).to match(/^#[0-9A-Fa-f]{6}$/)
      end
    end
  end

  describe '.time_period' do
    let(:dawn) { GameConfig::Time::DEFAULT_DAWN_HOUR }
    let(:dusk) { GameConfig::Time::DEFAULT_DUSK_HOUR }

    it 'returns :dawn for dawn hour' do
      expect(described_class.time_period(dawn)).to eq(:dawn)
    end

    it 'returns :morning for post-dawn until noon' do
      (dawn + 1..11).each do |hour|
        expect(described_class.time_period(hour)).to eq(:morning)
      end
    end

    it 'returns :noon for hour 12' do
      expect(described_class.time_period(12)).to eq(:noon)
    end

    it 'returns :afternoon for post-noon until dusk' do
      (13..(dusk - 1)).each do |hour|
        expect(described_class.time_period(hour)).to eq(:afternoon)
      end
    end

    it 'returns :dusk for dusk hour' do
      expect(described_class.time_period(dusk)).to eq(:dusk)
    end

    it 'returns :night for nighttime hours' do
      # Test early morning (before dawn)
      (0..(dawn - 1)).each do |hour|
        expect(described_class.time_period(hour)).to eq(:night)
      end
      # Test late evening (after dusk)
      ((dusk + 1)..23).each do |hour|
        expect(described_class.time_period(hour)).to eq(:night)
      end
    end
  end

  describe '.gradient_for_time' do
    before do
      allow(GameTimeService).to receive(:current_time).and_return(Time.new(2025, 1, 1, hour, 0, 0))
    end

    context 'during dawn' do
      let(:hour) { GameConfig::Time::DEFAULT_DAWN_HOUR }

      it 'returns dawn gradient' do
        result = described_class.gradient_for_time
        expect(result[:period]).to eq(:dawn)
        expect(result[:start_color]).to eq(described_class::COLORS[:dawn][:start])
        expect(result[:end_color]).to eq(described_class::COLORS[:dawn][:end])
        expect(result[:hour]).to eq(hour)
      end
    end

    context 'during noon' do
      let(:hour) { 12 }

      it 'returns noon gradient' do
        result = described_class.gradient_for_time
        expect(result[:period]).to eq(:noon)
        expect(result[:start_color]).to eq(described_class::COLORS[:noon][:start])
        expect(result[:end_color]).to eq(described_class::COLORS[:noon][:end])
      end
    end

    context 'during night' do
      let(:hour) { 2 }

      it 'returns night gradient (gray)' do
        result = described_class.gradient_for_time
        expect(result[:period]).to eq(:night)
        expect(result[:start_color]).to eq('#666666')
        expect(result[:end_color]).to eq('#666666')
      end
    end

    context 'when GameTimeService raises an error' do
      let(:hour) { 12 }

      it 'falls back to current system time' do
        allow(GameTimeService).to receive(:current_time).and_raise(StandardError, 'DB error')

        result = described_class.gradient_for_time
        expect(result).to have_key(:period)
        expect(result).to have_key(:start_color)
        expect(result).to have_key(:end_color)
        expect(result).to have_key(:hour)
      end
    end
  end

  describe '.all_colors' do
    it 'returns all defined colors' do
      result = described_class.all_colors
      expect(result).to eq(described_class::COLORS)
    end
  end
end
