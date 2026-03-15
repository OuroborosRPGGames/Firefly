# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AtmosphericEmitService do
  describe 'constants' do
    it 'defines COOLDOWN_SECONDS' do
      expect(described_class::COOLDOWN_SECONDS).to eq(3600)
    end

    it 'defines EXCLUDED_ROOM_TYPES' do
      expect(described_class::EXCLUDED_ROOM_TYPES).to match_array(%w[staff death limbo tutorial])
    end

    it 'defines ALLOWED_PUBLICITY' do
      expect(described_class::ALLOWED_PUBLICITY).to eq(%w[public semi_public])
    end
  end

  describe 'class methods' do
    it 'defines generate_for_room' do
      expect(described_class).to respond_to(:generate_for_room)
    end

    it 'defines broadcast_to_room' do
      expect(described_class).to respond_to(:broadcast_to_room)
    end

    it 'defines enabled?' do
      expect(described_class).to respond_to(:enabled?)
    end

    it 'defines emit_chance' do
      expect(described_class).to respond_to(:emit_chance)
    end

    it 'defines min_players' do
      expect(described_class).to respond_to(:min_players)
    end
  end

  describe '.emit_chance' do
    it 'returns a float' do
      result = described_class.emit_chance
      expect(result).to be_a(Float)
    end

    it 'returns a value between 0 and 1' do
      result = described_class.emit_chance
      expect(result).to be >= 0.0
      expect(result).to be <= 1.0
    end
  end

  describe '.min_players' do
    it 'returns an integer' do
      result = described_class.min_players
      expect(result).to be_an(Integer)
    end

    it 'returns at least 1' do
      result = described_class.min_players
      expect(result).to be >= 1
    end
  end

  describe '.generate_for_room' do
    it 'accepts a room parameter' do
      method = described_class.method(:generate_for_room)
      expect(method.parameters).to include([:req, :room])
    end
  end

  describe '.broadcast_to_room' do
    it 'accepts room and emit_text parameters' do
      method = described_class.method(:broadcast_to_room)
      expect(method.parameters).to include([:req, :room])
      expect(method.parameters).to include([:req, :emit_text])
    end
  end

  describe '.enabled?' do
    it 'returns true when setting is enabled' do
      allow(GameSetting).to receive(:boolean).with('atmospheric_emits_enabled').and_return(true)
      expect(described_class.enabled?).to be true
    end

    it 'returns false when setting is disabled' do
      allow(GameSetting).to receive(:boolean).with('atmospheric_emits_enabled').and_return(false)
      expect(described_class.enabled?).to be false
    end
  end

  describe '.generate_for_room behavior' do
    let(:location) { double('Location', weather: nil) }
    let(:room) do
      double('Room',
        id: 1,
        name: 'Town Square',
        room_type: 'outdoor',
        short_description: 'A bustling town square',
        publicity: 'public',
        location: location
      )
    end
    let(:mock_redis) { double('Redis') }

    before do
      allow(GameSetting).to receive(:boolean).with('atmospheric_emits_enabled').and_return(true)
      allow(GameTimeService).to receive(:time_of_day).and_return('afternoon')
      allow(GameTimeService).to receive(:season).and_return('summer')
      allow(WorldMemory).to receive(:for_room).and_return(double(all: []))
      allow(described_class).to receive(:find_characters_in_room).and_return([])
      allow(REDIS_POOL).to receive(:with).and_yield(mock_redis)
      allow(mock_redis).to receive(:exists?).and_return(false)
    end

    context 'when disabled' do
      before do
        allow(GameSetting).to receive(:boolean).with('atmospheric_emits_enabled').and_return(false)
      end

      it 'returns nil' do
        result = described_class.generate_for_room(room)
        expect(result).to be_nil
      end
    end

    context 'with nil room' do
      it 'returns nil' do
        result = described_class.generate_for_room(nil)
        expect(result).to be_nil
      end
    end

    context 'with excluded room type' do
      it 'returns nil for staff room' do
        staff_room = double('Room', room_type: 'staff')
        result = described_class.generate_for_room(staff_room)
        expect(result).to be_nil
      end

      it 'returns nil for death room' do
        death_room = double('Room', room_type: 'death')
        result = described_class.generate_for_room(death_room)
        expect(result).to be_nil
      end

      it 'returns nil for limbo room' do
        limbo_room = double('Room', room_type: 'limbo')
        result = described_class.generate_for_room(limbo_room)
        expect(result).to be_nil
      end
    end

    context 'with private room' do
      let(:private_room) do
        double('Room',
          room_type: 'apartment',
          publicity: 'private'
        )
      end

      it 'returns nil' do
        result = described_class.generate_for_room(private_room)
        expect(result).to be_nil
      end
    end

    context 'when on cooldown' do
      before do
        allow(mock_redis).to receive(:exists?).and_return(true)
      end

      it 'returns nil' do
        result = described_class.generate_for_room(room)
        expect(result).to be_nil
      end
    end

    context 'with valid room' do
      before do
        allow(GamePrompts).to receive(:get).and_return('Generate an atmospheric emit...')
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'The warm afternoon sun casts long shadows across the cobblestones.'
        })
      end

      it 'generates atmospheric description' do
        result = described_class.generate_for_room(room)
        expect(result).not_to be_nil
        expect(result).to include('afternoon')
      end

      it 'calls LLM with correct parameters' do
        expect(LLM::Client).to receive(:generate).with(
          hash_including(
            provider: 'google_gemini',
            model: 'gemini-3-flash-preview'
          )
        )
        described_class.generate_for_room(room)
      end

      it 'truncates long responses' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'A' * 200
        })
        result = described_class.generate_for_room(room)
        expect(result.length).to be <= 150
      end

      it 'strips quotes from response' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '"A gentle breeze carries the scent of flowers."'
        })
        result = described_class.generate_for_room(room)
        expect(result).not_to start_with('"')
        expect(result).not_to end_with('"')
      end
    end

    context 'when LLM fails' do
      before do
        allow(GamePrompts).to receive(:get).and_return('Generate...')
        allow(LLM::Client).to receive(:generate).and_return({ success: false, error: 'Rate limited' })
      end

      it 'returns nil' do
        result = described_class.generate_for_room(room)
        expect(result).to be_nil
      end
    end

    context 'with weather data' do
      let(:weather) do
        double('Weather',
          temperature_f: 72,
          intensity: 'light',
          condition: 'rain'
        )
      end
      let(:location_with_weather) { double('Location', weather: weather) }
      let(:room_with_weather) do
        double('Room',
          id: 1,
          name: 'Garden',
          room_type: 'outdoor',
          short_description: 'A peaceful garden',
          publicity: 'public',
          location: location_with_weather
        )
      end

      before do
        allow(GamePrompts).to receive(:get).and_return('Generate...')
        allow(LLM::Client).to receive(:generate).and_return({ success: true, text: 'Rain falls...' })
      end

      it 'includes weather context' do
        expect(GamePrompts).to receive(:get) do |_key, args|
          expect(args[:weather]).to include('72F')
          expect(args[:weather]).to include('rain')
          'Generate...'
        end
        described_class.generate_for_room(room_with_weather)
      end
    end

    context 'with world memories' do
      let(:memory1) { double('WorldMemory', summary: 'A bard performed here yesterday') }
      let(:memory2) { double('WorldMemory', summary: 'A market was held recently') }

      before do
        allow(WorldMemory).to receive(:for_room).and_return(double(all: [memory1, memory2]))
        allow(GamePrompts).to receive(:get).and_return('Generate...')
        allow(LLM::Client).to receive(:generate).and_return({ success: true, text: 'Nostalgic...' })
      end

      it 'includes recent memories in prompt' do
        expect(GamePrompts).to receive(:get) do |_key, args|
          expect(args[:memories_line]).to include('bard')
          expect(args[:memories_line]).to include('market')
          'Generate...'
        end
        described_class.generate_for_room(room)
      end
    end
  end

  describe '.broadcast_to_room behavior' do
    let(:room) { double('Room', id: 1) }
    let(:normal_ci) { double('CharacterInstance', accessibility_mode?: false) }
    let(:a11y_ci) { double('CharacterInstance', accessibility_mode?: true) }
    let(:mock_redis) { double('Redis') }

    before do
      allow(BroadcastService).to receive(:to_character_raw)
      allow(REDIS_POOL).to receive(:with).and_yield(mock_redis)
      allow(mock_redis).to receive(:setex)
    end

    context 'with empty emit text' do
      it 'does not broadcast nil text' do
        allow(described_class).to receive(:find_characters_in_room).and_return([normal_ci])
        described_class.broadcast_to_room(room, nil)
        expect(BroadcastService).not_to have_received(:to_character_raw)
      end

      it 'does not broadcast empty string' do
        allow(described_class).to receive(:find_characters_in_room).and_return([normal_ci])
        described_class.broadcast_to_room(room, '')
        expect(BroadcastService).not_to have_received(:to_character_raw)
      end
    end

    context 'with no characters in room' do
      before do
        allow(described_class).to receive(:find_characters_in_room).and_return([])
      end

      it 'does not broadcast' do
        described_class.broadcast_to_room(room, 'Test emit')
        expect(BroadcastService).not_to have_received(:to_character_raw)
      end
    end

    context 'with only accessibility mode users' do
      before do
        allow(described_class).to receive(:find_characters_in_room).and_return([a11y_ci])
      end

      it 'does not broadcast' do
        described_class.broadcast_to_room(room, 'Test emit')
        expect(BroadcastService).not_to have_received(:to_character_raw)
      end
    end

    context 'with eligible characters' do
      before do
        allow(described_class).to receive(:find_characters_in_room).and_return([normal_ci, a11y_ci])
      end

      it 'broadcasts to non-accessibility mode users' do
        described_class.broadcast_to_room(room, 'A soft breeze rustles the leaves.')
        expect(BroadcastService).to have_received(:to_character_raw).with(
          normal_ci,
          hash_including(content: 'A soft breeze rustles the leaves.'),
          hash_including(type: :atmosphere, skip_tts: true)
        )
      end

      it 'skips accessibility mode users' do
        described_class.broadcast_to_room(room, 'A soft breeze rustles the leaves.')
        expect(BroadcastService).not_to have_received(:to_character_raw).with(
          a11y_ci,
          anything,
          anything
        )
      end

      it 'sets room cooldown' do
        described_class.broadcast_to_room(room, 'Test emit')
        expect(mock_redis).to have_received(:setex).with(
          "atmospheric_emit_cooldown:#{room.id}",
          3600,
          '1'
        )
      end

      it 'includes HTML styling' do
        described_class.broadcast_to_room(room, 'A soft breeze.')
        expect(BroadcastService).to have_received(:to_character_raw).with(
          anything,
          hash_including(html: include('atmospheric-emit')),
          anything
        )
      end
    end
  end

  describe 'room population' do
    let(:room) { double('Room', id: 1) }

    before do
      allow(GameSetting).to receive(:boolean).with('atmospheric_emits_enabled').and_return(true)
    end

    it 'describes empty room correctly' do
      allow(described_class).to receive(:find_characters_in_room).and_return([])
      # Indirectly test via context that would be passed to LLM
      expect(described_class.send(:room_population, room)).to eq('empty')
    end

    it 'describes single person correctly' do
      allow(described_class).to receive(:find_characters_in_room).and_return([double])
      expect(described_class.send(:room_population, room)).to eq('one person')
    end

    it 'describes a few people correctly' do
      allow(described_class).to receive(:find_characters_in_room).and_return([double, double])
      expect(described_class.send(:room_population, room)).to eq('a few people')
    end

    it 'describes several people correctly' do
      allow(described_class).to receive(:find_characters_in_room).and_return(
        [double, double, double, double, double]
      )
      expect(described_class.send(:room_population, room)).to eq('several people')
    end
  end

  describe 'cooldown error handling' do
    let(:mock_redis) { double('Redis') }
    let(:room) { double('Room', id: 1, room_type: 'outdoor', publicity: 'public') }

    before do
      allow(GameSetting).to receive(:boolean).with('atmospheric_emits_enabled').and_return(true)
    end

    context 'when Redis fails during cooldown check' do
      before do
        allow(REDIS_POOL).to receive(:with).and_raise(StandardError.new('Redis connection failed'))
      end

      it 'returns false (not on cooldown) and continues' do
        result = described_class.send(:on_cooldown?, room)
        expect(result).to be false
      end
    end

    context 'when Redis fails during cooldown set' do
      before do
        allow(REDIS_POOL).to receive(:with).and_raise(StandardError.new('Redis connection failed'))
        allow(described_class).to receive(:find_characters_in_room).and_return([])
      end

      it 'logs error and continues' do
        expect {
          described_class.send(:set_cooldown!, room)
        }.not_to raise_error
      end
    end
  end
end
