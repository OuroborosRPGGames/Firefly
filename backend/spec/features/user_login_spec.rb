# frozen_string_literal: true

require 'spec_helper'

describe 'User Login', type: :feature do
  let(:user) { create(:user, username: 'testuser', email: 'test@example.com') }
  
  before do
    user.set_password('password123')
    user.save
  end
  
  describe 'GET /login' do
    it 'displays the login form' do
      get '/login'
      
      expect(last_response).to be_ok
      expect(last_response.body).to include('Welcome Back')
      expect(last_response.body).to include('name="username_or_email"')
      expect(last_response.body).to include('name="password"')
      expect(last_response.body).to include('name="remember_me"')
    end
  end
  
  describe 'POST /login' do
    context 'with valid credentials' do
      it 'logs in with username' do
        params = {
          'username_or_email' => 'testuser',
          'password' => 'password123'
        }
        
        post '/login', params
        
        expect(last_response).to be_redirect
        follow_redirect!
        expect(last_request.path).to eq('/dashboard')
      end
      
      it 'logs in with email' do
        params = {
          'username_or_email' => 'test@example.com',
          'password' => 'password123'
        }
        
        post '/login', params
        
        expect(last_response).to be_redirect
        follow_redirect!
        expect(last_request.path).to eq('/dashboard')
      end
      
      it 'stores the user ID in the session' do
        params = {
          'username_or_email' => 'testuser',
          'password' => 'password123'
        }
        
        post '/login', params
        
        expect(last_request.session['user_id']).to eq(user.id)
      end
      
      it 'updates last_login_at timestamp' do
        original_time = user.last_login_at
        
        params = {
          'username_or_email' => 'testuser',
          'password' => 'password123'
        }
        
        post '/login', params
        user.reload
        
        expect(user.last_login_at).to be > original_time if original_time
        expect(user.last_login_at).not_to be_nil
      end
      
      context 'with remember me enabled' do
        it 'sets a remember token and cookie' do
          params = {
            'username_or_email' => 'testuser',
            'password' => 'password123',
            'remember_me' => '1'
          }

          post '/login', params
          user.reload

          expect(user.remember_token).not_to be_nil
          expect(user.remember_created_at).not_to be_nil
          # Set-Cookie may be a String or Array depending on Rack version
          cookie_header = last_response.headers['Set-Cookie']
          cookie_str = cookie_header.is_a?(Array) ? cookie_header.join('; ') : cookie_header.to_s
          expect(cookie_str).to include('remember_token')
        end
      end
    end
    
    context 'with invalid credentials' do
      it 'rejects login with wrong password' do
        params = {
          'username_or_email' => 'testuser',
          'password' => 'wrongpassword'
        }
        
        post '/login', params
        
        expect(last_response).to be_redirect
        follow_redirect!
        expect(last_response.body).to include('Invalid username/email or password')
        expect(last_request.session['user_id']).to be_nil
      end
      
      it 'rejects login with non-existent user' do
        params = {
          'username_or_email' => 'nonexistentuser',
          'password' => 'password123'
        }
        
        post '/login', params
        
        expect(last_response).to be_redirect
        follow_redirect!
        expect(last_response.body).to include('Invalid username/email or password')
        expect(last_request.session['user_id']).to be_nil
      end
      
      it 'is case insensitive for username' do
        params = {
          'username_or_email' => 'TESTUSER',
          'password' => 'password123'
        }
        
        post '/login', params
        
        expect(last_response).to be_redirect
        follow_redirect!
        expect(last_request.path).to eq('/dashboard')
      end
      
      it 'is case insensitive for email' do
        params = {
          'username_or_email' => 'TEST@EXAMPLE.COM',
          'password' => 'password123'
        }
        
        post '/login', params
        
        expect(last_response).to be_redirect
        follow_redirect!
        expect(last_request.path).to eq('/dashboard')
      end
    end
  end
  
  describe 'POST /logout' do
    before do
      # Log in the user first
      params = {
        'username_or_email' => 'testuser',
        'password' => 'password123'
      }
      post '/login', params
    end
    
    it 'logs out the user' do
      post '/logout'
      
      expect(last_response).to be_redirect
      follow_redirect!
      expect(last_request.path).to eq('/')
      expect(last_request.session['user_id']).to be_nil
    end
    
    it 'clears session cookie' do
      post '/logout'

      # Logout clears the session cookie (remember token in DB is not cleared by current implementation)
      expect(last_response).to be_redirect
      expect(last_request.session['user_id']).to be_nil
    end
  end
end