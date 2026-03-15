# frozen_string_literal: true

# DescriptionCopyService handles copying default descriptions from Character
# to CharacterInstance when a character logs in.
#
# This ensures persistent descriptions are synced to the session while
# allowing session-specific modifications during gameplay.
#
# Supports multi-position descriptions (tattoos, etc.) and aesthetic types.
class DescriptionCopyService
  class << self
    # Sync descriptions from Character to CharacterInstance on login
    # @param character [Character] The character to copy from
    # @param instance [CharacterInstance] The instance to copy to
    # @return [Hash] Summary of sync operation
    def sync_on_login(character, instance)
      return { success: false, error: 'Invalid character' } unless character
      return { success: false, error: 'Invalid instance' } unless instance

      copied = 0
      updated = 0
      skipped = 0

      DB.transaction do
        character.default_descriptions_dataset.where(active: true).each do |default_desc|
          existing = find_matching_instance_description(instance, default_desc)

          if existing
            if content_differs?(existing, default_desc)
              update_description(existing, default_desc)
              updated += 1
            else
              skipped += 1
            end
          else
            create_description(instance, default_desc)
            copied += 1
          end
        end
      end

      {
        success: true,
        copied: copied,
        updated: updated,
        skipped: skipped,
        total: copied + updated + skipped
      }
    end

    # Sync a single description from Character to CharacterInstance
    # @param character [Character] The character owning the description
    # @param instance [CharacterInstance] The target instance
    # @param default_desc_id [Integer] The default description ID to sync
    # @return [Hash] Result of the operation
    def sync_single(character, instance, default_desc_id)
      return { success: false, error: 'Invalid character' } unless character
      return { success: false, error: 'Invalid instance' } unless instance

      default_desc = character.default_descriptions_dataset.first(
        id: default_desc_id,
        active: true
      )

      return { success: false, error: 'Description not found' } unless default_desc

      existing = find_matching_instance_description(instance, default_desc)

      if existing
        update_description(existing, default_desc)
        { success: true, action: :updated }
      else
        create_description(instance, default_desc)
        { success: true, action: :created }
      end
    end

    # Sync a single description by body position (legacy method for backwards compatibility)
    # @param character [Character] The character owning the description
    # @param instance [CharacterInstance] The target instance
    # @param body_position_id [Integer] The body position to sync
    # @return [Hash] Result of the operation
    def sync_single_by_position(character, instance, body_position_id)
      return { success: false, error: 'Invalid character' } unless character
      return { success: false, error: 'Invalid instance' } unless instance

      default_desc = character.default_descriptions_dataset.first(
        body_position_id: body_position_id,
        active: true
      )

      return { success: false, error: 'Description not found' } unless default_desc

      sync_single(character, instance, default_desc.id)
    end

    # Remove instance descriptions that no longer exist in defaults
    # @param character [Character] The character to check
    # @param instance [CharacterInstance] The instance to clean
    # @return [Integer] Number of descriptions removed
    def cleanup_orphaned(character, instance)
      return 0 unless character && instance

      # Get all active default description IDs
      default_ids = character.default_descriptions_dataset
                             .where(active: true)
                             .select_map(:id)

      # For descriptions with body positions, we need to match by content/type
      # For now, clean up by body_position_id (legacy approach)
      default_position_ids = character.default_descriptions_dataset
                                      .where(active: true)
                                      .exclude(body_position_id: nil)
                                      .select_map(:body_position_id)

      # Find instance descriptions with body_position_id not in defaults
      orphaned = CharacterDescription
                   .where(character_instance_id: instance.id)
                   .exclude(body_position_id: nil)
                   .exclude(body_position_id: default_position_ids)

      count = orphaned.count
      orphaned.each do |desc|
        # Clean up join table entries first
        CharacterInstanceDescriptionPosition.where(character_description_id: desc.id).delete
        desc.delete
      end
      count
    end

    private

    # Find matching instance description for a default description
    # Matches by body_position_id and aesthetic_type
    # Falls back to join table positions when body_position_id is nil
    def find_matching_instance_description(instance, default_desc)
      # First try matching by legacy body_position_id if present
      if default_desc.body_position_id
        existing = CharacterDescription.first(
          character_instance_id: instance.id,
          body_position_id: default_desc.body_position_id,
          aesthetic_type: default_desc.description_type
        )
        return existing if existing
      end

      # Fall back to matching via join table positions
      # This handles descriptions where body_position_id is nil but
      # positions exist in the join table (character_description_positions)
      join_position_id = default_desc.body_positions.first&.id
      if join_position_id
        existing = CharacterDescription.first(
          character_instance_id: instance.id,
          body_position_id: join_position_id,
          aesthetic_type: default_desc.description_type
        )
        return existing if existing
      end

      nil
    end

    def content_differs?(existing, default_desc)
      existing.content != default_desc.content ||
        existing.image_url != default_desc.image_url ||
        existing.concealed_by_clothing != default_desc.concealed_by_clothing ||
        existing.display_order != default_desc.display_order ||
        existing.aesthetic_type != default_desc.description_type ||
        positions_differ?(existing, default_desc)
    end

    def positions_differ?(existing, default_desc)
      existing_pos_ids = existing.body_positions.map(&:id).sort
      default_pos_ids = default_desc.body_positions.map(&:id).sort
      existing_pos_ids != default_pos_ids
    end

    def update_description(existing, default_desc)
      existing.update(
        content: default_desc.content,
        image_url: default_desc.image_url,
        concealed_by_clothing: default_desc.concealed_by_clothing,
        display_order: default_desc.display_order,
        aesthetic_type: default_desc.description_type,
        active: true
      )

      # Sync body positions via join table
      sync_positions(existing, default_desc)
    end

    def create_description(instance, default_desc)
      # Use legacy body_position_id, falling back to first join table position
      body_pos_id = default_desc.body_position_id || default_desc.body_positions.first&.id

      # Guard against duplicates: if one already exists, update it instead
      if body_pos_id && default_desc.description_type != 'tattoo'
        existing = CharacterDescription.first(
          character_instance_id: instance.id,
          body_position_id: body_pos_id,
          aesthetic_type: default_desc.description_type
        )
        if existing
          update_description(existing, default_desc)
          return existing
        end
      end

      desc = CharacterDescription.create(
        character_instance_id: instance.id,
        body_position_id: body_pos_id,
        content: default_desc.content,
        image_url: default_desc.image_url,
        concealed_by_clothing: default_desc.concealed_by_clothing,
        display_order: default_desc.display_order,
        aesthetic_type: default_desc.description_type,
        active: true
      )

      # Copy body positions from join table
      copy_positions(desc, default_desc)

      desc
    end

    def sync_positions(instance_desc, default_desc)
      # Get current and target position IDs
      current_pos_ids = instance_desc.body_positions.map(&:id)
      target_pos_ids = default_desc.body_positions.map(&:id)

      # Remove positions not in target
      to_remove = current_pos_ids - target_pos_ids
      if to_remove.any?
        CharacterInstanceDescriptionPosition
          .where(character_description_id: instance_desc.id, body_position_id: to_remove)
          .delete
      end

      # Add positions not in current
      to_add = target_pos_ids - current_pos_ids
      to_add.each do |pos_id|
        CharacterInstanceDescriptionPosition.create(
          character_description_id: instance_desc.id,
          body_position_id: pos_id
        )
      end
    end

    def copy_positions(instance_desc, default_desc)
      default_desc.body_positions.each do |pos|
        CharacterInstanceDescriptionPosition.create(
          character_description_id: instance_desc.id,
          body_position_id: pos.id
        )
      end
    end
  end
end
