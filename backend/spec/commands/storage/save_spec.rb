# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Storage::Save, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Eve') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no input' do
      it 'returns usage error' do
        result = command.execute('save')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end
    end

    context 'with invalid format' do
      it 'returns usage error for missing "as"' do
        result = command.execute('save pic1 sunset')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end

      it 'returns usage error for invalid type' do
        result = command.execute('save xyz1 as test')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end
    end

    context 'with valid format but no media in chat' do
      it 'returns not found error' do
        result = command.execute('save pic1 as sunset')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Could not find')
      end
    end

    context 'with recent message containing media' do
      before do
        Message.create(
          character_id: character.id,
          room_id: room.id,
          reality_id: reality.id,
          content: 'Check out this image: https://example.com/sunset.jpg',
          message_type: 'say'
        )
      end

      it 'saves the picture' do
        result = command.execute('save pic1 as sunset')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Saved')

        saved = MediaLibrary.find_by_name(character, 'sunset')
        expect(saved).not_to be_nil
        expect(saved.media_type).to eq('pic')
        expect(saved.content).to include('sunset.jpg')
      end
    end

    context 'with video URL in message' do
      before do
        Message.create(
          character_id: character.id,
          room_id: room.id,
          reality_id: reality.id,
          content: 'Watch this: https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          message_type: 'say'
        )
      end

      it 'saves the video' do
        result = command.execute('save vid1 as music')

        expect(result[:success]).to be true

        saved = MediaLibrary.find_by_name(character, 'music')
        expect(saved).not_to be_nil
        expect(saved.media_type).to eq('vid')
        expect(saved.content).to include('youtube')
      end
    end

    context 'type aliases' do
      before do
        Message.create(
          character_id: character.id,
          room_id: room.id,
          reality_id: reality.id,
          content: 'Image: https://example.com/photo.png',
          message_type: 'say'
        )
      end

      it 'accepts picture alias' do
        result = command.execute('save picture1 as test')

        expect(result[:success]).to be true
      end

      it 'accepts image alias' do
        result = command.execute('save image1 as test')

        expect(result[:success]).to be true
      end

      it 'accepts img alias' do
        result = command.execute('save img1 as test')

        expect(result[:success]).to be true
      end
    end

    context 'with duplicate name' do
      before do
        MediaLibrary.create(
          character_id: character.id,
          mtype: 'pic',
          mname: 'existing',
          mtext: 'https://example.com/old.jpg'
        )

        Message.create(
          character_id: character.id,
          room_id: room.id,
          reality_id: reality.id,
          content: 'New image: https://example.com/new.jpg',
          message_type: 'say'
        )
      end

      it 'returns error' do
        result = command.execute('save pic1 as existing')

        expect(result[:success]).to be false
        expect(result[:error]).to include('already have')
      end
    end
  end
end
