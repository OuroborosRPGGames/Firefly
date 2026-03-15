# frozen_string_literal: true

# ClanService provides clan/group management operations.
# Handles creation, membership, messaging, and room access.
class ClanService
  class << self
    # ========================================
    # Clan Creation
    # ========================================

    def create_clan(creator, name:, symbol: nil, secret: false, create_channel: true)
      return error('Name is required') if StringHelper.blank?(name)
      return error('Name too long (max 100 characters)') if name.length > 100

      # Check for existing clan with same name in universe
      universe_id = creator.respond_to?(:universe_id) ? creator.universe_id : nil
      existing = Group.where(name: name.strip, universe_id: universe_id).first
      return error('A group with that name already exists') if existing

      DB.transaction do
        clan = Group.create(
          name: name.strip,
          group_type: 'clan',
          universe_id: universe_id,
          leader_character_id: creator.id,
          symbol: symbol,
          is_secret: secret,
          is_public: !secret
        )

        # Add creator as leader
        clan.add_member(creator, rank: 'leader')

        # Create channel if requested
        clan.create_channel! if create_channel

        success(clan: clan, message: "Clan '#{clan.display_name}' created successfully!")
      end
    rescue Sequel::ValidationFailed => e
      error("Failed to create clan: #{e.message}")
    end

    # ========================================
    # Member Management
    # ========================================

    def invite_member(clan, inviter, target_character, handle: nil)
      # Verify inviter has permission
      membership = clan.membership_for(inviter)
      return error('You are not a member of this clan') unless membership
      return error("You don't have permission to invite members") unless membership.can_invite?

      # Check target isn't already a member
      inviter_instance = inviter.primary_instance
      target_name = target_character.display_name_for(inviter_instance)
      return error("#{target_name} is already a member") if clan.member?(target_character)

      DB.transaction do
        clan.add_member(target_character, rank: 'member', handle: handle)
      end

      success(
        member: target_character,
        message: "#{target_name} has been invited to #{clan.display_name}."
      )
    end

    def kick_member(clan, kicker, target_character)
      membership = clan.membership_for(kicker)
      return error('You are not a member of this clan') unless membership
      return error("You don't have permission to kick members") unless membership.can_kick?

      target_membership = clan.membership_for(target_character)
      kicker_instance = kicker.primary_instance
      target_name = target_character.display_name_for(kicker_instance)
      return error("#{target_name} is not a member") unless target_membership
      return error('You cannot kick the clan leader') if clan.leader?(target_character)

      # Officers can't kick other officers (only leader can)
      if target_membership.officer? && !clan.leader?(kicker)
        return error('Only the clan leader can remove officers')
      end

      clan.remove_member(target_character)

      success(
        member: target_character,
        message: "#{target_name} has been removed from #{clan.display_name}."
      )
    end

    def leave_clan(clan, character)
      membership = clan.membership_for(character)
      return error('You are not a member of this clan') unless membership

      if clan.leader?(character)
        return error('The clan leader cannot leave. Promote someone else to leader first, or disband the clan.')
      end

      clan.remove_member(character)

      success(message: "You have left #{clan.display_name}.")
    end

    def set_handle(clan, character, new_handle)
      membership = clan.membership_for(character)
      return error('You are not a member of this clan') unless membership
      return error('Handle too long (max 50 characters)') if new_handle && new_handle.length > 50

      membership.update(handle: new_handle)

      success(message: "Your handle in #{clan.display_name} is now '#{new_handle}'.")
    end

    # ========================================
    # Clan Queries
    # ========================================

    def list_clans_for(character)
      # Public clans + clans the character is a member of
      member_clan_ids = GroupMember.where(character_id: character.id, status: 'active')
                                   .select_map(:group_id)

      Group.where(group_type: 'clan', status: 'active')
           .where do
             Sequel.|(
               { is_secret: false, is_public: true },
               Sequel.expr(id: member_clan_ids)
             )
           end
           .order(:name)
           .all
    end

    def find_clan_by_name(name, universe_id: nil)
      dataset = Group.where(group_type: 'clan', status: 'active')
                     .where(Sequel.ilike(:name, name))
      dataset = dataset.where(universe_id: universe_id) if universe_id
      dataset.first
    end

    def find_clan_by_name_prefix(name, universe_id: nil, min_length: 2)
      return nil if name.nil? || name.length < min_length

      # Try exact match first
      dataset = Group.where(group_type: 'clan', status: 'active')
                     .where(Sequel.ilike(:name, name))
      dataset = dataset.where(universe_id: universe_id) if universe_id
      result = dataset.first
      return result if result

      # Try prefix match
      dataset = Group.where(group_type: 'clan', status: 'active')
                     .where(Sequel.ilike(:name, "#{name}%"))
      dataset = dataset.where(universe_id: universe_id) if universe_id
      dataset.first
    end

    # ========================================
    # Clan Chat
    # ========================================

    def broadcast_to_clan(clan, sender_instance, message)
      channel = clan.channel
      return error("This clan doesn't have a chat channel") unless channel

      membership = clan.membership_for(sender_instance.character)
      return error('You are not a member of this clan') unless membership

      # Use handle (or default Greek letter) if secret clan
      sender_name = if clan.secret?
                      membership.display_name_for
                    else
                      sender_instance.character.full_name
                    end

      # Use clan name for channel prefix
      prefix = clan.name
      formatted = {
        content: "[#{prefix}] #{sender_name}: #{message}",
        html: "<span class='channel-message'><span class='channel-name'>[#{prefix}]</span> <span class='sender'>#{sender_name}:</span> #{message}</span>"
      }

      # Send to all online members
      clan.active_members.eager(:character).all.each do |gm|
        char = gm.character
        instance = char&.primary_instance
        next unless instance&.online
        next if instance.id == sender_instance.id # Don't send to sender

        BroadcastService.to_character(instance, formatted, type: :channel)
      end

      success(message: "[#{prefix}] You: #{message}")
    end

    # ========================================
    # Clan Memos
    # ========================================

    def send_clan_memo(clan, sender, subject:, body:)
      membership = clan.membership_for(sender)
      return error('You are not a member of this clan') unless membership

      # Use display_name_for which handles default Greek letters
      sender_name = if clan.secret?
                      membership.display_name_for
                    else
                      sender.full_name
                    end

      # Create a memo for each member (except sender)
      memos_created = 0
      clan.active_members.each do |gm|
        next if gm.character_id == sender.id

        Memo.create(
          sender_id: sender.id,
          recipient_id: gm.character_id,
          subject: "[#{clan.display_name}] #{subject}",
          content: body
        )
        memos_created += 1
      end

      success(
        count: memos_created,
        message: "Memo sent to #{memos_created} clan member#{'s' unless memos_created == 1}."
      )
    end

    private

    def success(data = {})
      { success: true }.merge(data)
    end

    def error(message)
      { success: false, error: message }
    end
  end
end
