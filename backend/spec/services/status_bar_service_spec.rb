# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StatusBarService do
  let(:character) { create(:character, forename: 'Alice', surname: 'Smith') }
  let(:room) { create(:room, name: 'Town Square') }
  let(:char_instance) do
    create(:character_instance,
           character: character,
           current_room_id: room.id,
           current_action: nil,
           current_action_until: nil)
  end
  let(:service) { described_class.new(char_instance) }

  describe '#initialize' do
    it 'stores the character instance' do
      expect(service.character_instance).to eq(char_instance)
    end
  end

  describe '#build_status_data' do
    context 'with valid character instance' do
      before do
        allow(char_instance).to receive(:private_mode?).and_return(false)
        allow(char_instance).to receive(:last_channel_name).and_return('ooc')
        allow(char_instance).to receive(:last_dm_target_ids).and_return([])
        allow(char_instance).to receive(:timeline).and_return(nil)
        allow(char_instance).to receive(:display_action).and_return('standing here')
        allow(char_instance).to receive(:afk?).and_return(false)
        allow(char_instance).to receive(:gtg_until).and_return(nil)
        allow(char_instance).to receive(:semiafk?).and_return(false)
      end

      it 'returns hash with left, right, and weather keys' do
        result = service.build_status_data
        expect(result).to have_key(:left)
        expect(result).to have_key(:right)
        expect(result).to have_key(:weather)
      end

      it 'returns left status with channel info' do
        result = service.build_status_data
        expect(result[:left]).to have_key(:channel)
        expect(result[:left]).to have_key(:time)
        expect(result[:left]).to have_key(:private_mode)
      end

      it 'returns right status with action info' do
        result = service.build_status_data
        expect(result[:right]).to have_key(:action_text)
        expect(result[:right]).to have_key(:action_type)
        expect(result[:right]).to have_key(:presence)
      end
    end

    context 'with nil character instance' do
      let(:service) { described_class.new(nil) }

      it 'returns nil' do
        expect(service.build_status_data).to be_nil
      end
    end
  end

  describe 'channel display formatting' do
    before do
      allow(char_instance).to receive(:private_mode?).and_return(false)
      allow(char_instance).to receive(:last_dm_target_ids).and_return([])
      allow(char_instance).to receive(:timeline).and_return(nil)
      allow(char_instance).to receive(:display_action).and_return(nil)
      allow(char_instance).to receive(:afk?).and_return(false)
      allow(char_instance).to receive(:gtg_until).and_return(nil)
      allow(char_instance).to receive(:semiafk?).and_return(false)
    end

    it 'formats room channel correctly' do
      allow(char_instance).to receive(:last_channel_name).and_return('room')
      result = service.build_status_data
      expect(result[:left][:channel][:display]).to eq('Room')
    end

    it 'formats ooc channel correctly' do
      allow(char_instance).to receive(:last_channel_name).and_return('ooc')
      result = service.build_status_data
      expect(result[:left][:channel][:display]).to eq('OOC')
    end

    it 'formats whisper channel correctly' do
      allow(char_instance).to receive(:last_channel_name).and_return('whisper')
      result = service.build_status_data
      expect(result[:left][:channel][:display]).to eq('Whisper')
    end

    it 'formats pm channel correctly' do
      allow(char_instance).to receive(:last_channel_name).and_return('private_message')
      result = service.build_status_data
      expect(result[:left][:channel][:display]).to eq('PM')
    end

    it 'defaults to OOC for empty channel name' do
      allow(char_instance).to receive(:last_channel_name).and_return('')
      allow(char_instance).to receive(:current_channel_id).and_return(nil)
      result = service.build_status_data
      # Service defaults to OOC when no channel is set
      expect(result[:left][:channel][:name]).to match(/ooc/i)
    end

    it 'defaults to OOC for nil channel name' do
      allow(char_instance).to receive(:last_channel_name).and_return(nil)
      allow(char_instance).to receive(:current_channel_id).and_return(nil)
      result = service.build_status_data
      # Service defaults to OOC when no channel is set
      expect(result[:left][:channel][:name]).to match(/ooc/i)
    end
  end

  describe 'action type determination' do
    before do
      allow(char_instance).to receive(:private_mode?).and_return(false)
      allow(char_instance).to receive(:last_channel_name).and_return(nil)
      allow(char_instance).to receive(:last_dm_target_ids).and_return([])
      allow(char_instance).to receive(:timeline).and_return(nil)
      allow(char_instance).to receive(:display_action).and_return(nil)
      allow(char_instance).to receive(:afk?).and_return(false)
      allow(char_instance).to receive(:gtg_until).and_return(nil)
      allow(char_instance).to receive(:semiafk?).and_return(false)
    end

    context 'with temporary action' do
      before do
        allow(char_instance).to receive(:current_action).and_return('dancing')
        allow(char_instance).to receive(:current_action_until).and_return(Time.now + 60)
      end

      it 'returns :temporary action type' do
        result = service.build_status_data
        expect(result[:right][:action_type]).to eq(:temporary)
      end

      it 'calculates expires_in' do
        result = service.build_status_data
        expect(result[:right][:expires_in]).to be_a(Integer)
        expect(result[:right][:expires_in]).to be > 0
      end
    end

    context 'with static action' do
      before do
        allow(char_instance).to receive(:current_action).and_return(nil)
        allow(char_instance).to receive(:current_action_until).and_return(nil)
      end

      it 'returns :static action type' do
        result = service.build_status_data
        expect(result[:right][:action_type]).to eq(:static)
      end

      it 'returns nil for expires_in' do
        result = service.build_status_data
        expect(result[:right][:expires_in]).to be_nil
      end
    end

    context 'with expired temporary action' do
      before do
        allow(char_instance).to receive(:current_action).and_return('dancing')
        allow(char_instance).to receive(:current_action_until).and_return(Time.now - 60)
      end

      it 'returns :static action type for expired actions' do
        result = service.build_status_data
        expect(result[:right][:action_type]).to eq(:static)
      end
    end
  end

  describe 'presence info' do
    before do
      allow(char_instance).to receive(:private_mode?).and_return(false)
      allow(char_instance).to receive(:last_channel_name).and_return(nil)
      allow(char_instance).to receive(:last_dm_target_ids).and_return([])
      allow(char_instance).to receive(:timeline).and_return(nil)
      allow(char_instance).to receive(:display_action).and_return(nil)
      allow(char_instance).to receive(:current_action).and_return(nil)
      allow(char_instance).to receive(:current_action_until).and_return(nil)
    end

    context 'when AFK' do
      before do
        allow(char_instance).to receive(:afk?).and_return(true)
        allow(char_instance).to receive(:gtg_until).and_return(nil)
        allow(char_instance).to receive(:semiafk?).and_return(false)
      end

      it 'returns afk status' do
        result = service.build_status_data
        expect(result[:right][:presence][:status]).to eq('afk')
      end

      it 'includes time remaining when afk_until is set' do
        allow(char_instance).to receive(:afk_until).and_return(Time.now + 300)
        result = service.build_status_data
        expect(result[:right][:presence][:minutes_remaining]).to be_a(Integer)
      end

      it 'shows simple AFK when no time set' do
        allow(char_instance).to receive(:afk_until).and_return(nil)
        result = service.build_status_data
        expect(result[:right][:presence][:display]).to eq('AFK')
      end
    end

    context 'when GTG' do
      before do
        allow(char_instance).to receive(:afk?).and_return(false)
        allow(char_instance).to receive(:gtg_until).and_return(Time.now + 300)
        allow(char_instance).to receive(:semiafk?).and_return(false)
      end

      it 'returns gtg status' do
        result = service.build_status_data
        expect(result[:right][:presence][:status]).to eq('gtg')
      end

      it 'includes minutes remaining' do
        result = service.build_status_data
        expect(result[:right][:presence][:minutes_remaining]).to be_a(Integer)
      end
    end

    context 'when semi-AFK' do
      before do
        allow(char_instance).to receive(:afk?).and_return(false)
        allow(char_instance).to receive(:gtg_until).and_return(nil)
        allow(char_instance).to receive(:semiafk?).and_return(true)
      end

      it 'returns semiafk status' do
        allow(char_instance).to receive(:semiafk_until).and_return(nil)
        result = service.build_status_data
        expect(result[:right][:presence][:status]).to eq('semiafk')
        expect(result[:right][:presence][:display]).to eq('Semi-AFK')
      end

      it 'includes minutes remaining when semiafk_until is set' do
        allow(char_instance).to receive(:semiafk_until).and_return(Time.now + 900)
        result = service.build_status_data
        expect(result[:right][:presence][:status]).to eq('semiafk')
        expect(result[:right][:presence][:display]).to match(/Semi-AFK \d+m/)
        expect(result[:right][:presence][:minutes_remaining]).to be_a(Integer)
        expect(result[:right][:presence][:minutes_remaining]).to be > 0
      end
    end

    context 'when present' do
      before do
        allow(char_instance).to receive(:afk?).and_return(false)
        allow(char_instance).to receive(:gtg_until).and_return(nil)
        allow(char_instance).to receive(:semiafk?).and_return(false)
      end

      it 'returns present status' do
        result = service.build_status_data
        expect(result[:right][:presence][:status]).to eq('present')
        expect(result[:right][:presence][:display]).to be_nil
      end
    end
  end

  describe 'weather emoji' do
    let(:weather_method) { service.send(:weather_emoji, condition) }

    {
      'clear' => '☀',
      'cloudy' => '☁',
      'overcast' => '☁',
      'rain' => '☂',
      'storm' => '⛈',
      'thunderstorm' => '⛈',
      'snow' => '❄',
      'blizzard' => '❄',
      'fog' => '▒',
      'wind' => '≋',
      'hail' => '⛆',
      'hurricane' => '⚡',
      'tornado' => '⚡',
      'heat_wave' => '♨',
      'cold_snap' => '❆'
    }.each do |cond, emoji|
      context "with #{cond} condition" do
        let(:condition) { cond }

        it "returns #{emoji}" do
          expect(weather_method).to eq(emoji)
        end
      end
    end

    context 'with unknown condition' do
      let(:condition) { 'unknown' }

      it 'returns default emoji' do
        expect(weather_method).to eq('☀')
      end
    end
  end

  describe 'time display' do
    before do
      allow(char_instance).to receive(:private_mode?).and_return(false)
      allow(char_instance).to receive(:last_channel_name).and_return(nil)
      allow(char_instance).to receive(:last_dm_target_ids).and_return([])
      allow(char_instance).to receive(:display_action).and_return(nil)
      allow(char_instance).to receive(:current_action).and_return(nil)
      allow(char_instance).to receive(:current_action_until).and_return(nil)
      allow(char_instance).to receive(:afk?).and_return(false)
      allow(char_instance).to receive(:gtg_until).and_return(nil)
      allow(char_instance).to receive(:semiafk?).and_return(false)
    end

    context 'with normal timeline' do
      before do
        allow(char_instance).to receive(:timeline).and_return(nil)
      end

      it 'returns time info with is_historical false' do
        result = service.build_status_data
        expect(result[:left][:time][:is_historical]).to be false
      end
    end

    context 'with historical timeline' do
      let(:timeline) { instance_double('Timeline', historical?: true, year: 1850, era: 'Victorian', display_name: '1850 Victorian') }

      before do
        allow(char_instance).to receive(:timeline).and_return(timeline)
      end

      it 'returns historical time info' do
        result = service.build_status_data
        expect(result[:left][:time][:is_historical]).to be true
        expect(result[:left][:time][:year]).to eq(1850)
        expect(result[:left][:time][:era]).to eq('Victorian')
      end
    end
  end
end
