# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'zip'

RSpec.describe 'Content Portability Routes', type: :request do
  include Rack::Test::Methods

  let(:user) { create(:user) }
  let(:owner_character) { create(:character, user: user) }
  let(:reality) { create(:reality) }
  let(:room) { create(:room, owner_id: owner_character.id) }
  let(:character) { create(:character, user: user) }
  let!(:character_instance) { create(:character_instance, character: character, reality: reality, current_room: room, online: true) }

  def build_content_zip(payload)
    tempfile = Tempfile.new(['content_package', '.zip'])
    Zip::File.open(tempfile.path, Zip::File::CREATE) do |zip|
      zip.get_output_stream('data.json') { |f| f.write(JSON.generate(payload)) }
    end
    tempfile
  end

  before do
    env 'rack.session', { 'user_id' => user.id }
  end

  describe 'GET /characters/:id/export' do
    it 'returns a ZIP package' do
      get "/characters/#{character.id}/export"
      expect(last_response.status).to eq(200)
      expect(last_response.headers['Content-Type']).to include('application/zip')
      expect(last_response.body.bytesize).to be > 0
    end
  end

  describe 'POST /characters/:id/import' do
    it 'imports full character data including base metadata updates' do
      payload = {
        version: '1.0.0',
        export_type: 'character',
        character: { short_desc: 'Imported short description' },
        descriptions: [],
        items: [],
        outfits: []
      }

      zip = build_content_zip(payload)
      begin
        post "/characters/#{character.id}/import", content_package: Rack::Test::UploadedFile.new(zip.path, 'application/zip')
      ensure
        zip.close
        zip.unlink
      end

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body['success']).to be true
      expect(character.refresh.short_desc).to eq('Imported short description')
    end
  end

  describe 'GET /properties/:id' do
    it 'redirects when not authenticated' do
      env 'rack.session', {}
      get "/properties/#{room.id}"
      expect(last_response).to be_redirect
      expect(last_response.location).to include('/login')
    end

    it 'renders property details for owner' do
      get "/properties/#{room.id}"
      expect(last_response.status).to eq(200)
    end

    it 'redirects when user does not own the property' do
      other_user = create(:user)
      env 'rack.session', { 'user_id' => other_user.id }
      get "/properties/#{room.id}"
      expect(last_response).to be_redirect
    end
  end

  describe 'GET /properties/:id/export' do
    it 'returns a property ZIP package' do
      get "/properties/#{room.id}/export"
      expect(last_response.status).to eq(200)
      expect(last_response.headers['Content-Type']).to include('application/zip')
      expect(last_response.body.bytesize).to be > 0
    end
  end

  describe 'POST /properties/:id/import' do
    it 'imports property blueprint and redirects back to property page' do
      payload = {
        version: '1.0.0',
        export_type: 'property',
        room: {
          short_description: 'Imported room short description',
          room_type: room.room_type
        },
        places: [],
        decorations: [],
        room_features: [],
        room_hexes: []
      }

      zip = build_content_zip(payload)
      begin
        post "/properties/#{room.id}/import", {
          content_package: Rack::Test::UploadedFile.new(zip.path, 'application/zip'),
          scale_places: '1',
          import_battle_map: '1',
          preserve_exits: '1'
        }
      ensure
        zip.close
        zip.unlink
      end

      expect(last_response).to be_redirect
      expect(last_response.location).to include("/properties/#{room.id}")
      expect(room.refresh.short_description).to eq('Imported room short description')
    end
  end
end
