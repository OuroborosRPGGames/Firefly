# frozen_string_literal: true

# Service for building simplified NPC display data
# NPCs use a simpler display system than player characters:
# - Humanoids: body desc, hair, eyes, skin tone, clothes
# - Creatures: just description
class NpcDisplayService
  include CharacterDisplayConcern
  include StringHelper

  attr_reader :target, :character, :viewer

  def initialize(target_instance, viewer_instance: nil)
    @target = target_instance
    @character = target_instance.character
    @viewer = viewer_instance
  end

  # Build complete display data for an NPC
  # @return [Hash] structured NPC display data
  def build_display
    {
      profile_pic_url: @character.profile_pic_url,
      name: display_name,
      short_desc: @character.short_desc,
      status: @target.status,
      roomtitle: @target.roomtitle,
      is_npc: true,
      is_humanoid: @character.humanoid_npc?,
      intro: build_intro,
      appearance: build_appearance,
      clothing: build_clothing,
      held_items: [],
      thumbnails: collect_thumbnails,
      at_place: @target.at_place? ? @target.current_place&.name : nil,
      behavior: @character.npc_archetype&.behavior_pattern
    }
  end

  private

  def build_intro
    if @character.humanoid_npc?
      build_humanoid_intro
    else
      build_creature_intro
    end
  end

  def build_humanoid_intro
    parts = []

    # Body description
    parts << @character.npc_body_desc if present?(@character.npc_body_desc)

    # Eyes
    if present?(@character.npc_eyes_desc)
      parts << "#{pronoun_subject} has #{@character.npc_eyes_desc}."
    end

    # Hair
    if present?(@character.npc_hair_desc)
      parts << "#{pronoun_possessive} hair is #{@character.npc_hair_desc}."
    end

    # Skin tone
    if present?(@character.npc_skin_tone)
      parts << "#{pronoun_subject} has #{@character.npc_skin_tone} skin."
    end

    parts.join(' ')
  end

  def build_creature_intro
    @character.npc_creature_desc || @character.npc_body_desc || @character.short_desc || ''
  end

  def build_appearance
    if @character.humanoid_npc?
      {
        type: 'humanoid',
        body: @character.npc_body_desc,
        hair: @character.npc_hair_desc,
        eyes: @character.npc_eyes_desc,
        skin_tone: @character.npc_skin_tone
      }
    else
      {
        type: 'creature',
        description: @character.npc_creature_desc || @character.npc_body_desc
      }
    end
  end

  def build_clothing
    return [] unless @character.humanoid_npc?
    return [] unless present?(@character.npc_clothes_desc)

    # Return clothing as a single descriptive item
    [{
      name: 'attire',
      description: @character.npc_clothes_desc,
      is_clothing: true,
      is_jewelry: false
    }]
  end

  def collect_thumbnails
    thumbnails = []

    # Profile pic as thumbnail
    if present?(@character.profile_pic_url)
      thumbnails << {
        type: 'profile',
        url: @character.profile_pic_url,
        full_url: @character.profile_pic_url
      }
    end

    thumbnails
  end

end
