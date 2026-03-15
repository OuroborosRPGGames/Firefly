# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::SetSeasonal, type: :command do
  let(:room) { create(:room) }
  let(:outer_room) { double('outer_room') }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end

  subject(:command) do
    cmd = described_class.new(character_instance)
    # Override location since the command loads Room fresh from DB
    allow(cmd).to receive(:location).and_return(room)
    cmd
  end

  before do
    # Mock outer_room relationship
    allow(room).to receive(:outer_room).and_return(outer_room)
    # Use flexible matcher since character_instance.character may be a different Ruby object
    allow(outer_room).to receive(:owned_by?).and_return(true)
  end

  it_behaves_like "command metadata", 'set seasonal', :building, %w[setseasonal seasonal]

  describe '#execute' do
    context 'when not owner' do
      before do
        allow(outer_room).to receive(:owned_by?).and_return(false)
      end

      it 'returns error about ownership' do
        result = command.execute('set seasonal desc morning spring Test description')

        expect(result[:success]).to be false
        expect(result[:error]).to include("don't own this room")
      end
    end

    context 'with no arguments' do
      it 'shows usage help' do
        result = command.execute('set seasonal')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Usage: set seasonal')
        expect(result[:message]).to include('desc')
        expect(result[:message]).to include('bg')
        expect(result[:message]).to include('list')
        expect(result[:message]).to include('clear')
      end
    end

    context 'with "list" action' do
      it 'shows empty seasonal settings' do
        allow(room).to receive(:list_seasonal_descriptions).and_return({})
        allow(room).to receive(:list_seasonal_backgrounds).and_return({})

        result = command.execute('set seasonal list')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Seasonal settings')
        expect(result[:message]).to include('(none set)')
      end

      it 'shows existing descriptions' do
        allow(room).to receive(:list_seasonal_descriptions).and_return({
                                                                         'morning_spring' => 'The spring morning light...',
                                                                         'default' => 'A cozy room.'
                                                                       })
        allow(room).to receive(:list_seasonal_backgrounds).and_return({})

        result = command.execute('set seasonal list')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Descriptions:')
        expect(result[:message]).to include('morning_spring')
      end

      it 'shows existing backgrounds' do
        allow(room).to receive(:list_seasonal_descriptions).and_return({})
        allow(room).to receive(:list_seasonal_backgrounds).and_return({
                                                                        'night' => 'https://example.com/night.jpg'
                                                                      })

        result = command.execute('set seasonal list')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Backgrounds:')
        expect(result[:message]).to include('https://example.com/night.jpg')
      end

      it 'truncates long descriptions in preview' do
        long_desc = 'A' * 100
        allow(room).to receive(:list_seasonal_descriptions).and_return({ 'default' => long_desc })
        allow(room).to receive(:list_seasonal_backgrounds).and_return({})

        result = command.execute('set seasonal list')

        expect(result[:message]).to include('...')
      end
    end

    context 'with "desc" action' do
      it 'sets seasonal description with time and season' do
        expect(room).to receive(:set_seasonal_description!).with('morning', 'spring', 'The spring sun rises.')

        result = command.execute('set seasonal desc morning spring The spring sun rises.')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Seasonal description set for morning_spring')
        expect(result[:data][:action]).to eq('set_seasonal_description')
      end

      it 'sets description with wildcard time (-)' do
        expect(room).to receive(:set_seasonal_description!).with(nil, 'winter', 'Snow everywhere.')

        result = command.execute('set seasonal desc - winter Snow everywhere.')

        expect(result[:success]).to be true
        expect(result[:message]).to include('winter (any time)')
      end

      it 'sets description with wildcard season (-)' do
        expect(room).to receive(:set_seasonal_description!).with('night', nil, 'Dark and quiet.')

        result = command.execute('set seasonal desc night - Dark and quiet.')

        expect(result[:success]).to be true
        expect(result[:message]).to include('night (any season)')
      end

      it 'sets default description with both wildcards' do
        expect(room).to receive(:set_seasonal_description!).with(nil, nil, 'Regular room.')

        result = command.execute('set seasonal desc - - Regular room.')

        expect(result[:success]).to be true
        expect(result[:message]).to include('default')
      end

      it 'returns error for missing arguments' do
        result = command.execute('set seasonal desc morning')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end

      it 'returns error for invalid time' do
        result = command.execute('set seasonal desc invalid spring Description')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid time')
        expect(result[:error]).to include('morning, afternoon')
      end

      it 'returns error for invalid season' do
        result = command.execute('set seasonal desc morning invalid Description')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid season')
        expect(result[:error]).to include('spring, summer')
      end

      it 'returns error for empty description' do
        result = command.execute('set seasonal desc morning spring')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end

      it 'accepts "description" as alias for "desc"' do
        expect(room).to receive(:set_seasonal_description!).with('morning', 'spring', 'Test')

        result = command.execute('set seasonal description morning spring Test')

        expect(result[:success]).to be true
      end

      it 'handles all valid time options' do
        %w[morning afternoon evening night dawn day dusk].each do |time|
          expect(room).to receive(:set_seasonal_description!).with(time, 'spring', 'Test')
          result = command.execute("set seasonal desc #{time} spring Test")
          expect(result[:success]).to be true
        end
      end

      it 'handles all valid season options' do
        %w[spring summer fall winter].each do |season|
          expect(room).to receive(:set_seasonal_description!).with('morning', season, 'Test')
          result = command.execute("set seasonal desc morning #{season} Test")
          expect(result[:success]).to be true
        end
      end
    end

    context 'with "bg" action' do
      it 'sets seasonal background with valid URL' do
        expect(room).to receive(:set_seasonal_background!).with('morning', 'summer', 'https://example.com/summer.jpg')

        result = command.execute('set seasonal bg morning summer https://example.com/summer.jpg')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Seasonal background set for morning_summer')
        expect(result[:data][:action]).to eq('set_seasonal_background')
        expect(result[:data][:url]).to eq('https://example.com/summer.jpg')
      end

      it 'sets background with http URL' do
        expect(room).to receive(:set_seasonal_background!).with('night', nil, 'http://example.com/night.jpg')

        result = command.execute('set seasonal bg night - http://example.com/night.jpg')

        expect(result[:success]).to be true
      end

      it 'returns error for missing arguments' do
        result = command.execute('set seasonal bg morning')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end

      it 'returns error for invalid time' do
        result = command.execute('set seasonal bg invalid spring https://example.com/img.jpg')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid time')
      end

      it 'returns error for invalid season' do
        result = command.execute('set seasonal bg morning invalid https://example.com/img.jpg')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid season')
      end

      it 'returns error for empty URL' do
        result = command.execute('set seasonal bg morning spring')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end

      it 'returns error for invalid URL scheme' do
        result = command.execute('set seasonal bg morning spring ftp://example.com/img.jpg')

        expect(result[:success]).to be false
        expect(result[:error]).to include('valid URL')
        expect(result[:error]).to include('http://')
      end

      it 'returns error for URL too long' do
        long_url = "https://example.com/#{'a' * 2100}"
        result = command.execute("set seasonal bg morning spring #{long_url}")

        expect(result[:success]).to be false
        expect(result[:error]).to include('URL too long')
        expect(result[:error]).to include('2048')
      end

      it 'accepts "background" as alias for "bg"' do
        expect(room).to receive(:set_seasonal_background!).with('night', nil, 'https://example.com/bg.jpg')

        result = command.execute('set seasonal background night - https://example.com/bg.jpg')

        expect(result[:success]).to be true
      end
    end

    context 'with "clear" action' do
      it 'clears seasonal description' do
        expect(room).to receive(:clear_seasonal_description!).with('morning', 'spring')

        result = command.execute('set seasonal clear desc morning spring')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Cleared seasonal description')
      end

      it 'clears seasonal background' do
        expect(room).to receive(:clear_seasonal_background!).with('night', nil)

        result = command.execute('set seasonal clear bg night -')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Cleared seasonal background')
      end

      it 'returns error for missing arguments' do
        result = command.execute('set seasonal clear desc')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end

      it 'returns error for invalid type' do
        result = command.execute('set seasonal clear invalid morning spring')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Specify desc or bg')
      end

      it 'returns error for invalid time' do
        result = command.execute('set seasonal clear desc invalid spring')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid time')
      end

      it 'returns error for invalid season' do
        result = command.execute('set seasonal clear desc morning invalid')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid season')
      end

      it 'accepts "description" alias' do
        expect(room).to receive(:clear_seasonal_description!).with('morning', 'spring')

        result = command.execute('set seasonal clear description morning spring')

        expect(result[:success]).to be true
      end

      it 'accepts "background" alias' do
        expect(room).to receive(:clear_seasonal_background!).with('morning', 'spring')

        result = command.execute('set seasonal clear background morning spring')

        expect(result[:success]).to be true
      end
    end

    context 'with unknown action' do
      it 'shows usage help' do
        result = command.execute('set seasonal invalid')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Usage: set seasonal')
      end
    end
  end

  describe '#build_display_key' do
    it 'builds key for time and season' do
      expect(command.send(:build_display_key, 'morning', 'spring')).to eq('morning_spring')
    end

    it 'builds key for time only' do
      expect(command.send(:build_display_key, 'night', nil)).to eq('night (any season)')
    end

    it 'builds key for season only' do
      expect(command.send(:build_display_key, nil, 'winter')).to eq('winter (any time)')
    end

    it 'builds default key' do
      expect(command.send(:build_display_key, nil, nil)).to eq('default')
    end
  end

  describe '#valid_time?' do
    it 'accepts valid times' do
      %w[morning afternoon evening night dawn day dusk -].each do |time|
        expect(command.send(:valid_time?, time)).to be true
      end
    end

    it 'rejects invalid times' do
      expect(command.send(:valid_time?, 'midnight')).to be false
      expect(command.send(:valid_time?, 'noon')).to be false
    end
  end

  describe '#valid_season?' do
    it 'accepts valid seasons' do
      %w[spring summer fall winter -].each do |season|
        expect(command.send(:valid_season?, season)).to be true
      end
    end

    it 'rejects invalid seasons' do
      expect(command.send(:valid_season?, 'autumn')).to be false
      expect(command.send(:valid_season?, 'rainy')).to be false
    end
  end
end
