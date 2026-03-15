# frozen_string_literal: true

module Commands
  module Clothing
    class Outfit < Commands::Base::Command
      command_name 'outfit'
      aliases 'outfits'
      category :clothing
      help_text 'Manage your saved outfits. Outfits have a class that determines what gets removed when worn.'
      usage 'outfit [list|save|wear|delete] [name] [class]'
      examples(
        'outfit' => 'List all saved outfits',
        'outfit list' => 'List all saved outfits',
        'outfit save Casual' => 'Save current outfit as "Casual" (full class by default)',
        'outfit save Formal top' => 'Save current outfit as "Formal" with class "top"',
        'outfit wear Casual' => 'Change into the "Casual" outfit',
        'outfit delete Old' => 'Delete the "Old" outfit'
      )

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args]
        subcommand = args.first&.downcase

        case subcommand
        when 'save'
          save_outfit(args[1..].join(' '))
        when 'wear'
          wear_outfit(args[1..].join(' '))
        when 'delete', 'remove'
          delete_outfit(args[1..].join(' '))
        when 'list', nil
          list_outfits
        else
          # Treat as outfit name to wear if it looks like one
          if ::Outfit.first(character_instance_id: character_instance.id, name: subcommand)
            wear_outfit(args.join(' '))
          else
            list_outfits
          end
        end
      end

      private

      def list_outfits
        outfits = ::Outfit.where(character_instance_id: character_instance.id)
                          .eager(:outfit_items)
                          .order(:name)
                          .all

        if outfits.empty?
          return success_result(
            "You have no saved outfits.\nUse 'outfit save <name>' to save your current look.",
            type: :message,
            data: { action: 'list', outfits: [] }
          )
        end

        # Build output with pre-loaded counts to avoid N+1 queries
        outfit_data = outfits.map do |outfit|
          {
            name: outfit.name,
            item_count: outfit.outfit_items.length,
            description: outfit.description,
            outfit_class: outfit.outfit_class
          }
        end

        lines = ["<h3>Your Outfits</h3>", ""]
        outfit_data.each do |data|
          class_label = data[:outfit_class] == 'full' ? '' : " [#{data[:outfit_class]}]"
          desc = data[:description] ? " - #{data[:description]}" : ""
          lines << "  #{data[:name]}#{class_label} (#{data[:item_count]} items)#{desc}"
        end
        lines << ""
        lines << "Classes: full (removes all), top, bottoms, overwear, underwear, jewelry, accessories, other (removes none)"
        lines << "Use 'outfit wear <name>' to change into an outfit."

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'list',
            outfits: outfit_data.map { |d| { name: d[:name], item_count: d[:item_count], outfit_class: d[:outfit_class] } }
          }
        )
      end

      def save_outfit(args_string)
        # Parse name and optional class from args
        # Format: "name [class]" where class is one of the valid outfit classes
        parts = args_string.to_s.strip.split(/\s+/)
        return error_result("Please provide a name for the outfit. Example: outfit save Casual") if parts.empty?

        # Check if last part is a valid class
        outfit_class = 'full'
        if parts.length >= 2 && ::Outfit::CLASSES.include?(parts.last.downcase)
          outfit_class = parts.pop.downcase
        end

        name = parts.join(' ')
        return error_result("Please provide a name for the outfit. Example: outfit save Casual") if blank?(name)

        worn_items = character_instance.worn_items.all
        return error_result("You aren't wearing anything to save.") if worn_items.empty?

        # Find or create outfit
        outfit = ::Outfit.first(character_instance_id: character_instance.id, name: name)
        is_update = !outfit.nil?

        if outfit
          # Update existing - clear old items and update class
          outfit.outfit_items_dataset.delete
          outfit.update(outfit_class: outfit_class)
        else
          # Create new
          outfit = ::Outfit.create(
            character_instance_id: character_instance.id,
            name: name,
            outfit_class: outfit_class,
            description: "Saved on #{Time.now.strftime('%Y-%m-%d')}"
          )
        end

        # Save current worn items
        worn_items.each do |item|
          OutfitItem.create(
            outfit_id: outfit.id,
            pattern_id: item.pattern_id,
            display_order: item.display_order || 0
          )
        end

        item_names = worn_items.map(&:name).join(', ')
        action_word = is_update ? 'updated' : 'saved'
        class_note = outfit_class == 'full' ? '' : " (class: #{outfit_class})"

        success_result(
          "Outfit '#{name}'#{class_note} #{action_word} with #{worn_items.count} items: #{item_names}.",
          type: :message,
          data: {
            action: 'save',
            outfit_name: name,
            outfit_class: outfit_class,
            item_count: worn_items.count,
            updated: is_update
          }
        )
      end

      def wear_outfit(name)
        name = name&.strip
        return error_result("Which outfit do you want to wear? Use 'outfit list' to see your outfits.") if blank?(name)

        outfit = find_outfit(name)
        return error_result("You don't have an outfit called '#{name}'.") unless outfit

        # Determine what will be removed based on outfit class
        items_to_remove = outfit.items_to_remove_for_class(character_instance)
        items_to_remove.each(&:remove!)
        removed_count = items_to_remove.count

        # Apply outfit
        applied_count = 0
        skipped_missing_patterns = 0
        failed_items = []
        outfit.outfit_items.each do |oi|
          unless oi.pattern
            skipped_missing_patterns += 1
            next
          end

          # Create new item from pattern
          item = oi.pattern.instantiate(character_instance: character_instance)
          item.update(display_order: oi.display_order)

          wear_result = wear_outfit_item(item)
          unless wear_result == true
            failed_items << { name: item.name, reason: wear_result }
            item.destroy
            next
          end

          applied_count += 1
        end

        if applied_count.zero? && outfit.outfit_items.count.zero?
          removed_note = removed_count.positive? ? " Removed #{removed_count} items." : ""
          return success_result(
            "You change into the '#{name}' outfit. (Empty outfit - no new items added!)#{removed_note}",
            type: :message,
            data: { action: 'wear', outfit_name: name, item_count: 0, removed_count: removed_count }
          )
        elsif applied_count.zero? && skipped_missing_patterns == outfit.outfit_items.count
          return error_result(
            "Couldn't apply outfit '#{name}' - the item patterns no longer exist."
          )
        elsif applied_count.zero? && failed_items.any?
          failure_details = failed_items.map { |f| "#{f[:name]}: #{f[:reason]}" }.join('; ')
          return error_result(
            "Couldn't apply outfit '#{name}' - no items could be worn. #{failure_details}"
          )
        end

        broadcast_to_room(
          "#{character.full_name} changes into a different outfit.",
          exclude_character: character_instance
        )

        # Build message based on what was removed
        class_note = case outfit.outfit_class
                     when 'full' then ''
                     when 'other' then ' (keeping existing items)'
                     else " (replacing #{outfit.outfit_class} items)"
                     end

        if failed_items.any?
          failure_details = failed_items.map { |f| "#{f[:name]}: #{f[:reason]}" }.join('; ')
          message = "You change into the '#{name}' outfit#{class_note} (#{applied_count} items).\n(Could not wear: #{failure_details})"
        else
          message = "You change into the '#{name}' outfit#{class_note} (#{applied_count} items)."
        end

        success_result(
          message,
          type: :message,
          data: {
            action: 'wear',
            outfit_name: name,
            outfit_class: outfit.outfit_class,
            item_count: applied_count,
            removed_count: removed_count,
            failed_items: failed_items
          }
        )
      end

      def delete_outfit(name)
        name = name&.strip
        return error_result("Which outfit do you want to delete? Use 'outfit list' to see your outfits.") if blank?(name)

        outfit = find_outfit(name)
        return error_result("You don't have an outfit called '#{name}'.") unless outfit

        outfit.destroy

        success_result(
          "Outfit '#{name}' deleted.",
          type: :message,
          data: { action: 'delete', outfit_name: name }
        )
      end

      def find_outfit(name)
        # Exact match first
        outfit = ::Outfit.first(character_instance_id: character_instance.id, name: name)
        return outfit if outfit

        # Case-insensitive match
        ::Outfit.where(character_instance_id: character_instance.id)
                .all
                .find { |o| o.name.downcase == name.downcase }
      end

      def wear_outfit_item(item)
        return normalize_wear_result(item.wear!) unless item.piercing?

        positions = character_instance.pierced_positions
        return "you don't have any piercing holes for #{item.name}" if positions.empty?
        return "multiple piercing holes available for #{item.name}; wear it manually with a position" if positions.length > 1

        normalize_wear_result(item.wear!(position: positions.first))
      end

      def normalize_wear_result(result)
        return true if result == true

        result.is_a?(String) ? result : 'it cannot be worn right now'
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Clothing::Outfit)
