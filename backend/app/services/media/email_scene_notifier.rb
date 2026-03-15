# frozen_string_literal: true

# EmailSceneNotifier - Sends email notifications to offline characters
# when IC roleplay activity happens in their room.
#
# Uses a Redis cooldown (15 minutes per user per room) to avoid spam.
#
# Usage:
#   EmailSceneNotifier.notify_if_needed(room_id, content, sender_instance)
#
module EmailSceneNotifier
  COOLDOWN_PREFIX = 'email_scene_cooldown:'
  COOLDOWN_SECONDS = 900 # 15 minutes between emails per user per room

  class << self
    def notify_if_needed(room_id, content, sender_instance)
      return unless EmailService.configured?

      # Find offline characters in this room (not NPCs)
      offline_instances = CharacterInstance
        .where(current_room_id: room_id, online: false)
        .all
        .reject { |ci| ci.character&.is_npc }

      offline_instances.each do |ci|
        user = ci.character&.user
        next unless user&.email

        # Check if user has emailscene enabled
        next unless user_setting_enabled?(user.id, 'emailscene')

        # Check cooldown
        cooldown_key = "#{COOLDOWN_PREFIX}#{user.id}:#{room_id}"
        sent = false
        REDIS_POOL.with do |redis|
          next if redis.exists?(cooldown_key)

          redis.setex(cooldown_key, COOLDOWN_SECONDS, '1')
          sent = true
        end
        next unless sent

        sender_name = sender_instance&.character&.full_name || 'Someone'
        room_name = Room[room_id]&.name || 'a room'
        plain_content = content.to_s.gsub(/<[^>]*>/, '')[0..200]

        EmailService.send_email(
          to: user.email,
          subject: "New RP activity in #{room_name}",
          body: "There's new roleplay activity where your character is:\n\n#{sender_name}: #{plain_content}\n\nLog in to join the scene.",
          html: false
        )
      end
    rescue StandardError => e
      warn "[EmailSceneNotifier] Failed: #{e.message}"
    end

    private

    def user_setting_enabled?(user_id, key)
      cached = nil
      REDIS_POOL.with { |redis| cached = redis.get("settings:user:#{user_id}") }
      return false unless cached

      settings = JSON.parse(cached)
      settings[key] == true || settings[key] == 'true'
    rescue StandardError => e
      warn "[EmailSceneNotifier] Failed to check user setting #{key}: #{e.message}"
      false
    end
  end
end
