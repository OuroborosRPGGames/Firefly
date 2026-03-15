# frozen_string_literal: true

# Boot file for Sidekiq workers (Roda app, not Rails)
# Run with: bundle exec sidekiq -C config/sidekiq.yml -r ./config/sidekiq_boot

$LOAD_PATH.unshift File.expand_path('..', __dir__)

require_relative 'room_type_config'
Dir[File.join(__dir__, '../app/lib/*.rb')].each { |f| require f }
require_relative 'application'

# Disable the VIPS operation cache — it is not safe to share across Sidekiq's
# concurrent worker threads and causes SIGSEGV in vips_cache_operation_build.
require 'vips'
Vips.cache_set_max(0)
Vips.concurrency_set(1)
