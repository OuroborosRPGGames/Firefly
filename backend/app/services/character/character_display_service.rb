# frozen_string_literal: true

# Service for building rich character display data for the look command
# Follows updated display format:
# - Name line: known name, short desc
# - Intro: single sentence with build, ethnicity, height
# - Eyes/Hair line: extracted or defaults
# - Descriptions with separators
# - Thumbnails: held first, then items + body descriptions interleaved by body position
# - Using section: combined held + worn items head-to-toe
#
# Performance notes:
# - Uses memoization to avoid duplicate queries for descriptions, clothing, held items
class CharacterDisplayService
  include CharacterDisplayConcern

  # Body position ordering for head-to-toe display
  BODY_POSITION_ORDER = %w[
    head scalp face forehead eyes eyebrows nose cheeks mouth lips chin ears
    neck throat collarbone shoulders upper_back back mid_back lower_back chest breasts stomach waist
    upper_arms elbows forearms wrists hands fingers
    hips groin buttocks thighs knees calves ankles feet toes
  ].freeze

  # Map specific left/right body position labels to their general position for sorting
  BODY_POSITION_NORMALIZE = {
    'left_shoulder' => 'shoulders', 'right_shoulder' => 'shoulders',
    'left_bicep' => 'upper_arms', 'right_bicep' => 'upper_arms',
    'left_forearm' => 'forearms', 'right_forearm' => 'forearms',
    'left_wrist' => 'wrists', 'right_wrist' => 'wrists',
    'left_hand' => 'hands', 'right_hand' => 'hands',
    'left_thigh' => 'thighs', 'right_thigh' => 'thighs',
    'left_calf' => 'calves', 'right_calf' => 'calves',
    'left_foot' => 'feet', 'right_foot' => 'feet'
  }.freeze

  attr_reader :target, :character, :viewer, :xray, :show_private

  def initialize(target_instance, viewer_instance: nil, xray: false)
    @target = target_instance
    @character = target_instance.character
    @viewer = viewer_instance
    @xray = xray
    @show_private = VisibilityService.show_private_content?(viewer_instance, target_instance)
  end

  # Build complete display data for a character
  # Delegates to NpcDisplayService for NPCs (simplified appearance)
  # @return [Hash] structured character display data
  def build_display
    # Delegate to NpcDisplayService for NPCs
    if @character.npc?
      return NpcDisplayService.new(@target, viewer_instance: @viewer).build_display
    end

    {
      profile_pic_url: @character.profile_pic_url,
      name: display_name,
      casual_name: display_name,
      short_desc: @character.short_desc,
      name_line: build_name_line,
      status: @target.status,
      roomtitle: @target.roomtitle,
      is_npc: @character.is_npc,
      gender: @character.gender,
      intro: build_intro,
      eyes_hair_line: build_eyes_hair_line,
      descriptions: build_other_descriptions,
      clothing: cached_clothing_list,
      held_items: cached_held_items,
      using_items: build_using_items,
      thumbnails: collect_thumbnails_ordered,
      at_place: @target.at_place? ? @target.current_place&.name : nil,
      wetness_level: @target.wetness || 0,
      injury_level: calculate_injury_level
    }
  end

  private

  # Calculate injury level (HP lost) for display overlays
  # @return [Integer] 0-6 based on current health vs max health
  def calculate_injury_level
    max_hp = @target.max_health || 6
    current_hp = @target.health || max_hp
    [max_hp - current_hp, 0].max
  end

  # Build the combined name line: "Bob, a tall man"
  # @return [String] name and short_desc combined
  def build_name_line
    name = display_name
    short = @character.short_desc
    if StringHelper.present?(short)
      # Force first letter to lowercase for grammatical flow
      short_display = short.to_s.strip
      short_display = short_display[0].downcase + short_display[1..] if short_display.length > 0
      "#{name}, #{short_display}"
    else
      name
    end
  end

  # Build intro as single sentence: "He is a muscular Asian man in his mid twenties standing at 5'10\"."
  # @return [String] the intro sentence
  def build_intro
    # Body description (build + ethnicity + gender noun)
    body = body_description
    height = @character.height_display
    age_bracket = @character.apparent_age_bracket

    # Build age phrase: "in his mid twenties" or "in their late teens"
    # Use lowercase possessive pronoun since this appears mid-sentence
    age_phrase = age_bracket ? "in #{@character.pronoun_possessive} #{age_bracket}" : nil

    if body && age_phrase && height
      # Full sentence with all parts
      "#{pronoun_subject} #{verb_is} #{body} #{age_phrase} standing at #{height}."
    elsif body && age_phrase
      "#{pronoun_subject} #{verb_is} #{body} #{age_phrase}."
    elsif body && height
      "#{pronoun_subject} #{verb_is} #{body} standing at #{height}."
    elsif body
      "#{pronoun_subject} #{verb_is} #{body}."
    elsif age_phrase && height
      "#{pronoun_subject} #{verb_is} #{age_phrase} and #{verb_stands} at #{height}."
    elsif age_phrase
      "#{pronoun_subject} #{verb_is} #{age_phrase}."
    elsif height
      "#{pronoun_subject} #{verb_stands} at #{height}."
    else
      nil
    end
  end

  # Build the eyes and hair line
  # Only uses defaults - if user has custom descriptions, those appear separately
  # @return [String, nil] "He has brown eyes and a bald head." or nil if custom descriptions exist
  def build_eyes_hair_line
    body_descs = cached_body_descriptions

    # Find custom eyes description (not the default)
    eyes_desc = body_descs.find { |d| d[:body_position] == 'eyes' && d[:aesthetic_type] != 'default' }
    # Find custom hair description (not the default)
    hair_desc = body_descs.find { |d| (d[:body_position] == 'scalp' || d[:aesthetic_type] == 'hairstyle') && d[:aesthetic_type] != 'default' }

    # If user has BOTH custom descriptions, skip eyes_hair_line entirely
    # (custom descriptions will appear in their own section with full formatting)
    return nil if eyes_desc && hair_desc

    # Otherwise, show defaults for any missing custom ones
    if eyes_desc
      # User has custom eyes but not hair - show hair default only? No, show combined with custom eye
      eyes_text = extract_feature_from_content(eyes_desc[:content], 'eyes')
    else
      eyes_text = 'brown eyes'
    end

    if hair_desc
      hair_text = extract_feature_from_content(hair_desc[:content], 'hair')
    else
      hair_text = 'a bald head'
    end

    "#{pronoun_subject} #{verb_has} #{eyes_text} and #{hair_text}."
  end

  # Extract a feature description from content text
  # If the content is a full sentence, try to extract just the feature
  # @param content [String] the full description content
  # @param feature_type [String] 'eyes' or 'hair'
  # @return [String] extracted feature description
  def extract_feature_from_content(content, feature_type)
    return content if StringHelper.blank?(content)

    # Strip HTML tags from content (descriptions may have color formatting)
    text = content.to_s.gsub(/<[^>]+>/, '').strip

    # If it's already short, use as-is
    return text if text.length < 50 && !text.include?('. ')

    # Try to extract just the relevant part
    case feature_type
    when 'eyes'
      # Look for patterns like "blue eyes", "piercing green eyes"
      if match = text.match(/\b([\w\s]+(?:eyes|gaze))\b/i)
        match[1].strip.downcase
      else
        'brown eyes'
      end
    when 'hair'
      # Look for patterns like "long blonde hair", "curly black hair", "is bald"
      if text.downcase.include?('bald')
        'a bald head'
      elsif match = text.match(/\b([\w\s]+hair)\b/i)
        match[1].strip.downcase
      elsif match = text.match(/\b([\w\s]+(locks|curls|waves|braids|dreads|dreadlocks|mane|tresses|ringlets|coils))\b/i)
        # Handle alternative hair terms
        match[1].strip.downcase
      else
        # For short text, use as-is; for longer, try to extract the first clause
        text.length < 50 ? text : (text.split(/[.,]/).first&.strip || 'styled hair')
      end
    else
      text
    end
  end

  # Build descriptions excluding eyes and hair (which go in eyes_hair_line)
  # Includes separator information for each description
  # @return [Array<Hash>] descriptions with type, content, separator
  def build_other_descriptions
    all_descriptions = []

    # Profile descriptions (personality, background, etc.)
    profile_descriptions = @target.descriptions_for_display.eager(description_type: :description_type_body_positions).all
    filtered_profile = VisibilityService.filter_descriptions_for_privacy(
      profile_descriptions,
      @target,
      viewer: @viewer
    )

    filtered_profile.each do |desc|
      desc_type = desc.description_type
      content = desc.content
      # Apply auto-capitalization for proper grammar
      content = DescriptionGrammarService.auto_capitalize(content) if content
      all_descriptions << {
        type: desc_type&.name,
        content: content,
        content_type: desc_type&.content_type || 'text',
        image_url: desc_type&.content_type == 'image_url' ? desc.content : nil,
        suffix: desc.suffix || 'period',
        prefix: desc.prefix || 'none'
      }
    end

    # Body position descriptions
    # Include custom eye/hair descriptions (non-default), exclude only defaults
    body_descriptions = cached_body_descriptions.reject do |d|
      # Exclude default eye/hair (they go in eyes_hair_line)
      # Include custom eye/hair (user-created, aesthetic_type != 'default')
      is_eye_or_hair = d[:body_position] == 'eyes' || d[:body_position] == 'scalp' || d[:aesthetic_type] == 'hairstyle'
      is_default = d[:aesthetic_type] == 'default'
      is_eye_or_hair && is_default
    end

    body_descriptions.each do |desc|
      all_descriptions << desc
    end

    all_descriptions
  end

  # Memoized methods to avoid duplicate queries in collect_thumbnails
  def cached_descriptions
    @cached_descriptions ||= build_descriptions_legacy
  end

  def cached_body_descriptions
    @cached_body_descriptions ||= build_body_descriptions
  end

  def cached_clothing_list
    @cached_clothing_list ||= build_clothing_list
  end

  def cached_held_items
    @cached_held_items ||= build_held_items
  end

  # Legacy method for backwards compatibility - returns all descriptions
  def build_descriptions_legacy
    all_descriptions = []

    # Profile descriptions (personality, background, etc.)
    profile_descriptions = @target.descriptions_for_display.eager(description_type: :description_type_body_positions).all
    filtered_profile = VisibilityService.filter_descriptions_for_privacy(
      profile_descriptions,
      @target,
      viewer: @viewer
    )

    filtered_profile.each do |desc|
      desc_type = desc.description_type
      content = desc.content
      # Apply auto-capitalization for proper grammar
      content = DescriptionGrammarService.auto_capitalize(content) if content
      all_descriptions << {
        type: desc_type&.name,
        content: content,
        content_type: desc_type&.content_type || 'text',
        image_url: desc_type&.content_type == 'image_url' ? desc.content : nil,
        suffix: desc.suffix || 'period',
        prefix: desc.prefix || 'none'
      }
    end

    # Body position descriptions
    body_descriptions = cached_body_descriptions
    all_descriptions.concat(body_descriptions)

    all_descriptions
  end

  def body_description
    # Use body_type from character if available
    # Downcase body_type for mid-sentence use (e.g., "an athletic")
    # Keep ethnicity capitalized as proper adjective (e.g., "Asian")
    body_type = @character.body_type&.downcase
    ethnicity = @character.ethnicity

    if body_type && ethnicity
      "#{article_for(body_type)} #{body_type} #{ethnicity} #{gender_noun}"
    elsif body_type
      "#{article_for(body_type)} #{body_type} #{gender_noun}"
    elsif ethnicity
      "#{article_for(ethnicity)} #{ethnicity} #{gender_noun}"
    else
      nil
    end
  end

  def gender_noun
    case @character.gender&.downcase
    when 'male' then 'man'
    when 'female' then 'woman'
    else 'person'
    end
  end

  # Verb conjugation for "to be" based on gender/pronoun
  # Uses plural form for singular "they" (gender-neutral)
  # @return [String] "is" or "are"
  def verb_is
    uses_plural_conjugation? ? 'are' : 'is'
  end

  # Verb conjugation for "to have" based on gender/pronoun
  # Uses plural form for singular "they" (gender-neutral)
  # @return [String] "has" or "have"
  def verb_has
    uses_plural_conjugation? ? 'have' : 'has'
  end

  # Verb conjugation for "to stand" based on gender/pronoun
  # Uses plural form for singular "they" (gender-neutral)
  # @return [String] "stands" or "stand"
  def verb_stands
    uses_plural_conjugation? ? 'stand' : 'stands'
  end

  # Check if this character uses plural verb conjugation (for "they")
  # @return [Boolean] true if gender is unspecified/non-binary
  def uses_plural_conjugation?
    gender = @character.gender&.downcase
    gender.nil? || !%w[male female].include?(gender)
  end

  def article_for(word)
    return 'a' unless word
    %w[a e i o u].include?(word[0]&.downcase) ? 'an' : 'a'
  end

  # Build body position descriptions with defaults for hair and eyes
  # @return [Array<Hash>] Body position descriptions
  def build_body_descriptions
    return [] unless @target.respond_to?(:body_descriptions_for_display)

    body_descs = @target.body_descriptions_for_display.eager(:body_position).all
    filtered = VisibilityService.filter_descriptions_for_privacy(
      body_descs,
      @target,
      viewer: @viewer
    )

    # Track if we have hair (scalp/hairstyle) and eyes descriptions
    has_hair = false
    has_eyes = false

    result = filtered.map do |desc|
      # Use all_positions to handle both legacy body_position_id and join table
      positions = desc.respond_to?(:all_positions) ? desc.all_positions : [desc.body_position].compact
      position_labels = positions.map { |p| p.label&.downcase }.compact
      primary_position_label = position_labels.first

      has_hair = true if position_labels.include?('scalp') || desc.hairstyle?
      has_eyes = true if position_labels.include?('eyes')

      # Apply auto-capitalization for proper grammar
      content = DescriptionGrammarService.auto_capitalize(desc.content) if desc.content

      {
        type: desc.position_label || desc.aesthetic_type&.capitalize || 'Body',
        content: content,
        content_type: 'text',
        image_url: desc.image_url,
        body_position: primary_position_label,
        aesthetic_type: desc.aesthetic_type,
        suffix: desc.suffix || 'period',
        prefix: desc.prefix || 'none'
      }
    end

    # Add default hair description if none exists
    # Note: Content is just the feature text, not a full sentence
    # The eyes_hair_line builder will construct the full sentence
    unless has_hair
      result.unshift({
        type: 'Hair',
        content: 'a bald head',
        content_type: 'text',
        image_url: nil,
        body_position: 'scalp',
        aesthetic_type: 'default',
        suffix: 'period',
        prefix: 'none'
      })
    end

    # Add default eyes description if none exists
    # Note: Content is just the feature text, not a full sentence
    unless has_eyes
      result.unshift({
        type: 'Eyes',
        content: 'brown eyes',
        content_type: 'text',
        image_url: nil,
        body_position: 'eyes',
        aesthetic_type: 'default',
        suffix: 'period',
        prefix: 'none'
      })
    end

    result
  end

  def build_clothing_list
    items = VisibilityService.visible_clothing_for_privacy(@target, viewer: @viewer, xray: @xray)

    items.map do |item|
      # Suppress images for underwear items when not in private mode
      hide_images = !@show_private && !@xray && VisibilityService.underwear_item?(item) &&
                    !(@viewer && @viewer.id == @target.id)

      entry = {
        id: item.id,
        name: item.name,
        description: item.description,
        worn_layer: item.worn_layer,
        torn: item.torn,
        torn_percentage: item.damage_percentage,
        image_url: hide_images ? nil : item.image_url,
        thumbnail_url: hide_images ? nil : item.thumbnail_url,
        is_clothing: item.clothing?,
        is_jewelry: item.jewelry?,
        is_holster: item.pattern&.holster?,
        body_positions: item_body_positions(item)
      }

      # Include holstered weapons for holster items
      if item.pattern&.holster?
        entry[:holstered_weapons] = item.holstered_weapons.map do |weapon|
          { id: weapon.id, name: weapon.name, description: weapon.description }
        end
        # Build display name with holstered weapons
        entry[:display_name] = holster_display_name(item)
      end

      entry
    end
  end

  # Get body position labels for an item
  # @param item [Item] the item to get positions for
  # @return [Array<String>] body position labels
  def item_body_positions(item)
    return [] unless item.respond_to?(:item_body_positions)

    item.item_body_positions.map { |ibp| ibp.body_position&.label&.downcase }.compact
  end

  # Build display name for a holster with its contents
  def holster_display_name(holster_item)
    weapons = holster_item.holstered_weapons
    return holster_item.name if weapons.empty?

    weapon_names = weapons.map(&:name)
    weapon_text = weapon_names.size == 1 ? weapon_names.first : weapon_names.join(' and ')
    "#{holster_item.name} holding #{weapon_text}"
  end

  def build_held_items
    @target.held_items.map do |item|
      {
        id: item.id,
        name: item.name,
        hand: item.equipment_slot || 'hand',
        image_url: item.image_url,
        thumbnail_url: item.thumbnail_url
      }
    end
  end

  # Build combined using_items list: held items first, then worn items head-to-toe
  # @return [Array<Hash>] combined items list with item_type indicator
  def build_using_items
    items = []

    # Held items first
    cached_held_items.each do |item|
      items << item.merge(item_type: 'held')
    end

    # Worn items sorted by body position (head-to-toe)
    sorted_clothing = sort_items_by_body_position(cached_clothing_list)
    sorted_clothing.each do |item|
      items << item.merge(item_type: 'worn')
    end

    items
  end

  # Sort items by body position in head-to-toe order
  # @param items [Array<Hash>] items with body_positions field
  # @return [Array<Hash>] sorted items
  def sort_items_by_body_position(items)
    items.sort_by do |item|
      positions = item[:body_positions] || []
      if positions.empty?
        999 # Items without positions go last
      else
        # Use the earliest position in the head-to-toe order
        positions.map { |p| body_position_sort_order(p) }.min
      end
    end
  end

  # Normalize a body position label and return its sort order index
  # Handles specific labels like 'right_foot' by mapping to general 'feet'
  def body_position_sort_order(position)
    return 999 if position.nil?

    normalized = BODY_POSITION_NORMALIZE[position] || position
    BODY_POSITION_ORDER.index(normalized) || 999
  end

  # Collect thumbnails in specified order:
  # 1. Held items first
  # 2. Items + body descriptions interleaved by body position (head-to-toe)
  # @return [Array<Hash>] ordered thumbnails
  def collect_thumbnails_ordered
    thumbnails = []

    # 1. Held items with images first
    cached_held_items.each do |item|
      next unless item[:thumbnail_url] || item[:image_url]
      thumbnails << {
        type: 'held_item',
        item_name: item[:name],
        url: item[:thumbnail_url] || item[:image_url],
        full_url: item[:image_url],
        body_position: nil
      }
    end

    # 2. Collect all items and descriptions with body positions
    positioned_thumbnails = []

    # Clothing with images
    cached_clothing_list.each do |item|
      next unless item[:thumbnail_url] || item[:image_url]
      positions = item[:body_positions] || []
      primary_position = positions.first
      positioned_thumbnails << {
        type: 'clothing',
        item_name: item[:name],
        url: item[:thumbnail_url] || item[:image_url],
        full_url: item[:image_url],
        body_position: primary_position,
        sort_order: body_position_sort_order(primary_position)
      }
    end

    # Descriptions with images - include all body descriptions including eyes
    # (previously excluded eyes but users want to see eye description images)
    cached_body_descriptions.each do |desc|
      next unless desc[:image_url]

      positioned_thumbnails << {
        type: 'description',
        desc_type: desc[:type],
        url: desc[:image_url],
        full_url: desc[:image_url],
        body_position: desc[:body_position],
        sort_order: body_position_sort_order(desc[:body_position])
      }
    end

    # Sort by body position (head-to-toe)
    positioned_thumbnails.sort_by! { |t| t[:sort_order] }

    # Add to thumbnails list
    thumbnails.concat(positioned_thumbnails.map { |t| t.except(:sort_order) })

    thumbnails
  end
end
