# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require_relative '../../config/rack_attack'

RSpec.describe 'Rack::Attack rate limiting configuration' do
  include Rack::Test::Methods

  def app
    Rack::Builder.new do
      use Rack::Attack
      use Rack::Session::Cookie, secret: 'test_secret'
      run ->(env) { [200, { 'Content-Type' => 'text/plain' }, ['OK']] }
    end.to_app
  end

  before do
    # Clear Rack::Attack cache before each test
    Rack::Attack.cache.store.instance_variable_get(:@redis_pool)&.with { |r| r.flushdb } rescue nil
  end

  describe 'RedisRateLimitStore' do
    let(:redis_pool) { ConnectionPool.new(size: 5) { Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/1')) } }
    let(:store) { RedisRateLimitStore.new(redis_pool) }

    describe '#read' do
      it 'reads values from Redis' do
        redis_pool.with { |redis| redis.set('test_key', 'test_value') }
        expect(store.read('test_key')).to eq('test_value')
      end

      it 'returns nil for non-existent keys' do
        expect(store.read('nonexistent_key')).to be_nil
      end

      context 'when Redis fails' do
        before do
          allow_any_instance_of(Redis).to receive(:get).and_raise(Redis::BaseError.new('Connection refused'))
        end

        it 'returns nil and logs error' do
          expect { store.read('test_key') }.to output(/Redis error on read/).to_stderr
          expect(store.read('test_key')).to be_nil
        end
      end
    end

    describe '#write' do
      it 'writes values to Redis with expiration' do
        store.write('write_test', 'value', expires_in: 60)
        expect(store.read('write_test')).to eq('value')
      end

      it 'uses default 60 second expiration' do
        store.write('default_expire_test', 'value')
        # Value should exist immediately
        expect(store.read('default_expire_test')).to eq('value')
      end

      context 'when Redis fails' do
        before do
          allow_any_instance_of(Redis).to receive(:setex).and_raise(Redis::BaseError.new('Connection refused'))
        end

        it 'logs error and does not raise' do
          expect { store.write('test_key', 'value') }.to output(/Redis error on write/).to_stderr
        end
      end
    end

    describe '#increment' do
      it 'increments a key atomically' do
        result = store.increment('incr_test', 1, expires_in: 60)
        expect(result).to eq(1)

        result = store.increment('incr_test', 1, expires_in: 60)
        expect(result).to eq(2)
      end

      it 'increments by specified amount' do
        result = store.increment('incr_amount_test', 5, expires_in: 60)
        expect(result).to eq(5)
      end

      context 'when Redis fails (fail-closed behavior)' do
        before do
          allow_any_instance_of(Redis).to receive(:eval).and_raise(Redis::BaseError.new('Connection refused'))
        end

        it 'returns FAIL_CLOSED_VALUE to trigger rate limiting' do
          expect { store.increment('test_key') }.to output(/CRITICAL: Redis failure/).to_stderr
          result = store.increment('test_key')
          expect(result).to eq(RedisRateLimitStore::FAIL_CLOSED_VALUE)
        end

        it 'returns 10000 as fail-closed value' do
          expect(RedisRateLimitStore::FAIL_CLOSED_VALUE).to eq(10_000)
        end
      end
    end

    describe '#delete' do
      it 'deletes keys from Redis' do
        store.write('delete_test', 'value')
        expect(store.read('delete_test')).to eq('value')

        store.delete('delete_test')
        expect(store.read('delete_test')).to be_nil
      end

      context 'when Redis fails' do
        before do
          allow_any_instance_of(Redis).to receive(:del).and_raise(Redis::BaseError.new('Connection refused'))
        end

        it 'logs error and does not raise' do
          expect { store.delete('test_key') }.to output(/Redis error on delete/).to_stderr
        end
      end
    end
  end

  describe 'RATE_LIMIT_SCRIPT' do
    it 'is defined' do
      expect(defined?(RATE_LIMIT_SCRIPT)).to be_truthy
    end

    it 'contains Lua code for atomic increment' do
      expect(RATE_LIMIT_SCRIPT).to include('redis.call')
      expect(RATE_LIMIT_SCRIPT).to include('INCRBY')
      expect(RATE_LIMIT_SCRIPT).to include('EXPIRE')
    end
  end

  describe 'throttle configurations' do
    describe 'commands/webclient' do
      it 'is configured with 15 requests per second' do
        throttle = Rack::Attack.throttles['commands/webclient']
        expect(throttle).not_to be_nil
        expect(throttle.limit).to eq(15)
        expect(throttle.period).to eq(1)
      end
    end

    describe 'commands/agent' do
      it 'is configured with 30 requests per second' do
        throttle = Rack::Attack.throttles['commands/agent']
        expect(throttle).not_to be_nil
        expect(throttle.limit).to eq(30)
        expect(throttle.period).to eq(1)
      end
    end

    describe 'auth/bearer' do
      it 'is configured with 10 attempts per minute' do
        throttle = Rack::Attack.throttles['auth/bearer']
        expect(throttle).not_to be_nil
        expect(throttle.limit).to eq(10)
        expect(throttle.period).to eq(60)
      end
    end

    describe 'auth/bearer/ip' do
      it 'is configured with 20 attempts per minute per IP' do
        throttle = Rack::Attack.throttles['auth/bearer/ip']
        expect(throttle).not_to be_nil
        expect(throttle.limit).to eq(20)
        expect(throttle.period).to eq(60)
      end
    end

    describe 'login/email' do
      it 'is configured with 5 attempts per minute' do
        throttle = Rack::Attack.throttles['login/email']
        expect(throttle).not_to be_nil
        expect(throttle.limit).to eq(5)
        expect(throttle.period).to eq(60)
      end
    end

    describe 'register/ip' do
      it 'is configured with 3 attempts per hour' do
        throttle = Rack::Attack.throttles['register/ip']
        expect(throttle).not_to be_nil
        expect(throttle.limit).to eq(3)
        expect(throttle.period).to eq(3600)
      end
    end
  end

  describe 'throttle discriminators' do
    describe 'commands/webclient discriminator' do
      let(:throttle) { Rack::Attack.throttles['commands/webclient'] }

      it 'applies to /api/messages requests' do
        env = { 'PATH_INFO' => '/api/messages', 'REMOTE_ADDR' => '127.0.0.1' }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).not_to be_nil
      end

      it 'applies to /api/command requests' do
        env = { 'PATH_INFO' => '/api/command', 'REMOTE_ADDR' => '127.0.0.1' }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).not_to be_nil
      end

      it 'does not apply to /api/agent requests' do
        env = { 'PATH_INFO' => '/api/agent', 'REMOTE_ADDR' => '127.0.0.1' }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to be_nil
      end

      it 'uses character_instance_id from session if available' do
        env = {
          'PATH_INFO' => '/api/messages',
          'REMOTE_ADDR' => '127.0.0.1',
          'rack.session' => { 'character_instance_id' => 123 }
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to eq(123)
      end

      it 'falls back to IP if no session' do
        env = {
          'PATH_INFO' => '/api/messages',
          'REMOTE_ADDR' => '192.168.1.1',
          'rack.session' => {}
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to eq('192.168.1.1')
      end
    end

    describe 'commands/agent discriminator' do
      let(:throttle) { Rack::Attack.throttles['commands/agent'] }

      it 'applies to /api/agent requests' do
        env = { 'PATH_INFO' => '/api/agent', 'REMOTE_ADDR' => '127.0.0.1' }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).not_to be_nil
      end

      it 'does not apply to /api/messages requests' do
        env = { 'PATH_INFO' => '/api/messages', 'REMOTE_ADDR' => '127.0.0.1' }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to be_nil
      end
    end

    describe 'auth/bearer discriminator' do
      let(:throttle) { Rack::Attack.throttles['auth/bearer'] }

      it 'applies to agent requests with Bearer token' do
        env = {
          'PATH_INFO' => '/api/agent',
          'HTTP_AUTHORIZATION' => 'Bearer test_token_12345678'
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).not_to be_nil
        expect(key.length).to eq(16) # SHA256 hex prefix
      end

      it 'does not apply to short tokens' do
        env = {
          'PATH_INFO' => '/api/agent',
          'HTTP_AUTHORIZATION' => 'Bearer short'
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to be_nil
      end

      it 'does not apply to non-agent paths' do
        env = {
          'PATH_INFO' => '/api/messages',
          'HTTP_AUTHORIZATION' => 'Bearer test_token_12345678'
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to be_nil
      end

      it 'does not apply to non-Bearer auth' do
        env = {
          'PATH_INFO' => '/api/agent',
          'HTTP_AUTHORIZATION' => 'Basic dGVzdDp0ZXN0'
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to be_nil
      end
    end

    describe 'login/email discriminator' do
      let(:throttle) { Rack::Attack.throttles['login/email'] }

      it 'applies to POST /auth/login with valid email' do
        env = {
          'PATH_INFO' => '/auth/login',
          'REQUEST_METHOD' => 'POST',
          'rack.input' => StringIO.new('email=test@example.com'),
          'CONTENT_TYPE' => 'application/x-www-form-urlencoded'
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to eq('test@example.com')
      end

      it 'does not apply to GET /auth/login' do
        env = {
          'PATH_INFO' => '/auth/login',
          'REQUEST_METHOD' => 'GET'
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to be_nil
      end

      it 'does not apply to POST on other paths' do
        env = {
          'PATH_INFO' => '/register',
          'REQUEST_METHOD' => 'POST',
          'rack.input' => StringIO.new('email=test@example.com'),
          'CONTENT_TYPE' => 'application/x-www-form-urlencoded'
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to be_nil
      end

      it 'rejects invalid emails' do
        env = {
          'PATH_INFO' => '/auth/login',
          'REQUEST_METHOD' => 'POST',
          'rack.input' => StringIO.new('email=invalid'),
          'CONTENT_TYPE' => 'application/x-www-form-urlencoded'
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to be_nil
      end

      it 'rejects overly long emails' do
        long_email = "#{'a' * 250}@example.com"
        env = {
          'PATH_INFO' => '/auth/login',
          'REQUEST_METHOD' => 'POST',
          'rack.input' => StringIO.new("email=#{long_email}"),
          'CONTENT_TYPE' => 'application/x-www-form-urlencoded'
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to be_nil
      end
    end

    describe 'register/ip discriminator' do
      let(:throttle) { Rack::Attack.throttles['register/ip'] }

      it 'applies to POST /register' do
        env = {
          'PATH_INFO' => '/register',
          'REQUEST_METHOD' => 'POST',
          'REMOTE_ADDR' => '192.168.1.100'
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to eq('192.168.1.100')
      end

      it 'does not apply to GET /register' do
        env = {
          'PATH_INFO' => '/register',
          'REQUEST_METHOD' => 'GET',
          'REMOTE_ADDR' => '192.168.1.100'
        }
        req = Rack::Request.new(env)
        key = throttle.block.call(req)
        expect(key).to be_nil
      end
    end
  end

  describe 'throttled_responder' do
    let(:responder) { Rack::Attack.throttled_responder }

    it 'is configured' do
      expect(responder).to be_a(Proc)
    end

    it 'returns 429 status' do
      env = {
        'rack.attack.match_data' => { period: 60, count: 100, limit: 10 },
        'PATH_INFO' => '/api/test'
      }
      status, _headers, _body = responder.call(env)
      expect(status).to eq(429)
    end

    it 'includes Retry-After header' do
      env = {
        'rack.attack.match_data' => { period: 60, count: 100, limit: 10 },
        'PATH_INFO' => '/api/test'
      }
      _status, headers, _body = responder.call(env)
      expect(headers['Retry-After']).not_to be_nil
      expect(headers['Retry-After'].to_i).to be_between(0, 60)
    end

    context 'for API paths' do
      it 'returns JSON response' do
        env = {
          'rack.attack.match_data' => { period: 60, count: 100, limit: 10 },
          'PATH_INFO' => '/api/test'
        }
        _status, headers, body = responder.call(env)
        expect(headers['Content-Type']).to eq('application/json')
        json = JSON.parse(body.first)
        expect(json['success']).to eq(false)
        expect(json['error']).to eq('rate_limit_exceeded')
        expect(json['retry_after']).to be_a(Integer)
      end
    end

    context 'for non-API paths' do
      it 'returns plain text response' do
        env = {
          'rack.attack.match_data' => { period: 60, count: 100, limit: 10 },
          'PATH_INFO' => '/web/test'
        }
        _status, headers, body = responder.call(env)
        expect(headers['Content-Type']).to eq('text/plain')
        expect(body.first).to eq('Too many commands. Please slow down.')
      end
    end
  end

  describe 'Rack::Attack.cache.store' do
    it 'is configured to use RedisRateLimitStore' do
      expect(Rack::Attack.cache.store).to be_a(RedisRateLimitStore)
    end
  end
end
