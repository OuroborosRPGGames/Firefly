# frozen_string_literal: true

class Character < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps
  
  many_to_one :user
  many_to_one :npc_archetype
  many_to_one :home_room, class: :Room, key: :home_room_id
  many_to_one :npc_template, class: :Character, key: :npc_template_id
  one_to_many :character_shapes
  one_to_many :character_instances
  one_to_many :messages
  one_to_many :bank_accounts
  one_to_many :keys
  one_to_many :npc_memories
  one_to_many :npc_goals
  one_to_many :npc_schedules
  one_to_many :npc_spawn_instances
  one_to_many :npc_spawns, class: :Character, key: :npc_template_id
  one_to_many :pets
  one_to_many :group_memberships, class: :GroupMember
  one_to_many :owned_channels, class: :Channel, key: :owner_id
  one_to_many :owned_vehicles, class: :Vehicle, key: :owner_id
  one_to_many :memos_sent, class: :Memo, key: :sender_character_id
  one_to_many :memos_received, class: :Memo, key: :recipient_character_id
  one_to_many :media_library_items, class: :MediaLibrary
  one_to_many :saved_locations
  many_to_one :profile_gradient, class: :MediaLibrary, key: :profile_gradient_id
  one_to_many :default_descriptions, class: :CharacterDefaultDescription
  one_to_many :profile_pictures
  one_to_many :profile_sections
  one_to_many :profile_videos
  one_to_one :profile_setting

  # Name change cooldown (use centralized config)
  NAME_CHANGE_COOLDOWN = GameConfig::Timeouts::NAME_CHANGE_COOLDOWN_SECONDS

  # Soft delete retention period (30 days)
  SOFT_DELETE_RETENTION_DAYS = 30

  # ========================================
  # Soft Delete Scopes
  # ========================================

  # Characters that are not deleted
  def self.not_deleted
    where(deleted_at: nil)
  end

  # Characters that are soft deleted
  def self.deleted
    exclude(deleted_at: nil)
  end

  # Characters that are soft deleted and past retention period
  def self.expired_deleted
    where { deleted_at < Time.now - (SOFT_DELETE_RETENTION_DAYS * 24 * 3600) }
  end

  # Check if character is soft deleted
  def deleted?
    !deleted_at.nil?
  end

  # Check if character is past retention period
  def deletion_expired?
    deleted? && deleted_at < Time.now - (SOFT_DELETE_RETENTION_DAYS * 24 * 3600)
  end

  # Days remaining until permanent deletion
  def days_until_permanent_deletion
    return nil unless deleted?

    expiry = deleted_at + (SOFT_DELETE_RETENTION_DAYS * 24 * 3600)
    remaining = (expiry - Time.now) / (24 * 3600)
    [remaining.ceil, 0].max
  end

  def validate
    super
    validates_presence [:forename]
    
    # For PCs (non-NPCs), enforce unique forename+surname combination
    # Only check against non-draft characters (drafts don't count for uniqueness)
    if !is_npc && !is_draft
      # Custom uniqueness check that excludes draft characters
      existing = Character.where(is_npc: false, is_draft: false)
      existing = existing.exclude(id: id) if id # Exclude self when updating

      if surname
        if existing.where(forename: forename, surname: surname).any?
          errors.add([:forename, :surname], "combination must be unique for player characters")
        end
      else
        if existing.where(forename: forename, surname: nil).any?
          errors.add(:forename, "must be unique for player characters with no surname")
        end
      end
      validates_presence [:user_id], message: "is required for player characters"
    end
    
    # For NPCs, user_id should be null
    if is_npc && user_id
      errors.add(:user_id, "must be null for NPCs")
    end
    
    validates_min_length 1, :forename
    validates_max_length 50, :forename
    validates_max_length 50, :surname if surname

    # Staff character validation - only permitted users can create staff characters
    if is_staff_character && user && !user.can_create_staff_characters?
      errors.add(:is_staff_character, 'requires staff character creation permission')
    end
  end
  
  def before_save
    super
    self.forename = self.forename.strip if self.forename
    self.surname = self.surname.strip if self.surname

    # Auto-titlecase names (capitalize each word)
    self.forename = titlecase_name(self.forename) if self.forename
    self.surname = titlecase_name(self.surname) if self.surname
    self.nickname = titlecase_name(self.nickname) if self.nickname
    
    # Clear surname if it's empty string
    self.surname = nil if self.surname && self.surname.empty?

    # Cap short_desc length for NPCs (should be a brief identifier, not a paragraph)
    if self.short_desc && self.short_desc.length > 80
      truncated = self.short_desc[0..79]
      last_space = truncated.rindex(' ')
      self.short_desc = last_space && last_space > 20 ? truncated[0...last_space] : truncated
    end
    
    # Maintain backward compatibility with old columns
    if self.forename && !self.name
      self.name = self.surname ? "#{self.forename} #{self.surname}" : self.forename
    end
    
    # Generate session_id if not provided (for backward compatibility)
    self.session_id ||= SecureRandom.hex(16) if respond_to?(:session_id)
  end
  
  def full_name
    # Template monster characters have internal names like "Monster:rat" -
    # return a player-friendly name instead
    if is_npc && !is_unique_npc && forename&.start_with?('Monster:')
      return npc_archetype&.name || forename.sub('Monster:', '').capitalize
    end

    base_name = surname ? "#{forename} #{surname}" : forename
    # Include nickname in quotes if set and different from forename
    if nickname && !nickname.to_s.strip.empty? && nickname != forename
      "#{forename} '#{nickname}' #{surname}".strip
    else
      base_name
    end
  end
  
  # All name forms this character might be referred to as, longest first.
  # Used for name substitution in emotes and personalization.
  # @return [Array<String>] name variants sorted longest-first
  def name_variants
    variants = [full_name]

    # Forename + surname (without nickname quote format)
    if surname
      base = "#{forename} #{surname}"
      variants << base unless variants.include?(base)
    end

    # Nickname (if set and different from forename)
    if nickname && !nickname.to_s.strip.empty? && nickname != forename
      variants << nickname
    end

    # Forename alone
    variants << forename unless variants.include?(forename)

    # Surname alone
    if surname && !surname.to_s.strip.empty?
      variants << surname unless variants.include?(surname)
    end

    # Short description variants (for matching by viewers who don't know this character)
    # Minimum 8 chars to avoid matching common short phrases
    if short_desc && short_desc.to_s.strip.length >= 8
      desc = short_desc.to_s.strip
      variants << desc unless variants.include?(desc)

      # Article interchangeability: "a tall man" also matches "the tall man" and vice versa
      article_match = desc.match(/\A(an?|the)\s+/i)
      if article_match
        without_article = desc.sub(/\A(?:an?|the)\s+/i, '')
        words = without_article.split(/\s+/)

        if words.length >= 2
          # Add "the X" variant if original has a/an, and "a X" if original has "the"
          if article_match[1].downcase == 'the'
            alt = "a #{without_article}"
            variants << alt unless variants.include?(alt)
          else
            alt = "the #{without_article}"
            variants << alt unless variants.include?(alt)
          end

          # Without article entirely
          variants << without_article unless variants.include?(without_article)

          # First two words after stripping article (only if there are more)
          if words.length > 2
            first_two = words[0..1].join(' ')
            variants << first_two unless variants.include?(first_two)
          end
        end
      end
    end

    # Sort longest first to avoid partial matches
    variants.sort_by { |v| -v.length }
  end

  def default_shape
    character_shapes.first(is_default_shape: true) || character_shapes.first
  end
  
  def active_instances
    character_instances.where(status: ['alive', 'unconscious'])
  end
  
  def instance_in_reality(reality_id)
    character_instances.first(reality_id: reality_id)
  end
  
  def online_instances
    character_instances_dataset.where(online: true)
  end

  # Get the primary (first online or first) instance for this character
  def primary_instance
    online_instances.first || character_instances_dataset.first
  end

  # Get the default instance (non-timeline, in primary reality)
  def default_instance
    character_instances_dataset
      .where(is_timeline_instance: false)
      .first || primary_instance
  end

  # Returns all instances including timeline instances
  def all_instances
    character_instances_dataset.all
  end

  # Returns just timeline instances (not primary)
  def timeline_instances
    character_instances_dataset.where(is_timeline_instance: true).all
  end

  # Check if character has multiple playable instances
  def has_timeline_instances?
    character_instances_dataset.where(is_timeline_instance: true).any?
  end
  alias timeline_instances? has_timeline_instances?

  # Display name based on what the viewer knows about this character.
  # Uses shortest unambiguous name: nickname > forename > forename+surname > short_desc.
  # Pass room_characters (array of CharacterInstance) to enable disambiguation
  # against other characters with the same name in the room.
  def display_name_for(viewer_character_instance, room_characters: nil, knowledge: :not_provided)
    # If no viewer, use full name
    return full_name unless viewer_character_instance

    # NPCs are always known by name
    return full_name if is_npc

    # Self-viewing: use nickname or forename (you know your own preferred name)
    if viewer_character_instance.character_id == id
      return present_string(nickname) || forename
    end

    # Check if viewer knows this character (use pre-fetched if provided)
    knowledge = CharacterKnowledge.first(
      knower_character_id: viewer_character_instance.character_id,
      known_character_id: id
    ) if knowledge == :not_provided

    if knowledge&.is_known
      known = knowledge.known_name
      return present_string(known) || full_name unless known

      # Build list of other characters for disambiguation
      others = other_room_characters(room_characters, viewer_character_instance)

      known_lower = known.downcase

      # 1. Nickname (if known and unique in room)
      nick = present_string(nickname)
      if nick && nick != forename && known_lower.include?(nick.downcase)
        return nick unless name_clashes?(nick, others) { |c| c.nickname }
      end

      # 2. Forename (if known and unique in room)
      if forename && known_lower.include?(forename.downcase)
        return forename unless name_clashes?(forename, others) { |c| c.forename }
      end

      # 3. Forename + Surname (if both known)
      if forename && surname && !surname.to_s.strip.empty? &&
         known_lower.include?(forename.downcase) && known_lower.include?(surname.downcase)
        return "#{forename} #{surname}"
      end

      # 4. Whatever we know
      present_string(known) || full_name
    else
      # Use short description or nickname if unknown
      present_string(short_desc) || present_string(nickname) || 'someone'
    end
  end

  # Check if this character is known by another
  def known_by?(viewer_character)
    return false unless viewer_character

    CharacterKnowledge.where(
      knower_character_id: viewer_character.id,
      known_character_id: id,
      is_known: true
    ).any?
  end

  # ---- Pronoun helpers ----
  # These provide gender-appropriate pronouns based on the character's gender attribute.
  # All methods return lowercase strings for easy interpolation.

  # Subject pronoun (he/she/they)
  def pronoun_subject
    case gender&.downcase
    when 'male' then 'he'
    when 'female' then 'she'
    else 'they'
    end
  end

  # Possessive pronoun (his/her/their)
  def pronoun_possessive
    case gender&.downcase
    when 'male' then 'his'
    when 'female' then 'her'
    else 'their'
    end
  end

  # Object pronoun (him/her/them)
  def pronoun_object
    case gender&.downcase
    when 'male' then 'him'
    when 'female' then 'her'
    else 'them'
    end
  end

  # Reflexive pronoun (himself/herself/themselves)
  def pronoun_reflexive
    case gender&.downcase
    when 'male' then 'himself'
    when 'female' then 'herself'
    else 'themselves'
    end
  end
  
  # Introduce this character to another (they learn the name)
  # Accumulates name parts — learning "Testerman" then "Robert" results in "Robert Testerman"
  def introduce_to(other_character, known_as = nil)
    return false unless other_character

    new_name = known_as || full_name

    knowledge = CharacterKnowledge.find_or_create(
      knower_character_id: other_character.id,
      known_character_id: id
    ) do |k|
      k.first_met_at = Time.now
      k.last_seen_at = Time.now
    end

    # Merge newly learned name parts with existing knowledge
    merged = if knowledge.is_known && knowledge.known_name
              merge_known_names(knowledge.known_name, new_name)
            else
              new_name
            end

    knowledge.update(is_known: true, known_name: merged, last_seen_at: Time.now)
    true
  end

  # Build a display name from the set of known name parts
  # Nickname takes preference over forename when both are known
  def build_known_display_name(parts)
    has_nick = parts.include?(:nickname) && nickname && !nickname.to_s.strip.empty? && nickname != forename
    has_fore = parts.include?(:forename)
    has_sur = parts.include?(:surname)

    if has_nick && has_fore && has_sur
      full_name
    elsif has_nick && has_sur
      "#{nickname} #{surname}"
    elsif has_fore && has_sur
      "#{forename} #{surname}"
    elsif has_nick
      nickname
    elsif has_fore
      forename
    elsif has_sur
      surname
    else
      full_name
    end
  end

  # Profile picture URL (alias for picture_url)
  alias_method :profile_pic_url, :picture_url

  # Height display in imperial and metric
  def height_display
    return nil unless height_cm

    total_inches = (height_cm / 2.54).round
    feet = total_inches / 12
    inches = total_inches % 12
    "#{feet}'#{inches}\" / #{height_cm}cm"
  end

  # Convert numeric age to readable age bracket
  # Examples: 18-19 -> "late teens", 23 -> "early twenties", 36 -> "mid thirties"
  # @return [String, nil] age bracket or nil if age not set or under 18
  def apparent_age_bracket
    return nil unless age && age >= 18

    # Special case: 18-19 are "late teens"
    return 'late teens' if age <= 19

    decade = (age / 10) * 10
    position = age % 10

    decade_name = case decade
                  when 20 then 'twenties'
                  when 30 then 'thirties'
                  when 40 then 'forties'
                  when 50 then 'fifties'
                  when 60 then 'sixties'
                  when 70 then 'seventies'
                  when 80 then 'eighties'
                  when 90 then 'nineties'
                  else
                    # 100+ just say "very old"
                    return 'very old' if age >= 100
                    'years old'
                  end

    qualifier = case position
                when 0..4 then 'early'
                when 5..7 then 'mid'
                else 'late'
                end

    "#{qualifier} #{decade_name}"
  end

  # Set a room as this character's home
  def set_home!(room)
    update(home_room_id: room.id)
  end

  # ========================================
  # Public Profile Methods
  # ========================================

  # Scope for publicly visible characters
  # Excludes: NPCs, profile_visible=false
  def self.publicly_visible
    dataset
      .where(is_npc: false)
      .where(profile_visible: true)
  end

  # Check if this character's profile is publicly visible
  def publicly_visible?
    return false if is_npc
    return false unless profile_visible
    return false if user&.agent?
    true
  end

  # Update last seen timestamp
  def touch_last_seen!
    update(last_seen_at: Time.now)
  end

  # Increment profile score for ranking
  def increment_profile_score!(amount = 1)
    update(profile_score: (profile_score || 0) + amount)
  end

  # ========================================
  # NPC Type Methods
  # ========================================

  # Check if this is an NPC (convenience method)
  def npc?
    is_npc
  end

  # Check if this is a unique NPC (one-off character like "Jane the Barmaid")
  def unique_npc?
    npc? && is_unique_npc
  end

  # Check if this is a template NPC (for spawning multiples like "Orc Warrior")
  def template_npc?
    npc? && !is_unique_npc
  end

  # Check if this NPC uses humanoid appearance (hair, eyes, etc.)
  def humanoid_npc?
    return false unless npc?

    # If archetype specifies, use that
    return npc_archetype.is_humanoid if npc_archetype&.is_humanoid != nil

    # Otherwise, check if humanoid fields are set
    (npc_hair_desc && !npc_hair_desc.empty?) ||
      (npc_eyes_desc && !npc_eyes_desc.empty?) ||
      (npc_skin_tone && !npc_skin_tone.empty?)
  end

  # Check if this is a creature/non-humanoid NPC
  def creature_npc?
    npc? && !humanoid_npc?
  end

  # Check if this NPC has hostile behavior (hostile or aggressive)
  # Used to determine death vs knockout in combat
  # @return [Boolean]
  def hostile?
    return false unless npc?

    %w[hostile aggressive].include?(npc_archetype&.behavior_pattern)
  end

  # ========================================
  # NPC Leadership (Lead/Summon)
  # ========================================

  # Check if this NPC can be led by PCs
  # Character override takes precedence, then archetype default
  # @return [Boolean]
  def leadable?
    return false unless npc?
    return leadable_override unless leadable_override.nil?

    npc_archetype&.is_leadable != false
  end

  # Check if this NPC can be summoned by PCs
  # @return [Boolean]
  def summonable?
    return false unless npc?
    return summonable_override unless summonable_override.nil?

    npc_archetype&.is_summonable != false
  end

  # Get the summon range for this NPC
  # @return [String] 'room', 'area', or 'world'
  def summon_range
    npc_archetype&.summon_range || 'area'
  end

  # Build the full appearance description for an NPC
  # @return [String] Full appearance description
  def npc_appearance_description
    return nil unless npc?

    if humanoid_npc?
      build_humanoid_appearance
    else
      npc_creature_desc || npc_body_desc || short_desc
    end
  end

  # Get clothes description for humanoid NPCs
  # @return [String, nil] Clothing description
  def npc_clothing_description
    return nil unless npc? && humanoid_npc?

    npc_clothes_desc
  end

  # @return [Boolean] true if this NPC was spawned from a template
  def spawned_from_template?
    !npc_template_id.nil?
  end

  # ========================================
  # Staff Character Methods
  # ========================================

  # @return [Boolean]
  def staff_character?
    is_staff_character
  end

  # Alias for consistency with new naming
  def staff?
    staff_character?
  end

  # Check if the user who owns this character is an admin
  # @return [Boolean]
  def admin?
    user&.admin?
  end

  # Check if this character can use building commands
  # @return [Boolean]
  def can_build?
    # Staff characters, admin users, or users with build permissions can build
    staff_character? || user&.can_build?
  end

  # Check if staff character has a specific permission via their user
  # @param permission_name [String, Symbol]
  # @return [Boolean]
  def has_user_permission?(permission_name)
    user&.has_permission?(permission_name)
  end

  # Check if this staff character can go invisible
  def can_go_invisible?
    staff_character? && has_user_permission?('can_go_invisible')
  end

  # Check if this staff character can see all RP
  def can_see_all_rp?
    staff_character? && has_user_permission?('can_see_all_rp')
  end

  # Speech color is the same as distinctive_color (no separate field)
  def speech_color
    distinctive_color
  end

  # ===== Handle Display =====

  # Get display handle (formatted name with colors/styles)
  def display_handle
    (handle_display && !handle_display.empty?) ? handle_display : full_name
  end

  # ===== Name Change Cooldown =====

  # Check if character can change their name (21-day cooldown)
  def can_change_name?
    return true unless last_name_change

    last_name_change < Time.now - NAME_CHANGE_COOLDOWN
  end

  # Get days remaining until name can be changed
  def days_until_name_change
    return 0 if can_change_name?

    ((last_name_change + NAME_CHANGE_COOLDOWN - Time.now) / GameConfig::Timeouts::SECONDS_PER_DAY).ceil
  end

  # Get or create default character instance
  def default_instance
    # Try to find an existing instance in the default reality
    default_reality = Reality.first(reality_type: 'primary') || Reality.first
    return nil unless default_reality

    instance = CharacterInstance.where(character_id: id, reality_id: default_reality.id).first
    return instance if instance

    # Create a new instance in the default reality if none exists
    create_default_instance(default_reality)
  end

  # ===== Description Management =====

  # Copy all default descriptions from Character to a CharacterInstance
  # This is called when the character logs in to sync their persistent descriptions
  # @param instance [CharacterInstance] The instance to copy descriptions to
  # @return [Integer] Number of descriptions copied/updated
  def copy_descriptions_to_instance!(instance)
    return 0 unless instance

    copied_count = 0
    default_descriptions_dataset.where(active: true).each do |default_desc|
      # Find or create the instance description for this body position
      existing = CharacterDescription.first(
        character_instance_id: instance.id,
        body_position_id: default_desc.body_position_id
      )

      if existing
        # Update existing description if content differs
        if existing.content != default_desc.content ||
           existing.image_url != default_desc.image_url ||
           existing.concealed_by_clothing != default_desc.concealed_by_clothing
          existing.update(
            content: default_desc.content,
            image_url: default_desc.image_url,
            concealed_by_clothing: default_desc.concealed_by_clothing,
            display_order: default_desc.display_order,
            active: true
          )
          copied_count += 1
        end
      else
        # Create new instance description
        CharacterDescription.create(
          character_instance_id: instance.id,
          body_position_id: default_desc.body_position_id,
          content: default_desc.content,
          image_url: default_desc.image_url,
          concealed_by_clothing: default_desc.concealed_by_clothing,
          display_order: default_desc.display_order,
          active: true
        )
        copied_count += 1
      end
    end

    copied_count
  end

  # Get default descriptions grouped by body region
  # @return [Hash] Descriptions grouped by region (head, torso, arms, hands, legs, feet)
  def descriptions_by_region
    default_descriptions_dataset.eager(:body_position).all.group_by(&:region)
  end

  # ========================================
  # Voice Configuration (TTS)
  # ========================================

  # Get voice settings hash
  # @return [Hash] voice_type, voice_pitch, voice_speed
  def voice_settings
    {
      voice_type: voice_type || 'Kore',
      voice_pitch: voice_pitch || 0.0,
      voice_speed: voice_speed || 1.0
    }
  end

  # Set voice configuration
  # @param type [String] Chirp 3 HD voice name (e.g., 'Kore', 'Charon')
  # @param pitch [Float] Pitch adjustment (-20.0 to +20.0)
  # @param speed [Float] Speaking rate (0.25 to 4.0)
  def set_voice!(type:, pitch: 0.0, speed: 1.0)
    update(
      voice_type: type,
      voice_pitch: pitch.to_f.clamp(-20.0, 20.0),
      voice_speed: speed.to_f.clamp(0.25, 4.0)
    )
  end

  # Check if character has a voice configured
  def has_voice?
    voice_type && !voice_type.to_s.empty?
  end
  alias voice? has_voice?

  private

  # Filter room_characters to other characters (excluding self and viewer)
  def other_room_characters(room_characters, viewer_instance)
    return [] if room_characters.nil?

    room_characters.select do |ci|
      ci.character_id != id && ci.character_id != viewer_instance.character_id
    end
  end

  # Check if a candidate name clashes with another character's name in the room.
  # The block extracts the comparable name field from a Character.
  def name_clashes?(candidate, other_instances)
    return false if other_instances.nil? || other_instances.empty?

    candidate_lower = candidate.downcase
    other_instances.any? do |ci|
      other_name = yield(ci.character)
      other_name && other_name.downcase == candidate_lower
    end
  end

  # Identify which name parts a given string matches
  def identify_name_parts(name_str)
    parts = Set.new
    return parts if name_str.nil?

    lower = name_str.downcase
    parts.add(:forename) if forename && lower.include?(forename.downcase)
    parts.add(:surname) if surname && !surname.to_s.strip.empty? && lower.include?(surname.downcase)
    parts.add(:nickname) if nickname && !nickname.to_s.strip.empty? && nickname != forename && lower.include?(nickname.downcase)
    parts
  end

  # Merge existing known name with newly learned name, accumulating parts
  def merge_known_names(existing_name, new_name)
    known_parts = identify_name_parts(existing_name) | identify_name_parts(new_name)

    if known_parts.empty?
      new_name.length > existing_name.length ? new_name : existing_name
    else
      build_known_display_name(known_parts)
    end
  end

  # Build humanoid NPC appearance from component parts
  # @return [String] Combined appearance description
  def build_humanoid_appearance
    parts = []

    # Body description is the base
    parts << npc_body_desc if npc_body_desc && !npc_body_desc.empty?

    # Add specific features
    has_hair = npc_hair_desc && !npc_hair_desc.empty?
    has_eyes = npc_eyes_desc && !npc_eyes_desc.empty?

    if has_hair || has_eyes
      features = []
      features << npc_hair_desc if has_hair
      features << npc_eyes_desc if has_eyes

      if features.any?
        # Combine features naturally
        feature_text = features.join(' and ')
        parts << "They have #{feature_text}."
      end
    end

    # Add skin tone if specified
    if npc_skin_tone && !npc_skin_tone.empty?
      parts << "They have #{npc_skin_tone} skin."
    end

    # Join all parts or fall back to short_desc
    parts.any? ? parts.join(' ') : short_desc
  end

  # Titlecase a name, handling multi-word names and special cases
  # Examples: "mary jane" -> "Mary Jane", "VAN DER BERG" -> "Van Der Berg"
  def titlecase_name(name)
    return nil if name.nil?
    return '' if name.empty?

    # Split on spaces and capitalize each word
    name.split(/\s+/).map do |word|
      next word if word.empty?

      # Handle hyphenated names like "Mary-Jane"
      if word.include?('-')
        word.split('-').map(&:capitalize).join('-')
      else
        word.capitalize
      end
    end.join(' ')
  end

  def create_default_instance(reality)
    starting_room = Room.tutorial_spawn_room
    return nil unless starting_room

    CharacterInstance.create(
      character_id: id,
      reality_id: reality.id,
      current_room_id: starting_room.id,
      level: 1,
      experience: 0,
      health: 100,
      max_health: 100,
      mana: 50,
      max_mana: 50,
      online: false,
      status: 'alive'
    )
  end

  # Returns the string if it's not nil/empty, otherwise nil (for chaining with ||)
  def present_string(value)
    value if value && !value.to_s.strip.empty?
  end
end