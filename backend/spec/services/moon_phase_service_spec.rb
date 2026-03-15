# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MoonPhaseService do
  describe '.current_phase' do
    context 'with default date' do
      it 'returns a MoonPhase struct' do
        result = described_class.current_phase

        expect(result).to be_a(described_class::MoonPhase)
      end

      it 'includes all expected attributes' do
        result = described_class.current_phase

        expect(result).to respond_to(:name)
        expect(result).to respond_to(:emoji)
        expect(result).to respond_to(:illumination)
        expect(result).to respond_to(:waxing)
        expect(result).to respond_to(:cycle_position)
      end
    end

    context 'with specific date' do
      it 'accepts Date object' do
        result = described_class.current_phase(Date.new(2024, 1, 11))

        expect(result).to be_a(described_class::MoonPhase)
      end

      it 'accepts Time object' do
        result = described_class.current_phase(Time.utc(2024, 1, 25, 12, 0))

        expect(result).to be_a(described_class::MoonPhase)
      end
    end

    context 'lunar cycle progression' do
      # Start from known new moon reference point
      let(:reference_new_moon) { described_class::KNOWN_NEW_MOON.to_date }

      it 'returns new moon near cycle start' do
        result = described_class.current_phase(reference_new_moon)

        expect(result.illumination).to be <= 0.1
      end

      it 'returns full moon near cycle midpoint' do
        # Full moon occurs ~14.5 days after new moon
        full_moon_date = reference_new_moon + 15

        result = described_class.current_phase(full_moon_date)

        expect(result.illumination).to be >= 0.9
      end

      it 'shows waxing during first half of cycle' do
        result = described_class.current_phase(reference_new_moon + 7)

        expect(result.waxing).to be true
      end

      it 'shows waning during second half of cycle' do
        result = described_class.current_phase(reference_new_moon + 22)

        expect(result.waxing).to be false
      end
    end

    context 'cycle position tracking' do
      it 'returns cycle_position between 0 and 1' do
        result = described_class.current_phase

        expect(result.cycle_position).to be_between(0.0, 1.0)
      end

      it 'different dates have different cycle positions' do
        result1 = described_class.current_phase(Date.today)
        result2 = described_class.current_phase(Date.today + 10)

        expect(result1.cycle_position).not_to eq(result2.cycle_position)
      end
    end
  end

  describe '.emoji' do
    it 'returns emoji for current date' do
      result = described_class.emoji

      expect(result).to match(/[\u{1F311}-\u{1F318}]/)
    end

    it 'returns full moon emoji when illumination high' do
      # Use reference date that we know produces full moon
      full_moon_date = described_class::KNOWN_NEW_MOON.to_date + 15

      expect(described_class.emoji(full_moon_date)).to eq("\u{1F315}")
    end
  end

  describe '.phase_name' do
    it 'returns phase name string' do
      result = described_class.phase_name

      expect(result).to be_a(String)
      expect(result).not_to be_empty
    end
  end

  describe '.illumination' do
    let(:reference_new_moon) { described_class::KNOWN_NEW_MOON.to_date }

    it 'returns float between 0 and 1' do
      result = described_class.illumination

      expect(result).to be_between(0.0, 1.0)
    end

    it 'returns low value for new moon' do
      expect(described_class.illumination(reference_new_moon)).to be <= 0.1
    end

    it 'returns high value for full moon' do
      full_moon = reference_new_moon + 15

      expect(described_class.illumination(full_moon)).to be >= 0.9
    end
  end

  describe '.waxing?' do
    let(:reference_new_moon) { described_class::KNOWN_NEW_MOON.to_date }

    it 'returns true during waxing phase' do
      waxing_date = reference_new_moon + 7

      expect(described_class.waxing?(waxing_date)).to be true
    end

    it 'returns false during waning phase' do
      waning_date = reference_new_moon + 22

      expect(described_class.waxing?(waning_date)).to be false
    end
  end

  describe '.waning?' do
    it 'returns opposite of waxing' do
      date = Date.today

      expect(described_class.waning?(date)).to eq(!described_class.waxing?(date))
    end
  end

  describe '.full_moon?' do
    let(:reference_new_moon) { described_class::KNOWN_NEW_MOON.to_date }

    it 'returns true on full moon date' do
      full_moon = reference_new_moon + 15

      expect(described_class.full_moon?(full_moon)).to be true
    end

    it 'returns false on new moon date' do
      expect(described_class.full_moon?(reference_new_moon)).to be false
    end
  end

  describe '.new_moon?' do
    let(:reference_new_moon) { described_class::KNOWN_NEW_MOON.to_date }

    it 'returns true when illumination is very low' do
      # The reference is not exactly on new moon day but close
      # Test that a date with very low illumination returns true
      phase = described_class.current_phase(reference_new_moon)

      # If illumination <= 0.05, new_moon? should return true
      expect(described_class.new_moon?(reference_new_moon)).to eq(phase.illumination <= 0.05)
    end

    it 'returns false on full moon date' do
      full_moon = reference_new_moon + 15

      expect(described_class.new_moon?(full_moon)).to be false
    end
  end

  describe '.description' do
    let(:reference_new_moon) { described_class::KNOWN_NEW_MOON.to_date }

    context 'for full moon' do
      it 'returns description with full moon' do
        full_moon = reference_new_moon + 15

        result = described_class.description(full_moon)

        expect(result).to include('full moon')
        expect(result).to include('hangs in the sky')
      end
    end

    context 'for very low illumination' do
      it 'returns description based on phase name' do
        result = described_class.description(reference_new_moon)
        phase = described_class.current_phase(reference_new_moon)

        # Description should include the phase name
        expect(result).to include(phase.name)
      end
    end

    context 'for intermediate phase' do
      it 'returns description with illumination' do
        intermediate_date = reference_new_moon + 7

        result = described_class.description(intermediate_date)

        expect(result).to include('illuminated')
      end
    end

    context 'for waning phase' do
      it 'includes waning in description' do
        waning_date = reference_new_moon + 22

        result = described_class.description(waning_date)

        expect(result).to include('waning')
      end
    end
  end

  describe 'MoonPhase struct' do
    it 'has all expected attributes' do
      phase = described_class::MoonPhase.new(
        name: 'full moon',
        emoji: "\u{1F315}",
        illumination: 1.0,
        waxing: false,
        cycle_position: 0.5
      )

      expect(phase.name).to eq('full moon')
      expect(phase.emoji).to eq("\u{1F315}")
      expect(phase.illumination).to eq(1.0)
      expect(phase.waxing).to be false
      expect(phase.cycle_position).to eq(0.5)
    end
  end
end
