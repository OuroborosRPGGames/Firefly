# frozen_string_literal: true

module Commands
  module Building
    # Unified design command for creating game objects.
    # Replaces: create_item.rb
    class Design < Commands::Base::Command
      command_name 'design'
      aliases 'create item', 'createitem', 'spawn item', 'item create'
      category :building
      help_text 'Staff command to create physical items and objects in the game world (weapons, armor, clothing, furniture, decorations)'
      usage 'design [item]'
      examples(
        'design',
        'design item'
      )

      ITEM_TYPES = [
        { value: 'generic', label: 'Generic Item' },
        { value: 'weapon', label: 'Weapon' },
        { value: 'armor', label: 'Armor' },
        { value: 'clothing', label: 'Clothing' },
        { value: 'jewelry', label: 'Jewelry' },
        { value: 'container', label: 'Container' },
        { value: 'food', label: 'Food' },
        { value: 'drink', label: 'Drink' },
        { value: 'key', label: 'Key' },
        { value: 'furniture', label: 'Furniture' },
        { value: 'decoration', label: 'Decoration' }
      ].freeze

      CONDITIONS = [
        { value: 'excellent', label: 'Excellent' },
        { value: 'good', label: 'Good' },
        { value: 'fair', label: 'Fair' },
        { value: 'poor', label: 'Poor' },
        { value: 'broken', label: 'Broken' }
      ].freeze

      protected

      def perform_command(parsed_input)
        error = require_building_permission(error_message: 'Design commands require staff access.')
        return error if error

        args = (parsed_input[:text] || '').strip.split(/\s+/)
        subcommand = args.shift&.downcase

        case subcommand
        when nil, '', 'help'
          show_design_menu
        when 'item', 'object'
          handle_design_item(args.join(' '))
        else
          error_result("Unknown design subcommand: #{subcommand}\nUse 'design' for help.")
        end
      end

      # Handle form submission
      def handle_form_response(form_data, context)
        case context['stage']
        when 'item_form'
          process_item_form(form_data, context)
        else
          error_result('Unknown form context.')
        end
      end

      private

      # ========================================
      # Design Menu
      # ========================================

      def show_design_menu
        options = [
          { key: '1', label: 'Item', description: 'Create a new item' },
          { key: 'q', label: 'Cancel', description: 'Close menu' }
        ]

        create_quickmenu(
          character_instance,
          'Design Menu - Create new game objects:',
          options,
          context: {
            command: 'design',
            stage: 'select_type',
            room_id: location.id
          }
        )
      end

      # ========================================
      # Item Creation (from create_item.rb)
      # ========================================

      def handle_design_item(_args)
        show_item_creator_form
      end

      def show_item_creator_form
        fields = [
          {
            name: 'name',
            label: 'Item Name',
            type: 'text',
            required: true,
            placeholder: 'e.g., Rusty Sword, Golden Ring, Leather Jacket'
          },
          {
            name: 'description',
            label: 'Description',
            type: 'textarea',
            required: false,
            placeholder: 'A detailed description of the item'
          },
          {
            name: 'item_type',
            label: 'Item Type',
            type: 'select',
            required: true,
            default: 'generic',
            options: ITEM_TYPES
          },
          {
            name: 'quantity',
            label: 'Quantity',
            type: 'number',
            required: false,
            default: 1,
            min: 1,
            max: 999
          },
          {
            name: 'condition',
            label: 'Condition',
            type: 'select',
            required: false,
            default: 'good',
            options: CONDITIONS
          },
          {
            name: 'image_url',
            label: 'Image URL (optional)',
            type: 'text',
            required: false,
            placeholder: 'https://example.com/item.jpg'
          }
        ]

        create_form(
          character_instance,
          'Design Item',
          fields,
          context: {
            command: 'design',
            stage: 'item_form',
            room_id: location.id
          }
        )
      end

      def process_item_form(form_data, context)
        room = Room[context['room_id']]
        unless room
          return error_result('Room no longer exists.')
        end

        # Validate name
        name = form_data['name']&.strip
        if name.nil? || name.empty?
          return error_result('Item name is required.')
        end

        if name.length > 200
          return error_result('Item name must be 200 characters or less.')
        end

        # Validate description
        description = form_data['description']&.strip || ''
        if description.length > 2000
          return error_result('Description must be 2000 characters or less.')
        end

        # Validate quantity
        quantity = (form_data['quantity'] || '1').to_i
        quantity = 1 if quantity < 1
        quantity = 999 if quantity > 999

        # Validate condition
        condition = form_data['condition']&.strip || 'good'
        unless %w[excellent good fair poor broken].include?(condition)
          condition = 'good'
        end

        # Parse item type for properties
        item_type = form_data['item_type']&.strip || 'generic'
        properties = build_item_properties(item_type, form_data)

        # Validate image URL
        image_url = form_data['image_url']&.strip
        if image_url && !image_url.empty?
          unless image_url.match?(%r{^https?://})
            return error_result('Image URL must start with http:// or https://')
          end
          if image_url.length > 2048
            return error_result('Image URL too long (max 2048 characters).')
          end
        else
          image_url = nil
        end

        # Create the item
        item = Item.create(
          name: name,
          description: description.empty? ? nil : description,
          room_id: room.id,
          quantity: quantity,
          condition: condition,
          properties: properties,
          image_url: image_url,
          item_type: item_type,
          is_clothing: item_type == 'clothing',
          is_jewelry: item_type == 'jewelry'
        )

        # Broadcast creation
        BroadcastService.to_room(
          room.id,
          "#{character.full_name} creates #{item.name}.",
          exclude: [character_instance.id],
          type: :message
        )

        success_result(
          "Created: #{item.name}#{quantity > 1 ? " (x#{quantity})" : ''}",
          type: :message,
          data: {
            action: 'design_item',
            item_id: item.id,
            item_name: item.name,
            item_type: item_type,
            room_id: room.id
          }
        )
      end

      def build_item_properties(item_type, _form_data)
        properties = {}

        case item_type
        when 'weapon'
          properties['damage_dice'] = '1d6'
          properties['weapon_type'] = 'melee'
        when 'armor'
          properties['armor_value'] = 1
          properties['armor_type'] = 'light'
        when 'container'
          properties['capacity'] = 10
          properties['container'] = true
        when 'food'
          properties['consume_type'] = 'food'
          properties['consume_time'] = 5
        when 'drink'
          properties['consume_type'] = 'drink'
          properties['consume_time'] = 3
        when 'key'
          properties['key_id'] = SecureRandom.hex(8)
        end

        properties
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::Design)
