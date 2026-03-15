# frozen_string_literal: true

require 'sidekiq'

# Sidekiq job for processing one NPC animation queue entry.
#
# Usage:
#   NpcAnimationProcessJob.perform_async(queue_entry_id)
#
class NpcAnimationProcessJob
  include Sidekiq::Job

  sidekiq_options queue: 'npc_animation', retry: 0

  def perform(queue_entry_id)
    entry = nil
    entry = NpcAnimationQueue[queue_entry_id]
    unless entry
      warn "[NpcAnimationProcessJob] Queue entry #{queue_entry_id} not found, skipping"
      return
    end

    processed = NpcAnimationService.send(:process_queue_entry, entry)
    return if processed

    warn "[NpcAnimationProcessJob] Queue entry #{queue_entry_id} failed during processing"
  rescue StandardError => e
    warn "[NpcAnimationProcessJob] Failed for queue entry #{queue_entry_id}: #{e.message}"
    entry&.fail!("Job error: #{e.message}")
  end
end
