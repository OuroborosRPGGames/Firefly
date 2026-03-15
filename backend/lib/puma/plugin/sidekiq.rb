# frozen_string_literal: true

require 'puma/plugin'
require_relative '../sidekiq_settings'

Puma::Plugin.create do
  def start(launcher)
    return if ENV['DISABLE_SIDEKIQ'] == '1'

    require 'sidekiq'
    require 'sidekiq/embedded'

    settings = Puma::SidekiqSettings.load
    config = Sidekiq::Config.new
    config.concurrency = ENV.fetch('SIDEKIQ_CONCURRENCY', settings.fetch('concurrency', 60)).to_i
    config.queues = Puma::SidekiqSettings.expand_weighted_queues(settings['queues'])
    config[:timeout] = ENV.fetch('SIDEKIQ_TIMEOUT', settings.fetch('timeout', 300)).to_i
    config[:tag] = settings['tag'] if settings['tag']

    redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
    config.redis = { url: redis_url }

    # Ensure job classes are loaded before Sidekiq starts processing.
    # In Puma cluster mode the plugin start hook runs before application preloading,
    # so we must explicitly require the boot file here.
    require File.expand_path('../../../config/sidekiq_boot', __dir__)

    @sidekiq = Sidekiq::Embedded.new(config)
    @sidekiq.run

    launcher.events.on_stopped { Thread.new { @sidekiq.stop } }
    launcher.events.on_restart { Thread.new { @sidekiq.quiet } }
  end
end
