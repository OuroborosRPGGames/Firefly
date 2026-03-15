# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ProfileDisplayService do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:viewer) { create(:character) }
  let(:service) { described_class.new(character) }
  let(:service_with_viewer) { described_class.new(character, viewer: viewer) }

  describe '#initialize' do
    it 'accepts a character' do
      expect(service.character).to eq(character)
    end

    it 'accepts an optional viewer' do
      expect(service_with_viewer.viewer).to eq(viewer)
    end

    it 'defaults viewer to nil' do
      expect(service.viewer).to be_nil
    end
  end

  describe '#build_profile' do
    context 'when character is not publicly visible' do
      before do
        allow(character).to receive(:publicly_visible?).and_return(false)
      end

      it 'returns nil' do
        expect(service.build_profile).to be_nil
      end
    end

    context 'when character is publicly visible' do
      before do
        allow(character).to receive(:publicly_visible?).and_return(true)
        allow(character).to receive(:full_name).and_return('Test Character')
        allow(character).to receive(:nickname).and_return('Testy')
      end

      it 'returns a hash with profile data' do
        result = service.build_profile

        expect(result).to be_a(Hash)
        expect(result[:id]).to eq(character.id)
        expect(result[:name]).to eq('Test Character')
        expect(result[:nickname]).to eq('Testy')
      end

      it 'includes account_handle from user' do
        result = service.build_profile
        expect(result[:account_handle]).to eq(user.username)
      end

      it 'includes is_owner as false when no viewer' do
        result = service.build_profile
        expect(result[:is_owner]).to be false
      end
    end

    context 'pictures ordering' do
      before do
        allow(character).to receive(:publicly_visible?).and_return(true)
        # Create pictures in reverse order to verify sorting
        create(:profile_picture, character: character, url: 'pic3.jpg', position: 3)
        create(:profile_picture, character: character, url: 'pic1.jpg', position: 1)
        create(:profile_picture, character: character, url: 'pic2.jpg', position: 2)
      end

      it 'returns pictures ordered by position' do
        result = service.build_profile
        urls = result[:pictures].map { |p| p[:url] }
        expect(urls).to eq(%w[pic1.jpg pic2.jpg pic3.jpg])
      end

      it 'includes id, url, and position for each picture' do
        result = service.build_profile
        first_pic = result[:pictures].first
        expect(first_pic).to have_key(:id)
        expect(first_pic).to have_key(:url)
        expect(first_pic).to have_key(:position)
      end
    end

    context 'sections ordering' do
      before do
        allow(character).to receive(:publicly_visible?).and_return(true)
        create(:profile_section, character: character, title: 'Section C', content: 'Content C', position: 3)
        create(:profile_section, character: character, title: 'Section A', content: 'Content A', position: 1)
        create(:profile_section, character: character, title: 'Section B', content: 'Content B', position: 2)
      end

      it 'returns sections ordered by position' do
        result = service.build_profile
        titles = result[:sections].map { |s| s[:title] }
        expect(titles).to eq(['Section A', 'Section B', 'Section C'])
      end

      it 'includes id, title, content, and position for each section' do
        result = service.build_profile
        first_section = result[:sections].first
        expect(first_section).to have_key(:id)
        expect(first_section).to have_key(:title)
        expect(first_section).to have_key(:content)
        expect(first_section).to have_key(:position)
      end
    end

    context 'videos ordering' do
      before do
        allow(character).to receive(:publicly_visible?).and_return(true)
        create(:profile_video, character: character, youtube_id: 'dQw4w9WgXc3', title: 'Video 3', position: 3)
        create(:profile_video, character: character, youtube_id: 'dQw4w9WgXc1', title: 'Video 1', position: 1)
        create(:profile_video, character: character, youtube_id: 'dQw4w9WgXc2', title: 'Video 2', position: 2)
      end

      it 'returns videos ordered by position' do
        result = service.build_profile
        titles = result[:videos].map { |v| v[:title] }
        expect(titles).to eq(['Video 1', 'Video 2', 'Video 3'])
      end

      it 'includes id, youtube_id, title, and position for each video' do
        result = service.build_profile
        first_video = result[:videos].first
        expect(first_video).to have_key(:id)
        expect(first_video).to have_key(:youtube_id)
        expect(first_video).to have_key(:title)
        expect(first_video).to have_key(:position)
      end
    end

    context 'background_url from profile_setting' do
      before do
        allow(character).to receive(:publicly_visible?).and_return(true)
      end

      it 'returns nil when no profile_setting exists' do
        result = service.build_profile
        expect(result[:background_url]).to be_nil
      end

      it 'returns background_url from profile_setting' do
        create(:profile_setting, character: character, background_url: 'https://example.com/bg.jpg')
        result = service.build_profile
        expect(result[:background_url]).to eq('https://example.com/bg.jpg')
      end
    end

    context 'is_owner flag' do
      before do
        allow(character).to receive(:publicly_visible?).and_return(true)
      end

      it 'returns false when no viewer provided' do
        result = service.build_profile
        expect(result[:is_owner]).to be false
      end

      it 'returns false when viewer is different character' do
        result = service_with_viewer.build_profile
        expect(result[:is_owner]).to be false
      end

      it 'returns true when viewer is the same character' do
        owner_service = described_class.new(character, viewer: character)
        result = owner_service.build_profile
        expect(result[:is_owner]).to be true
      end
    end

    context 'with empty collections' do
      before do
        allow(character).to receive(:publicly_visible?).and_return(true)
      end

      it 'returns empty arrays when no pictures, sections, or videos' do
        result = service.build_profile
        expect(result[:pictures]).to eq([])
        expect(result[:sections]).to eq([])
        expect(result[:videos]).to eq([])
      end
    end
  end
end
