# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityProfile do
  let(:character) { create(:character) }

  describe 'constants' do
    it 'defines DAYS' do
      expect(described_class::DAYS).to eq(%w[mon tue wed thu fri sat sun])
    end

    it 'defines HOURS' do
      expect(described_class::HOURS).to eq((0..23).to_a)
    end

    it 'defines DAY_NAMES' do
      expect(described_class::DAY_NAMES['mon']).to eq('Monday')
    end
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      profile = described_class.create(character_id: character.id)
      expect(profile).to be_valid
    end

    it 'requires character_id' do
      profile = described_class.new
      expect(profile).not_to be_valid
    end

    it 'validates uniqueness of character_id' do
      described_class.create(character_id: character.id)
      duplicate = described_class.new(character_id: character.id)
      expect(duplicate).not_to be_valid
    end
  end

  describe '#record_sample!' do
    let(:profile) { create(:activity_profile, character: character) }

    it 'records sample when tracking enabled' do
      profile.update(tracking_enabled: true)
      profile.record_sample!(weight: 1.0)
      profile.reload
      expect(profile.total_samples).to be > 0
    end

    it 'does not record when tracking disabled' do
      profile.update(tracking_enabled: false)
      profile.record_sample!(weight: 1.0)
      profile.reload
      expect(profile.total_samples).to eq(0)
    end
  end

  describe '#activity_at' do
    let(:profile) { create(:activity_profile, :with_data, character: character) }

    it 'returns activity score for day/hour' do
      score = profile.activity_at('mon', 14)
      expect(score).to eq(80)
    end

    it 'returns 0 for slots without data' do
      score = profile.activity_at('sun', 3)
      expect(score).to eq(0)
    end
  end

  describe '#peak_times' do
    let(:profile) { create(:activity_profile, :with_data, character: character) }

    it 'returns sorted peak times' do
      peaks = profile.peak_times(limit: 3)
      expect(peaks.first[:score]).to be >= peaks.last[:score]
    end

    it 'filters by threshold' do
      peaks = profile.peak_times(threshold: 70)
      peaks.each do |p|
        expect(p[:score]).to be >= 70
      end
    end
  end

  describe '#weekly_schedule' do
    let(:profile) { create(:activity_profile, :with_data, character: character) }

    it 'returns hash with day keys' do
      schedule = profile.weekly_schedule
      expect(schedule.keys).to match_array(described_class::DAYS)
    end

    it 'includes hours above threshold' do
      schedule = profile.weekly_schedule(threshold: 70)
      expect(schedule['mon']).to include(14)
    end
  end

  describe '#has_sufficient_data?' do
    it 'returns false with few samples' do
      profile = create(:activity_profile, character: character, total_samples: 5)
      expect(profile.has_sufficient_data?).to be false
    end

    it 'returns true with enough samples' do
      profile = create(:activity_profile, character: character, total_samples: 25)
      expect(profile.has_sufficient_data?).to be true
    end
  end

  describe '#overlap_with' do
    let(:profile1) { create(:activity_profile, :with_data, character: character) }
    let(:character2) { create(:character) }
    let(:profile2) do
      create(:activity_profile,
             character: character2,
             activity_buckets: { 'mon_14' => 90, 'mon_15' => 85, 'fri_20' => 70 })
    end

    it 'returns 0 when other is not ActivityProfile' do
      expect(profile1.overlap_with('not a profile')).to eq(0.0)
    end

    it 'calculates overlap percentage' do
      overlap = profile1.overlap_with(profile2)
      expect(overlap).to be_a(Float)
      expect(overlap).to be >= 0
      expect(overlap).to be <= 100
    end
  end

  describe '#best_overlap_days' do
    let(:profile1) { create(:activity_profile, :with_data, character: character) }
    let(:character2) { create(:character) }
    let(:profile2) do
      create(:activity_profile,
             character: character2,
             activity_buckets: { 'mon_14' => 90, 'mon_15' => 85 })
    end

    it 'returns days with shared availability' do
      days = profile1.best_overlap_days(profile2)
      days.each do |d|
        expect(d[:overlap_hours]).to be_an(Array)
      end
    end
  end

  describe '#parsed_buckets' do
    it 'returns empty hash when nil' do
      profile = build(:activity_profile, character: character, activity_buckets: nil)
      expect(profile.parsed_buckets).to eq({})
    end

    it 'returns hash when set' do
      profile = create(:activity_profile, :with_data, character: character)
      expect(profile.parsed_buckets).to be_a(Hash)
    end
  end

  describe '.slot_key_for' do
    it 'returns formatted slot key' do
      time = Time.new(2024, 1, 15, 14, 30, 0) # Monday at 14:30
      key = described_class.slot_key_for(time)
      expect(key).to match(/\w{3}_\d{1,2}/)
    end
  end

  describe '.for_character' do
    it 'returns existing profile' do
      existing = create(:activity_profile, character: character)
      found = described_class.for_character(character)
      expect(found.id).to eq(existing.id)
    end

    it 'finds or creates profile' do
      new_char = create(:character)
      profile = described_class.for_character(new_char)
      expect(profile).to be_a(described_class)
      expect(profile.character_id).to eq(new_char.id)
    end
  end

  describe '#apply_decay!' do
    let(:profile) { create(:activity_profile, :with_data, character: character) }

    it 'does nothing when buckets are empty' do
      empty_profile = create(:activity_profile, character: create(:character))
      expect { empty_profile.apply_decay! }.not_to raise_error
    end

    it 'does not decay if less than a week since last decay' do
      profile.update(last_decay_applied_at: Time.now - (3 * 24 * 3600)) # 3 days ago
      original_buckets = profile.parsed_buckets.dup
      profile.apply_decay!
      profile.reload
      expect(profile.parsed_buckets).to eq(original_buckets)
    end

    it 'applies decay when a week or more has passed' do
      profile.update(last_decay_applied_at: Time.now - (8 * 24 * 3600)) # 8 days ago
      original_value = profile.activity_at('mon', 14)
      profile.apply_decay!
      profile.reload
      expect(profile.activity_at('mon', 14)).to be < original_value
    end

    it 'removes buckets that decay below 1' do
      # Set very low values and long time ago to ensure decay below 1
      profile.update(
        activity_buckets: { 'mon_14' => 1.5, 'tue_10' => 80 },
        last_decay_applied_at: Time.now - (60 * 24 * 3600) # 60 days ago - very heavy decay
      )
      profile.apply_decay!
      profile.reload
      # The low value bucket should be removed (decayed below 1)
      # The high value bucket should remain but be reduced
      expect(profile.activity_at('tue', 10)).to be > 0
      # After heavy decay, the 1.5 value should have decayed below 1 and been removed
      # (decay factor after ~8 weeks = 0.5^(8/4) = 0.25, so 1.5 * 0.25 = 0.375 < 1)
      expect(profile.parsed_buckets.key?('mon_14')).to be false
    end

    it 'updates last_decay_applied_at' do
      profile.update(last_decay_applied_at: Time.now - (14 * 24 * 3600)) # 2 weeks ago
      profile.apply_decay!
      profile.reload
      expect(profile.last_decay_applied_at).to be_within(5).of(Time.now)
    end

    it 'increments weeks_tracked' do
      profile.update(
        last_decay_applied_at: Time.now - (14 * 24 * 3600), # 2 weeks ago
        weeks_tracked: 5
      )
      profile.apply_decay!
      profile.reload
      expect(profile.weeks_tracked).to eq(7) # 5 + 2 weeks
    end
  end

  describe '#best_overlap_times' do
    let(:profile1) { create(:activity_profile, :with_data, character: character) }
    let(:character2) { create(:character) }
    let(:profile2) do
      create(:activity_profile,
             character: character2,
             activity_buckets: { 'mon_14' => 90, 'mon_15' => 85, 'tue_20' => 70, 'wed_18' => 50 })
    end

    it 'returns times where both profiles have activity above threshold' do
      times = profile1.best_overlap_times(profile2)
      expect(times).to be_an(Array)
      times.each do |t|
        expect(t).to have_key(:day)
        expect(t).to have_key(:hour)
        expect(t).to have_key(:score)
      end
    end

    it 'respects the limit parameter' do
      times = profile1.best_overlap_times(profile2, limit: 2)
      expect(times.length).to be <= 2
    end

    it 'respects the threshold parameter' do
      times = profile1.best_overlap_times(profile2, threshold: 60)
      times.each do |t|
        expect(profile1.activity_at(t[:day], t[:hour])).to be >= 60
        expect(profile2.activity_at(t[:day], t[:hour])).to be >= 60
      end
    end

    it 'returns times sorted by score descending' do
      times = profile1.best_overlap_times(profile2, limit: 10)
      scores = times.map { |t| t[:score] }
      expect(scores).to eq(scores.sort.reverse)
    end

    it 'returns empty array when no overlapping times' do
      no_overlap_profile = create(:activity_profile,
                                   character: create(:character),
                                   activity_buckets: { 'sun_3' => 80 }) # Different time slots
      times = profile1.best_overlap_times(no_overlap_profile)
      expect(times).to eq([])
    end
  end

  describe '.find_best_meeting_times' do
    let(:character1) { create(:character) }
    let(:character2) { create(:character) }
    let(:character3) { create(:character) }

    let!(:profile1) do
      create(:activity_profile,
             character: character1,
             share_schedule: true,
             activity_buckets: { 'mon_14' => 80, 'mon_15' => 75, 'tue_10' => 60 })
    end

    let!(:profile2) do
      create(:activity_profile,
             character: character2,
             share_schedule: true,
             activity_buckets: { 'mon_14' => 90, 'mon_15' => 70, 'wed_12' => 50 })
    end

    let!(:profile3) do
      create(:activity_profile,
             character: character3,
             share_schedule: true,
             activity_buckets: { 'mon_14' => 70, 'tue_10' => 55, 'wed_12' => 60 })
    end

    it 'returns empty array with fewer than 2 characters' do
      expect(described_class.find_best_meeting_times([character1])).to eq([])
    end

    it 'returns times where multiple characters are available' do
      times = described_class.find_best_meeting_times([character1, character2])
      expect(times).to be_an(Array)
      times.each do |t|
        expect(t).to have_key(:day)
        expect(t).to have_key(:hour)
        expect(t).to have_key(:attendees)
        expect(t).to have_key(:score)
        expect(t[:attendees].length).to be >= 2
      end
    end

    it 'respects the limit parameter' do
      times = described_class.find_best_meeting_times([character1, character2, character3], limit: 2)
      expect(times.length).to be <= 2
    end

    it 'prioritizes times with more attendees' do
      times = described_class.find_best_meeting_times([character1, character2, character3], limit: 10)
      # First result should have most attendees
      if times.length > 1
        expect(times.first[:attendee_count]).to be >= times.last[:attendee_count]
      end
    end

    it 'excludes characters with share_schedule disabled' do
      profile2.update(share_schedule: false)
      times = described_class.find_best_meeting_times([character1, character2, character3])
      # character2 should not appear in attendees
      times.each do |t|
        expect(t[:attendees].map(&:id)).not_to include(character2.id)
      end
    end

    it 'returns empty array if fewer than 2 shareable profiles' do
      profile1.update(share_schedule: false)
      profile2.update(share_schedule: false)
      times = described_class.find_best_meeting_times([character1, character2, character3])
      expect(times).to eq([])
    end
  end

  describe '#parsed_buckets edge cases' do
    it 'handles String JSON input' do
      profile = build(:activity_profile, character: character)
      profile.values[:activity_buckets] = '{"mon_14": 80}'
      expect(profile.parsed_buckets).to eq({ 'mon_14' => 80 })
    end

    it 'returns empty hash for invalid JSON' do
      profile = build(:activity_profile, character: character)
      profile.values[:activity_buckets] = 'not valid json'
      expect(profile.parsed_buckets).to eq({})
    end

    it 'handles Sequel JSONB wrapper objects' do
      profile = create(:activity_profile, :with_data, character: character)
      profile.reload
      expect(profile.parsed_buckets).to be_a(Hash)
      expect(profile.parsed_buckets).not_to be_empty
    end
  end

  describe '#record_sample! with time parameter' do
    let(:profile) { create(:activity_profile, character: character, tracking_enabled: true) }

    it 'records sample at specified time' do
      specific_time = Time.new(2024, 1, 15, 14, 30, 0) # Monday at 14:30
      profile.record_sample!(weight: 1.0, time: specific_time)
      profile.reload
      expect(profile.last_sample_at).to be_within(1).of(specific_time)
    end

    it 'uses correct slot key for the given time' do
      monday_3pm = Time.new(2024, 1, 15, 15, 0, 0) # Monday at 15:00
      profile.record_sample!(weight: 1.0, time: monday_3pm)
      profile.reload
      expect(profile.activity_at('mon', 15)).to be > 0
    end
  end

  describe 'before_save callback' do
    it 'initializes activity_buckets to empty hash if nil' do
      profile = described_class.create(character_id: character.id, activity_buckets: nil)
      expect(profile.activity_buckets).to eq({})
    end
  end
end
