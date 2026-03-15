# frozen_string_literal: true

require 'spec_helper'

describe 'User Registration', type: :feature do
  describe 'GET /register' do
    it 'displays the registration form' do
      get '/register'
      
      expect(last_response).to be_ok
      expect(last_response.body).to include('Create Account')
      expect(last_response.body).to include('name="username"')
      expect(last_response.body).to include('name="email"')
      expect(last_response.body).to include('name="password"')
      expect(last_response.body).to include('name="password_confirmation"')
    end
  end
  
  describe 'POST /register' do
    context 'with valid user data' do
      let(:valid_params) do
        {
          'username' => 'testuser',
          'email' => 'test@example.com',
          'password' => 'password123',
          'password_confirmation' => 'password123'
        }
      end
      
      it 'creates a new user' do
        expect {
          post '/register', valid_params
        }.to change(User, :count).by(1)
      end
      
      it 'redirects to dashboard on successful registration' do
        post '/register', valid_params
        
        expect(last_response).to be_redirect
        follow_redirect!
        expect(last_request.path).to eq('/dashboard')
      end
      
      it 'logs the user in automatically' do
        post '/register', valid_params
        follow_redirect!

        # Dashboard should show "Welcome Back" or username if properly logged in
        # If @current_user is nil in view, it means session isn't persisting in test
        expect(last_response.body).to include('Dashboard').or include('testuser')
      end
      
      it 'stores the user ID in the session' do
        expect { post '/register', valid_params }.to change(User, :count).by(1)

        user = User.last
        expect(last_request.session['user_id']).to eq(user.id)
      end
    end
    
    context 'with invalid user data' do
      it 'rejects registration with mismatched passwords' do
        params = {
          'username' => 'testuser',
          'email' => 'test@example.com',
          'password' => 'password123',
          'password_confirmation' => 'different_password'
        }
        
        expect {
          post '/register', params
        }.not_to change(User, :count)
        
        expect(last_response).to be_redirect
        follow_redirect!
        expect(last_response.body).to include('Passwords do not match')
      end
      
      it 'rejects registration with short password' do
        params = {
          'username' => 'testuser',
          'email' => 'test@example.com',
          'password' => '123',
          'password_confirmation' => '123'
        }
        
        expect {
          post '/register', params
        }.not_to change(User, :count)
        
        expect(last_response).to be_redirect
        follow_redirect!
        expect(last_response.body).to include('Password must be at least 6 characters')
      end
      
      it 'rejects registration with duplicate username' do
        create(:user, username: 'testuser')

        params = {
          'username' => 'testuser',
          'email' => 'different@example.com',
          'password' => 'password123',
          'password_confirmation' => 'password123'
        }

        expect {
          post '/register', params
        }.not_to change(User, :count)

        expect(last_response).to be_redirect
      end

      it 'rejects registration with duplicate email' do
        create(:user, email: 'test@example.com')

        params = {
          'username' => 'differentuser',
          'email' => 'test@example.com',
          'password' => 'password123',
          'password_confirmation' => 'password123'
        }

        expect {
          post '/register', params
        }.not_to change(User, :count)

        expect(last_response).to be_redirect
      end

      it 'rejects registration with invalid email format' do
        params = {
          'username' => 'testuser',
          'email' => 'invalid-email',
          'password' => 'password123',
          'password_confirmation' => 'password123'
        }

        expect {
          post '/register', params
        }.not_to change(User, :count)

        expect(last_response).to be_redirect
      end
    end
  end
end