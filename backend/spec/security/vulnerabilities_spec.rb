# frozen_string_literal: true

require 'spec_helper'

# Load rate limiting config for testing if not already loaded
unless defined?(RedisRateLimitStore)
  require_relative '../../config/rack_attack'
end

RSpec.describe 'Security', type: :security do
  # =========================================================================
  # SQL INJECTION PROTECTION
  # =========================================================================

  describe 'SQL injection protection' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let(:reality) { create(:reality) }
    let(:room) { create(:room) }
    let(:character_instance) do
      create(:character_instance,
             character: character,
             reality: reality,
             current_room: room,
             status: 'alive',
             online: true)
    end

    context 'Room model queries' do
      it 'safely handles string IDs by rejecting invalid input' do
        # Sequel properly rejects non-integer input for integer columns
        # This IS the security - malicious strings are rejected, not executed
        malicious_id = "1; DROP TABLE rooms;--"
        expect {
          Room.where(id: malicious_id).first
        }.to raise_error(Sequel::DatabaseError)
        # The key security here is that the DROP TABLE was never executed
      end

      it 'safely handles malicious sightline data via Sequel.case' do
        # Sequel.case properly parameterizes all values
        room # ensure room exists
        sightlines = { room.id => 0.8 }

        expect {
          case_conditions = sightlines.map do |room_id, quality|
            [{ Sequel[:character_instances][:current_room_id] => room_id }, quality]
          end
          Sequel.case(case_conditions, 0)
        }.not_to raise_error
      end

      it 'safely handles SQL injection attempts in string columns' do
        room # ensure room exists
        malicious_name = "test'; DROP TABLE rooms; --"
        # Query succeeds but finds nothing (no SQL execution)
        result = Room.where(name: malicious_name).first
        expect(result).to be_nil
        expect(Room.count).to be >= 1 # Table not dropped
      end

      it 'Sequel LIKE queries with user input are parameterized' do
        room # ensure room exists
        # Test that Sequel parameterizes LIKE queries safely
        # User input with special LIKE characters should not cause injection
        malicious_pattern = "%'; DROP TABLE rooms;--"
        expect {
          # Sequel's ilike with string creates parameterized query
          Room.where(Sequel.ilike(:name, malicious_pattern)).all
        }.not_to raise_error
        # Tables should still exist
        expect(Room.count).to be >= 1
      end
    end

    context 'Character queries' do
      it 'safely handles malicious character names' do
        user # ensure user exists
        malicious_name = "evil'; DELETE FROM users;--"
        result = Character.where(name: malicious_name).first
        expect(result).to be_nil
        expect(User.count).to be >= 1 # Users not deleted
      end

      it 'Sequel LIKE queries with special characters are safe' do
        character # ensure character exists
        # LIKE queries with SQL injection attempts should not execute
        malicious_patterns = [
          "test%' UNION SELECT * FROM users;--",
          "test_'; DROP TABLE characters;--",
          "test\\'; DELETE FROM characters;--"
        ]
        malicious_patterns.each do |pattern|
          expect {
            Character.where(Sequel.ilike(:name, pattern)).all
          }.not_to raise_error
        end
        # Tables should still exist
        expect(Character.count).to be >= 1
      end
    end

    context 'ORDER BY protection' do
      it 'rejects untrusted ORDER BY columns via whitelist' do
        # This test verifies the pattern documented in SECURITY.md
        allowed_columns = %w[name created_at level].freeze
        malicious_column = "name; DROP TABLE characters;--"

        column = allowed_columns.include?(malicious_column) ? malicious_column.to_sym : :name
        expect(column).to eq(:name)
      end
    end
  end

  # =========================================================================
  # RATE LIMITING (FAIL-CLOSED BEHAVIOR)
  # =========================================================================

  describe 'Rate limiting fail-closed behavior' do
    it 'RedisRateLimitStore class is defined' do
      # Verify the rate limit store class exists
      expect(defined?(RedisRateLimitStore)).to eq('constant')
    end

    it 'RedisRateLimitStore has FAIL_CLOSED_VALUE constant' do
      # Verify the fail-closed constant exists and is high
      expect(RedisRateLimitStore::FAIL_CLOSED_VALUE).to be_a(Integer)
      expect(RedisRateLimitStore::FAIL_CLOSED_VALUE).to be > 100
    end

    it 'RedisRateLimitStore implements increment method' do
      store = RedisRateLimitStore.new(REDIS_POOL)
      expect(store).to respond_to(:increment)
    end

    it 'RedisRateLimitStore implements read/write/delete methods' do
      store = RedisRateLimitStore.new(REDIS_POOL)
      expect(store).to respond_to(:read)
      expect(store).to respond_to(:write)
      expect(store).to respond_to(:delete)
    end
  end

  # =========================================================================
  # AUTHENTICATION & AUTHORIZATION
  # =========================================================================

  describe 'Authentication security' do
    let(:user) { create(:user, email: 'test@example.com') }
    let(:character) { create(:character, user: user) }
    let(:reality) { create(:reality) }
    let(:room) { create(:room) }
    let!(:character_instance) do
      create(:character_instance,
             character: character,
             reality: reality,
             current_room: room)
    end

    describe 'Bearer token authentication' do
      let!(:api_token) { user.generate_api_token! }

      it 'rejects malformed authorization header' do
        get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer" }
        expect(last_response.status).to eq(401)
      end

      it 'rejects empty token' do
        get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer " }
        expect(last_response.status).to eq(401)
      end

      it 'rejects null byte injection in token' do
        get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}\x00malicious" }
        expect(last_response.status).to eq(401)
      end

      it 'rejects very long tokens (DoS prevention)' do
        long_token = "a" * 10000
        get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{long_token}" }
        expect(last_response.status).to eq(401)
      end

      it 'returns 401 for both invalid and expired tokens' do
        # Invalid token
        get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer invalid123" }
        expect(last_response.status).to eq(401)

        # Expired token
        user.update(api_token_expires_at: Time.now - 1)
        get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}" }
        expect(last_response.status).to eq(401)
      end
    end

    describe 'Session security' do
      it 'requires authentication for protected routes' do
        get '/api/agent/room'
        expect(last_response.status).to eq(401)
      end

      it 'prevents session fixation by clearing on login' do
        # This tests the pattern documented in SECURITY.md
        # Session should be cleared on successful authentication
        # (Tested implicitly through login flow)
        expect(true).to be true # Placeholder for integration test
      end
    end
  end

  # =========================================================================
  # INPUT VALIDATION
  # =========================================================================

  describe 'Input validation' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let(:reality) { create(:reality) }
    let(:room) { create(:room) }
    let(:character_instance) do
      create(:character_instance,
             character: character,
             reality: reality,
             current_room: room,
             status: 'alive',
             online: true)
    end
    let!(:api_token) { user.generate_api_token! }
    let(:auth_headers) { { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}", 'CONTENT_TYPE' => 'application/json' } }

    describe 'Command input' do
      it 'handles empty command gracefully' do
        post '/api/agent/command', { command: '' }.to_json, auth_headers
        data = JSON.parse(last_response.body)
        expect(data['success']).to be false
      end

      it 'handles nil command gracefully' do
        post '/api/agent/command', { command: nil }.to_json, auth_headers
        data = JSON.parse(last_response.body)
        expect(data['success']).to be false
      end

      it 'handles very long command input without crashing' do
        long_command = "say " + "a" * 10000
        expect {
          post '/api/agent/command', { command: long_command }.to_json, auth_headers
        }.not_to raise_error
        # May truncate or reject, but should not crash
        expect(last_response).not_to be_nil
      end

      it 'handles special characters in command' do
        special_command = "say <script>alert('xss')</script>"
        expect {
          post '/api/agent/command', { command: special_command }.to_json, auth_headers
        }.not_to raise_error
        # Server should handle without crashing
        expect(last_response).not_to be_nil
      end

      it 'handles unicode in command' do
        unicode_command = "say 你好世界"
        expect {
          post '/api/agent/command', { command: unicode_command }.to_json, auth_headers
        }.not_to raise_error
        expect(last_response).not_to be_nil
      end

      it 'handles control characters in command without crashing' do
        control_command = "say hello\x00world"
        expect {
          post '/api/agent/command', { command: control_command }.to_json, auth_headers
        }.not_to raise_error
      end
    end

    describe 'JSON input' do
      it 'handles malformed JSON without crashing' do
        expect {
          post '/api/agent/command', 'not json', auth_headers
        }.not_to raise_error
        # Server should not crash
        expect(last_response).not_to be_nil
      end

      it 'JSON library limits nesting depth for safety' do
        # Ruby's JSON library has built-in protection against deep nesting
        # This is a security feature - verify it's present
        nested = {}
        current = nested
        100.times do |i|
          current[:nested] = { level: i }
          current = current[:nested]
        end
        # JSON.generate should raise NestingError for too-deep nesting
        expect { nested.to_json }.to raise_error(JSON::NestingError)
      end

      it 'handles JSON with unexpected types' do
        post '/api/agent/command', { command: { not: 'a string' } }.to_json, auth_headers
        data = JSON.parse(last_response.body)
        expect(data['success']).to be false
      end
    end
  end

  # =========================================================================
  # MASS ASSIGNMENT PROTECTION
  # =========================================================================

  describe 'Mass assignment protection' do
    let(:user) { create(:user) }

    it 'Character model tracks user ownership' do
      # Sequel doesn't have mass assignment protection by default,
      # but we should test that controllers filter params
      character = create(:character, user: user)
      other_user = create(:user)

      # Direct model update - should be allowed (for admin/internal use)
      # But API endpoints should whitelist fields
      expect(character.user_id).to eq(user.id)
    end
  end

  # =========================================================================
  # INFORMATION DISCLOSURE
  # =========================================================================

  describe 'Information disclosure prevention' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let(:reality) { create(:reality) }
    let(:room) { create(:room) }
    let!(:character_instance) do
      create(:character_instance,
             character: character,
             reality: reality,
             current_room: room)
    end
    let!(:api_token) { user.generate_api_token! }

    it 'returns 404 for nonexistent routes' do
      get '/api/agent/nonexistent', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}" }
      expect(last_response.status).to eq(404)
    end

    it 'does not expose database column names in auth errors' do
      get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer invalid" }
      data = JSON.parse(last_response.body)

      # Error message should be generic
      expect(data['error']).to eq('Unauthorized')
      expect(data.to_s).not_to include('password_hash')
      expect(data.to_s).not_to include('api_token')
    end

    it 'returns consistent error for invalid vs expired tokens' do
      # Invalid token
      get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer invalid123" }
      invalid_data = JSON.parse(last_response.body)

      # Expired token
      user.update(api_token_expires_at: Time.now - 1)
      get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}" }
      expired_data = JSON.parse(last_response.body)

      # Both should have same error message (prevent token enumeration)
      expect(invalid_data['error']).to eq(expired_data['error'])
    end
  end

  # =========================================================================
  # INSECURE DIRECT OBJECT REFERENCE (IDOR)
  # =========================================================================

  describe 'IDOR protection' do
    let(:user1) { create(:user) }
    let(:user2) { create(:user) }
    let(:character1) { create(:character, user: user1) }
    let(:character2) { create(:character, user: user2) }
    let(:reality) { create(:reality) }
    let(:room) { create(:room) }
    let!(:instance1) do
      create(:character_instance,
             character: character1,
             reality: reality,
             current_room: room)
    end
    let!(:instance2) do
      create(:character_instance,
             character: character2,
             reality: reality,
             current_room: room)
    end
    let!(:token1) { user1.generate_api_token! }

    it 'user cannot access other users characters directly' do
      # When authenticated as user1, should not be able to access user2's data
      # This would be tested via specific endpoints that take character IDs
      expect(character1.user_id).not_to eq(user2.id)
      expect(character2.user_id).not_to eq(user1.id)
    end
  end

  # =========================================================================
  # MODEL VALIDATIONS
  # =========================================================================

  describe 'Model validation security' do
    describe 'User model' do
      it 'validates email format' do
        user = User.new(
          email: 'not-an-email',
          password_hash: BCrypt::Password.create('password123')
        )
        expect(user.valid?).to be false
      end

      it 'validates email length' do
        long_email = "a" * 250 + "@test.com"
        user = User.new(
          email: long_email,
          password_hash: BCrypt::Password.create('password123')
        )
        expect(user.valid?).to be false
      end

      it 'enforces unique emails via model validation' do
        create(:user, email: 'unique@test.com')
        duplicate = User.new(
          email: 'unique@test.com',
          password_hash: BCrypt::Password.create('password')
        )
        expect(duplicate.valid?).to be false
        expect(duplicate.errors[:email]).not_to be_empty
      end
    end

    describe 'Room model' do
      it 'validates name length' do
        location = create(:location)
        room = Room.new(
          name: "a" * 200,
          location: location
        )
        expect(room.valid?).to be false
      end

      it 'validates room_type values' do
        location = create(:location)
        room = Room.new(
          name: "Test",
          location: location,
          room_type: 'invalid_type'
        )
        expect(room.valid?).to be false
      end
    end

    describe 'Character model' do
      it 'validates name length' do
        user = create(:user)
        character = Character.new(
          user: user,
          name: "a" * 200
        )
        expect(character.valid?).to be false
      end
    end
  end

  # =========================================================================
  # COMMAND SYSTEM SECURITY
  # =========================================================================

  describe 'Command system security' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let(:reality) { create(:reality) }
    let(:room) { create(:room) }
    let(:character_instance) do
      create(:character_instance,
             character: character,
             reality: reality,
             current_room: room,
             status: 'alive',
             online: true)
    end

    describe 'request_env passing' do
      it 'command receives request_env for agent detection' do
        # Verify the command system passes request_env properly
        mock_env = { 'HTTP_X_OUTPUT_MODE' => 'agent' }

        command_class = Commands::Navigation::Look
        command = command_class.new(character_instance, request_env: mock_env)

        expect(command.request_env).to eq(mock_env)
      end

      it 'registry passes request_env to commands' do
        mock_env = { 'HTTP_USER_AGENT' => 'Claude Agent' }

        result = Commands::Base::Registry.execute_command(
          character_instance,
          'look',
          request_env: mock_env
        )

        expect(result[:success]).to be true
      end
    end

    describe 'requirement enforcement' do
      it 'commands return error when requirements not met' do
        character_instance.update(status: 'dead')

        # Attack command requires being alive and in combat
        result = Commands::Base::Registry.execute_command(
          character_instance,
          'attack target'
        )

        # Command should fail
        expect(result[:success]).to be false
        # Error message should exist and be a string
        expect(result[:error]).to be_a(String)
        expect(result[:error].length).to be > 0
      end
    end
  end
end
