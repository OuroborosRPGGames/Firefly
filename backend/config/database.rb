# frozen_string_literal: true

require 'sequel'
Sequel.extension :pg_json_ops

module FireflyDatabase
  class << self
    def connect
      # Calculate pool size based on Puma configuration
      # Formula: (workers × threads) + overhead + buffer
      workers = ENV.fetch('WEB_CONCURRENCY', 4).to_i
      threads_per_worker = ENV.fetch('PUMA_THREADS', 5).to_i
      base_connections = workers * threads_per_worker
      overhead = 15 # WebSocket handlers, background jobs, admin connections
      default_pool_size = base_connections + overhead

      Sequel.connect(
        adapter: 'postgres',
        host: ENV.fetch('DB_HOST', 'localhost'),
        database: ENV.fetch('DB_NAME', 'firefly'),
        user: ENV.fetch('DB_USER', 'prom_user'),
        password: ENV.fetch('DB_PASSWORD', 'prom_password'),

        # Dynamic pool sizing for scalability
        max_connections: ENV.fetch('DB_POOL_SIZE', default_pool_size).to_i,
        pool_timeout: ENV.fetch('DB_POOL_TIMEOUT', 5).to_i,

        # Only enable test mode in test environment (not production!)
        test: ENV['RACK_ENV'] == 'test',

        after_connect: proc do |conn|
          # Configurable statement timeout - stricter in production
          timeout = ENV.fetch('DB_STATEMENT_TIMEOUT') do
            ENV['RACK_ENV'] == 'production' ? '500ms' : '5s'
          end
          conn.execute("SET statement_timeout = '#{timeout}'")
          conn.execute("SET application_name = 'firefly_mud'")
        end
      ).tap do |db|
        db.extension :pg_json
        db.extension(:connection_validator)
        # Validate connections every 5 minutes (300 seconds) instead of 1 hour
        db.pool.connection_validation_timeout = ENV.fetch('DB_VALIDATION_TIMEOUT', 300).to_i
      end
    end

    def disconnect
      DB.disconnect if defined?(DB) && DB
    end

    # Pool statistics for monitoring
    def pool_stats
      return {} unless defined?(DB) && DB

      pool = DB.pool
      {
        size: pool.size,
        max_size: pool.max_size,
        available: pool.max_size - pool.size,
        allocated: pool.size
      }
    rescue StandardError => e
      warn "[FireflyDatabase] pool_stats failed: #{e.message}"
      {}
    end
  end
end
