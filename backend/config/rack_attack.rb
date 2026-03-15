# frozen_string_literal: true

require 'rack/attack'

# Lua script for atomic increment + expire (prevents race condition)
RATE_LIMIT_SCRIPT = <<~LUA
  local current = redis.call('INCRBY', KEYS[1], ARGV[1])
  if current == tonumber(ARGV[1]) then
    redis.call('EXPIRE', KEYS[1], ARGV[2])
  end
  return current
LUA

# Use Redis for distributed rate limiting with fail-closed behavior
class RedisRateLimitStore
  # Return this value when Redis fails to ensure rate limiting still applies
  FAIL_CLOSED_VALUE = 10_000

  def initialize(redis_pool)
    @redis_pool = redis_pool
  end

  def read(key)
    @redis_pool.with { |redis| redis.get(key) }
  rescue Redis::BaseError => e
    warn "[RackAttack] Redis error on read: #{e.message}"
    nil
  end

  def write(key, value, options = {})
    expires_in = options[:expires_in] || 60
    @redis_pool.with { |redis| redis.setex(key, expires_in, value) }
  rescue Redis::BaseError => e
    warn "[RackAttack] Redis error on write: #{e.message}"
  end

  def increment(key, amount = 1, options = {})
    expires_in = options[:expires_in] || 60
    @redis_pool.with do |redis|
      # Use Lua script for atomic increment + expire (prevents race condition)
      redis.eval(RATE_LIMIT_SCRIPT, keys: [key], argv: [amount, expires_in])
    end
  rescue Redis::BaseError => e
    # SECURITY: Fail closed - return high value to trigger rate limiting
    # This prevents attackers from bypassing rate limits by crashing Redis
    warn "[RackAttack] CRITICAL: Redis failure - rate limiting in fail-closed mode: #{e.message}"
    FAIL_CLOSED_VALUE
  end

  def delete(key)
    @redis_pool.with { |redis| redis.del(key) }
  rescue Redis::BaseError => e
    warn "[RackAttack] Redis error on delete: #{e.message}"
  end
end

# Configure Rack::Attack cache store
Rack::Attack.cache.store = RedisRateLimitStore.new(REDIS_POOL)

# Rate limit commands for webclient: 15 per second per character
Rack::Attack.throttle('commands/webclient', limit: 15, period: 1) do |req|
  if req.path.start_with?('/api/messages', '/api/command') && !req.path.start_with?('/api/agent')
    req.session['character_instance_id'] || req.ip
  end
end

# Rate limit commands for agents: 30 per second (higher throughput for autonomous operation)
Rack::Attack.throttle('commands/agent', limit: 30, period: 1) do |req|
  if req.path.start_with?('/api/agent')
    req.session['character_instance_id'] || req.ip
  end
end

# Rate limit Bearer token authentication attempts: 10 per minute per token prefix
# This prevents brute-force attacks on token guessing
Rack::Attack.throttle('auth/bearer', limit: 10, period: 60) do |req|
  if req.path.start_with?('/api/agent')
    auth_header = req.env['HTTP_AUTHORIZATION']
    if auth_header&.start_with?('Bearer ')
      token = auth_header.sub('Bearer ', '').strip
      # Rate limit by token prefix hash (prevents enumeration without storing tokens)
      Digest::SHA256.hexdigest(token[0..7])[0..15] if token.length >= 8
    end
  end
end

# Additional protection: limit failed auth attempts per IP
Rack::Attack.throttle('auth/bearer/ip', limit: 20, period: 60) do |req|
  req.ip if req.path.start_with?('/api/agent') && req.env['HTTP_AUTHORIZATION']&.start_with?('Bearer ')
end

# Protect login: 5 attempts per minute per email (with safe key validation)
Rack::Attack.throttle('login/email', limit: 5, period: 60) do |req|
  if req.path == '/auth/login' && req.post?
    email = req.params['email']&.to_s&.strip&.downcase
    # Validate email format and length to prevent Redis key injection
    email if email && email.length <= 255 && email.match?(/\A[^@\s]+@[^@\s]+\z/)
  end
end

# Protect registration: 3 per hour per IP
Rack::Attack.throttle('register/ip', limit: 3, period: 3600) do |req|
  req.ip if req.path == '/register' && req.post?
end

# Custom response for rate-limited requests
Rack::Attack.throttled_responder = lambda do |env|
  match_data = env['rack.attack.match_data']
  period = match_data[:period]
  retry_after = period - (Time.now.to_i % period)

  # Use JSON for API paths, plain text for web
  content_type = env['PATH_INFO'].start_with?('/api') ?
    'application/json' : 'text/plain'

  body = if content_type == 'application/json'
    { success: false, error: 'rate_limit_exceeded', retry_after: retry_after }.to_json
  else
    'Too many commands. Please slow down.'
  end

  [429, { 'Content-Type' => content_type, 'Retry-After' => retry_after.to_s }, [body]]
end
