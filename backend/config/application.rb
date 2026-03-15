# frozen_string_literal: true

require 'bundler/setup'
require 'dotenv/load'
require 'roda'
require 'sequel'
require 'redis'
require 'connection_pool'
require 'json'
require 'securerandom'

# Load game configuration constants
require_relative 'game_config'

# Load centralized LLM prompts
require_relative 'game_prompts'

# Database setup (shared with main app path)
require_relative 'database'

# Database setup - skip if already defined (for test environment with DatabaseCleaner)
unless defined?(DB)
  DB = FireflyDatabase.connect
end

# Redis setup
unless defined?(REDIS_POOL)
  REDIS_POOL = ConnectionPool.new(size: 50, timeout: 5) do
    Redis.new(
      url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
      timeout: 5,
      reconnect_attempts: 3
    )
  end
end

# Load helpers first (some models depend on them)
Dir[File.join(__dir__, '../app/helpers/*.rb')].sort.each { |f| require f }

# Load model concerns (they're dependencies for models)
Dir[File.join(__dir__, '../app/models/concerns/*.rb')].sort.each { |f| require f }

# Load models
Dir[File.join(__dir__, '../app/models/*.rb')].sort.each { |f| require f }

# Load service concerns first (they're dependencies for other services)
Dir[File.join(__dir__, '../app/services/concerns/*.rb')].sort.each { |f| require f }

# Load services
Dir[File.join(__dir__, '../app/services/**/*.rb')].sort.each { |f| require f }

# Load handler concerns and handlers (callback handlers run in Sidekiq context)
Dir[File.join(__dir__, '../app/handlers/concerns/*.rb')].sort.each { |f| require f }
Dir[File.join(__dir__, '../app/handlers/*.rb')].sort.each { |f| require f }

# Load jobs (Sidekiq workers)
Dir[File.join(__dir__, '../app/jobs/*.rb')].sort.each { |f| require f }

# Load controllers
Dir[File.join(__dir__, '../app/controllers/*.rb')].sort.each { |f| require f }
