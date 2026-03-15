# frozen_string_literal: true

module Commands
  module Inventory
    class Reskin < Commands::Base::Command
      command_name 'reskin'
      aliases 'restyle', 'redesign'
      category :inventory
      help_text 'Change the appearance of an item using a different pattern'
      usage 'reskin <item> [pattern name]'
      examples(
        'reskin sword',
        'reskin leather jacket to denim jacket'
      )

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]
        return error_result("Reskin what?\nUsage: reskin <item> [to <pattern>]") if blank?(text)

        # Parse: item [to pattern]
        if text.include?(' to ')
          parts = text.split(' to ', 2)
          item_name = parts[0].strip
          pattern_name = parts[1].strip
        else
          item_name = text.strip
          pattern_name = nil
        end

        # Find the item (must be stored)
        item = find_stored_item(item_name)
        unless item
          return error_result(
            "You don't have any stored items like '#{item_name}'.\n" \
            "Only stored items can be reskinned. Use 'store <item>' first."
          )
        end

        unless item.pattern
          return error_result("#{item.name} doesn't have a pattern to change.")
        end

        if pattern_name
          # Direct reskin to specific pattern
          reskin_to_pattern(item, pattern_name)
        else
          # Show available patterns
          show_available_patterns(item)
        end
      end

      private

      def find_stored_item(name)
        items = Item.stored_items_for(character_instance).all
        TargetResolverService.resolve(
          query: name,
          candidates: items,
          name_field: :name
        )
      end

      def find_compatible_patterns(item)
        current_pattern = item.pattern
        return [] unless current_pattern

        # Find patterns of the same unified object type (same category/type)
        Pattern.where(unified_object_type_id: current_pattern.unified_object_type_id)
               .exclude(id: current_pattern.id)
               .limit(20)
               .all
      end

      def show_available_patterns(item)
        patterns = find_compatible_patterns(item)

        if patterns.empty?
          return error_result("No alternative patterns available for #{item.name}.")
        end

        lines = ["Available patterns for #{item.name}:\n"]

        patterns.each_with_index do |pattern, idx|
          lines << "  #{idx + 1}. #{pattern.description}"
        end

        lines << "\nUse 'reskin #{item.name} to <pattern name>' to apply."

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'reskin_list',
            item_name: item.name,
            pattern_count: patterns.length
          }
        )
      end

      def reskin_to_pattern(item, pattern_name)
        patterns = find_compatible_patterns(item)
        pattern_name_lower = pattern_name.downcase

        # Find matching pattern
        target_pattern = patterns.find do |p|
          p.description.downcase.include?(pattern_name_lower)
        end

        unless target_pattern
          return error_result(
            "No compatible pattern matching '#{pattern_name}' found.\n" \
            "Use 'reskin #{item.name}' to see available options."
          )
        end

        old_name = item.name
        new_description = target_pattern.description

        # Update item
        item.update(
          pattern_id: target_pattern.id,
          name: new_description
        )

        success_result(
          "Reskinned #{old_name} to #{new_description}.",
          type: :message,
          data: {
            action: 'reskin',
            item_id: item.id,
            old_name: old_name,
            new_name: new_description,
            pattern_id: target_pattern.id
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Reskin)
