# frozen_string_literal: true

require 'sidekiq'

# Sidekiq job for asynchronous room mask generation.
#
# Usage:
#   MaskGenerationJob.perform_async(room.id)
#
class MaskGenerationJob
  include Sidekiq::Job

  sidekiq_options queue: 'llm', retry: 0

  def perform(room_id)
    room = Room[room_id]
    unless room
      warn "[MaskGenerationJob] Room #{room_id} not found, skipping"
      return
    end

    result = MaskGenerationService.generate(room)
    return if result[:success]

    warn "[MaskGenerationJob] Mask generation failed for room #{room_id}: #{result[:error]}"
  rescue StandardError => e
    warn "[MaskGenerationJob] Failed for room #{room_id}: #{e.message}"
  end
end
