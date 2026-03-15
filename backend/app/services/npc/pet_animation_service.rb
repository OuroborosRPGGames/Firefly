# frozen_string_literal: true

# PetAnimationService - Orchestrates pet animation
#
# Simplified version of NpcAnimationService for pet items.
# Pets can only perform physical actions and creature sounds (no speech).
#
# Triggers:
#   - Room broadcasts (IC content): process_room_broadcast
#   - Idle animations: process_idle_animations (scheduler)
#
# Rate limiting:
#   - Per-pet cooldown: 2 minutes
#   - Room rate limit: 3 pet animations per minute
#   - Don't react to other pets
#
module PetAnimationService
  # Pet animation constants (from centralized config)
  PET_COOLDOWN_SECONDS = GameConfig::PetAnimation::PET_COOLDOWN_SECONDS
  MAX_ROOM_ANIMATIONS_PER_MINUTE = GameConfig::PetAnimation::MAX_ROOM_ANIMATIONS_PER_MINUTE
  IDLE_MIN_SECONDS = GameConfig::PetAnimation::IDLE_MIN_SECONDS
  IDLE_MAX_SECONDS = GameConfig::PetAnimation::IDLE_MAX_SECONDS

  class << self
    # Entry point from BroadcastService for room broadcasts
    # @param room_id [Integer]
    # @param content [String] the IC content
    # @param sender_instance [CharacterInstance]
    # @param type [Symbol] the broadcast type
    def process_room_broadcast(room_id:, content:, sender_instance:, type:)
      return if room_id.nil? || content.nil?

      # Only react to IC content types
      return unless %i[say emote pose action].include?(type)

      # Don't react to pets (sender check) - sender_instance won't be an item
      # This is handled implicitly since pets don't have CharacterInstances

      # Find active pets in the room
      pets = find_pets_in_room(room_id)
      return if pets.empty?

      pets.each do |pet|
        process_pet_for_broadcast(pet: pet, room_id: room_id, content: content, sender_instance: sender_instance)
      end
    end

    # Process idle animations for all active pets (called by scheduler)
    # @return [Hash] results with :queued and :skipped counts
    def process_idle_animations!
      results = { queued: 0, skipped: 0 }

      # Find all held pets whose owners are online
      active_pets = find_active_pets_for_idle

      active_pets.each do |pet|
        if queue_idle_animation(pet)
          results[:queued] += 1
        else
          results[:skipped] += 1
        end
      end

      results
    end

    # Process pending queue entries (fallback, called by scheduler)
    # @return [Hash] results with :processed and :failed counts
    def process_queue!
      results = { processed: 0, failed: 0 }

      pending = PetAnimationQueue.pending_ready(limit: 5)
      return results if pending.empty?

      pending.each do |entry|
        if process_queue_entry(entry)
          results[:processed] += 1
        else
          results[:failed] += 1
        end
      end

      PetAnimationQueue.cleanup_old_entries
      results
    end

    private

    # Find pets held by characters in the room
    # @param room_id [Integer]
    # @return [Array<Item>]
    def find_pets_in_room(room_id)
      Item.pets_held_in_room(room_id).all
    end

    # Find all held pets whose owners are online (for idle animations)
    # A pet is "held" when it has a character_instance_id and is not stored
    # @return [Array<Item>]
    def find_active_pets_for_idle
      Item
        .where(is_pet_instance: true)
        .exclude(character_instance_id: nil)
        .where(stored: false)
        .join(:character_instances, id: :character_instance_id)
        .where(Sequel[:character_instances][:online] => true)
        .select_all(:objects)
        .all
    end

    # Process a pet for a room broadcast
    # @param pet [Item]
    # @param room_id [Integer]
    # @param content [String]
    # @param sender_instance [CharacterInstance]
    def process_pet_for_broadcast(pet:, room_id:, content:, sender_instance:)
      return unless can_animate?(pet: pet, room_id: room_id)

      # Store emote in history before queuing
      pet.add_emote_to_history(content)

      # Queue the animation
      entry = PetAnimationQueue.queue_animation(
        pet: pet,
        room_id: room_id,
        trigger_type: 'broadcast_reaction',
        trigger_content: content,
        owner_instance: pet.owner_instance
      )

      # Process immediately in background
      process_async(entry)
    end

    # Queue an idle animation for a pet
    # @param pet [Item]
    # @return [Boolean] true if queued
    def queue_idle_animation(pet)
      return false unless pet.owner_instance&.online
      return false if pet.pet_on_cooldown?

      room_id = pet.owner_instance.current_room_id
      return false unless can_animate?(pet: pet, room_id: room_id)

      entry = PetAnimationQueue.queue_animation(
        pet: pet,
        room_id: room_id,
        trigger_type: 'idle_animation',
        owner_instance: pet.owner_instance
      )

      process_async(entry)
      true
    end

    # Check if a pet can animate right now
    # @param pet [Item]
    # @param room_id [Integer]
    # @return [Boolean]
    def can_animate?(pet:, room_id:)
      # Check per-pet cooldown
      return false if pet.pet_on_cooldown?(PET_COOLDOWN_SECONDS)

      # Check room rate limit
      return false unless room_has_capacity?(room_id)

      true
    end

    # Check if room can accept another pet animation
    # @param room_id [Integer]
    # @return [Boolean]
    def room_has_capacity?(room_id)
      recent = PetAnimationQueue.recent_count_for_room(room_id, window_seconds: 60)
      recent < MAX_ROOM_ANIMATIONS_PER_MINUTE
    end

    # Process a queue entry asynchronously
    # @param entry [PetAnimationQueue]
    def process_async(entry)
      Thread.new do
        process_queue_entry(entry)
      rescue StandardError => e
        entry&.fail!("Async error: #{e.message}")
        warn "[PetAnimation] Async error: #{e.message}"
      end
    end

    # Process a single queue entry
    # @param entry [PetAnimationQueue]
    # @return [Boolean] success
    def process_queue_entry(entry)
      entry.start_processing!

      pet = entry.item
      unless pet&.pet? && pet.owner_instance&.online
        entry.fail!('Pet no longer active')
        return false
      end

      # Generate the emote
      result = generate_pet_emote(pet: pet, trigger_content: entry.trigger_content)

      if result[:success]
        emote_text = result[:text]
        broadcast_pet_emote(pet, entry.room_id, emote_text)

        # Update tracking
        pet.update_pet_animation_time!

        entry.complete!(emote_text)
        true
      else
        entry.fail!(result[:error] || 'Generation failed')
        false
      end
    end

    # Generate a pet emote using LLM
    # @param pet [Item]
    # @param trigger_content [String, nil]
    # @return [Hash] { success: Boolean, text: String, error: String }
    def generate_pet_emote(pet:, trigger_content: nil)
      prompt = build_pet_prompt(pet: pet, trigger_content: trigger_content)

      # Use fast model (haiku)
      result = LLM::Client.generate(
        prompt: prompt,
        model: 'claude-haiku-4-5-20251001',
        provider: 'anthropic',
        options: { max_tokens: 100, temperature: 0.8 }
      )

      if result[:success] && result[:text]
        cleaned = clean_pet_emote(result[:text], pet.name)
        { success: true, text: cleaned }
      else
        { success: false, error: result[:error] || 'Unknown error' }
      end
    rescue StandardError => e
      { success: false, error: e.message }
    end

    # Build the LLM prompt for pet animation
    # @param pet [Item]
    # @param trigger_content [String, nil]
    # @return [String]
    def build_pet_prompt(pet:, trigger_content: nil)
      owner_name = pet.owner_name
      pet_name = pet.name
      pet_desc = pet.pet_description
      pet_sounds = pet.pet_sounds
      recent_context = pet.recent_emote_context

      trigger_section = if trigger_content
                          "Someone in the room said/did: \"#{trigger_content}\""
                        else
                          'The room is quiet.'
                        end

      GamePrompts.get(
        'pet_animation.emote',
        pet_name: pet_name,
        pet_desc: pet_desc,
        owner_name: owner_name,
        pet_sounds: pet_sounds,
        recent_context: recent_context,
        trigger_section: trigger_section
      )
    end

    # Clean up the pet emote output
    # @param text [String] raw LLM output
    # @param pet_name [String] the pet's name
    # @return [String] cleaned emote
    def clean_pet_emote(text, pet_name)
      cleaned = text.strip

      # Remove quoted speech
      cleaned = cleaned.gsub(/"[^"]*"/, '')
      cleaned = cleaned.gsub(/'[^']*'/, '')
      cleaned = cleaned.gsub(/\([^)]*\)/, '')  # Parenthetical notes
      cleaned = cleaned.gsub(/\[[^\]]*\]/, '')  # Brackets

      # Clean extra whitespace
      cleaned = cleaned.gsub(/\s+/, ' ').strip

      # Ensure it starts with the pet name or "The"
      unless cleaned.start_with?(pet_name) || cleaned.start_with?('The ')
        cleaned = "#{pet_name} #{cleaned.sub(/^\w+\s+/, '')}"
      end

      cleaned
    end

    # Broadcast the pet emote to the room
    # @param pet [Item]
    # @param room_id [Integer]
    # @param emote_text [String]
    def broadcast_pet_emote(pet, room_id, emote_text)
      BroadcastService.to_room(
        room_id,
        { content: emote_text, html: emote_text },
        type: :emote,
        sender_instance: pet.owner_instance # Attribute to owner for RP logging
      )

      # Log pet emote to character stories (use RpLoggingService directly to avoid
      # re-triggering NPC/pet animation side effects, which would cause recursion)
      RpLoggingService.log_to_room(
        room_id, emote_text,
        sender: pet.owner_instance, type: 'emote'
      )
    end
  end
end
