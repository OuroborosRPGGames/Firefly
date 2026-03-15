# frozen_string_literal: true

# Automatic cleanup hooks for combat tests
# Ensures fights are properly cleaned up before and after each combat test
#
# Tests tagged with :combat will automatically:
# - Clean up stale fights before running
# - Complete any ongoing fights after running
#
# @example
#   RSpec.describe "Combat System", :combat do
#     # Cleanup happens automatically
#   end
RSpec.configure do |config|
  # Before each combat test: clean up stale fights
  config.before(:each, :combat) do
    # Use FightCleanupService if available, otherwise manual cleanup
    if defined?(FightCleanupService)
      FightCleanupService.cleanup_all!
    else
      # Manual cleanup: complete all ongoing fights
      Fight.where(status: %w[input resolving narrative]).update(status: 'complete')
    end

    # Also clean up orphaned fight participants (defensive)
    FightParticipant.eager(:fight).all.each do |fp|
      next if fp.fight
      fp.destroy
    end
  end

  # After each combat test: ensure fights are completed
  config.after(:each, :combat) do
    # Mark all ongoing fights as complete
    Fight.where(status: %w[input resolving narrative]).update(status: 'complete')
  end

  # Before suite: one-time cleanup of any old test data
  config.before(:suite) do
    if ENV['CLEANUP_STALE_FIGHTS'] == 'true'
      puts "Cleaning up stale fights from previous test runs..."
      Fight.where(status: %w[input resolving narrative]).update(status: 'complete')
    end
  end
end
