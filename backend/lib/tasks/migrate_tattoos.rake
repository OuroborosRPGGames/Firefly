# frozen_string_literal: true

namespace :migrate do
  desc 'Migrate existing tattoo Items to CharacterDefaultDescription records'
  task :tattoos => :environment do
    require_relative '../../config/environment'

    puts 'Starting tattoo migration...'

    tattoo_items = Item.where(is_tattoo: true).all
    puts "Found #{tattoo_items.count} tattoo items to migrate"

    migrated = 0
    skipped = 0
    errors = 0

    tattoo_items.each do |item|
      begin
        # Get the character via the character_instance
        char_instance = item.character_instance
        unless char_instance
          puts "  SKIP: Item #{item.id} '#{item.name}' has no character_instance"
          skipped += 1
          next
        end

        character = char_instance.character
        unless character
          puts "  SKIP: Item #{item.id} '#{item.name}' - character_instance has no character"
          skipped += 1
          next
        end

        # Check if there's already a description with this content for this character
        existing = CharacterDefaultDescription.where(
          character_id: character.id,
          description_type: 'tattoo',
          content: item.description || item.name
        ).first

        if existing
          puts "  SKIP: Item #{item.id} '#{item.name}' already migrated for character #{character.id}"
          skipped += 1
          next
        end

        # Get body positions for this item
        body_positions = item.item_body_positions.map(&:body_position).compact

        # If no body positions, try to infer from item name
        if body_positions.empty?
          inferred_position = infer_body_position(item.name)
          if inferred_position
            body_positions = [inferred_position]
          end
        end

        # Create the CharacterDefaultDescription
        desc = CharacterDefaultDescription.create(
          character_id: character.id,
          description_type: 'tattoo',
          content: item.description.presence || "A tattoo: #{item.name}",
          image_url: item.image_url,
          display_order: 0,
          concealed_by_clothing: item.properties&.dig('concealed') || false
        )

        # Create position associations
        body_positions.each do |position|
          CharacterDescriptionPosition.create(
            character_default_description_id: desc.id,
            body_position_id: position.id
          )
        end

        puts "  OK: Migrated item #{item.id} '#{item.name}' -> description #{desc.id} for character #{character.full_name}"
        migrated += 1

      rescue StandardError => e
        puts "  ERROR: Item #{item.id} '#{item.name}' - #{e.message}"
        errors += 1
      end
    end

    puts
    puts 'Migration complete!'
    puts "  Migrated: #{migrated}"
    puts "  Skipped:  #{skipped}"
    puts "  Errors:   #{errors}"
  end

  desc 'Delete old tattoo Items after successful migration (dry-run by default)'
  task :delete_old_tattoos, [:confirm] => :environment do |t, args|
    require_relative '../../config/environment'

    confirm = args[:confirm] == 'yes'

    puts confirm ? 'Deleting old tattoo items...' : 'DRY RUN - Would delete these tattoo items:'

    tattoo_items = Item.where(is_tattoo: true).all
    puts "Found #{tattoo_items.count} tattoo items"

    deleted = 0
    kept = 0

    tattoo_items.each do |item|
      char_instance = item.character_instance
      character = char_instance&.character

      if character
        # Check if there's a matching CharacterDefaultDescription
        matching = CharacterDefaultDescription.where(
          character_id: character.id,
          description_type: 'tattoo'
        ).first

        if matching
          if confirm
            # Delete item body positions first
            ItemBodyPosition.where(item_id: item.id).delete
            item.delete
            puts "  DELETED: Item #{item.id} '#{item.name}'"
          else
            puts "  WOULD DELETE: Item #{item.id} '#{item.name}'"
          end
          deleted += 1
        else
          puts "  KEEP: Item #{item.id} '#{item.name}' - no matching description found"
          kept += 1
        end
      else
        puts "  KEEP: Item #{item.id} '#{item.name}' - no character association"
        kept += 1
      end
    end

    puts
    if confirm
      puts "Deleted: #{deleted}"
    else
      puts "Would delete: #{deleted}"
    end
    puts "Kept: #{kept}"
    puts
    puts 'Run with [yes] argument to actually delete: rake migrate:delete_old_tattoos[yes]' unless confirm
  end
end

# Helper to infer body position from item name
def infer_body_position(name)
  name_lower = name.downcase

  # Map common terms to body position labels
  mappings = {
    'wrist' => 'wrist',
    'forearm' => 'forearm',
    'upper arm' => 'upper_arm',
    'bicep' => 'upper_arm',
    'shoulder' => 'shoulder',
    'back' => 'back',
    'lower back' => 'lower_back',
    'chest' => 'chest',
    'stomach' => 'stomach',
    'abdomen' => 'stomach',
    'thigh' => 'thigh',
    'calf' => 'calf',
    'ankle' => 'ankle',
    'foot' => 'feet',
    'neck' => 'neck',
    'face' => 'cheeks',
    'hand' => 'palm'
  }

  mappings.each do |term, label|
    if name_lower.include?(term)
      position = BodyPosition.first(label: label)
      return position if position
    end
  end

  nil
end
