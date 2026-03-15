# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Public Routes', type: :request do
  describe 'GET /' do
    it 'renders home page' do
      get '/'
      expect(last_response).to be_ok
    end
  end

  describe 'GET /news' do
    it 'renders news page' do
      get '/news'
      expect(last_response).to be_ok
    end
  end

  describe 'info pages' do
    describe 'GET /info' do
      it 'renders info index' do
        get '/info'
        expect(last_response).to be_ok
      end
    end

    describe 'GET /info/rules' do
      it 'renders rules page' do
        get '/info/rules'
        expect(last_response).to be_ok
      end
    end

    describe 'GET /info/getting-started' do
      it 'renders getting started page' do
        get '/info/getting-started'
        expect(last_response).to be_ok
      end
    end

    describe 'GET /info/terms' do
      it 'renders terms page' do
        get '/info/terms'
        expect(last_response).to be_ok
      end
    end

    describe 'GET /info/privacy' do
      it 'renders privacy page' do
        get '/info/privacy'
        expect(last_response).to be_ok
      end
    end

    describe 'GET /info/contact' do
      it 'renders contact page' do
        get '/info/contact'
        expect(last_response).to be_ok
      end
    end

    describe 'GET /info/commands' do
      it 'renders commands listing' do
        get '/info/commands'
        expect(last_response).to be_ok
      end
    end

    describe 'GET /info/helps' do
      it 'renders help topics listing' do
        get '/info/helps'
        expect(last_response).to be_ok
      end
    end

    describe 'GET /info/systems' do
      it 'renders game systems listing' do
        get '/info/systems'
        expect(last_response).to be_ok
      end
    end
  end

  describe 'world pages' do
    describe 'GET /world' do
      it 'renders world index' do
        get '/world'
        expect(last_response).to be_ok
      end
    end

    describe 'GET /world/lore' do
      it 'renders lore page' do
        get '/world/lore'
        expect(last_response).to be_ok
      end
    end

    describe 'GET /world/locations' do
      it 'renders locations page' do
        get '/world/locations'
        expect(last_response).to be_ok
      end
    end

    describe 'GET /world/factions' do
      it 'renders factions page' do
        get '/world/factions'
        expect(last_response).to be_ok
      end
    end
  end

  describe 'profiles directory' do
    describe 'GET /profiles/:id' do
      let(:user) { create(:user) }
      let(:character) { create(:character, user: user) }

      it 'shows public character profile' do
        allow_any_instance_of(Character).to receive(:publicly_visible?).and_return(true)
        allow(ProfileDisplayService).to receive(:new).and_return(double(build_profile: {}))

        get "/profiles/#{character.id}"
        expect(last_response).to be_ok
      end

      it 'redirects for non-public profile' do
        allow_any_instance_of(Character).to receive(:publicly_visible?).and_return(false)

        get "/profiles/#{character.id}"
        expect(last_response).to be_redirect
        expect(last_response.location).to include('/profiles')
      end

      it 'redirects for non-existent character' do
        get '/profiles/999999'
        expect(last_response).to be_redirect
      end
    end
  end

end
