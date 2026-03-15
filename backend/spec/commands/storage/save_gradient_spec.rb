# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Storage::SaveGradient, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Diana') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with valid gradient' do
      it 'saves the gradient' do
        result = command.execute('save gradient #ff0000,#00ff00 as christmas')

        expect(result[:success]).to be true
        expect(result[:message]).to include('saved')
        expect(result[:message]).to include('christmas')

        saved = MediaLibrary.find_by_name(character, 'christmas')
        expect(saved).not_to be_nil
        expect(saved.media_type).to eq('gradient')
        expect(saved.content).to eq('#ff0000,#00ff00')
      end

      it 'returns gradient data in result' do
        result = command.execute('save gradient #000,#fff as mono')

        expect(result[:data][:action]).to eq('save_gradient')
        expect(result[:data][:name]).to eq('mono')
      end

      it 'accepts hex codes without hash' do
        result = command.execute('save gradient ff0000,00ff00 as test')

        expect(result[:success]).to be true
      end

      it 'accepts three or more colors' do
        result = command.execute('save gradient #ff0000,#00ff00,#0000ff as rainbow')

        expect(result[:success]).to be true
        expect(MediaLibrary.find_by_name(character, 'rainbow').content).to eq('#ff0000,#00ff00,#0000ff')
      end
    end

    context 'with invalid gradient format' do
      it 'rejects single color' do
        result = command.execute('save gradient #ff0000 as single')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid gradient')
      end

      it 'rejects invalid hex codes' do
        result = command.execute('save gradient #gg0000,#00ff00 as invalid')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid gradient')
      end
    end

    context 'with no input' do
      it 'returns error' do
        result = command.execute('save gradient')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end
    end

    context 'without "as" separator' do
      it 'returns error' do
        result = command.execute('save gradient #ff0000,#00ff00 christmas')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end
    end

    context 'with duplicate name' do
      before do
        MediaLibrary.create(
          character_id: character.id,
          mtype: 'gradient',
          mname: 'existing',
          mtext: '#000000,#ffffff'
        )
      end

      it 'returns error' do
        result = command.execute('save gradient #ff0000,#00ff00 as existing')

        expect(result[:success]).to be false
        expect(result[:error]).to include('already have')
      end
    end
  end

  describe 'aliases' do
    it 'responds to savegrad alias' do
      result = Commands::Base::Registry.find_command('savegrad')
      expect(result[0]).to eq(described_class)
    end
  end
end
