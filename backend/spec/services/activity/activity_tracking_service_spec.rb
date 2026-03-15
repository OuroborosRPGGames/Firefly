# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityTrackingService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }

  let(:character_a) { create(:character, forename: 'Alice') }
  let(:character_b) { create(:character, forename: 'Bob') }

  let(:profile_a) do
    create(:activity_profile, :with_data,
      character: character_a,
      share_schedule: true
    )
  end

  let(:profile_b) do
    create(:activity_profile, :with_data,
      character: character_b,
      share_schedule: true
    )
  end

  describe '.record_active_characters!' do
    let(:character_instance) do
      create(:character_instance,
        character: character_a,
        reality: reality,
        current_room: room,
        online: true,
        last_activity: Time.now - 5 * 60, # 5 minutes ago
        activity_tracking_enabled: true
      )
    end

    before do
      character_instance
      profile_a
    end

    it 'records samples for active characters' do
      allow(ActivityProfile).to receive(:for_character)
        .with(character_a).and_return(profile_a)

      expect(profile_a).to receive(:record_sample!)

      described_class.record_active_characters!
    end

    it 'returns count of recorded and skipped' do
      allow(ActivityProfile).to receive(:for_character)
        .with(character_a).and_return(profile_a)

      result = described_class.record_active_characters!

      expect(result).to include(:recorded, :skipped)
      expect(result[:recorded]).to eq(1)
    end

    it 'skips characters with tracking disabled on profile' do
      profile_a.update(tracking_enabled: false)
      allow(ActivityProfile).to receive(:for_character)
        .with(character_a).and_return(profile_a)

      result = described_class.record_active_characters!

      expect(result[:recorded]).to eq(0)
    end

    context 'when recording fails for a character' do
      before do
        allow(ActivityProfile).to receive(:for_character)
          .with(character_a).and_return(profile_a)
        allow(profile_a).to receive(:record_sample!).and_raise(StandardError.new('DB error'))
      end

      it 'continues with other characters and counts skipped' do
        result = described_class.record_active_characters!

        expect(result[:skipped]).to eq(1)
      end
    end
  end

  describe '.apply_decay_to_all!' do
    before do
      profile_a
      profile_b
    end

    it 'applies decay to all enabled profiles' do
      # Stub to allow but not verify, then check result count
      result = described_class.apply_decay_to_all!

      expect(result[:decayed]).to eq(2)
    end

    it 'returns count of decayed profiles' do
      result = described_class.apply_decay_to_all!

      expect(result).to include(:decayed)
      expect(result[:decayed]).to be_a(Integer)
    end

    context 'when profile has tracking disabled' do
      before do
        profile_a.update(tracking_enabled: false)
      end

      it 'skips disabled profiles' do
        # Only profile_b should be processed
        result = described_class.apply_decay_to_all!

        expect(result[:decayed]).to eq(1)
      end
    end
  end

  describe '.calculate_overlap' do
    before do
      profile_a
      profile_b
    end

    it 'returns overlap percentage and best times' do
      allow(ActivityProfile).to receive(:for_character).with(character_a).and_return(profile_a)
      allow(ActivityProfile).to receive(:for_character).with(character_b).and_return(profile_b)
      allow(profile_a).to receive(:has_sufficient_data?).and_return(true)
      allow(profile_b).to receive(:has_sufficient_data?).and_return(true)
      allow(profile_a).to receive(:overlap_with).and_return(45)
      allow(profile_a).to receive(:best_overlap_days).and_return([])
      allow(profile_a).to receive(:best_overlap_times).and_return([])

      result = described_class.calculate_overlap(character_a, character_b)

      expect(result[:percentage]).to eq(45)
      expect(result).to include(:best_days, :best_times, :summary)
    end

    context 'when one character has sharing disabled' do
      before do
        profile_a.update(share_schedule: false)
        allow(ActivityProfile).to receive(:for_character).with(character_a).and_return(profile_a)
        allow(ActivityProfile).to receive(:for_character).with(character_b).and_return(profile_b)
      end

      it 'returns error' do
        result = described_class.calculate_overlap(character_a, character_b)

        expect(result[:error]).to include('schedule sharing disabled')
      end
    end

    context 'when insufficient data' do
      before do
        allow(ActivityProfile).to receive(:for_character).with(character_a).and_return(profile_a)
        allow(ActivityProfile).to receive(:for_character).with(character_b).and_return(profile_b)
        allow(profile_a).to receive(:has_sufficient_data?).and_return(false)
      end

      it 'returns error with insufficient_data flag' do
        result = described_class.calculate_overlap(character_a, character_b)

        expect(result[:error]).to include('Not enough activity data')
        expect(result[:insufficient_data]).to be true
      end
    end
  end

  describe '.find_meeting_times' do
    let(:character_c) { create(:character, forename: 'Charlie') }
    let(:profile_c) do
      create(:activity_profile, :with_data, character: character_c, share_schedule: true)
    end

    before do
      profile_a
      profile_b
      profile_c
    end

    it 'returns best meeting times for group' do
      allow(ActivityProfile).to receive(:for_character).with(character_a).and_return(profile_a)
      allow(ActivityProfile).to receive(:for_character).with(character_b).and_return(profile_b)
      allow(ActivityProfile).to receive(:for_character).with(character_c).and_return(profile_c)
      allow(profile_a).to receive(:has_sufficient_data?).and_return(true)
      allow(profile_b).to receive(:has_sufficient_data?).and_return(true)
      allow(profile_c).to receive(:has_sufficient_data?).and_return(true)

      mock_times = [
        { day: 'mon', hour: 14, attendee_count: 3 },
        { day: 'wed', hour: 19, attendee_count: 2 }
      ]
      allow(ActivityProfile).to receive(:find_best_meeting_times).and_return(mock_times)

      result = described_class.find_meeting_times([character_a, character_b, character_c])

      expect(result[:times]).to eq(mock_times)
      expect(result[:total_characters]).to eq(3)
      expect(result[:shareable_characters]).to eq(3)
    end

    context 'when less than 2 characters provided' do
      it 'returns error' do
        result = described_class.find_meeting_times([character_a])

        expect(result[:error]).to eq('Need at least 2 characters')
      end
    end

    context 'when not enough characters share schedules' do
      before do
        profile_a.update(share_schedule: false)
        profile_b.update(share_schedule: false)
        allow(ActivityProfile).to receive(:for_character).with(character_a).and_return(profile_a)
        allow(ActivityProfile).to receive(:for_character).with(character_b).and_return(profile_b)
        allow(ActivityProfile).to receive(:for_character).with(character_c).and_return(profile_c)
        allow(profile_c).to receive(:has_sufficient_data?).and_return(true)
      end

      it 'returns error' do
        result = described_class.find_meeting_times([character_a, character_b, character_c])

        expect(result[:error]).to include('Not enough characters')
      end
    end
  end

  describe '.format_hour' do
    it 'formats midnight as 12:00 AM' do
      expect(described_class.format_hour(0)).to eq('12:00 AM')
    end

    it 'formats morning hours correctly' do
      expect(described_class.format_hour(9)).to eq('9:00 AM')
    end

    it 'formats noon as 12:00 PM' do
      expect(described_class.format_hour(12)).to eq('12:00 PM')
    end

    it 'formats afternoon hours correctly' do
      expect(described_class.format_hour(15)).to eq('3:00 PM')
    end

    it 'formats evening hours correctly' do
      expect(described_class.format_hour(22)).to eq('10:00 PM')
    end
  end

  describe '.format_hour_range' do
    it 'returns various times for empty array' do
      expect(described_class.format_hour_range([])).to eq('various times')
    end

    it 'formats single hour' do
      expect(described_class.format_hour_range([14])).to eq('2:00 PM')
    end

    it 'formats consecutive hours as range' do
      expect(described_class.format_hour_range([14, 15, 16])).to eq('2:00 PM-5:00 PM')
    end

    it 'formats non-consecutive hours separately' do
      expect(described_class.format_hour_range([9, 14, 15])).to eq('9:00 AM, 2:00 PM-4:00 PM')
    end

    it 'handles multiple ranges' do
      hours = [9, 10, 14, 15, 16, 20, 21]
      result = described_class.format_hour_range(hours)

      expect(result).to include('9:00 AM-11:00 AM')
      expect(result).to include('2:00 PM-5:00 PM')
      expect(result).to include('8:00 PM-10:00 PM')
    end
  end

  describe '.full_day_name' do
    it 'returns Monday for mon' do
      expect(described_class.full_day_name('mon')).to eq('Monday')
    end

    it 'returns Tuesday for tue' do
      expect(described_class.full_day_name('tue')).to eq('Tuesday')
    end

    it 'returns Wednesday for wed' do
      expect(described_class.full_day_name('wed')).to eq('Wednesday')
    end

    it 'returns Thursday for thu' do
      expect(described_class.full_day_name('thu')).to eq('Thursday')
    end

    it 'returns Friday for fri' do
      expect(described_class.full_day_name('fri')).to eq('Friday')
    end

    it 'returns Saturday for sat' do
      expect(described_class.full_day_name('sat')).to eq('Saturday')
    end

    it 'returns Sunday for sun' do
      expect(described_class.full_day_name('sun')).to eq('Sunday')
    end

    it 'handles uppercase input' do
      expect(described_class.full_day_name('MON')).to eq('Monday')
    end

    it 'handles longer input by truncating' do
      expect(described_class.full_day_name('monday')).to eq('Monday')
    end

    it 'capitalizes unknown input' do
      expect(described_class.full_day_name('xyz')).to eq('Xyz')
    end
  end

  describe 'private methods' do
    describe '#build_overlap_summary' do
      it 'returns very little overlap message for low percentage' do
        result = described_class.send(:build_overlap_summary, 5, [])

        expect(result).to eq('Very little schedule overlap found.')
      end

      it 'returns minimal overlap message for 10-25%' do
        result = described_class.send(:build_overlap_summary, 20, [])

        expect(result).to eq('Minimal overlap (20%).')
      end

      it 'includes best day info when available' do
        best_days = [
          { day: 'mon', overlap_hours: [14, 15, 16] },
          { day: 'wed', overlap_hours: [19] }
        ]

        result = described_class.send(:build_overlap_summary, 50, best_days)

        expect(result).to include('50%')
        expect(result).to include('Monday')
      end

      it 'shows overall percentage when no best days' do
        result = described_class.send(:build_overlap_summary, 45, [])

        expect(result).to eq('45% overlap overall.')
      end
    end

    describe '#build_meeting_summary' do
      it 'returns no availability message when times empty' do
        result = described_class.send(:build_meeting_summary, [], [character_a, character_b])

        expect(result).to eq('No common availability found.')
      end

      it 'shows all available when all can attend' do
        times = [{ day: 'mon', hour: 14, attendee_count: 2 }]
        characters = [character_a, character_b]

        result = described_class.send(:build_meeting_summary, times, characters)

        expect(result).to include('Monday at 2:00 PM')
        expect(result).to include('all 2 available')
      end

      it 'shows partial attendance when not all can attend' do
        times = [{ day: 'wed', hour: 19, attendee_count: 2 }]
        characters = [character_a, character_b, create(:character)]

        result = described_class.send(:build_meeting_summary, times, characters)

        expect(result).to include('Wednesday at 7:00 PM')
        expect(result).to include('2/3 available')
      end
    end
  end
end
