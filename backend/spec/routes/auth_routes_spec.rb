# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Auth Routes', type: :request do
  describe 'GET /register' do
    it 'renders registration page' do
      get '/register'
      expect(last_response).to be_ok
      expect(last_response.body).to include('register')
    end
  end

  describe 'POST /register' do
    before do
      allow(GameSetting).to receive(:get_boolean).and_return(false)
      allow(EmailService).to receive(:configured?).and_return(false)
    end

    it 'redirects after registration attempt' do
      post '/register', {
        username: 'newuser',
        email: 'newuser@example.com',
        password: 'password123',
        password_confirmation: 'password123'
      }

      expect(last_response).to be_redirect
    end

    it 'rejects mismatched passwords' do
      post '/register', {
        username: 'newuser',
        email: 'newuser@example.com',
        password: 'password123',
        password_confirmation: 'differentpassword'
      }

      expect(last_response).to be_redirect
      expect(last_response.location).to include('/register')
    end

    it 'rejects short passwords' do
      post '/register', {
        username: 'newuser',
        email: 'newuser@example.com',
        password: 'short',
        password_confirmation: 'short'
      }

      expect(last_response).to be_redirect
      expect(last_response.location).to include('/register')
    end

    it 'rejects duplicate username' do
      create(:user, username: 'existinguser')

      post '/register', {
        username: 'existinguser',
        email: 'new@example.com',
        password: 'password123',
        password_confirmation: 'password123'
      }

      expect(last_response).to be_redirect
      expect(last_response.location).to include('/register')
    end

    it 'rejects duplicate email' do
      create(:user, email: 'existing@example.com')

      post '/register', {
        username: 'newuser',
        email: 'existing@example.com',
        password: 'password123',
        password_confirmation: 'password123'
      }

      expect(last_response).to be_redirect
      expect(last_response.location).to include('/register')
    end

    it 'saves optional discord handle in modern format' do
      post '/register', {
        username: 'newuser',
        email: 'newuser@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        discord_handle: 'TeSt.User'
      }

      expect(last_response).to be_redirect
      created_user = User.order(Sequel.desc(:id)).first
      expect(created_user.discord_username).to eq('@test.user')
    end

    it 'rejects legacy discord tag format' do
      post '/register', {
        username: 'newuser',
        email: 'newuser@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        discord_handle: 'LegacyName#1234'
      }

      expect(last_response).to be_redirect
      expect(last_response.location).to include('/register')
      expect(User.where(email: 'newuser@example.com').count).to eq(0)
    end
  end

  describe 'GET /login' do
    it 'renders login page' do
      get '/login'
      expect(last_response).to be_ok
      expect(last_response.body).to include('login')
    end
  end

  describe 'POST /login' do
    let(:user) do
      u = create(:user)
      u.set_password('password123')
      u.save
      u
    end

    before do
      allow(AccessControlService).to receive(:ip_banned?).and_return(false)
      allow(AccessControlService).to receive(:check_access).and_return({ allowed: true })
    end

    it 'logs in with valid credentials by username' do
      post '/login', {
        username_or_email: user.username,
        password: 'password123'
      }

      expect(last_response).to be_redirect
      expect(last_response.location).to include('/dashboard')
    end

    it 'logs in with valid credentials by email' do
      post '/login', {
        username_or_email: user.email,
        password: 'password123'
      }

      expect(last_response).to be_redirect
      expect(last_response.location).to include('/dashboard')
    end

    it 'rejects invalid password' do
      allow(AccessControlService).to receive(:log_failed_login)

      post '/login', {
        username_or_email: user.username,
        password: 'wrongpassword'
      }

      expect(last_response).to be_redirect
      expect(last_response.location).to include('/login')
    end

    it 'rejects non-existent user' do
      allow(AccessControlService).to receive(:log_failed_login)

      post '/login', {
        username_or_email: 'nonexistent',
        password: 'password123'
      }

      expect(last_response).to be_redirect
      expect(last_response.location).to include('/login')
    end

    it 'rejects suspended user' do
      user.update(suspended_until: Time.now + 3600)
      allow(AccessControlService).to receive(:check_access).and_return({ allowed: false, reason: 'Suspended' })

      post '/login', {
        username_or_email: user.username,
        password: 'password123'
      }

      expect(last_response).to be_redirect
      expect(last_response.location).to include('/login')
    end
  end

  describe 'GET /logout' do
    let(:user) { create(:user) }

    it 'logs out and redirects to home' do
      env 'rack.session', { 'user_id' => user.id }

      get '/logout'
      expect(last_response).to be_redirect
      expect(last_response.location).to include('/')
    end
  end

  describe 'POST /logout' do
    let(:user) { create(:user) }

    it 'logs out and redirects to home' do
      env 'rack.session', { 'user_id' => user.id }

      post '/logout'
      expect(last_response).to be_redirect
      expect(last_response.location).to include('/')
    end
  end

  describe 'GET /verify-email' do
    it_behaves_like 'requires authentication', '/verify-email'

    context 'when logged in' do
      let(:user) { create(:user) }

      before do
        allow_any_instance_of(User).to receive(:email_verified?).and_return(false)
      end

      it 'renders verification page' do
        env 'rack.session', { 'user_id' => user.id }

        get '/verify-email'
        expect(last_response).to be_ok
      end
    end
  end

  describe 'POST /resend-verification' do
    it_behaves_like 'requires authentication', '/resend-verification', method: :post

    context 'when logged in' do
      let(:user) { create(:user) }

      before do
        env 'rack.session', { 'user_id' => user.id }
        allow_any_instance_of(User).to receive(:email_verified?).and_return(false)
      end

      it 'redirects to verify-email' do
        allow(EmailService).to receive(:configured?).and_return(false)

        post '/resend-verification'
        expect(last_response).to be_redirect
        expect(last_response.location).to include('/verify-email')
      end
    end
  end
end
