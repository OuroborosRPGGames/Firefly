# frozen_string_literal: true

require_relative '../../../../app/helpers/room_display_helper'

module Commands
  module Info
    class Observe < Commands::Base::Command
      include RoomDisplayHelper
      command_name 'observe'
      aliases 'watch', 'o'
      category :info
      help_text 'Observe a character, place, or room to receive continuous updates about their actions'
      usage 'observe [character|place|room|stop]'
      examples 'observe Alice', 'observe me', 'observe bar', 'observe room', 'observe', 'observe stop'

      protected

      def perform_command(parsed_input)
        target_name = parsed_input[:text]&.strip&.downcase

        case target_name
        when 'stop', 'off', 'none'
          stop_observing
        when nil, ''
          character_instance.observing? ? stop_observing : observe_room
        when 'self', 'me'
          observe_self
        when 'room', 'here', 'around'
          observe_room
        else
          observe_target(parsed_input[:text].strip)
        end
      end

      private

      def stop_observing
        unless character_instance.observing?
          return error_result("You're not currently observing anything.")
        end

        observed_name = current_observation_name
        character_instance.stop_observing!

        success_result(
          "You stop observing #{observed_name}.",
          type: :message,
          data: { action: 'stop_observing' },
          target_panel: Firefly::Panels::LEFT_OBSERVE
        )
      end

      def current_observation_name
        if character_instance.observing_character?
          character_instance.observing&.character&.full_name || 'that character'
        elsif character_instance.observing_place?
          character_instance.observed_place&.name || 'that place'
        elsif character_instance.observing_room?
          'the room'
        else
          'that'
        end
      end

      def observe_self
        character_instance.start_observing!(character_instance)

        service = CharacterDisplayService.new(character_instance, viewer_instance: character_instance)
        char_data = service.build_display

        success_result(
          "You begin observing yourself.",
          type: :message,
          structured: char_data.merge(display_type: :character),
          data: {
            action: 'observe',
            target_id: character_instance.id,
            target_name: character.full_name,
            target_type: 'character',
            is_self: true
          },
          target_panel: Firefly::Panels::LEFT_OBSERVE
        )
      end

      def observe_room
        character_instance.start_observing_room!

        service = RoomDisplayService.for(location, character_instance, mode: :full)
        room_data = service.build_display

        nearby_areas = build_nearby_areas_text(room_data[:exits])
        room_data[:nearby_areas_text] = nearby_areas if nearby_areas

        room_result(room_data,
          room_id: location.id,
          target_panel: Firefly::Panels::LEFT_OBSERVE
        )
      end

      def observe_target(name)
        # First try to find a character
        target_char = find_character_in_room(name)
        if target_char
          return observe_character(target_char)
        end

        # Then try to find a place
        target_place = find_place_in_room(name)
        if target_place
          return observe_place(target_place)
        end

        # Not found
        error_result("You don't see '#{name}' here to observe.")
      end

      def observe_character(target)
        # Stop observing previous target if any
        if character_instance.observing? && character_instance.observing_id != target.id
          character_instance.stop_observing!
        end

        character_instance.start_observing!(target)

        service = CharacterDisplayService.new(target, viewer_instance: character_instance)
        char_data = service.build_display

        success_result(
          "You begin observing #{target.character.full_name}.",
          type: :message,
          structured: char_data.merge(display_type: :character),
          data: {
            action: 'observe',
            target_id: target.id,
            target_name: target.character.full_name,
            target_type: 'character',
            is_self: false
          },
          target_panel: Firefly::Panels::LEFT_OBSERVE
        )
      end

      def observe_place(place)
        if character_instance.observing?
          character_instance.stop_observing!
        end

        character_instance.start_observing_place!(place)

        place_data = build_place_display(place)

        success_result(
          "You begin observing #{place.name}.",
          type: :message,
          structured: place_data.merge(display_type: :place),
          data: {
            action: 'observe',
            target_id: place.id,
            target_name: place.name,
            target_type: 'place',
            is_self: false
          },
          target_panel: Firefly::Panels::LEFT_OBSERVE
        )
      end

      def find_character_in_room(name)
        super(name, alive_only: true)
      end

      def find_place_in_room(name)
        TargetResolverService.resolve(
          query: name,
          candidates: location.visible_places.all,
          name_field: :name
        )
      end

      def build_place_display(place)
        chars_here = place.characters_here(character_instance.reality_id, viewer: character_instance)
                         .exclude(id: character_instance.id)
                         .eager(:character)
                         .all

        {
          id: place.id,
          name: place.name,
          description: place.description,
          place_type: place.place_type,
          is_furniture: place.furniture?,
          capacity: place.capacity,
          characters: chars_here.map do |ci|
            {
              id: ci.id,
              name: ci.character.display_name_for(character_instance),
              short_desc: ci.character.short_desc,
              stance: ci.current_stance
            }
          end
        }
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Info::Observe)
