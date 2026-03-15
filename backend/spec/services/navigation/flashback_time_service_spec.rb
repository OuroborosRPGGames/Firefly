# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FlashbackTimeService do
  describe 'FLASHBACK_MAX_SECONDS' do
    it 'uses GameConfig for FLASHBACK_MAX_SECONDS' do
      expect(GameConfig::Journey::FLASHBACK_MAX_SECONDS).to eq(12 * 3600)
    end
  end

  describe '.touch_room_activity' do
    let(:location) { create(:location) }
    let(:room) { create(:room, location: location) }
    let(:character1) { create(:character) }
    let(:character2) { create(:character) }
    let(:instance1) do
      create(:character_instance,
             character: character1,
             current_room: room,
             online: true,
             last_rp_activity_at: Time.now - 3600)
    end
    let(:instance2) do
      create(:character_instance,
             character: character2,
             current_room: room,
             online: true,
             last_rp_activity_at: Time.now - 3600)
    end

    before do
      instance1
      instance2
    end

    it 'returns early when room_id is nil' do
      expect(CharacterInstance).not_to receive(:where)
      described_class.touch_room_activity(nil)
    end

    it 'updates last_rp_activity_at for online characters in room' do
      old_time = instance1.reload.last_rp_activity_at
      described_class.touch_room_activity(room.id)

      expect(instance1.reload.last_rp_activity_at).to be > old_time
    end

    it 'updates multiple characters in the room' do
      described_class.touch_room_activity(room.id)

      expect(instance1.reload.last_rp_activity_at).to be_within(2).of(Time.now)
      expect(instance2.reload.last_rp_activity_at).to be_within(2).of(Time.now)
    end

    it 'does not update offline characters' do
      instance1.update(online: false)
      old_time = instance1.reload.last_rp_activity_at

      described_class.touch_room_activity(room.id)

      expect(instance1.reload.last_rp_activity_at).to eq(old_time)
    end

    it 'excludes specified character instances' do
      old_time = instance1.reload.last_rp_activity_at

      described_class.touch_room_activity(room.id, exclude: [instance1.id])

      expect(instance1.reload.last_rp_activity_at).to eq(old_time)
      expect(instance2.reload.last_rp_activity_at).to be > old_time
    end

    it 'handles exclude as a single id' do
      described_class.touch_room_activity(room.id, exclude: instance1.id)

      expect(instance2.reload.last_rp_activity_at).to be_within(2).of(Time.now)
    end
  end

  describe '.available_time' do
    let(:character_instance) { double('CharacterInstance', flashback_time_available: 7200) }

    it 'returns flashback_time_available from the instance' do
      expect(described_class.available_time(character_instance)).to eq(7200)
    end
  end

  describe '.calculate_flashback_coverage' do
    let(:character_instance) { double('CharacterInstance', flashback_time_available: 3600) }

    context 'with basic mode' do
      it 'calculates basic coverage' do
        result = described_class.calculate_flashback_coverage(character_instance, 1800, mode: :basic)

        expect(result[:success]).to be true
        expect(result[:can_instant]).to be true
        expect(result[:flashback_used]).to eq(1800)
        expect(result[:time_remaining]).to eq(0)
        expect(result[:mode]).to eq(:basic)
      end

      it 'handles journey longer than available time' do
        result = described_class.calculate_flashback_coverage(character_instance, 7200, mode: :basic)

        expect(result[:success]).to be true
        expect(result[:can_instant]).to be false
        expect(result[:flashback_used]).to eq(3600)
        expect(result[:time_remaining]).to eq(3600)
      end
    end

    context 'with return mode' do
      it 'reserves half for return trip' do
        result = described_class.calculate_flashback_coverage(character_instance, 1800, mode: :return)

        expect(result[:success]).to be true
        expect(result[:can_instant]).to be true
        expect(result[:flashback_used]).to eq(1800)
        expect(result[:reserved_for_return]).to eq(1800)
        expect(result[:mode]).to eq(:return)
      end

      it 'uses only half of available time' do
        # 3600 available, reserve 1800 for return, only 1800 usable
        result = described_class.calculate_flashback_coverage(character_instance, 2000, mode: :return)

        expect(result[:can_instant]).to be false
        expect(result[:flashback_used]).to eq(1800)
        expect(result[:time_remaining]).to eq(200)
      end
    end

    context 'with backloaded mode' do
      it 'allows instant travel with return debt' do
        result = described_class.calculate_flashback_coverage(character_instance, 1800, mode: :backloaded)

        expect(result[:success]).to be true
        expect(result[:can_instant]).to be true
        expect(result[:return_debt]).to eq(3600) # 2x journey
        expect(result[:mode]).to eq(:backloaded)
      end

      it 'rejects journeys over 12 hours' do
        result = described_class.calculate_flashback_coverage(character_instance, 13 * 3600, mode: :backloaded)

        expect(result[:success]).to be false
        expect(result[:error]).to include('too long')
        expect(result[:can_instant]).to be false
      end

      it 'accepts journeys exactly 12 hours' do
        result = described_class.calculate_flashback_coverage(character_instance, 12 * 3600, mode: :backloaded)

        expect(result[:success]).to be true
        expect(result[:can_instant]).to be true
      end
    end

    context 'with unknown mode' do
      it 'returns error' do
        result = described_class.calculate_flashback_coverage(character_instance, 1800, mode: :invalid)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown flashback mode')
      end
    end
  end

  describe '.format_duration (flashback style)' do
    it 'returns "0 seconds" for zero' do
      expect(described_class.format_duration(0, style: :flashback)).to eq('0 seconds')
    end

    it 'returns "0 seconds" for negative values' do
      expect(described_class.format_duration(-10, style: :flashback)).to eq('0 seconds')
    end

    it 'formats seconds under 60' do
      expect(described_class.format_duration(45, style: :flashback)).to eq('45 seconds')
    end

    it 'formats whole minutes' do
      expect(described_class.format_duration(120, style: :flashback)).to eq('2 minutes')
    end

    it 'formats fractional minutes' do
      expect(described_class.format_duration(90, style: :flashback)).to eq('1.5 minutes')
    end

    it 'formats hours with remaining minutes' do
      expect(described_class.format_duration(3900, style: :flashback)).to eq('1h 5m')
    end

    it 'formats whole hours singular' do
      expect(described_class.format_duration(3600, style: :flashback)).to eq('1 hour')
    end

    it 'formats whole hours plural' do
      expect(described_class.format_duration(7200, style: :flashback)).to eq('2 hours')
    end

    it 'handles large values' do
      expect(described_class.format_duration(12 * 3600, style: :flashback)).to eq('12 hours')
    end
  end

  describe '.format_journey_time' do
    it 'returns "instant" for zero' do
      expect(described_class.format_journey_time(0)).to eq('instant')
    end

    it 'returns "instant" for negative values' do
      expect(described_class.format_journey_time(-10)).to eq('instant')
    end

    it 'delegates to format_duration for positive values' do
      expect(described_class.format_journey_time(120)).to eq('2 minutes')
    end
  end

  describe '.calculate_flashback_coverage_with_available' do
    context 'with basic mode' do
      it 'calculates coverage using provided available time' do
        result = described_class.calculate_flashback_coverage_with_available(1800, 900, mode: :basic)

        expect(result[:success]).to be true
        expect(result[:can_instant]).to be true
        expect(result[:flashback_used]).to eq(900)
        expect(result[:time_remaining]).to eq(0)
      end

      it 'handles insufficient available time' do
        result = described_class.calculate_flashback_coverage_with_available(500, 900, mode: :basic)

        expect(result[:can_instant]).to be false
        expect(result[:flashback_used]).to eq(500)
        expect(result[:time_remaining]).to eq(400)
      end
    end

    context 'with return mode' do
      it 'reserves half for return' do
        result = described_class.calculate_flashback_coverage_with_available(2000, 800, mode: :return)

        expect(result[:can_instant]).to be true
        expect(result[:reserved_for_return]).to eq(1000)
      end
    end

    context 'with backloaded mode' do
      it 'works with any available time' do
        result = described_class.calculate_flashback_coverage_with_available(0, 1800, mode: :backloaded)

        expect(result[:success]).to be true
        expect(result[:can_instant]).to be true
        expect(result[:return_debt]).to eq(3600)
      end
    end

    context 'with unknown mode' do
      it 'returns error' do
        result = described_class.calculate_flashback_coverage_with_available(1000, 500, mode: :unknown)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown flashback mode')
      end
    end
  end

  describe 'private methods' do
    describe '.calculate_basic_coverage' do
      it 'uses all available time up to journey length' do
        result = described_class.send(:calculate_basic_coverage, 1000, 800)

        expect(result[:flashback_used]).to eq(800)
        expect(result[:time_remaining]).to eq(0)
        expect(result[:can_instant]).to be true
      end

      it 'caps at journey length when available exceeds journey' do
        result = described_class.send(:calculate_basic_coverage, 5000, 2000)

        expect(result[:flashback_used]).to eq(2000)
        expect(result[:time_remaining]).to eq(0)
      end

      it 'returns remaining time when journey exceeds available' do
        result = described_class.send(:calculate_basic_coverage, 500, 2000)

        expect(result[:flashback_used]).to eq(500)
        expect(result[:time_remaining]).to eq(1500)
        expect(result[:can_instant]).to be false
      end

      it 'sets reserved_for_return to 0' do
        result = described_class.send(:calculate_basic_coverage, 1000, 500)
        expect(result[:reserved_for_return]).to eq(0)
      end
    end

    describe '.calculate_return_coverage' do
      it 'uses only half of available time' do
        result = described_class.send(:calculate_return_coverage, 2000, 800)

        expect(result[:reserved_for_return]).to eq(1000)
        expect(result[:flashback_used]).to eq(800)
      end

      it 'caps usage at half available' do
        result = described_class.send(:calculate_return_coverage, 2000, 1500)

        expect(result[:flashback_used]).to eq(1000)
        expect(result[:time_remaining]).to eq(500)
      end

      it 'allows instant when journey fits in half' do
        result = described_class.send(:calculate_return_coverage, 2000, 500)

        expect(result[:can_instant]).to be true
        expect(result[:time_remaining]).to eq(0)
      end
    end

    describe '.calculate_backloaded_coverage' do
      it 'always allows instant travel for valid journeys' do
        result = described_class.send(:calculate_backloaded_coverage, 1800)

        expect(result[:can_instant]).to be true
        expect(result[:time_remaining]).to eq(0)
      end

      it 'sets return_debt to 2x journey time' do
        result = described_class.send(:calculate_backloaded_coverage, 1800)
        expect(result[:return_debt]).to eq(3600)
      end

      it 'sets flashback_used to journey time' do
        result = described_class.send(:calculate_backloaded_coverage, 1800)
        expect(result[:flashback_used]).to eq(1800)
      end

      it 'rejects journeys over max' do
        max_plus_one = GameConfig::Journey::FLASHBACK_MAX_SECONDS + 1
        result = described_class.send(:calculate_backloaded_coverage, max_plus_one)

        expect(result[:success]).to be false
        expect(result[:can_instant]).to be false
      end
    end
  end
end
