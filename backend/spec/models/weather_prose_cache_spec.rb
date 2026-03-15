# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WeatherProseCache do
  let(:location) { create(:location) }

  # Helper to create a valid cache entry
  def create_cache(attrs = {})
    entry = WeatherProseCache.new
    entry.location = attrs[:location] || location
    entry.prose_text = attrs[:prose_text] || 'The sun shines brightly over the city.'
    entry.condition = attrs[:condition] || 'clear'
    entry.intensity = attrs[:intensity] if attrs[:intensity]
    entry.time_of_day = attrs[:time_of_day] if attrs[:time_of_day]
    entry.moon_phase = attrs[:moon_phase] if attrs[:moon_phase]
    entry.temperature_c = attrs[:temperature_c] if attrs[:temperature_c]
    entry.expires_at = attrs[:expires_at] || (Time.now + 3600)
    entry.save
    entry
  end

  describe 'associations' do
    it 'belongs to location' do
      cache = create_cache(location: location)
      expect(cache.location.id).to eq(location.id)
    end
  end

  describe 'validations' do
    it 'requires prose_text' do
      cache = WeatherProseCache.new(condition: 'clear', expires_at: Time.now + 3600)
      expect(cache.valid?).to be false
      expect(cache.errors[:prose_text]).not_to be_empty
    end

    it 'requires condition' do
      cache = WeatherProseCache.new(prose_text: 'Test', expires_at: Time.now + 3600)
      expect(cache.valid?).to be false
      expect(cache.errors[:condition]).not_to be_empty
    end

    it 'requires expires_at' do
      cache = WeatherProseCache.new(prose_text: 'Test', condition: 'clear')
      expect(cache.valid?).to be false
      expect(cache.errors[:expires_at]).not_to be_empty
    end

    it 'is valid with all required fields' do
      cache = WeatherProseCache.new(
        prose_text: 'Test prose',
        condition: 'clear',
        expires_at: Time.now + 3600
      )
      expect(cache.valid?).to be true
    end
  end

  describe '#expired?' do
    it 'returns true when expires_at is in the past' do
      cache = create_cache(expires_at: Time.now - 60)
      expect(cache.expired?).to be true
    end

    it 'returns false when expires_at is in the future' do
      cache = create_cache(expires_at: Time.now + 3600)
      expect(cache.expired?).to be false
    end
  end

  describe '#cache_valid?' do
    it 'returns true when not expired' do
      cache = create_cache(expires_at: Time.now + 3600)
      expect(cache.cache_valid?).to be true
    end

    it 'returns false when expired' do
      cache = create_cache(expires_at: Time.now - 60)
      expect(cache.cache_valid?).to be false
    end
  end

  describe '#seconds_until_expiry' do
    it 'returns positive seconds when not expired' do
      cache = create_cache(expires_at: Time.now + 120)
      expect(cache.seconds_until_expiry).to be_within(5).of(120)
    end

    it 'returns 0 when expired' do
      cache = create_cache(expires_at: Time.now - 60)
      expect(cache.seconds_until_expiry).to eq(0)
    end
  end

  describe '.find_valid' do
    let!(:valid_cache) do
      create_cache(
        location: location,
        condition: 'rain',
        intensity: 'heavy',
        time_of_day: 'night',
        moon_phase: 'full',
        expires_at: Time.now + 1800
      )
    end

    it 'returns matching cache entry' do
      result = WeatherProseCache.find_valid(
        location: location,
        condition: 'rain',
        intensity: 'heavy',
        time_of_day: 'night',
        moon_phase: 'full'
      )

      expect(result.id).to eq(valid_cache.id)
    end

    it 'returns nil when condition does not match' do
      result = WeatherProseCache.find_valid(
        location: location,
        condition: 'clear',
        intensity: 'heavy',
        time_of_day: 'night',
        moon_phase: 'full'
      )

      expect(result).to be_nil
    end

    it 'returns nil when cache is expired' do
      valid_cache.update(expires_at: Time.now - 60)

      result = WeatherProseCache.find_valid(
        location: location,
        condition: 'rain',
        intensity: 'heavy',
        time_of_day: 'night',
        moon_phase: 'full'
      )

      expect(result).to be_nil
    end

    it 'returns nil for different location' do
      other_location = create(:location)

      result = WeatherProseCache.find_valid(
        location: other_location,
        condition: 'rain',
        intensity: 'heavy',
        time_of_day: 'night',
        moon_phase: 'full'
      )

      expect(result).to be_nil
    end
  end

  describe '.cache_for' do
    it 'creates a new cache entry' do
      result = WeatherProseCache.cache_for(
        location: location,
        prose: 'It is raining heavily.',
        context: {
          condition: 'rain',
          intensity: 'heavy',
          time_of_day: :night,
          moon_phase: 'full',
          temperature_c: 15
        }
      )

      expect(result.prose_text).to eq('It is raining heavily.')
      expect(result.condition).to eq('rain')
      expect(result.intensity).to eq('heavy')
      expect(result.time_of_day).to eq('night')
      expect(result.moon_phase).to eq('full')
      expect(result.temperature_c).to eq(15)
    end

    it 'sets expiration 45 minutes from now' do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      result = WeatherProseCache.cache_for(
        location: location,
        prose: 'Test',
        context: { condition: 'clear' }
      )

      expected_expiry = freeze_time + (45 * 60)
      expect(result.expires_at).to be_within(1).of(expected_expiry)
    end

    it 'removes old cache entries for location' do
      old_cache = create_cache(location: location)

      WeatherProseCache.cache_for(
        location: location,
        prose: 'New prose',
        context: { condition: 'clear' }
      )

      expect(WeatherProseCache[old_cache.id]).to be_nil
    end
  end

  describe '.clear_expired!' do
    it 'deletes expired entries' do
      expired = create_cache(expires_at: Time.now - 120)
      valid = create_cache(expires_at: Time.now + 3600)

      deleted_count = WeatherProseCache.clear_expired!

      expect(deleted_count).to eq(1)
      expect(WeatherProseCache[expired.id]).to be_nil
      expect(WeatherProseCache[valid.id]).not_to be_nil
    end
  end

  describe '.clear_for_location!' do
    it 'deletes all entries for location' do
      cache1 = create_cache(location: location)
      cache2 = create_cache(location: location)
      other_location = create(:location)
      other_cache = create_cache(location: other_location)

      deleted_count = WeatherProseCache.clear_for_location!(location)

      expect(deleted_count).to eq(2)
      expect(WeatherProseCache[cache1.id]).to be_nil
      expect(WeatherProseCache[cache2.id]).to be_nil
      expect(WeatherProseCache[other_cache.id]).not_to be_nil
    end
  end
end
