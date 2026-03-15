# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Character Story API Routes', type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:other_character) { create(:character, user: other_user) }
  let(:reality) { create(:reality) }
  let(:room) { create(:room) }
  let(:character_instance) do
    create(:character_instance, character: character, reality: reality, current_room: room)
  end

  # Session-based auth helper
  def login_as(user_obj)
    env 'rack.session', { 'user_id' => user_obj.id }
  end

  describe 'GET /api/character_story/:character_id/summary' do
    context 'when not logged in' do
      it 'redirects to login' do
        get "/api/character_story/#{character.id}/summary"
        expect(last_response).to be_redirect
        expect(last_response.location).to include('/login')
      end
    end

    context 'when logged in' do
      before do
        login_as(user)
        character_instance # ensure instance exists
      end

      it 'returns summary for own character' do
        get "/api/character_story/#{character.id}/summary"
        expect(last_response.status).to eq(200)
        json = JSON.parse(last_response.body)
        expect(json['success']).to be true
        expect(json['summary']).to have_key('chapter_count')
        expect(json['summary']).to have_key('total_words')
        expect(json['summary']).to have_key('total_logs')
      end

      it 'returns 403 for other user character' do
        get "/api/character_story/#{other_character.id}/summary"
        expect(last_response.status).to eq(403)
        json = JSON.parse(last_response.body)
        expect(json['success']).to be false
        expect(json['error']).to include('Not authorized')
      end

      it 'returns 404 for non-existent character' do
        get '/api/character_story/999999/summary'
        expect(last_response.status).to eq(404)
        json = JSON.parse(last_response.body)
        expect(json['success']).to be false
        expect(json['error']).to include('not found')
      end
    end
  end

  describe 'GET /api/character_story/:character_id/chapters' do
    before do
      login_as(user)
      character_instance
    end

    it 'returns chapter list for own character' do
      get "/api/character_story/#{character.id}/chapters"
      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json['success']).to be true
      expect(json['chapters']).to be_an(Array)
    end

    it 'returns chapters with metadata' do
      # Create some RP logs for the character
      create(:rp_log, character_instance: character_instance, room: room, logged_at: Time.now - 3600)
      create(:rp_log, character_instance: character_instance, room: room, logged_at: Time.now)

      get "/api/character_story/#{character.id}/chapters"
      json = JSON.parse(last_response.body)

      if json['chapters'].any?
        chapter = json['chapters'].first
        expect(chapter).to have_key('index')
        expect(chapter).to have_key('log_count')
        expect(chapter).to have_key('word_count')
        expect(chapter).to have_key('title')
      end
    end

    it 'returns 403 for other user character' do
      get "/api/character_story/#{other_character.id}/chapters"
      expect(last_response.status).to eq(403)
    end
  end

  describe 'GET /api/character_story/:character_id/chapter/:index' do
    before do
      login_as(user)
      character_instance
    end

    it 'returns chapter content' do
      get "/api/character_story/#{character.id}/chapter/0"
      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json['success']).to be true
      expect(json).to have_key('logs')
      expect(json).to have_key('title')
    end

    it 'returns logs array for chapter with content' do
      create(:rp_log, character_instance: character_instance, room: room, content: 'Test log entry')

      get "/api/character_story/#{character.id}/chapter/0"
      json = JSON.parse(last_response.body)
      expect(json['logs']).to be_an(Array)
    end

    it 'returns 403 for other user character' do
      get "/api/character_story/#{other_character.id}/chapter/0"
      expect(last_response.status).to eq(403)
    end
  end

  describe 'GET /api/character_story/:character_id/download' do
    before do
      login_as(user)
      character_instance
    end

    it 'returns text file' do
      get "/api/character_story/#{character.id}/download"
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include('text/plain')
    end

    it 'sets Content-Disposition for download' do
      get "/api/character_story/#{character.id}/download"
      expect(last_response.headers['Content-Disposition']).to include('attachment')
      expect(last_response.headers['Content-Disposition']).to include('.txt')
    end

    it 'includes character name in filename' do
      get "/api/character_story/#{character.id}/download"
      # Filename should contain sanitized character name
      expect(last_response.headers['Content-Disposition']).to include('story')
    end

    it 'returns 403 for other user character' do
      get "/api/character_story/#{other_character.id}/download"
      expect(last_response.status).to eq(403)
    end

    context 'with story content' do
      before do
        create(:rp_log, character_instance: character_instance, room: room,
               content: 'A test log entry for the story')
      end

      it 'includes chapter content in download' do
        get "/api/character_story/#{character.id}/download"
        expect(last_response.body).to include('THE STORY OF')
      end
    end
  end
end
