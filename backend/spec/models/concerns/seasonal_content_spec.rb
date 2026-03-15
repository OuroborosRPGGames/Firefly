# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SeasonalContent do
  # Create a test class that uses SeasonalContent
  let(:test_class) do
    Class.new do
      attr_accessor :seasonal_descriptions, :seasonal_backgrounds, :description, :default_background_url

      include SeasonalContent

      def initialize
        @seasonal_descriptions = {}
        @seasonal_backgrounds = {}
        @description = 'Default description'
        @default_background_url = 'https://example.com/default.jpg'
      end

      def update(attrs)
        attrs.each do |key, value|
          # Handle Sequel JSONB wrap
          if value.respond_to?(:to_hash)
            instance_variable_set("@#{key}", value.to_hash)
          else
            instance_variable_set("@#{key}", value)
          end
        end
      end
    end
  end

  let(:instance) { test_class.new }

  before do
    # Mock GameTimeService
    allow(GameTimeService).to receive(:normalize_time_name) do |time|
      case time.to_s
      when 'dawn', 'day', 'dusk', 'night' then time.to_s
      when '-', '' then nil
      else time&.to_s
      end
    end

    allow(GameTimeService).to receive(:normalize_season_name) do |season|
      case season.to_s
      when 'spring', 'summer', 'fall', 'winter' then season.to_s
      when '-', '' then nil
      else season&.to_s
      end
    end
  end

  describe '#set_seasonal_description!' do
    it 'sets a time-and-season specific description' do
      instance.set_seasonal_description!(:dawn, :spring, 'Morning dew sparkles...')

      expect(instance.seasonal_descriptions['dawn_spring']).to eq('Morning dew sparkles...')
    end

    it 'sets a time-only description when season is nil' do
      instance.set_seasonal_description!(:night, nil, 'Stars twinkle overhead...')

      expect(instance.seasonal_descriptions['night']).to eq('Stars twinkle overhead...')
    end

    it 'sets a season-only description when time is nil' do
      instance.set_seasonal_description!(nil, :winter, 'Snow blankets everything...')

      expect(instance.seasonal_descriptions['winter']).to eq('Snow blankets everything...')
    end

    it 'sets a default description when both are nil' do
      instance.set_seasonal_description!(nil, nil, 'A default description')

      expect(instance.seasonal_descriptions['default']).to eq('A default description')
    end
  end

  describe '#clear_seasonal_description!' do
    before do
      instance.seasonal_descriptions = {
        'dawn_spring' => 'Morning dew...',
        'night' => 'Stars...'
      }
    end

    it 'removes the specified description' do
      instance.clear_seasonal_description!(:dawn, :spring)

      expect(instance.seasonal_descriptions).not_to have_key('dawn_spring')
      expect(instance.seasonal_descriptions['night']).to eq('Stars...')
    end
  end

  describe '#list_seasonal_descriptions' do
    it 'returns the seasonal descriptions hash' do
      instance.seasonal_descriptions = { 'dawn' => 'Morning', 'night' => 'Evening' }

      expect(instance.list_seasonal_descriptions).to eq({ 'dawn' => 'Morning', 'night' => 'Evening' })
    end

    it 'returns empty hash when nil' do
      instance.seasonal_descriptions = nil

      expect(instance.list_seasonal_descriptions).to eq({})
    end
  end

  describe '#resolve_description' do
    before do
      instance.seasonal_descriptions = {
        'dawn_spring' => 'Spring dawn description',
        'dawn' => 'Dawn description',
        'spring' => 'Spring description',
        'default' => 'Default seasonal description'
      }
      instance.description = 'Fallback description'
    end

    it 'returns specific time_season description first' do
      expect(instance.resolve_description(:dawn, :spring)).to eq('Spring dawn description')
    end

    it 'falls back to time-only description' do
      expect(instance.resolve_description(:dawn, :winter)).to eq('Dawn description')
    end

    it 'falls back to season-only description' do
      expect(instance.resolve_description(:dusk, :spring)).to eq('Spring description')
    end

    it 'falls back to default seasonal description' do
      expect(instance.resolve_description(:dusk, :winter)).to eq('Default seasonal description')
    end

    it 'falls back to base description when no seasonal match' do
      instance.seasonal_descriptions = {}
      expect(instance.resolve_description(:dusk, :winter)).to eq('Fallback description')
    end

    it 'returns nil when no descriptions exist' do
      instance.seasonal_descriptions = {}
      instance.description = nil

      # Need to handle respond_to? check
      allow(instance).to receive(:respond_to?).with(:description).and_return(false)

      expect(instance.resolve_description(:dawn, :spring)).to be_nil
    end
  end

  describe '#set_seasonal_background!' do
    it 'sets a time-and-season specific background' do
      instance.set_seasonal_background!(:dawn, :spring, 'https://example.com/dawn_spring.jpg')

      expect(instance.seasonal_backgrounds['dawn_spring']).to eq('https://example.com/dawn_spring.jpg')
    end

    it 'sets a default background when both are nil' do
      instance.set_seasonal_background!(nil, nil, 'https://example.com/default.jpg')

      expect(instance.seasonal_backgrounds['default']).to eq('https://example.com/default.jpg')
    end

    it 'does nothing when seasonal_backgrounds is not supported' do
      no_bg_instance = Object.new
      no_bg_instance.extend(SeasonalContent)

      # Should not raise
      no_bg_instance.set_seasonal_background!(:dawn, :spring, 'https://example.com/test.jpg')
    end
  end

  describe '#clear_seasonal_background!' do
    before do
      instance.seasonal_backgrounds = {
        'dawn_spring' => 'https://example.com/dawn_spring.jpg',
        'night' => 'https://example.com/night.jpg'
      }
    end

    it 'removes the specified background' do
      instance.clear_seasonal_background!(:dawn, :spring)

      expect(instance.seasonal_backgrounds).not_to have_key('dawn_spring')
      expect(instance.seasonal_backgrounds['night']).to eq('https://example.com/night.jpg')
    end
  end

  describe '#list_seasonal_backgrounds' do
    it 'returns the seasonal backgrounds hash' do
      instance.seasonal_backgrounds = { 'dawn' => 'url1', 'night' => 'url2' }

      expect(instance.list_seasonal_backgrounds).to eq({ 'dawn' => 'url1', 'night' => 'url2' })
    end

    it 'returns empty hash when nil' do
      instance.seasonal_backgrounds = nil

      expect(instance.list_seasonal_backgrounds).to eq({})
    end

    it 'returns empty hash when not supported' do
      no_bg_instance = Object.new
      no_bg_instance.extend(SeasonalContent)

      expect(no_bg_instance.list_seasonal_backgrounds).to eq({})
    end
  end

  describe '#resolve_background' do
    before do
      instance.seasonal_backgrounds = {
        'dawn_spring' => 'https://example.com/dawn_spring.jpg',
        'dawn' => 'https://example.com/dawn.jpg',
        'spring' => 'https://example.com/spring.jpg',
        'default' => 'https://example.com/seasonal_default.jpg'
      }
      instance.default_background_url = 'https://example.com/fallback.jpg'
    end

    it 'returns specific time_season background first' do
      expect(instance.resolve_background(:dawn, :spring)).to eq('https://example.com/dawn_spring.jpg')
    end

    it 'falls back to time-only background' do
      expect(instance.resolve_background(:dawn, :winter)).to eq('https://example.com/dawn.jpg')
    end

    it 'falls back to season-only background' do
      expect(instance.resolve_background(:dusk, :spring)).to eq('https://example.com/spring.jpg')
    end

    it 'falls back to default seasonal background' do
      expect(instance.resolve_background(:dusk, :winter)).to eq('https://example.com/seasonal_default.jpg')
    end

    it 'falls back to default_background_url when no seasonal match' do
      instance.seasonal_backgrounds = {}
      expect(instance.resolve_background(:dusk, :winter)).to eq('https://example.com/fallback.jpg')
    end

    it 'returns nil when not supported' do
      no_bg_instance = Object.new
      no_bg_instance.extend(SeasonalContent)

      expect(no_bg_instance.resolve_background(:dawn, :spring)).to be_nil
    end
  end

  describe 'key building' do
    it 'builds time_season key for both values' do
      instance.set_seasonal_description!(:dawn, :spring, 'test')
      expect(instance.seasonal_descriptions).to have_key('dawn_spring')
    end

    it 'builds time-only key when season is -' do
      allow(GameTimeService).to receive(:normalize_season_name).with('-').and_return(nil)
      instance.set_seasonal_description!(:dawn, '-', 'test')
      expect(instance.seasonal_descriptions).to have_key('dawn')
    end

    it 'builds season-only key when time is -' do
      allow(GameTimeService).to receive(:normalize_time_name).with('-').and_return(nil)
      instance.set_seasonal_description!('-', :spring, 'test')
      expect(instance.seasonal_descriptions).to have_key('spring')
    end

    it 'builds default key when both are -' do
      allow(GameTimeService).to receive(:normalize_time_name).with('-').and_return(nil)
      allow(GameTimeService).to receive(:normalize_season_name).with('-').and_return(nil)
      instance.set_seasonal_description!('-', '-', 'test')
      expect(instance.seasonal_descriptions).to have_key('default')
    end
  end
end
