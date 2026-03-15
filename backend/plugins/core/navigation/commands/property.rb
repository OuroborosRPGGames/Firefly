# frozen_string_literal: true

module Commands
  module Navigation
    class Property < Commands::Base::Command
      command_name 'property'
      aliases 'properties', 'myproperties', 'owned', 'access', 'access list'
      category :building
      help_text 'Manage your properties, access permissions, and locks'
      usage 'property [list|access|lock|unlock|grant <name>|revoke <name>]'
      examples 'property', 'property list', 'property access', 'property lock', 'property grant Bob'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args] || []
        text = parsed_input[:text]&.strip || ''

        # Detect alias used
        called_as_access = text.match?(/^access(\s|$)/i)

        # Strip command prefix
        text = text.sub(/^(property|properties|myproperties|owned|access)\s*/i, '').strip

        # If called as 'access' without args, show access list
        if called_as_access && text.empty?
          return show_access_list
        end

        # If called as 'access list', show access list
        if called_as_access && text.match?(/^list$/i)
          return show_access_list
        end

        # No args - show property menu
        if args.empty? && text.empty?
          return show_property_menu
        end

        action = args.first&.to_s&.downcase || text.split.first&.downcase

        case action
        when 'list', 'all'
          show_property_list
        when 'access'
          show_access_list
        when 'lock'
          sub_action = args[1]&.downcase || text.split[1]&.downcase
          if sub_action == 'doors'
            lock_doors
          else
            lock_room
          end
        when 'unlock'
          sub_action = args[1]&.downcase || text.split[1]&.downcase
          if sub_action == 'doors'
            unlock_doors
          else
            unlock_room
          end
        when 'grant'
          args_name = args[1..].join(' ').strip
          target_name = args_name.empty? ? text.sub(/^grant\s*/i, '').strip : args_name
          grant_access(target_name)
        when 'revoke', 'remove'
          args_name = args[1..].join(' ').strip
          target_name = args_name.empty? ? text.sub(/^(revoke|remove)\s*/i, '').strip : args_name
          revoke_access(target_name)
        else
          error_result("Unknown action '#{action}'. Use: property list, property access, property lock, property grant <name>")
        end
      end

      private

      def show_property_menu
        owned_rooms = Room.where(owner_id: character.id).all
        room = location
        is_owner = room&.outer_room&.owned_by?(character)

        options = [
          { key: 'list', label: 'My Properties', description: "View all #{owned_rooms.count} properties you own" },
          { key: 'access', label: 'Access List', description: 'View who has access to what' }
        ]

        if is_owner
          options << { key: 'lock', label: 'Lock Room', description: 'Lock doors in this room' }
          options << { key: 'unlock', label: 'Unlock Room', description: 'Unlock doors in this room' }
          options << { key: 'lock_doors', label: 'Lock Property', description: 'Lock property to visitors' }
          options << { key: 'unlock_doors', label: 'Unlock Property', description: 'Open property to visitors' }
          options << { key: 'grant', label: 'Grant Access', description: 'Give someone access' }
          options << { key: 'revoke', label: 'Revoke Access', description: 'Remove someone\'s access' }
        end

        create_quickmenu(
          character_instance,
          'Property Management',
          options,
          context: { command: 'property' }
        )
      end

      # ========== Property List ==========

      def show_property_list
        owned_rooms = Room.where(owner_id: character.id).order(:name).all

        if owned_rooms.empty?
          return success_result(
            "You don't own any properties.",
            type: :message,
            data: { action: 'properties', properties: [] }
          )
        end

        rooms_by_location = owned_rooms.group_by { |r| r.location&.name || 'Unknown' }

        lines = ["<h3>Your Properties</h3>"]
        rooms_by_location.each do |location_name, rooms|
          lines << "\n#{location_name}:"
          rooms.each do |room|
            locked_status = room.locked? ? ' [Locked]' : ''
            lines << "  - #{room.name}#{locked_status}"
          end
        end

        properties_data = owned_rooms.map do |room|
          { id: room.id, name: room.name, location: room.location&.name, locked: room.locked? }
        end

        success_result(
          lines.join("\n"),
          type: :message,
          data: { action: 'properties', count: owned_rooms.size, properties: properties_data }
        )
      end

      # ========== Access List ==========

      def show_access_list
        lines = []

        owned_rooms = Room.where(owner_id: character.id).all

        if owned_rooms.any?
          lines << "<h3>Your Properties</h3>"
          owned_rooms.each do |room|
            lines << "\n#{room.name}:"

            unlocks = RoomUnlock.where(room_id: room.id)
                                .where { (expires_at =~ nil) | (expires_at > Sequel::CURRENT_TIMESTAMP) }
                                .all

            public_unlocks = unlocks.select(&:public_unlock?)
            character_unlocks = unlocks.reject(&:public_unlock?)

            if public_unlocks.any?
              public_unlock = public_unlocks.first
              if public_unlock.permanent?
                lines << "  Public: Open to all"
              else
                lines << "  Public: Open until #{public_unlock.expires_at.strftime('%H:%M')}"
              end
            else
              lines << "  Public: Locked"
            end

            if character_unlocks.any?
              lines << "  Granted access:"
              character_unlocks.each do |unlock|
                char = unlock.character
                next unless char

                status = unlock.permanent? ? '(permanent)' : "(until #{unlock.expires_at.strftime('%H:%M')})"
                lines << "    - #{char.full_name} #{status}"
              end
            end
          end
        else
          lines << "You don't own any properties."
        end

        lines << "<h3>Properties You Can Access</h3>"

        my_unlocks = RoomUnlock.where(character_id: character.id)
                               .where { (expires_at =~ nil) | (expires_at > Sequel::CURRENT_TIMESTAMP) }
                               .all

        if my_unlocks.any?
          my_unlocks.each do |unlock|
            room = unlock.room
            next unless room

            owner = room.owner
            owner_name = owner ? owner.full_name : 'Unknown'
            status = unlock.permanent? ? '(permanent)' : "(until #{unlock.expires_at.strftime('%H:%M')})"
            lines << "  - #{room.name} (owned by #{owner_name}) #{status}"
          end
        else
          lines << "  None"
        end

        success_result(
          lines.join("\n"),
          type: :message,
          data: { action: 'access_list', owned_properties: owned_rooms.count, accessible_properties: my_unlocks.count }
        )
      end

      # ========== Lock/Unlock ==========

      def lock_room
        room = location
        error = require_property_ownership
        return error if error

        # Find door features in this room
        doors = room.room_features_dataset.where(feature_type: %w[door gate hatch])
        door_count = doors.count
        return error_result('There are no doors to lock here.') if door_count.zero?
        connected_room_ids = doors.exclude(connected_room_id: nil).select_map(:connected_room_id).uniq

        # Close and lock all doors
        doors.update(open_state: 'closed')
        invalidate_door_caches_for_room!(room.id, connected_room_ids)

        broadcast_to_room("#{character.full_name} locks the door.", exclude_character: character_instance, type: :emote)
        success_result('You lock the door.', type: :message, data: { action: 'lock_room', room_id: room.id, doors_locked: door_count })
      end

      def unlock_room
        room = location
        error = require_property_ownership
        return error if error

        # Find door features in this room
        doors = room.room_features_dataset.where(feature_type: %w[door gate hatch])
        door_count = doors.count
        return error_result('There are no doors to unlock here.') if door_count.zero?
        connected_room_ids = doors.exclude(connected_room_id: nil).select_map(:connected_room_id).uniq

        # Open all doors
        doors.update(open_state: 'open')
        invalidate_door_caches_for_room!(room.id, connected_room_ids)

        broadcast_to_room("#{character.full_name} unlocks the door.", exclude_character: character_instance, type: :emote)
        success_result('You unlock the door.', type: :message, data: { action: 'unlock_room', room_id: room.id, doors_unlocked: door_count })
      end

      def lock_doors
        room = location
        outer_room = room.outer_room

        error = require_property_ownership
        return error if error

        outer_room.lock_doors!
        success_result('You lock the doors.', type: :message, data: { action: 'lock_doors', room_id: outer_room.id })
      end

      def unlock_doors
        room = location
        outer_room = room.outer_room

        error = require_property_ownership
        return error if error

        outer_room.unlock_doors!
        success_result('You unlock the doors.', type: :message, data: { action: 'unlock_doors', room_id: outer_room.id })
      end

      # ========== Grant/Revoke Access ==========

      def grant_access(target_name)
        if target_name.nil? || target_name.empty?
          return show_grant_menu
        end

        # Remove "to" prefix
        target_name = target_name.sub(/^to\s+/i, '')

        room = location
        outer_room = room.outer_room

        error = require_property_ownership
        return error if error

        target = find_character_globally(target_name)
        return error_result("No character found named '#{target_name}'.") unless target

        return error_result("You already have access to your own property!") if target.id == character.id

        existing = RoomUnlock.where(room_id: outer_room.id, character_id: target.id)
                             .where { (expires_at =~ nil) | (expires_at > Sequel::CURRENT_TIMESTAMP) }
                             .first
        return error_result("#{target.full_name} already has access to this property.") if existing

        outer_room.grant_access!(target, permanent: true)

        success_result(
          "You grant #{target.full_name} access to this property.",
          type: :message,
          data: { action: 'grant_access', room_id: outer_room.id, target_id: target.id, target_name: target.full_name }
        )
      end

      def revoke_access(target_name)
        if target_name.nil? || target_name.empty?
          return show_revoke_menu
        end

        # Remove "from" prefix
        target_name = target_name.sub(/^from\s+/i, '')

        room = location
        outer_room = room.outer_room

        error = require_property_ownership
        return error if error

        target = find_character_globally(target_name)
        return error_result("No character found named '#{target_name}'.") unless target

        return error_result("You can't revoke your own access to your property!") if target.id == character.id

        existing = RoomUnlock.where(room_id: outer_room.id, character_id: target.id).first
        return error_result("#{target.full_name} doesn't have access to this property.") unless existing

        outer_room.revoke_access!(target)

        success_result(
          "You revoke #{target.full_name}'s access to this property.",
          type: :message,
          data: { action: 'revoke_access', room_id: outer_room.id, target_id: target.id, target_name: target.full_name }
        )
      end

      def show_grant_menu
        # Show characters in room as options
        others = characters_in_room.reject { |ci| ci.id == character_instance.id }

        if others.empty?
          return success_result(
            "No one here to grant access to. Type: property grant <name>",
            type: :message
          )
        end

        options = others.each_with_index.map do |ci, idx|
          { key: (idx + 1).to_s, label: ci.character.full_name, description: ci.character.short_desc || '' }
        end
        options << { key: 'q', label: 'Cancel', description: 'Close menu' }

        char_data = others.map { |ci| { id: ci.character.id, name: ci.character.forename } }

        create_quickmenu(
          character_instance,
          'Grant access to whom?',
          options,
          context: { command: 'property_grant', characters: char_data }
        )
      end

      def show_revoke_menu
        room = location
        outer_room = room.outer_room

        # Show characters with access as options
        unlocks = RoomUnlock.where(room_id: outer_room.id)
                            .exclude(character_id: nil)
                            .exclude(character_id: character.id)
                            .where { (expires_at =~ nil) | (expires_at > Sequel::CURRENT_TIMESTAMP) }
                            .all

        if unlocks.empty?
          return success_result(
            "No one has access to revoke. Type: property revoke <name>",
            type: :message
          )
        end

        options = unlocks.each_with_index.map do |unlock, idx|
          char = unlock.character
          next unless char

          { key: (idx + 1).to_s, label: char.full_name, description: unlock.permanent? ? 'permanent' : "until #{unlock.expires_at.strftime('%H:%M')}" }
        end.compact
        options << { key: 'q', label: 'Cancel', description: 'Close menu' }

        char_data = unlocks.filter_map { |u| u.character && { id: u.character.id, name: u.character.forename } }

        create_quickmenu(
          character_instance,
          'Revoke access from whom?',
          options,
          context: { command: 'property_revoke', characters: char_data }
        )
      end

      def characters_in_room
        room = character_instance.current_room
        room.characters_here(character_instance.reality_id, viewer: character_instance)
            .exclude(id: character_instance.id)
            .all
      rescue StandardError => e
        warn "[Property] Error fetching characters: #{e.message}"
        []
      end

      def invalidate_door_caches_for_room!(room_id, connected_room_ids = [])
        RoomExitCacheService.invalidate_door_state!(room_id)
        connected_room_ids.each do |connected_id|
          RoomExitCacheService.invalidate_door_state!(connected_id)
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Property)
