# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Entertainment::Play do
  let(:reality) { create_test_reality }
  let(:room) { create_test_room(reality_id: reality.id) }
  let(:character) { create_test_character }
  let(:character_instance) { create_test_character_instance(character: character, room: room, reality: reality) }

  subject { described_class.new(character_instance) }

  describe '#execute' do
    context 'without a URL' do
      it 'returns an error' do
        result = subject.execute('play')
        expect(result[:success]).to be false
        expect(result[:error]).to include("Play what")
      end
    end

    context 'with an invalid URL' do
      it 'returns an error for non-YouTube URLs' do
        result = subject.execute('play https://example.com/video')
        expect(result[:success]).to be false
        expect(result[:error]).to include("Invalid URL")
      end

      it 'returns an error for malformed URLs' do
        result = subject.execute('play not-a-url')
        expect(result[:success]).to be false
        expect(result[:error]).to include("Invalid URL")
      end
    end

    context 'with a valid YouTube URL' do
      let(:youtube_url) { 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' }

      it 'starts a synchronized watch party' do
        result = subject.execute("play #{youtube_url}")
        expect(result[:success]).to be true
        expect(result[:message]).to include("Watch party started")
      end

      it 'creates a MediaSession record' do
        expect { subject.execute("play #{youtube_url}") }
          .to change { MediaSession.count }.by(1)
      end

      it 'returns sync session data' do
        result = subject.execute("play #{youtube_url}")
        expect(result[:data][:action]).to eq('start_youtube_sync')
        expect(result[:data][:video_id]).to eq('dQw4w9WgXcQ')
        expect(result[:data][:is_host]).to be true
        expect(result[:data][:session_id]).to be_a(Integer)
      end

      it 'accepts youtu.be short URLs' do
        result = subject.execute('play https://youtu.be/dQw4w9WgXcQ')
        expect(result[:success]).to be true
        expect(result[:data][:video_id]).to eq('dQw4w9WgXcQ')
      end
    end

    context 'when another user is already hosting a watch party' do
      let(:other_character) { create_test_character }
      let(:other_instance) { create_test_character_instance(character: other_character, room: room, reality: reality) }

      before do
        MediaSyncService.start_youtube(
          room_id: room.id,
          host: other_instance,
          video_id: 'existing',
          title: 'Existing Video',
          duration: 300
        )
      end

      it 'returns an error' do
        result = subject.execute('play https://www.youtube.com/watch?v=new')
        expect(result[:success]).to be false
        expect(result[:error]).to include("already running a watch party")
      end
    end
  end
end
