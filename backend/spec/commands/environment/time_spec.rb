# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Environment::Time, type: :command do
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Test', user: user) }
  let(:character_instance) { create(:character_instance, character: character, stance: 'standing') }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'basic time display' do
      it 'returns success' do
        result = command.execute('time')
        expect(result[:success]).to be true
      end

      it 'displays current time' do
        result = command.execute('time')
        expect(result[:message]).to match(/It is \d{1,2}:\d{2} [AP]M/)
      end

      it 'displays current date' do
        result = command.execute('time')
        expect(result[:message]).to match(/\w+, \w+ \d{1,2}, \d{4}/)
      end

      it 'displays time of day period' do
        result = command.execute('time')
        expect(result[:message]).to match(/(Dawn|Day|Dusk|Night)/)
      end

      it 'includes moon phase information' do
        result = command.execute('time')
        # Moon phase names include: new moon, waxing crescent, first quarter, etc.
        expect(result[:message]).to match(/moon|crescent|quarter|gibbous/)
      end

      it 'includes moon emoji' do
        result = command.execute('time')
        # Moon emojis are in the range U+1F311 to U+1F318
        expect(result[:message]).to match(/[\u{1F311}-\u{1F318}]/)
      end
    end

    context 'with clock alias' do
      it 'works with clock alias' do
        result = command.execute('clock')
        expect(result[:success]).to be true
        expect(result[:message]).to match(/It is/)
      end
    end

    context 'with date alias' do
      it 'works with date alias' do
        result = command.execute('date')
        expect(result[:success]).to be true
        expect(result[:message]).to match(/\w+, \w+ \d{1,2}, \d{4}/)
      end
    end

    context 'structured data' do
      it 'returns hour in data' do
        result = command.execute('time')
        expect(result[:data][:hour]).to be_between(0, 23)
      end

      it 'returns minute in data' do
        result = command.execute('time')
        expect(result[:data][:minute]).to be_between(0, 59)
      end

      it 'returns time_of_day in data' do
        result = command.execute('time')
        expect(%i[dawn day dusk night]).to include(result[:data][:time_of_day])
      end

      it 'returns moon_phase in data' do
        result = command.execute('time')
        expect(result[:data][:moon_phase]).to be_a(String)
        expect(result[:data][:moon_phase]).not_to be_empty
      end

      it 'returns moon_illumination in data' do
        result = command.execute('time')
        expect(result[:data][:moon_illumination]).to be_between(0, 1)
      end
    end
  end
end
