# frozen_string_literal: true

module Commands
  module Clothing
    class Dress < Commands::Base::Command
      command_name 'dress'
      category :clothing
      help_text 'Dress another character with clothing (requires their consent)'
      usage 'dress <character> with <item>'
      examples 'dress Bob with jacket', 'dress Alice with hat'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]
        return error_result("Dress whom? Use: dress <character> with <item>") if blank?(text)

        # Parse "dress <target> with <item>"
        match = text.match(/\A(.+?)\s+with\s+(.+)\z/i)
        unless match
          return error_result("Dress #{text} with what? Use: dress <character> with <item>")
        end

        target_name = match[1].strip
        item_name = match[2].strip

        # Check for dressing self
        if target_name.downcase == 'self' || target_name.downcase == 'me'
          return error_result("To dress yourself, just use 'wear #{item_name}'.")
        end

        # Find target in room
        target = find_character_in_room(target_name)
        return error_result("#{target_name} is not here.") unless target

        # Find item in our inventory
        item = find_item_in_inventory(item_name)
        return error_result("You don't have '#{item_name}'.") unless item
        return error_result("You can't dress someone in that.") unless item.clothing? || item.jewelry?

        # Check if target already has this item worn
        target_item = find_item_by_name(target.worn_items.all, item.name)
        if target_item
          return error_result("#{target.character.forename} is already wearing #{item.name}.")
        end

        # Check dress/style permission at user level
        error = check_dress_style_permission(target)
        return error if error

        # Check for permission using unified permission service
        has_permission = InteractionPermissionService.has_permission?(
          character_instance,
          target,
          'dress',
          room_scoped: true
        )

        if has_permission
          # Dress the target
          dress_target(target, item)
        else
          # Request permission via quickmenu
          request_permission(target, item)
        end
      end

      private

      def dress_target(target, item)
        # Transfer item to target, then use Item#wear! so piercing validation runs.
        previous_owner_id = item.character_instance_id
        previous_worn = item.worn?
        previous_piercing_position = item.piercing_position if item.respond_to?(:piercing_position)

        item.update(
          character_instance_id: target.id,
          worn: false,
          piercing_position: nil
        )

        wear_result = wear_item_on_target(item, target)
        unless wear_result == true
          rollback_updates = {
            character_instance_id: previous_owner_id,
            worn: previous_worn
          }
          rollback_updates[:piercing_position] = previous_piercing_position if item.respond_to?(:piercing_position)
          item.update(rollback_updates)
          return error_result("You can't dress #{target.character.forename} in #{item.name}: #{wear_result}")
        end

        broadcast_to_room(
          "#{character.full_name} dresses #{target.character.forename} in #{item.name}.",
          exclude_character: nil # Everyone sees this
        )

        success_result(
          "You dress #{target.character.forename} in #{item.name}.",
          type: :message,
          data: {
            action: 'dress',
            target_id: target.id,
            target_name: target.character.forename,
            item_id: item.id,
            item_name: item.name
          }
        )
      end

      def request_permission(target, item)
        # Create a quickmenu for the target to approve/deny
        interaction_id = SecureRandom.uuid

        quickmenu = {
          interaction_id: interaction_id,
          type: 'quickmenu',
          prompt: "#{character.full_name} wants to dress you in #{item.name}. Allow?",
          options: [
            { key: 'yes', label: 'Yes', description: 'Allow them to dress you' },
            { key: 'no', label: 'No', description: 'Decline' }
          ],
          context: {
            action: 'dress_consent',
            dresser_id: character_instance.id,
            item_id: item.id,
            room_id: character_instance.current_room_id
          },
          created_at: Time.now.iso8601
        }

        # Store interaction for target
        store_agent_interaction(target, interaction_id, quickmenu)

        # Also send via broadcast service if target is connected
        BroadcastService.to_character(target, {
          type: 'quickmenu',
          content: quickmenu
        })

        success_result(
          "You ask #{target.character.forename} for permission to dress them in #{item.name}.",
          type: :message,
          data: {
            action: 'dress',
            awaiting_consent: true,
            target_id: target.id,
            target_name: target.character.forename,
            item_id: item.id,
            item_name: item.name,
            interaction_id: interaction_id
          }
        )
      end

      def find_item_by_name(items, name)
        TargetResolverService.resolve(
          query: name,
          candidates: items,
          name_field: :name
        )
      end

      # Check dress/style permission at user level
      # @param target_instance [CharacterInstance]
      # @return [Hash, nil] Error result if blocked, nil if allowed
      def check_dress_style_permission(target_instance)
        actor_user = character.user
        target_user = target_instance.character&.user
        return nil unless target_user # No user = allowed

        unless UserPermission.dress_style_allowed?(actor_user, target_user)
          return error_result("#{target_instance.character.full_name} has blocked dress/style interactions from you.")
        end

        nil
      end

      def wear_item_on_target(item, target)
        return normalize_wear_result(item.wear!) unless item.piercing?

        positions = target.pierced_positions
        return "they don't have any piercing holes" if positions.empty?
        return 'they have multiple piercing holes; they must wear it manually with a position' if positions.length > 1

        normalize_wear_result(item.wear!(position: positions.first))
      end

      def normalize_wear_result(result)
        return true if result == true

        result.is_a?(String) ? result : 'it cannot be worn right now'
      end

      # Uses inherited find_item_in_inventory from base command
      # Uses inherited find_character_in_room from base command
    end
  end
end

Commands::Base::Registry.register(Commands::Clothing::Dress)
