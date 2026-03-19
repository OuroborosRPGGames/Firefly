# frozen_string_literal: true

require_relative '../../../config/movement'
require_relative '../concerns/result_handler'
require_relative '../../helpers/canvas_helper'

class MovementService
  extend ResultHandler

  # Lightweight struct to represent a spatial exit for movement
  # Provides interface compatibility with legacy RoomExit code
  SpatialExit = Struct.new(:to_room, :direction, :from_room, keyword_init: true) do
    def id
      nil  # No database ID for spatial exits
    end

    def can_pass?
      RoomPassabilityService.can_pass?(from_room, to_room, direction)
    end

    def locked?
      false  # Locks are on RoomFeatures, not exits
    end

    def lock_type
      nil
    end

    def opposite_direction
      CanvasHelper.opposite_direction(direction.to_s.downcase, fallback: 'somewhere')
    end
  end

  class << self
    include PersonalizedBroadcastConcern

    def start_movement(character_instance, target:, adverb: 'walk', manner: nil, skip_autodrive: false)
      return error('Already moving') if moving?(character_instance)

      adverb = normalize_adverb(adverb)
      # Store manner adverb (e.g., "angrily") on character instance
      character_instance.update(movement_manner: manner) if character_instance.respond_to?(:movement_manner=)

      # Some service callers already resolved a Room target.
      # Bypass string resolver to avoid calling `downcase` on Room objects.
      if defined?(Room) && target.is_a?(Room)
        return start_pathfind_movement(character_instance, target, adverb, skip_autodrive: skip_autodrive)
      end

      result = TargetResolverService.resolve_movement_target(target, character_instance)

      case result.type
      when :error
        error(result.error)
      when :ambiguous
        Result.new(success: false, message: 'Multiple matches found', data: result.target)
      when :exit
        start_exit_movement(character_instance, result.exit, adverb)
      when :room
        start_pathfind_movement(character_instance, result.target, adverb)
      when :character
        start_character_movement(character_instance, result.target, adverb)
      when :furniture
        # Furniture is in same room - just approach it
        approach_furniture(character_instance, result.target, adverb)
      else
        error("Don't know how to move to that.")
      end
    end

    # Start pathfinding movement to a known room object.
    # Unlike start_movement (which resolves a target string), this accepts
    # a Room directly. Used by commands like 'home' that already know the destination.
    # Set skip_autodrive: true to bypass the vehicle/taxi prompt (e.g., when player already chose "walk").
    def move_to_room(character_instance, destination_room, adverb: 'walk', manner: nil, skip_autodrive: false)
      return error('Already moving') if moving?(character_instance)

      adverb = normalize_adverb(adverb)
      character_instance.update(movement_manner: manner) if manner && character_instance.respond_to?(:movement_manner=)

      start_pathfind_movement(character_instance, destination_room, adverb, skip_autodrive: skip_autodrive)
    end

    def stop_movement(character_instance, reason: nil)
      return error('Not moving') unless moving?(character_instance)

      was_directional = !character_instance.movement_direction.nil?

      cancel_movement_action(character_instance)

      character_instance.update(
        movement_state: 'idle',
        final_destination_id: nil,
        person_target_id: nil,
        movement_manner: nil,
        movement_direction: nil
      )

      MovementBroadcaster.broadcast_movement_stop(character_instance, reason: reason)

      Result.new(
        success: true,
        message: 'You stop walking.',
        data: { was_directional: was_directional, room_id: character_instance.current_room_id }
      )
    end

    def moving?(character_instance)
      character_instance.movement_state == 'moving'
    end

    def complete_room_transition(character_instance, room_exit)
      old_room = character_instance.current_room
      new_room = room_exit.to_room
      adverb = character_instance.movement_adverb || 'walk'
      direction = room_exit.direction

      # Calculate arrival position in new room
      arrival_pos = DistanceService.randomized_arrival_position(room_exit)

      # Broadcast departure
      MovementBroadcaster.broadcast_departure(
        character_instance, old_room, direction, adverb: adverb
      )

      # Update room_players Redis set: remove from old room, add to new room
      update_room_players_set(character_instance, old_room.id, new_room.id)

      # Move the character with new coordinates
      character_instance.update(
        current_room_id: new_room.id,
        x: arrival_pos[0],
        y: arrival_pos[1],
        z: arrival_pos[2]
      )

      # Broadcast arrival to other characters in the room
      MovementBroadcaster.broadcast_arrival(
        character_instance, new_room, direction, adverb: adverb
      )

      # Send arrival room display to the moving character
      send_arrival_room_display(character_instance, new_room)

      # Clear interaction context on room change (preserves combat target)
      character_instance.clear_interaction_context!

      # Clear game scores for games in the old room
      GameScore.clear_for_room(old_room.id, character_instance.id) if defined?(GameScore)

      # Update content consent timer for room changes
      ContentConsentService.on_room_exit(old_room) if old_room
      ContentConsentService.on_room_entry(character_instance, new_room)

      # Move followers
      move_followers(character_instance, room_exit, adverb)

      # Move prisoners (dragged/carried characters)
      move_prisoners(character_instance, new_room, adverb)

      # Check if we need to continue to final destination
      begin
        if character_instance.final_destination_id && new_room.id != character_instance.final_destination_id
          continue_to_destination(character_instance)
        elsif character_instance.movement_direction
          continue_in_direction(character_instance)
        elsif character_instance.person_target_id
          continue_following_person(character_instance)
        else
          # Clear any remaining destination tracking when we stop
          character_instance.update(
            movement_state: 'idle',
            final_destination_id: nil,
            movement_direction: nil
          )
        end
      rescue StandardError => e
        # If continuation fails, stop movement rather than leaving character stuck
        warn "[MovementService] Movement continuation failed: #{e.message}"
        character_instance.update(
          movement_state: 'idle',
          final_destination_id: nil,
          movement_direction: nil,
          person_target_id: nil
        )
      end

      # Log departure/arrival to character stories (only for final stops, not pass-throughs)
      if character_instance.movement_state == 'idle'
        verb = MovementConfig.conjugate(adverb, :present)
        departure_msg = "#{character_instance.full_name} #{verb} #{direction}."
        IcActivityService.record(
          room_id: old_room.id, content: departure_msg,
          sender: character_instance, type: :movement,
          exclude: [character_instance.id]
        )

        opposite = CanvasHelper.arrival_direction(direction)
        arrival_msg = "#{character_instance.full_name} #{verb} in from the #{opposite}."
        IcActivityService.record(
          room_id: new_room.id, content: arrival_msg,
          sender: character_instance, type: :movement,
          exclude: [character_instance.id]
        )
      end

      Result.new(
        success: true,
        message: "You arrive at #{new_room.name}.",
        data: { room: new_room, from: old_room }
      )
    end

    def start_following(follower, leader)
      return error('Cannot follow yourself') if follower.id == leader.id
      return error('Already following someone') if follower.following_id

      # Check permission
      unless can_follow?(follower, leader)
        return error("#{leader.character.display_name_for(follower)} hasn't given you permission to follow them.")
      end

      follower.update(
        following_id: leader.id,
        movement_state: 'following'
      )

      MovementBroadcaster.broadcast_follow_start(follower, leader)

      Result.new(success: true, message: "You start following #{leader.character.display_name_for(follower)}.")
    end

    def stop_following(follower, reason: nil)
      leader = CharacterInstance[follower.following_id]
      return error('Not following anyone') unless leader

      follower.update(
        following_id: nil,
        movement_state: 'idle'
      )

      MovementBroadcaster.broadcast_follow_stop(follower, leader, reason: reason)

      Result.new(success: true, message: "You stop following #{leader.character.display_name_for(follower)}.")
    end

    def grant_follow_permission(leader, follower)
      leader_char = leader.character
      follower_char = follower.character

      rel = Relationship.find_or_create_between(follower_char, leader_char)
      rel.update(status: 'accepted', can_follow: true)

      Result.new(success: true, message: "#{follower.character.display_name_for(leader)} can now follow you.")
    end

    def revoke_follow_permission(leader, follower)
      leader_char = leader.character
      follower_char = follower.character

      rel = Relationship.between(follower_char, leader_char)
      rel&.update(can_follow: false)

      # Stop them following if they are
      if follower.following_id == leader.id
        stop_following(follower, reason: 'permission revoked')
      end

      Result.new(success: true, message: "#{follower.character.display_name_for(leader)} can no longer follow you.")
    end

    # Public helper for commands that handle their own room transitions
    # (e.g., the enter command) but still need minimap updates sent.
    def notify_room_arrival(character_instance, new_room)
      send_arrival_room_display(character_instance, new_room)
    end

    private

    def start_exit_movement(character_instance, room_exit, adverb)
      # Check prisoner/restraint movement restrictions
      unless character_instance.can_move_independently?
        if character_instance.unconscious?
          return error("You can't move while unconscious.")
        elsif character_instance.feet_bound?
          return error("Your feet are bound. You can't move.")
        elsif character_instance.being_moved?
          captor = character_instance.captor
          return error("You are being held by #{captor&.character&.display_name_for(character_instance) || 'someone'}.")
        end
      end

      unless room_exit.can_pass?
        return error(exit_blocked_message(room_exit))
      end

      # Check if destination is a staff-only room
      destination = room_exit.to_room
      access_check = can_enter_room?(character_instance, destination)
      unless access_check[:allowed]
        return error(access_check[:message])
      end

      # Check if destination is outside zone polygon (inaccessible)
      unless destination.navigable?
        return error('That area is beyond the zone boundaries.')
      end

      # Calculate time based on distance from character to exit
      # Apply speed modifier if dragging/carrying a prisoner
      base_duration = MovementConfig.time_for_movement(adverb, room_exit, character_instance)
      speed_modifier = PrisonerService.movement_speed_modifier(character_instance)
      duration = (base_duration * speed_modifier).to_i

      # Cap movement to 1 second in tutorial rooms (newbie school/mall)
      if duration > 1000 && (character_instance.current_room&.tutorial_room || destination.tutorial_room)
        duration = 1000
      end

      # Store positions for the handler
      start_pos = character_instance.position
      exit_pos = DistanceService.exit_position_in_room(room_exit)

      character_instance.update(
        movement_state: 'moving',
        movement_adverb: adverb
      )

      # Create timed action for the movement
      # Store direction and destination room ID (spatial exits have no database ID)
      TimedAction.start_delayed(
        character_instance,
        'movement',
        duration,
        'MovementHandler',
        {
          direction: room_exit.direction,
          destination_room_id: room_exit.to_room.id,
          adverb: adverb,
          start_x: start_pos[0],
          start_y: start_pos[1],
          start_z: start_pos[2],
          target_x: exit_pos[0],
          target_y: exit_pos[1],
          target_z: exit_pos[2]
        }
      )

      verb_continuous = MovementConfig.conjugate(adverb, :continuous)

      # Build appropriate message based on direction type
      direction = room_exit.direction.to_s
      destination_name = room_exit.to_room.name
      message = "You start #{verb_continuous} toward #{destination_name}."

      Result.new(
        success: true,
        message: message,
        data: { exit: room_exit, duration: duration,
                target_world_x: exit_pos[0], target_world_y: exit_pos[1] }
      )
    end

    def start_pathfind_movement(character_instance, destination_room, adverb, skip_autodrive: false)
      path = PathfindingService.find_path(character_instance.current_room, destination_room)

      if path.empty?
        # Try smart navigation for cross-area travel (uses taxi if available)
        return use_smart_navigation(character_instance, destination_room, adverb)
      end

      first_exit = path.first

      unless first_exit.can_pass?
        return error(exit_blocked_message(first_exit))
      end

      # Offer vehicle/taxi options for long-distance pathfinding
      if !skip_autodrive && AutodrivePromptService.should_prompt?(character_instance, destination_room)
        options = AutodrivePromptService.build_options(character_instance, destination_room)
        return Result.new(
          success: false,
          message: "That's a long way on foot. How would you like to travel?",
          data: {
            autodrive_prompt: true,
            destination_id: destination_room.id,
            destination_name: destination_room.name,
            adverb: adverb,
            options: options
          }
        )
      end

      character_instance.update(
        movement_state: 'moving',
        movement_adverb: adverb,
        final_destination_id: destination_room.id
      )

      # Calculate time based on distance to first exit
      duration = MovementConfig.time_for_movement(adverb, first_exit, character_instance)
      start_pos = character_instance.position
      exit_pos = DistanceService.exit_position_in_room(first_exit)

      TimedAction.start_delayed(
        character_instance,
        'movement',
        duration,
        'MovementHandler',
        {
          direction: first_exit.direction,
          destination_room_id: first_exit.to_room.id,
          adverb: adverb,
          start_x: start_pos[0],
          start_y: start_pos[1],
          start_z: start_pos[2],
          target_x: exit_pos[0],
          target_y: exit_pos[1],
          target_z: exit_pos[2]
        }
      )

      verb_continuous = MovementConfig.conjugate(adverb, :continuous)

      Result.new(
        success: true,
        message: "You start #{verb_continuous} toward #{destination_room.name}.",
        data: { destination: destination_room, path_length: path.length, duration: duration,
                target_world_x: exit_pos[0], target_world_y: exit_pos[1] }
      )
    end

    def start_character_movement(character_instance, target_instance, adverb)
      target_room = target_instance.current_room

      if character_instance.current_room_id == target_room.id
        return error("#{target_instance.character.display_name_for(character_instance)} is right here.")
      end

      path = PathfindingService.find_path(character_instance.current_room, target_room)

      if path.empty?
        return error("Can't find a way to get to #{target_instance.character.display_name_for(character_instance)}.")
      end

      first_exit = path.first

      character_instance.update(
        movement_state: 'moving',
        movement_adverb: adverb,
        person_target_id: target_instance.id
      )

      # Calculate time based on distance to first exit
      duration = MovementConfig.time_for_movement(adverb, first_exit, character_instance)
      start_pos = character_instance.position
      exit_pos = DistanceService.exit_position_in_room(first_exit)

      TimedAction.start_delayed(
        character_instance,
        'movement',
        duration,
        'MovementHandler',
        {
          direction: first_exit.direction,
          destination_room_id: first_exit.to_room.id,
          adverb: adverb,
          start_x: start_pos[0],
          start_y: start_pos[1],
          start_z: start_pos[2],
          target_x: exit_pos[0],
          target_y: exit_pos[1],
          target_z: exit_pos[2]
        }
      )

      verb_continuous = MovementConfig.conjugate(adverb, :continuous)

      Result.new(
        success: true,
        message: "You start #{verb_continuous} toward #{target_instance.character.display_name_for(character_instance)}.",
        data: { target: target_instance, path_length: path.length }
      )
    end

    def approach_furniture(character_instance, furniture, adverb)
      # Get furniture position (if available) or use room center
      target_x = furniture.respond_to?(:x) && furniture.x ? furniture.x : 50.0
      target_y = furniture.respond_to?(:y) && furniture.y ? furniture.y : 50.0
      target_z = furniture.respond_to?(:z) && furniture.z ? furniture.z : 0.0

      char_pos = character_instance.position
      distance = DistanceService.calculate_distance(
        char_pos[0], char_pos[1], char_pos[2],
        target_x, target_y, target_z
      )

      verb_past = MovementConfig.conjugate(adverb, :past)

      # For short distances (< 5 units), move instantly
      if distance < 5.0
        character_instance.move_to(target_x, target_y, target_z)
        return Result.new(
          success: true,
          message: "You #{verb_past} over to #{furniture.name}.",
          data: { furniture: furniture, instant: true }
        )
      end

      # For longer distances, create timed action
      multiplier = MovementConfig::SPEED_MULTIPLIERS[adverb] || 1.0
      duration = DistanceService.time_for_distance(distance, multiplier)
      duration = [duration, MovementConfig::MIN_TRANSITION_TIME_MS].max

      character_instance.update(
        movement_state: 'moving',
        movement_adverb: adverb
      )

      TimedAction.start_delayed(
        character_instance,
        'approach',
        duration,
        'ApproachHandler',
        {
          target_type: 'furniture',
          target_id: furniture.id,
          target_name: furniture.name,
          target_x: target_x,
          target_y: target_y,
          target_z: target_z,
          adverb: adverb
        }
      )

      verb_continuous = MovementConfig.conjugate(adverb, :continuous)
      Result.new(
        success: true,
        message: "You start #{verb_continuous} toward #{furniture.name}.",
        data: { furniture: furniture, duration: duration }
      )
    end

    # Make approach_furniture public for use by DisambiguationHandler
    public :approach_furniture

    # Start continuous directional walking on city streets.
    # The character will keep moving in the given direction until they stop
    # or reach a dead end.
    def start_directional_walk(character_instance, direction, adverb: 'walk')
      return error('Already moving') if moving?(character_instance)

      room = character_instance.current_room
      next_room = RoomAdjacencyService.resolve_direction_movement(room, direction.to_sym)

      return error("You can't go that way.") unless next_room

      # Check passability and access
      access = can_enter_room?(character_instance, next_room)
      return error(access[:message]) unless access[:allowed]

      unless next_room.navigable?
        return error('That area is beyond the zone boundaries.')
      end

      # Set directional walking state
      character_instance.update(
        movement_state: 'moving',
        movement_adverb: adverb,
        movement_direction: direction
      )

      # Create timed action for first step
      duration = calculate_street_walk_duration(room, next_room, adverb)
      start_pos = character_instance.position
      exit_pos = DistanceService.wall_position(room, direction)

      TimedAction.start_delayed(
        character_instance,
        'movement',
        duration,
        'MovementHandler',
        {
          direction: direction,
          destination_room_id: next_room.id,
          adverb: adverb,
          start_x: start_pos[0],
          start_y: start_pos[1],
          start_z: start_pos[2],
          target_x: exit_pos[0],
          target_y: exit_pos[1],
          target_z: exit_pos[2]
        }
      )

      verb_continuous = MovementConfig.conjugate(adverb, :continuous)
      Result.new(success: true, message: "You start #{verb_continuous} #{direction}.",
                 data: { duration: duration,
                         target_world_x: exit_pos[0], target_world_y: exit_pos[1] })
    end

    # Make start_directional_walk public for use by DirectionWalk command
    public :start_directional_walk

    # Continue walking in the set direction after arriving in a new room.
    # Sends transit messages and queues the next movement step.
    def continue_in_direction(character_instance)
      direction = character_instance.movement_direction
      adverb = character_instance.movement_adverb || 'walk'
      current_room = character_instance.current_room

      # Send transit messages about the room we just arrived in
      send_directional_transit(character_instance, current_room, direction)

      # Find next room in this direction
      next_room = RoomAdjacencyService.resolve_direction_movement(current_room, direction.to_sym)

      # Stop conditions: no exit, not outdoor city room, blocked
      unless next_room && city_outdoor_room?(next_room)
        stop_directional_walk(character_instance)
        broadcast_stop_message(character_instance, current_room, next_room)
        return
      end

      access = can_enter_room?(character_instance, next_room)
      unless access[:allowed]
        stop_directional_walk(character_instance)
        BroadcastService.to_character(character_instance, access[:message], type: :movement)
        return
      end

      unless next_room.navigable?
        stop_directional_walk(character_instance)
        BroadcastService.to_character(character_instance, 'That area is beyond the zone boundaries.', type: :movement)
        return
      end

      # Create next timed action
      duration = calculate_street_walk_duration(current_room, next_room, adverb)
      start_pos = character_instance.position
      exit_pos = DistanceService.wall_position(current_room, direction)

      TimedAction.start_delayed(
        character_instance,
        'movement',
        duration,
        'MovementHandler',
        {
          direction: direction,
          destination_room_id: next_room.id,
          adverb: adverb,
          start_x: start_pos[0],
          start_y: start_pos[1],
          start_z: start_pos[2],
          target_x: exit_pos[0],
          target_y: exit_pos[1],
          target_z: exit_pos[2]
        }
      )
    end

    def continue_to_destination(character_instance)
      destination = Room[character_instance.final_destination_id]
      adverb = character_instance.movement_adverb || 'walk'

      path = PathfindingService.find_path(character_instance.current_room, destination)

      if path.empty?
        character_instance.update(
          movement_state: 'idle',
          final_destination_id: nil
        )
        return
      end

      first_exit = path.first
      duration = MovementConfig.time_for_movement(adverb, first_exit, character_instance)
      start_pos = character_instance.position
      exit_pos = DistanceService.exit_position_in_room(first_exit)

      TimedAction.start_delayed(
        character_instance,
        'movement',
        duration,
        'MovementHandler',
        {
          direction: first_exit.direction,
          destination_room_id: first_exit.to_room.id,
          adverb: adverb,
          start_x: start_pos[0],
          start_y: start_pos[1],
          start_z: start_pos[2],
          target_x: exit_pos[0],
          target_y: exit_pos[1],
          target_z: exit_pos[2]
        }
      )
    end

    def continue_following_person(character_instance)
      target = CharacterInstance[character_instance.person_target_id]
      adverb = character_instance.movement_adverb || 'walk'

      unless target&.online
        character_instance.update(
          movement_state: 'idle',
          person_target_id: nil
        )
        return
      end

      if character_instance.current_room_id == target.current_room_id
        character_instance.update(
          movement_state: 'idle',
          person_target_id: nil
        )
        return
      end

      path = PathfindingService.find_path(character_instance.current_room, target.current_room)

      if path.empty?
        character_instance.update(
          movement_state: 'idle',
          person_target_id: nil
        )
        return
      end

      first_exit = path.first
      duration = MovementConfig.time_for_movement(adverb, first_exit, character_instance)
      start_pos = character_instance.position
      exit_pos = DistanceService.exit_position_in_room(first_exit)

      TimedAction.start_delayed(
        character_instance,
        'movement',
        duration,
        'MovementHandler',
        {
          direction: first_exit.direction,
          destination_room_id: first_exit.to_room.id,
          adverb: adverb,
          start_x: start_pos[0],
          start_y: start_pos[1],
          start_z: start_pos[2],
          target_x: exit_pos[0],
          target_y: exit_pos[1],
          target_z: exit_pos[2]
        }
      )
    end

    def move_followers(leader, room_exit, adverb)
      followers = CharacterInstance.where(following_id: leader.id, online: true).all

      followers.each do |follower|
        next if MovementService.moving?(follower)

        duration = MovementConfig.time_for_movement(adverb, room_exit, follower)
        start_pos = follower.position
        exit_pos = DistanceService.exit_position_in_room(room_exit)

        follower.update(movement_adverb: adverb)

        TimedAction.start_delayed(
          follower,
          'movement',
          duration,
          'MovementHandler',
          {
            direction: room_exit.direction,
            destination_room_id: room_exit.to_room.id,
            adverb: adverb,
            following: true,
            start_x: start_pos[0],
            start_y: start_pos[1],
            start_z: start_pos[2],
            target_x: exit_pos[0],
            target_y: exit_pos[1],
            target_z: exit_pos[2]
          }
        )
      end
    end

    # Move prisoners (dragged/carried characters) when captor moves
    # Unlike followers, prisoners move instantly with no delay
    def move_prisoners(captor, new_room, adverb)
      prisoners = PrisonerService.move_prisoners!(captor, new_room)

      prisoners.each do |prisoner|
        # Calculate arrival position (same as captor)
        prisoner.update(
          x: captor.x,
          y: captor.y,
          z: captor.z
        )

        # Broadcast their movement (personalized per viewer)
        if prisoner.being_dragged?
          broadcast_personalized_to_room(
            new_room.id,
            "#{captor.full_name} drags #{prisoner.full_name} along.",
            exclude: [captor.id, prisoner.id],
            extra_characters: [captor, prisoner]
          )
          BroadcastService.to_character(
            prisoner,
            "You are dragged along by #{captor.character.display_name_for(prisoner)}.",
            type: :movement
          )

          # Log prisoner dragged to character stories
          IcActivityService.record(
            room_id: new_room.id,
            content: "#{captor.full_name} drags #{prisoner.full_name} along.",
            sender: captor, type: :movement
          )
        else
          broadcast_personalized_to_room(
            new_room.id,
            "#{captor.full_name} carries #{prisoner.full_name} along.",
            exclude: [captor.id, prisoner.id],
            extra_characters: [captor, prisoner]
          )
          BroadcastService.to_character(
            prisoner,
            "You are carried along by #{captor.character.display_name_for(prisoner)}.",
            type: :movement
          )

          # Log prisoner carried to character stories
          IcActivityService.record(
            room_id: new_room.id,
            content: "#{captor.full_name} carries #{prisoner.full_name} along.",
            sender: captor, type: :movement
          )
        end

        # Update consent timer for prisoners too
        ContentConsentService.on_room_entry(prisoner, new_room)
      end
    end

    # Send arrival room info to the moving character via WebSocket.
    # Sends a brief text message (room name + short description) to the main feed
    # and includes metadata for minimap/status bar updates.
    def send_arrival_room_display(character_instance, new_room)
      transit = character_instance.final_destination_id &&
                new_room.id != character_instance.final_destination_id

      # Build room display data for exits and characters
      display = RoomDisplayService.for(new_room, character_instance, mode: transit ? :transit : :arrival)
      room_display = display.build_display
      exits_data = room_display[:exits] || []
      characters_data = room_display[:characters_ungrouped] || []

      room_name = new_room.name
      is_tutorial = new_room.respond_to?(:tutorial_room) && new_room.tutorial_room

      # Build brief text: arrival message + exits + people present
      if transit
        html = "<span class=\"room-arrival-name\">You walk through #{room_name}.</span>"
      else
        html = "<span class=\"room-arrival-msg\">You arrive at #{room_name}.</span>"
      end

      # Show exits summary
      if exits_data.any?
        exit_parts = exits_data.map do |ex|
          arrow = ex[:direction_arrow] || ''
          dist = ex[:distance] ? "#{ex[:distance]}ft" : ''
          "#{ex[:to_room_name]}<sup>#{arrow}#{dist}</sup>"
        end
        html += "<br><span class=\"room-arrival-exits\">Exits: #{exit_parts.join(', ')}</span>"
      end

      # Show people present (excluding the viewer)
      if characters_data.any?
        names = characters_data.map { |c| c[:name] }
        html += "<br><span class=\"room-arrival-people\">Here: #{names.join(', ')}</span>"
      end

      if is_tutorial
        html += '<br><span class="room-arrival-hint">Type <b>look</b> for details.</span>'
      end

      message = {
        content: html,
        room_arrival: true,
        room_name: room_name,
        room_id: new_room.id,
        exits: exits_data,
        content_consent: room_display[:content_consent],
        room: {
          vault_accessible: new_room.vault_accessible?(character_instance.character)
        },
        background_image: new_room.current_background_url,
        minimap_data: generate_minimap_svg(character_instance)
      }

      BroadcastService.to_character_raw(
        character_instance, message, type: :room
      )
    rescue StandardError => e
      warn "[MovementService] Failed to send arrival room display: #{e.message}"
    end

    # Generate minimap SVG data via CityMapRenderService.
    # Returns a hash with :svg and :metadata keys, or nil on failure.
    def generate_minimap_svg(character_instance)
      # Skip minimap generation during delves (delve has its own map panel)
      if DelveParticipant.where(character_instance_id: character_instance.id, status: 'active').any?
        return nil
      end

      service_result = CityMapRenderService.render(
        viewer: character_instance,
        mode: :minimap
      )
      {
        svg: service_result[:svg],
        metadata: service_result[:metadata]
      }
    rescue StandardError => e
      warn "[MovementService] Minimap SVG generation failed: #{e.message}"
      nil
    end

    def cancel_movement_action(character_instance)
      TimedAction
        .where(character_instance_id: character_instance.id, action_name: 'movement')
        .where(status: 'active')
        .update(status: 'cancelled')
    end

    def can_follow?(follower, leader)
      Relationship.can_follow?(follower.character, leader.character)
    end

    def exit_blocked_message(room_exit)
      if room_exit.locked?
        "The way #{room_exit.direction} is locked."
      else
        "You can't go that way."
      end
    end

    # Check if a character can enter a room
    # Handles staff-only room restrictions and other access controls

    def can_enter_room?(character_instance, room)
      # Check staff-only restriction
      if room.staff_only?
        unless character_instance.character&.staff?
          return { allowed: false, message: "That area is restricted to staff only." }
        end
      end

      # Check room ownership/lock
      if room.locked? && !room.unlocked_for?(character_instance.character)
        return { allowed: false, message: "The door is locked." }
      end

      # Check for active fight with entry delay
      active_fight = Fight.where(room_id: room.id)
                          .where(status: %w[input resolving narrative])
                          .first

      if active_fight && !FightEntryDelayService.can_enter?(character_instance, active_fight)
        rounds_left = FightEntryDelayService.rounds_until_entry(character_instance, active_fight)
        return { allowed: false, message: "A fight is in progress. Entry allowed in #{rounds_left} more combat round(s)." }
      end

      # Check for recently-ended fight (10 minute cooldown)
      # This prevents people from immediately entering after combat to catch fighters off-guard
      unless active_fight
        recent_fight = Fight.where(room_id: room.id)
                            .where(status: 'complete')
                            .where { combat_ended_at > Time.now - GameConfig::Combat::POST_COMBAT_ENTRY_COOLDOWN_SECONDS }
                            .first

        if recent_fight
          # Allow entry if the character was a participant in that fight
          was_participant = recent_fight.fight_participants.any? do |p|
            p.character_instance_id == character_instance.id
          end

          unless was_participant
            seconds_remaining = (recent_fight.combat_ended_at + GameConfig::Combat::POST_COMBAT_ENTRY_COOLDOWN_SECONDS - Time.now).to_i
            minutes_remaining = (seconds_remaining / 60.0).ceil
            return { allowed: false, message: "Combat recently ended here. Entry allowed in #{minutes_remaining} minute(s)." }
          end
        end
      end

      { allowed: true }
    end

    def normalize_adverb(adverb)
      adverb = adverb&.downcase&.strip
      MovementConfig.valid_verb?(adverb) ? adverb : MovementConfig.default_verb
    end

    # Update room_players Redis sets when a character changes rooms
    # Removes from old room and adds to new room for polling fallback
    def update_room_players_set(character_instance, old_room_id, new_room_id)
      return unless defined?(REDIS_POOL) && REDIS_POOL

      REDIS_POOL.with do |redis|
        # Remove from old room
        redis.srem("room_players:#{old_room_id}", character_instance.id) if old_room_id

        # Add to new room
        if new_room_id
          redis.sadd("room_players:#{new_room_id}", character_instance.id)
          redis.expire("room_players:#{new_room_id}", 600)
        end
      end
    rescue StandardError => e
      warn "[MovementService] Failed to update room_players: #{e.message}"
    end

    # Use SmartNavigationService for cross-area travel (building exit → taxi → building entry).
    def use_smart_navigation(character_instance, destination_room, adverb)
      smart_nav = SmartNavigationService.new(character_instance)
      result = smart_nav.navigate_to(destination_room)

      if result[:success]
        Result.new(
          success: true,
          message: result[:message],
          data: {
            destination: destination_room,
            travel_type: result[:travel_type],
            smart_navigation: true,
            duration: result[:duration],
            path_length: result[:path_length]
          }
        )
      else
        error(result[:error] || "Can't find a way to get there from here.")
      end
    end

    # Check if a room is a city-grid outdoor room (street/avenue/intersection).
    # Intentionally narrower than Room#outdoor_room? — this is used to continue
    # directional walks through city streets, and checks city_role in addition to
    # room_type. Parks, plazas, and other outdoor types intentionally do NOT
    # continue directional walking.
    def city_outdoor_room?(room)
      return false unless room
      RoomTypeConfig.street?(room.city_role.to_s) ||
        RoomTypeConfig.street?(room.room_type)
    end

    # Calculate walk duration between two street rooms
    def calculate_street_walk_duration(from_room, to_room, adverb)
      distance = RoomAdjacencyService.distance_between(from_room, to_room)
      multiplier = MovementConfig::SPEED_MULTIPLIERS[adverb] || 1.0
      # ~5 ft/s walking speed
      base_ms = (distance / 5.0 * 1000).to_i
      [(base_ms * multiplier).to_i, MovementConfig::MIN_TRANSITION_TIME_MS].max
    end

    # Send transit messages to a character walking through a room
    def send_directional_transit(character_instance, room, direction)
      messages = []

      if %w[intersection].include?(room.city_role) || room.room_type == 'intersection'
        messages << "You pass through #{room.name}."
      else
        messages << "You walk along #{room.name}."
      end

      # Characters present
      visible = CharacterInstance.where(current_room_id: room.id, online: true)
                                 .exclude(id: character_instance.id)
                                 .all
      if visible.any?
        names = visible.map { |ci| ci.character.display_name_for(character_instance) }
        messages << "  You see #{names.join(', ')} here."
      end

      # Buildings on left/right
      building_msgs = StreetContextService.buildings_along_street(room, direction)
      messages.concat(building_msgs)

      BroadcastService.to_character(character_instance, messages.join("\n"), type: :movement)
    end

    # Stop directional walking and reset state
    def stop_directional_walk(character_instance)
      character_instance.update(
        movement_state: 'idle',
        movement_direction: nil,
        movement_manner: nil
      )
    end

    # Broadcast a stop message when directional walking ends.
    # The room display update is handled by the MovementHandler's moved_to mechanism.
    def broadcast_stop_message(character_instance, _current_room, next_room)
      message = if next_room.nil?
                  'You reach the end of the road and stop.'
                else
                  'You stop walking.'
                end
      BroadcastService.to_character(character_instance, message, type: :movement)
    end

  end
end
