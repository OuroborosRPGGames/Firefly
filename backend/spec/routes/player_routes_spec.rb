# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Player Routes', type: :request do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:reality) { create(:reality) }
  let(:room) { create(:room) }
  let(:character_instance) do
    create(:character_instance, character: character, reality: reality, current_room: room)
  end

  describe 'GET /dashboard' do
    it_behaves_like 'requires authentication', '/dashboard'

    context 'when logged in' do
      before do
        env 'rack.session', { 'user_id' => user.id }
      end

      it 'renders dashboard' do
        get '/dashboard'
        expect(last_response).to be_ok
      end

      it 'lists user characters' do
        character
        get '/dashboard'
        expect(last_response.body).to include(character.forename)
      end
    end
  end

  describe 'GET /characters/new' do
    it_behaves_like 'requires authentication', '/characters/new'

    context 'when logged in' do
      before do
        env 'rack.session', { 'user_id' => user.id }
      end

      it 'renders character creation form' do
        get '/characters/new'
        expect(last_response).to be_ok
      end

      it 'redirects to verify-email if verification required' do
        allow(GameSetting).to receive(:boolean).with('email_require_verification').and_return(true)
        allow_any_instance_of(User).to receive(:email_verified?).and_return(false)
        allow(EmailService).to receive(:configured?).and_return(true)

        get '/characters/new'
        expect(last_response).to be_redirect
        expect(last_response.location).to include('/verify-email')
      end
    end
  end

  describe 'POST /characters/create' do
    it_behaves_like 'requires authentication', '/characters/create', method: :post

    context 'when logged in' do
      before do
        env 'rack.session', { 'user_id' => user.id }
        allow(GameSetting).to receive(:boolean).and_return(false)
        allow_any_instance_of(User).to receive(:verification_required?).and_return(false)
      end

      it 'processes character creation form' do
        post '/characters/create', {
          forename: 'New',
          surname: 'Character',
          gender: 'male'
        }

        # Either redirects to dashboard on success/error or shows form again
        expect([200, 302]).to include(last_response.status)
      end
    end
  end

  describe 'GET /characters/:id' do
    it_behaves_like 'requires authentication', '/characters/1'

    context 'when logged in' do
      before do
        env 'rack.session', { 'user_id' => user.id }
      end

      it 'shows character details' do
        get "/characters/#{character.id}"
        expect(last_response).to be_ok
      end

      it 'redirects for non-owned character' do
        other_user = create(:user)
        other_char = create(:character, user: other_user)

        get "/characters/#{other_char.id}"
        expect(last_response).to be_redirect
        expect(last_response.location).to include('/dashboard')
      end
    end
  end

  describe 'POST /characters/:id/select' do
    before do
      env 'rack.session', { 'user_id' => user.id }
      character_instance
    end

    it 'selects character for play' do
      post "/characters/#{character.id}/select"
      expect(last_response).to be_redirect
      expect(last_response.location).to include('/webclient')
      expect(last_response.location).to include("character=#{character.id}")
    end
  end

  describe 'GET /webclient' do
    it_behaves_like 'requires authentication', '/webclient'

    context 'when logged in with selected character' do
      before do
        env 'rack.session', { 'user_id' => user.id, 'character_id' => character.id }
        character_instance
      end

      it 'renders webclient' do
        get '/webclient'
        expect(last_response).to be_ok
      end
    end

    context 'when logged in without character' do
      before do
        env 'rack.session', { 'user_id' => user.id }
      end

      it 'redirects to dashboard' do
        get '/webclient'
        expect(last_response).to be_redirect
        expect(last_response.location).to include('/dashboard')
      end
    end
  end

  describe 'GET /play' do
    context 'when logged in with selected character' do
      before do
        env 'rack.session', { 'user_id' => user.id, 'character_id' => character.id }
        character_instance
      end

      it 'redirects to webclient' do
        get '/play'
        expect(last_response).to be_redirect
        expect(last_response.location).to include('/webclient')
      end
    end
  end

  describe 'GET /settings' do
    it_behaves_like 'requires authentication', '/settings'

    context 'when logged in' do
      before do
        env 'rack.session', { 'user_id' => user.id }
      end

      it 'renders settings page' do
        get '/settings'
        expect(last_response).to be_ok
      end
    end
  end

  describe 'GET /missions' do
    it_behaves_like 'requires authentication', '/missions'
  end
end
