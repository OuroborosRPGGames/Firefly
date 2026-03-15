# frozen_string_literal: true

module Commands
  module Social
    class Permissions < Commands::Base::Command
      command_name 'permissions'
      aliases 'perms', 'prefs', 'consent', 'consents', 'block', 'unblock', 'unfriend'
      category :social
      help_text 'Manage permissions and consent settings'
      usage 'permissions [character|general|consent]'
      examples 'permissions', 'permissions Bob', 'permissions general', 'permissions consent'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:text]&.strip&.split(/\s+/) || []
        command_word = parsed_input[:command_word]&.downcase

        # Route based on alias used to invoke the command
        case command_word
        when 'block'
          return manage_blocks(args)
        when 'unblock'
          return manage_unblock(args)
        when 'unfriend'
          return manage_unfriend(args.join(' '))
        when 'consent', 'consents'
          return manage_consent(args)
        end

        if args.empty?
          return show_permissions_menu
        end

        case args[0].downcase
        when 'general'
          show_generic_permissions
        when 'blocks', 'block', 'blocked'
          manage_blocks(args[1..])
        when 'consent', 'consents', 'content'
          manage_consent(args[1..])
        when 'unfriend'
          manage_unfriend(args[1..].join(' '))
        when 'unblock'
          manage_unblock(args[1..])
        else
          # Treat as character name
          show_character_permissions(args.join(' '))
        end
      end

      private

      # ========== Main Menu ==========
      def show_permissions_menu
        options = [
          { key: 'general', label: 'General Settings', description: 'Default permissions for all players' },
          { key: 'blocks', label: 'Blocked Players', description: 'Manage who you have blocked' },
          { key: 'consent', label: 'Content Consent', description: 'Set which content types you consent to' }
        ]

        create_quickmenu(
          character_instance,
          'Permissions & Settings',
          options,
          context: { command: 'permissions' }
        )
      end

      # ========== General Permissions ==========
      def show_generic_permissions
        perm = UserPermission.generic_for(current_user)
        show_permission_form(perm, "Generic Permissions")
      end

      def show_character_permissions(target_name)
        target = find_player_character_by_name_globally(target_name)
        return error_result("Character '#{target_name}' not found.") unless target
        return error_result("Use 'permissions general' to edit your default settings.") if target.user_id == current_user.id

        target_user = target.user
        return error_result("Character '#{target_name}' is not a player character.") unless target_user

        perm = UserPermission.specific_for(current_user, target_user, display_character: target)
        show_permission_form(perm, "Permissions for #{target.full_name}")
      end

      def show_permission_form(perm, title)
        is_generic = perm.generic?

        fields = [
          {
            name: 'visibility',
            label: 'Where Visibility',
            type: 'select',
            default: perm.visibility || 'generic',
            options: build_options(is_generic, [
              { value: 'default', label: 'Default (follow my locatability)' },
              { value: 'never', label: 'Never see me in where' },
              { value: 'favorite', label: 'Favorite (see me in favorites mode)' },
              { value: 'always', label: 'Always see me' }
            ]),
            description: 'Controls who can see your location in the where list'
          },
          {
            name: 'ooc_messaging',
            label: 'OOC Messages',
            type: 'select',
            default: perm.ooc_messaging || 'generic',
            options: build_options(is_generic, [
              { value: 'yes', label: 'Allow' },
              { value: 'no', label: 'Block' },
              { value: 'ask', label: 'Require request' }
            ]),
            description: 'Controls who can send you private OOC messages'
          },
          {
            name: 'ic_messaging',
            label: 'IC Messages',
            type: 'select',
            default: perm.ic_messaging || 'generic',
            options: build_options(is_generic, [
              { value: 'yes', label: 'Allow' },
              { value: 'no', label: 'Block' }
            ]),
            description: 'Controls who can whisper/say_to you in character'
          },
          {
            name: 'lead_follow',
            label: 'Lead/Follow',
            type: 'select',
            default: perm.lead_follow || 'generic',
            options: build_options(is_generic, [
              { value: 'yes', label: 'Allow' },
              { value: 'no', label: 'Block' }
            ]),
            description: 'Controls who can lead or follow you'
          },
          {
            name: 'dress_style',
            label: 'Dress/Tattoo/Style',
            type: 'select',
            default: perm.dress_style || 'generic',
            options: build_options(is_generic, [
              { value: 'yes', label: 'Allow' },
              { value: 'no', label: 'Block' }
            ]),
            description: 'Controls who can dress, tattoo, or style you'
          },
          {
            name: 'channel_muting',
            label: 'Channel Messages',
            type: 'select',
            default: perm.channel_muting || 'generic',
            options: build_options(is_generic, [
              { value: 'yes', label: 'Show' },
              { value: 'muted', label: 'Mute' }
            ]),
            description: 'Controls whether you see their channel messages'
          },
          {
            name: 'group_preference',
            label: 'Group Finding',
            type: 'select',
            default: perm.group_preference || 'generic',
            options: build_options(is_generic, [
              { value: 'favored', label: 'Favored' },
              { value: 'neutral', label: 'Neutral' },
              { value: 'disfavored', label: 'Disfavored' }
            ]),
            description: 'Your preference for being matched with this player'
          }
        ]

        restrictions = ContentRestriction.where(is_active: true).order(:name).all
        restrictions.each do |restriction|
          fields << {
            name: "content_#{restriction.code}",
            label: restriction.name,
            type: 'select',
            default: perm.content_consent_for(restriction.code),
            options: build_options(is_generic, [
              { value: 'yes', label: 'Yes' },
              { value: 'no', label: 'No' }
            ]),
            description: restriction.description || "Consent to #{restriction.name} content"
          }
        end

        create_form(
          character_instance,
          title,
          fields,
          context: {
            command: 'permissions',
            permission_id: perm.id,
            character_id: character.id,
            instance_id: character_instance.id
          }
        )
      end

      def build_options(is_generic, specific_options)
        if is_generic
          specific_options
        else
          [{ value: 'generic', label: 'Use Generic Setting' }] + specific_options
        end
      end

      # ========== Blocks Management ==========
      def manage_blocks(args)
        args ||= []

        if args.empty?
          return list_blocks
        end

        target_name = args[0]
        block_type = args[1]&.downcase || 'all'

        target = find_character_globally(target_name)
        return error_result("No character found with that name.") unless target

        return error_result("You can't block yourself.") if target.id == character.id

        unless Relationship::BLOCK_TYPES.include?(block_type) || block_type == 'all'
          return error_result("Invalid block type. Use: dm, ooc, channels, interaction, perception, or all")
        end

        apply_block(target, block_type)
      end

      def manage_unblock(args)
        args ||= []

        if args.empty?
          return list_blocks
        end

        target_name = args[0]
        block_type = args[1]&.downcase

        target = find_character_globally(target_name)
        return error_result("No character found with that name.") unless target

        relationship = Relationship.between(character, target)
        unless relationship&.any_block?
          return error_result("#{target.forename} is not blocked.")
        end

        remove_block(target, relationship, block_type)
      end

      def list_blocks
        blocked = Relationship.blocked_by(character)

        if blocked.empty?
          return success_result(
            "You haven't blocked anyone.\n\nUse 'permissions blocks <name>' to block someone.",
            type: :message,
            data: { action: 'list_blocks', blocks: [] }
          )
        end

        lines = ["<h3>Blocked Players</h3>"]
        blocked.each do |rel|
          target = rel.target_character
          blocks = rel.active_blocks.join(', ')
          lines << "  #{target.forename}: #{blocks}"
        end

        lines << ""
        lines << "Commands:"
        lines << "  permissions blocks <name>        - Block all"
        lines << "  permissions blocks <name> <type> - Block specific type"
        lines << "  permissions unblock <name>       - Remove all blocks"
        lines << "Block types: dm, ooc, channels, interaction, perception, all"

        success_result(
          lines.join("\n"),
          type: :message,
          data: { action: 'list_blocks', blocks: blocked.map { |r| { name: r.target_character.forename, types: r.active_blocks } } }
        )
      end

      def apply_block(target, block_type)
        relationship = Relationship.find_or_create_between(character, target)

        if block_type == 'all'
          if relationship.active_blocks.length == 5
            return error_result("#{target.forename} is already fully blocked.")
          end
          relationship.block_type!('all')
          success_result(
            "You have fully blocked #{target.forename}. They cannot interact with you.",
            type: :message,
            data: { action: 'block', target_id: target.id, target_name: target.forename, block_type: 'all' }
          )
        else
          if relationship.blocked_for?(block_type)
            return error_result("#{target.forename} is already blocked for #{block_type}.")
          end
          relationship.block_type!(block_type)
          success_result(
            "You have blocked #{target.forename} for #{block_type}.",
            type: :message,
            data: { action: 'block', target_id: target.id, target_name: target.forename, block_type: block_type }
          )
        end
      end

      def remove_block(target, relationship, block_type)
        if block_type.nil? || block_type == 'all'
          relationship.clear_all_blocks!
          success_result(
            "You have unblocked #{target.forename}.",
            type: :message,
            data: { action: 'unblock', target_id: target.id, target_name: target.forename, block_type: 'all' }
          )
        else
          unless Relationship::BLOCK_TYPES.include?(block_type)
            return error_result("Invalid block type. Use: dm, ooc, channels, interaction, perception, or all")
          end

          unless relationship.blocked_for?(block_type)
            return error_result("#{target.forename} is not blocked for #{block_type}.")
          end

          relationship.unblock_type!(block_type)
          success_result(
            "You have unblocked #{target.forename} for #{block_type}.",
            type: :message,
            data: { action: 'unblock', target_id: target.id, target_name: target.forename, block_type: block_type }
          )
        end
      end

      # ========== Consent Management ==========
      def manage_consent(args)
        args ||= []

        if args.empty?
          return show_consent_form
        end

        case args[0].downcase
        when 'list'
          list_consents
        when 'set'
          set_consent(args[1], args[2])
        when 'info'
          show_restriction_info(args[1])
        when 'override'
          manage_override(args[1], args[2], args[3])
        when 'overrides'
          list_overrides
        when 'room'
          show_room_consents
        else
          set_consent(args[0], args[1] || 'toggle')
        end
      end

      def show_consent_form
        restrictions = ContentRestriction.where(is_active: true).order(:name).all
        generic_perm = UserPermission.generic_for(current_user)

        if restrictions.empty?
          return success_result("No content restrictions are configured.", type: :message)
        end

        fields = restrictions.map do |r|
          is_consenting = generic_perm.content_consent_for(r.code) == 'yes'

          {
            name: r.code,
            label: r.name,
            type: 'checkbox',
            default: is_consenting,
            description: r.description || "#{r.severity} content"
          }
        end

        create_form(
          character_instance,
          "Content Consent Settings",
          fields,
          context: {
            command: 'consent',
            character_id: character.id,
            instance_id: character_instance.id,
            restriction_codes: restrictions.map(&:code)
          }
        )
      end

      def list_consents
        restrictions = ContentRestriction.where(is_active: true).order(:name).all
        generic_perm = UserPermission.generic_for(current_user)

        if restrictions.empty?
          return success_result("No content restrictions are configured.", type: :message)
        end

        lines = ["Your content consent settings:"]

        restrictions.each do |r|
          status = generic_perm.content_consent_for(r.code) == 'yes' ? "[ON]" : "[OFF]"
          lines << "  #{r.code}: #{r.name} #{status}"
        end

        lines << ""
        lines << "Commands:"
        lines << "  permissions consent set <CODE> on/off  - Change setting"
        lines << "  permissions consent info <CODE>        - View details"
        lines << "  permissions consent override <char> <CODE> on/off - Per-player exception"

        success_result(lines.join("\n"), type: :message)
      end

      def set_consent(code, value)
        return error_result("Usage: permissions consent set <CODE> on/off") unless code

        restriction = ContentRestriction.first(code: code.upcase, is_active: true)
        return error_result("Unknown content type: #{code}. Use 'permissions consent' to see available types.") unless restriction

        generic_perm = UserPermission.generic_for(current_user)
        current_value = generic_perm.content_consent_for(restriction.code)
        consents = (generic_perm.content_consents || {}).dup

        if value.nil? || value == 'toggle'
          value = current_value == 'yes' ? 'off' : 'on'
        end

        case value.downcase
        when 'on', 'yes', 'true', '1'
          consents[restriction.code] = 'yes'
          generic_perm.update(content_consents: consents)
          success_result(
            "You now consent to #{restriction.name} content.",
            type: :message,
            data: { action: 'consent_set', code: restriction.code, value: true }
          )
        when 'off', 'no', 'false', '0'
          consents[restriction.code] = 'no'
          generic_perm.update(content_consents: consents)
          success_result(
            "You have revoked consent for #{restriction.name} content.",
            type: :message,
            data: { action: 'consent_set', code: restriction.code, value: false }
          )
        else
          error_result("Invalid value. Use 'on' or 'off'.")
        end
      end

      def show_restriction_info(code)
        return error_result("Usage: permissions consent info <CODE>") unless code

        restriction = ContentRestriction.first(code: code.upcase, is_active: true)
        return error_result("Unknown content type: #{code}") unless restriction

        generic_perm = UserPermission.generic_for(current_user)
        consenting = generic_perm.content_consent_for(restriction.code) == 'yes'
        your_status = consenting ? "You consent to this content." : "You do NOT consent to this content."

        lines = [
          "#{restriction.name} (#{restriction.code})",
          "Severity: #{restriction.severity}",
          "Description: #{restriction.description || 'No description available'}",
          "Requires mutual consent: #{restriction.mutual? ? 'Yes' : 'No'}",
          "",
          your_status
        ]

        success_result(lines.join("\n"), type: :message)
      end

      def manage_override(target_name, code, value)
        return error_result("Usage: permissions consent override <character> <CODE> on/off") unless target_name && code

        target = find_player_character_by_name_globally(target_name)
        return error_result("Character not found: #{target_name}") unless target
        return error_result("You can't set an override for yourself.") if target.id == character.id

        restriction = ContentRestriction.first(code: code.upcase, is_active: true)
        return error_result("Unknown content type: #{code}") unless restriction

        target_user = target.user
        return error_result("Character not found: #{target_name}") unless target_user

        perm = UserPermission.specific_for(current_user, target_user, display_character: target)
        consents = (perm.content_consents || {}).dup

        if value.nil?
          value = perm.content_consent_for(restriction.code) == 'yes' ? 'off' : 'on'
        end

        case value.downcase
        when 'on', 'yes', 'true', '1'
          consents[restriction.code] = 'yes'
          perm.update(content_consents: consents)
          success_result(
            "You now allow #{restriction.name} content specifically with #{target.forename}.",
            type: :message,
            data: { action: 'consent_override', target_id: target.id, code: restriction.code, value: true }
          )
        when 'off', 'no', 'false', '0'
          consents.delete(restriction.code)
          perm.update(content_consents: consents)
          success_result(
            "You have revoked the #{restriction.name} override for #{target.forename}.",
            type: :message,
            data: { action: 'consent_override', target_id: target.id, code: restriction.code, value: false }
          )
        else
          error_result("Invalid value. Use 'on' or 'off'.")
        end
      end

      def list_overrides
        overrides = UserPermission.all_specific_for(current_user)
                                  .all
                                  .select do |perm|
                                    next false unless perm.target_user
                                    (perm.content_consents || {}).values.any? { |value| value == 'yes' }
                                  end

        if overrides.empty?
          return success_result("You have no per-player content overrides set.", type: :message)
        end

        by_target = overrides.group_by(&:display_character)

        lines = ["Your per-player content overrides:"]
        by_target.each do |target, target_overrides|
          codes = target_overrides.flat_map do |perm|
            (perm.content_consents || {})
              .select { |_code, value| value == 'yes' }
              .keys
          end.uniq.sort
          target_name = target&.forename || target_overrides.first.target_user.username
          lines << "  #{target_name}: #{codes.join(', ')}"
        end

        lines << ""
        lines << "Use 'permissions consent override <character> <CODE> off' to remove."

        success_result(lines.join("\n"), type: :message)
      end

      def show_room_consents
        room = character_instance.current_room

        if ContentConsentService.display_ready?(room)
          info = ContentConsentService.consent_display_for_room(room)

          if info[:allowed_content].empty?
            return success_result(
              "No content types are mutually consented to by all players in this room.",
              type: :message
            )
          end

          restrictions = ContentRestriction.where(code: info[:allowed_content]).all
          names = restrictions.map(&:name).sort.join(', ')

          success_result(
            "All players in this room consent to: #{names}",
            type: :message,
            data: { action: 'room_consents', allowed: info[:allowed_content] }
          )
        else
          remaining = ContentConsentService.time_until_display(room)
          minutes = (remaining / 60.0).ceil

          success_result(
            "Room content information will be available after #{minutes} more minute(s) of stable occupancy.",
            type: :message
          )
        end
      end

      # ========== Unfriend Management ==========
      def manage_unfriend(target_name)
        if target_name.nil? || target_name.empty?
          return error_result("Unfriend whom? Use: permissions unfriend <character>")
        end

        target = find_character_globally(target_name)
        return error_result("No character found with that name.") unless target

        return error_result("You can't unfriend yourself.") if target.id == character.id

        relationship = Relationship.between(character, target)
        return error_result("You haven't interacted with #{target.forename} yet.") unless relationship

        if relationship.any_block?
          return error_result("#{target.forename} has blocks set. Use 'permissions unblock #{target.forename}' first.")
        end

        toggle_unfriend(relationship, target)
      end

      def toggle_unfriend(relationship, target)
        if relationship.unfriended?
          relationship.refriend!
          success_result(
            "You have restored your friendship with #{target.forename}.",
            type: :message,
            data: { action: 'refriend', target_id: target.id, target_name: target.forename }
          )
        else
          relationship.unfriend!
          success_result(
            "You have unfriended #{target.forename}.",
            type: :message,
            data: { action: 'unfriend', target_id: target.id, target_name: target.forename }
          )
        end
      end

      def current_user
        character.user
      end

      def find_player_character_by_name_globally(name, limit: 500)
        return nil if blank?(name)

        normalized = name.to_s.downcase.strip
        exact = Character.where(is_npc: false).where(Sequel.ilike(:forename, normalized)).first
        return exact if exact

        candidates = Character.where(is_npc: false).limit(limit).all
        TargetResolverService.resolve_character(
          query: normalized,
          candidates: candidates,
          forename_field: :forename,
          full_name_method: :full_name
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Social::Permissions)
