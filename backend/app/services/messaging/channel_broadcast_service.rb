# frozen_string_literal: true

# ChannelBroadcastService handles broadcasting messages to channel members.
# Integrates with BroadcastService for actual message delivery.
#
# Name display rules:
#   - OOC channels: Always show sender's full character name (not personalized)
#   - IC/other channels: Show personalized name based on what viewer knows
#   - All channels: Color the sender name with their speech_color
#
# Example usage:
#   ChannelBroadcastService.broadcast(channel, sender_instance, "Hello everyone!")
#
class ChannelBroadcastService
  class << self
    # Broadcast a message to all online members of a channel
    # @param channel [Channel] the channel to broadcast to
    # @param sender_instance [CharacterInstance] the sender's instance
    # @param message [String] the message content
    # @param type [Symbol] message type for BroadcastService
    # @return [Hash] result with success status and member count
    def broadcast(channel, sender_instance, message, type: :channel, broadcast_id: nil)
      return error("Channel not found") unless channel
      return error("Sender not found") unless sender_instance

      broadcast_id ||= SecureRandom.uuid
      members = online_members(channel, exclude: [sender_instance])
      sender_user = sender_instance.character&.user
      sender_character = sender_instance.character

      delivered_count = 0
      members.each do |member_instance|
        # Check if member has muted the sender via permissions
        next unless should_deliver_to?(member_instance, sender_user)

        # Format message personalized for this viewer
        formatted = format_channel_message_for_viewer(channel, sender_character, member_instance, message)
        BroadcastService.to_character(
          member_instance,
          formatted,
          type: type,
          broadcast_id: broadcast_id
        )
        delivered_count += 1
      end

      # Also send to sender with confirmation format
      sender_message = format_sender_message(channel, message, sender_character)
      BroadcastService.to_character(sender_instance, sender_message, type: type, broadcast_id: broadcast_id)

      success(member_count: delivered_count + 1, channel: channel.name, broadcast_id: broadcast_id)
    end

    # Get all online members of a channel, optionally excluding some
    # @param channel [Channel] the channel
    # @param exclude [Array<CharacterInstance>] instances to exclude
    # @return [Array<CharacterInstance>] online member instances
    def online_members(channel, exclude: [])
      exclude_ids = exclude.map(&:id)

      members = channel.channel_members_dataset.eager(:character).all
      members
             .reject { |cm| cm.is_muted }
             .filter_map do |cm|
               char = cm.character
               next unless char

               instance = char.primary_instance
               next unless instance&.online
               next if exclude_ids.include?(instance.id)
               next if instance.quiet_mode? # Skip users in quiet mode

               instance
             end
    end

    # Find a channel by name (case-insensitive)
    # @param name [String] channel name to find
    # @param universe_id [Integer, nil] optional universe to scope to
    # @return [Channel, nil]
    def find_channel(name, universe_id: nil)
      dataset = Channel.where(Sequel.ilike(:name, name))
      dataset = dataset.where(universe_id: universe_id) if universe_id
      dataset.first
    end

    # Get the default OOC channel for a universe
    # @param universe_id [Integer, nil] the universe ID
    # @return [Channel, nil]
    def default_ooc_channel(universe_id: nil)
      # Find OOC channel, preferring the one scoped to the universe
      dataset = Channel.where(channel_type: 'ooc')
      dataset = dataset.where(universe_id: universe_id) if universe_id
      dataset.first || Channel.where(channel_type: 'ooc').first
    end

    # List channels a character can see/join
    # @param character [Character] the character
    # @return [Array<Hash>] array of channel info hashes
    def available_channels(character)
      # Get public channels and channels they're a member of
      memberships = ChannelMember.where(character_id: character.id).all
      member_channel_ids = memberships.map(&:channel_id)
      membership_by_channel = memberships.each_with_object({}) { |m, h| h[m.channel_id] = m }

      # Public channels OR channels the character is a member of
      Channel.where(Sequel.|({ is_public: true }, { id: member_channel_ids }))
             .order(:name)
             .map do |ch|
               membership = membership_by_channel[ch.id]
               {
                 id: ch.id,
                 name: ch.name,
                 type: ch.channel_type,
                 description: ch.description,
                 is_member: !membership.nil?,
                 role: membership&.role,
                 muted: membership&.is_muted || false,
                 online_count: online_members(ch).count
               }
             end
    end

    private

    # Check if a channel message from sender_user should be delivered to member_instance
    # Uses UserPermission system to check if member has muted the sender
    # @param member_instance [CharacterInstance] the potential recipient
    # @param sender_user [User, nil] the sender's user
    # @return [Boolean] true if message should be delivered
    def should_deliver_to?(member_instance, sender_user)
      return true unless sender_user # System messages always delivered

      viewer_user = member_instance.character&.user
      return true unless viewer_user # No user = deliver

      UserPermission.channel_visible?(viewer_user, sender_user)
    end

    # Format message personalized for a specific viewer
    # - OOC channels: Always show full name (OOC is out-of-character, no mystery)
    # - IC/other channels: Show personalized name based on CharacterKnowledge
    # - All channels: Apply sender's speech_color to their name
    # @param channel [Channel] the channel
    # @param sender_character [Character] the sender's character
    # @param viewer_instance [CharacterInstance] the recipient's instance
    # @param message [String] the message content
    # @return [String] formatted message
    def format_channel_message_for_viewer(channel, sender_character, viewer_instance, message)
      prefix = channel_prefix(channel)
      sender_name = resolve_sender_name_for_viewer(channel, sender_character, viewer_instance)
      colored_name = apply_speech_color(sender_name, sender_character&.speech_color)
      "#{prefix} #{colored_name}: #{message}"
    end

    # Resolve the display name for a sender based on channel type and viewer knowledge
    # @param channel [Channel] the channel
    # @param sender_character [Character] the sender's character
    # @param viewer_instance [CharacterInstance] the viewer's instance
    # @return [String] the name to display
    def resolve_sender_name_for_viewer(channel, sender_character, viewer_instance)
      return 'Someone' unless sender_character

      # OOC channels always show full character name (it's out of character)
      if channel.ooc?
        return sender_character.full_name
      end

      # IC and other channels use personalized names based on what viewer knows
      sender_character.display_name_for(viewer_instance)
    end

    # Apply speech color styling to a name
    # @param name [String] the name to color
    # @param color [String, nil] hex color (e.g., '#FF5733')
    # @return [String] the name, optionally wrapped in a color span
    def apply_speech_color(name, color)
      MessageFormattingHelper.apply_speech_color_to_text(name, color)
    end

    # Format message for sender (confirmation style)
    # Shows "You:" with sender's own speech color
    # @param channel [Channel] the channel
    # @param message [String] the message content
    # @param sender_character [Character, nil] the sender's character
    # @return [String] formatted message
    def format_sender_message(channel, message, sender_character = nil)
      prefix = channel_prefix(channel)
      you_text = apply_speech_color('You', sender_character&.speech_color)
      "#{prefix} #{you_text}: #{message}"
    end

    # Get the display prefix for a channel
    def channel_prefix(channel)
      name = channel.name.to_s.split(/[\s_]+/).map(&:capitalize).join(' ')
      "[#{name}]"
    end

    def success(data = {})
      { success: true }.merge(data)
    end

    def error(message)
      { success: false, error: message }
    end
  end
end
