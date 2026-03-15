# frozen_string_literal: true

# Additional factories for models not covered by individual factory files
# Note: character, user, message are defined in separate files

FactoryBot.define do
  # === BASE WORLD HIERARCHY ===

  factory :universe do
    sequence(:name) { |n| "Test Universe #{n}" }
    theme { 'fantasy' }
    active { true }
  end

  factory :world do
    association :universe
    sequence(:name) { |n| "Test World #{n}" }
    gravity_multiplier { 1.0 }
    world_size { 1000.0 }
    coordinates_x { 0 }
    coordinates_y { 0 }
    coordinates_z { 0 }
    active { true }
  end

  factory :zone do
    association :world
    sequence(:name) { |n| "Test Zone #{n}" }
    zone_type { 'city' }
    danger_level { 1 }
    active { true }
    polygon_points { [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }, { x: 0, y: 10 }] }
  end

  # Legacy alias for backward compatibility
  factory :area, parent: :zone

  factory :location do
    association :zone
    sequence(:name) { |n| "Test Location #{n}" }
    location_type { 'building' }
    active { true }
  end

  factory :weather do
    association :location
    condition { 'clear' }
    intensity { 'moderate' }
    temperature_c { 20 }
    humidity { 50 }
    wind_speed_kph { 10 }
    cloud_cover { 30 }
    weather_source { 'internal' }
  end

  factory :room do
    association :location
    sequence(:name) { |n| "Test Room #{n}" }
    short_description { 'A test room.' }
    long_description { 'This is a test room for testing purposes.' }
    room_type { 'standard' }
    active { true }
    min_x { 0.0 }
    max_x { 100.0 }
    min_y { 0.0 }
    max_y { 100.0 }
    min_z { 0.0 }
    max_z { 10.0 }
    indoors { true }
  end

  factory :room_hex do
    association :room
    hex_x { 0 }
    hex_y { 0 }
    hex_type { 'normal' }
    danger_level { 0 }
    traversable { true }
    elevation { 0 }
    cover_value { 0 }
  end

  # NOTE: room_exit factory removed - RoomExit model deleted
  # Navigation now uses spatial adjacency via RoomAdjacencyService

  # === REALITY & CHARACTER INSTANCE ===

  factory :reality do
    sequence(:name) { |n| "Test Reality #{n}" }
    reality_type { 'primary' }
    time_offset { 0 }
    active { true }

    trait :primary do
      reality_type { 'primary' }
    end

    trait :flashback do
      reality_type { 'flashback' }
    end
  end

  factory :timeline do
    association :reality, factory: [:reality, :flashback]
    sequence(:name) { |n| "Test Timeline #{n}" }
    timeline_type { 'historical' }  # Default to historical (doesn't require snapshot)
    year { 1920 }
    association :zone
    is_active { true }
    rooms_read_only { true }
    restrictions { Sequel.pg_jsonb_wrap({ 'no_death' => true, 'no_prisoner' => true, 'no_xp' => true }) }

    # Snapshot timeline requires a snapshot
    trait :snapshot do
      timeline_type { 'snapshot' }
      year { nil }
      zone { nil }
      association :snapshot, factory: :character_snapshot
    end

    # Historical timeline (explicit trait if needed)
    trait :historical do
      timeline_type { 'historical' }
      year { 1920 }
      era { 'Prohibition Era' }
      association :zone
    end
  end

  factory :character_snapshot do
    association :character
    association :room
    sequence(:name) { |n| "Snapshot #{n}" }
    allowed_character_ids { Sequel.pg_jsonb_wrap([]) }
    frozen_state { Sequel.pg_jsonb_wrap({ 'level' => 1, 'health' => 6, 'max_health' => 6 }) }
    snapshot_taken_at { Time.now }
  end

  factory :character_instance do
    association :character
    association :reality
    association :current_room, factory: :room
    status { 'alive' }
    level { 1 }
    experience { 0 }
    health { 6 }
    max_health { 6 }
    mana { 50 }
    max_mana { 50 }
    online { true }
    x { 50.0 }
    y { 50.0 }
    z { 0.0 }

    # Trait to ensure character is not in any active fights
    # Use this in combat tests to prevent "already in fight" errors
    trait :not_in_combat do
      after(:create) do |ci|
        # Complete any ongoing fights this character is in
        FightParticipant.where(character_instance_id: ci.id)
                        .eager(:fight)
                        .all
                        .each do |fp|
          fp.fight&.update(status: 'complete') if fp.fight&.ongoing?
        end
      end
    end
  end

  # === ROOM FEATURES ===

  factory :room_feature do
    association :room
    sequence(:name) { |n| "Feature #{n}" }
    feature_type { 'window' }
    x { 50.0 }
    y { 0.0 }
    z { 5.0 }
    width { 1.0 }
    height { 2.0 }
    orientation { 'north' }
    open_state { 'open' }
    transparency_state { 'transparent' }
    visibility_state { 'both_ways' }
    allows_sight { true }
    allows_movement { false }
    direction { nil }

    trait :wall do
      feature_type { 'wall' }
      open_state { 'closed' }
      transparency_state { 'opaque' }
      allows_sight { false }
      allows_movement { false }
    end

    trait :door do
      feature_type { 'door' }
      open_state { 'closed' }
      transparency_state { 'opaque' }
      allows_movement { true }
    end
  end

  factory :room_sightline do
    association :from_room, factory: :room
    association :to_room, factory: :room
    has_sight { true }
    sight_quality { 0.8 }
    bidirectional { true }
  end

  # === KNOWLEDGE ===

  factory :character_knowledge do
    association :knower_character, factory: :character
    association :known_character, factory: :character
    is_known { true }
    known_name { nil }
    first_met_at { Time.now }
    last_seen_at { Time.now }
  end

  # === API TOKENS ===

  factory :user_api_token do
    association :user
    sequence(:name) { |n| "Token #{n}" }
    token_digest { BCrypt::Password.create(SecureRandom.hex(32)) }
    expires_at { nil }
    last_used_at { nil }
  end

  # === OBJECT SYSTEM ===

  factory :unified_object_type do
    sequence(:name) { |n| "Object Type #{n}" }
    category { 'Top' }
  end

  factory :pattern do
    association :unified_object_type
    sequence(:description) { |n| "Pattern #{n}" }
    price { 100 }

    # Weapon traits for combat testing
    # Note: category/subcategory come from unified_object_type, not pattern directly
    trait :melee_weapon do
      association :unified_object_type, factory: :unified_object_type, category: 'Sword', subcategory: 'melee'
      attack_speed { 5 }
      weapon_range { 'melee' }
      is_melee { true }
      is_ranged { false }
    end

    trait :ranged_weapon do
      association :unified_object_type, factory: :unified_object_type, category: 'Firearm', subcategory: 'ranged'
      attack_speed { 3 }
      weapon_range { 'medium' }
      is_melee { false }
      is_ranged { true }
    end

    trait :fast_melee do
      association :unified_object_type, factory: :unified_object_type, category: 'Sword', subcategory: 'melee'
      attack_speed { 8 }
      weapon_range { 'melee' }
      is_melee { true }
      is_ranged { false }
    end

    trait :slow_melee do
      association :unified_object_type, factory: :unified_object_type, category: 'Sword', subcategory: 'melee'
      attack_speed { 2 }
      weapon_range { 'melee' }
      is_melee { true }
      is_ranged { false }
    end
  end

  # === NPC SYSTEM ===

  factory :npc_archetype do
    sequence(:name) { |n| "Archetype #{n}" }
    behavior_pattern { 'friendly' }
    is_humanoid { true }
    name_pattern { '{archetype}' }
    name_counter { 0 }
    spawn_health_range { '100-100' }
    spawn_level_range { '1-1' }

    trait :humanoid do
      is_humanoid { true }
    end

    trait :creature do
      is_humanoid { false }
    end

    # Animation traits
    trait :animated do
      animation_level { 'high' }
      animation_primary_model { 'claude-sonnet-4-6' }
      animation_first_emote_model { 'claude-opus-4-6' }
      animation_personality_prompt { 'A friendly merchant who enjoys helping customers' }
      animation_cooldown_seconds { 300 }
    end

    trait :animation_high do
      animation_level { 'high' }
    end

    trait :animation_medium do
      animation_level { 'medium' }
    end

    trait :animation_low do
      animation_level { 'low' }
    end

    trait :animation_off do
      animation_level { 'off' }
    end
  end

  factory :rp_log do
    association :room
    association :character_instance
    timeline_id { character_instance&.timeline_id }
    content { 'Test message in the RP log' }
    log_type { 'say' }
  end

  factory :npc_animation_queue do
    association :character_instance
    association :room
    trigger_type { 'high_turn' }
    trigger_content { 'Hello there!' }
    status { 'pending' }
    priority { 5 }

    trait :pending do
      status { 'pending' }
    end

    trait :processing do
      status { 'processing' }
    end

    trait :complete do
      status { 'complete' }
      processed_at { Time.now }
    end

    trait :failed do
      status { 'failed' }
      error_message { 'Test failure' }
    end
  end

  factory :npc_schedule do
    association :character, factory: [:character, :npc]
    association :room
    start_hour { 0 }
    end_hour { 24 }
    is_active { true }
    probability { 100 }
    weekdays { 'all' }
    max_npcs { 1 }
  end

  factory :item, class: 'Item' do
    association :pattern
    association :character_instance
    sequence(:name) { |n| "Item #{n}" }
    quantity { 1 }
    condition { 'good' }

    trait :in_room do
      character_instance { nil }
      association :room
    end
  end

  factory :fabrication_order do
    association :character
    association :pattern
    association :fabrication_room, factory: :room
    status { 'crafting' }
    delivery_method { 'pickup' }
    started_at { Time.now }
    completes_at { Time.now + 3600 }

    trait :ready do
      status { 'ready' }
      completes_at { Time.now - 60 }
    end

    trait :delivered do
      status { 'delivered' }
      completes_at { Time.now - 60 }
      delivered_at { Time.now }
    end

    trait :cancelled do
      status { 'cancelled' }
    end

    trait :delivery_method_delivery do
      delivery_method { 'delivery' }
      association :delivery_room, factory: :room
    end

    trait :completed_fabrication do
      completes_at { Time.now - 60 }
    end
  end

  # === COMBAT SYSTEM ===

  factory :fight do
    association :room
    round_number { 1 }
    status { 'input' }
    started_at { Time.now }
    arena_width { 10 }
    arena_height { 10 }
  end

  factory :fight_participant do
    association :fight
    association :character_instance
    current_hp { 5 }
    max_hp { 5 }
    hex_x { 0 }
    hex_y { 0 }
    side { 1 }
    input_complete { false }
    is_knocked_out { false }

    # Position traits for combat testing
    trait :center_arena do
      hex_x { 5 }
      hex_y { 5 }
    end

    trait :corner_arena do
      hex_x { 0 }
      hex_y { 0 }
    end

    trait :far_corner do
      hex_x { 9 }
      hex_y { 9 }
    end

    # For testing melee combat - pair with another participant at (5,6)
    trait :melee_position_a do
      hex_x { 5 }
      hex_y { 5 }
    end

    # For testing melee combat - pair with :melee_position_a (distance = 1)
    trait :melee_position_b do
      hex_x { 5 }
      hex_y { 6 }
    end

    # Side traits for team-based combat testing
    trait :side_1 do
      side { 1 }
    end

    trait :side_2 do
      side { 2 }
    end
  end

  factory :status_effect do
    sequence(:name) { |n| "Effect #{n}" }
    effect_type { 'stat_modifier' }
    is_buff { false }
    stacking_behavior { 'refresh' }
    max_stacks { 1 }

    trait :buff do
      is_buff { true }
      effect_type { 'stat_modifier' }
    end

    trait :debuff do
      is_buff { false }
      effect_type { 'stat_modifier' }
    end

    trait :dot do
      effect_type { 'damage_over_time' }
      is_buff { false }
    end

    trait :stackable do
      stacking_behavior { 'stack' }
      max_stacks { 5 }
    end
  end

  factory :participant_status_effect do
    association :fight_participant
    association :status_effect
    expires_at_round { 3 }
    stack_count { 1 }
    effect_value { 0 }

    trait :expired do
      expires_at_round { 0 }
    end

    trait :stacked do
      stack_count { 3 }
    end
  end

  factory :cover_object_type do
    sequence(:name) { |n| "Cover #{n}" }
    category { 'furniture' }
    size { 'medium' }
    default_cover_value { 2 }
    default_height { 1 }
    default_hp { 20 }
    hex_width { 1 }
    hex_height { 1 }
    is_destroyable { true }
    is_explosive { false }
    is_flammable { false }

    trait :small do
      size { 'small' }
      default_cover_value { 1 }
    end

    trait :large do
      size { 'large' }
      hex_width { 2 }
      hex_height { 2 }
      default_cover_value { 3 }
    end

    trait :vehicle do
      category { 'vehicle' }
      default_cover_value { 3 }
      default_hp { 50 }
    end

    trait :explosive do
      is_explosive { true }
      is_destroyable { true }
    end

    trait :flammable do
      is_flammable { true }
    end
  end

  factory :ability do
    association :universe
    sequence(:name) { |n| "Ability #{n}" }
    ability_type { 'combat' }
    action_type { 'main' }
    target_type { 'enemy' }
    activation_segment { 50 }
    segment_variance { 2 }
    aoe_shape { 'single' }
    damage_type { 'fire' }

    trait :with_cooldown do
      cooldown_seconds { 60 }
    end

  end

  factory :character_ability do
    association :character_instance
    association :ability
    learned_at { Time.now }
    uses_today { 0 }
  end

  factory :fight_event do
    association :fight
    round_number { 1 }
    segment { 1 }
    event_type { 'attack' }
    details { {} }

    trait :hit do
      event_type { 'hit' }
    end

    trait :miss do
      event_type { 'miss' }
    end

    trait :move do
      event_type { 'move' }
    end

    trait :knockout do
      event_type { 'knockout' }
    end
  end

  # === HELPFILES & LORE ===

  factory :helpfile do
    sequence(:command_name) { |n| "testcommand#{n}" }
    sequence(:topic) { |n| "testcommand#{n}" }
    plugin { 'core' }
    summary { 'A test command for testing' }
    category { 'general' }
    hidden { false }
    admin_only { false }
    auto_generated { false }
    is_lore { false }

    trait :lore do
      is_lore { true }
      category { 'lore' }
      summary { 'Lore about the world' }
    end

    trait :hidden do
      hidden { true }
    end

    trait :admin_only do
      admin_only { true }
    end
  end

  # === NPC RELATIONSHIPS ===

  factory :npc_relationship do
    association :npc_character, factory: [:character, :npc]
    association :pc_character, factory: :character
    sentiment { 0.0 }
    trust { 0.5 }
    interaction_count { 0 }
  end

  # === CHANNELS & ADDRESS HISTORY ===

  factory :channel do
    association :universe
    sequence(:name) { |n| "Channel #{n}" }
    channel_type { 'ooc' }
    is_public { true }
    is_default { false }

    trait :ooc do
      channel_type { 'ooc' }
    end

    trait :ic do
      channel_type { 'ic' }
    end

    trait :global do
      channel_type { 'global' }
    end

    trait :private do
      channel_type { 'private' }
      is_public { false }
    end

    trait :default do
      is_default { true }
    end
  end

  factory :channel_member do
    association :channel
    association :character
    role { 'member' }
    is_muted { false }
    joined_at { Time.now }
  end

  # === EVENTS ===

  factory :event do
    association :organizer, factory: :character
    association :room
    association :location
    sequence(:name) { |n| "Test Event #{n}" }
    sequence(:title) { |n| "Test Event #{n}" }
    event_type { 'party' }
    starts_at { Time.now + 3600 }  # 1 hour from now
    ends_at { nil }
    status { 'scheduled' }
    is_public { true }
    logs_visible_to { 'public' }

    trait :active do
      status { 'active' }
      started_at { Time.now }
    end

    trait :completed do
      status { 'completed' }
      started_at { Time.now - 7200 }
      ended_at { Time.now - 3600 }
    end

    trait :cancelled do
      status { 'cancelled' }
    end

    trait :private do
      is_public { false }
    end

    trait :in_progress do
      starts_at { Time.now - 30 }  # Started 30 seconds ago
      status { 'scheduled' }
    end
  end

  factory :event_attendee do
    association :event
    association :character
    status { 'yes' }
    role { 'attendee' }

    trait :host do
      role { 'host' }
    end

    trait :staff do
      role { 'staff' }
    end

    trait :maybe do
      status { 'maybe' }
    end

    trait :no do
      status { 'no' }
    end
  end

  # === ACTIVITY SYSTEM ===

  factory :activity do
    sequence(:name) { |n| "Test Activity #{n}" }
    description { 'A test activity for testing' }
    activity_type { 'mission' }
    share_type { 'public' }
    launch_mode { 'creator' }
    is_public { true }
    repeatable { true }
    pending_approval { false }
    stat_type { 'standard' }
    wins { 0 }
    losses { 0 }

    trait :mission do
      activity_type { 'mission' }
    end

    trait :adventure do
      activity_type { 'adventure' }
    end

    trait :competition do
      activity_type { 'competition' }
    end

    trait :team_competition do
      activity_type { 'tcompetition' }
      team_name_one { 'Red Team' }
      team_name_two { 'Blue Team' }
    end

    trait :task do
      activity_type { 'task' }
    end

    trait :collaboration do
      activity_type { 'collaboration' }
    end

    trait :interpersonal do
      activity_type { 'intersym' }
    end

    trait :private do
      share_type { 'private' }
      is_public { false }
    end

    trait :emergency do
      is_emergency { true }
      can_emergency { true }
    end

    trait :with_anchor_item do
      association :anchor_item, factory: :item
    end
  end

  factory :activity_instance do
    transient do
      activity { nil }
      room { nil }
    end

    atype { 'mission' }
    setup_stage { 1 }
    rounds_done { 0 }
    branch { 0 }
    running { true }

    after(:build) do |instance, evaluator|
      if evaluator.activity
        instance.activity_id = evaluator.activity.id
      elsif instance.activity_id.nil?
        instance.activity_id = create(:activity).id
      end
      if evaluator.room
        instance.room_id = evaluator.room.id
      elsif instance.room_id.nil?
        instance.room_id = create(:room).id
      end
    end

    trait :completed do
      running { false }
      setup_stage { 3 }
    end

    trait :in_setup do
      setup_stage { 1 }
    end

    trait :running do
      running { true }
      setup_stage { 2 }
    end

    trait :paused_for_combat do
      paused_for_fight_id { create(:fight).id }
    end

    trait :test_run do
      test_run { true }
    end

    trait :emergency do
      is_emergency { true }
    end
  end

  factory :activity_participant do
    transient do
      instance { nil }
      character { nil }
    end

    team { nil }
    continue { true }

    after(:build) do |participant, evaluator|
      if evaluator.instance
        participant.instance_id = evaluator.instance.id
      elsif participant.instance_id.nil?
        inst = create(:activity_instance)
        participant.instance_id = inst.id
      end
      if evaluator.character
        participant.char_id = evaluator.character.id
      elsif participant.char_id.nil?
        participant.char_id = create(:character).id
      end
    end

    trait :team_one do
      team { 'one' }
    end

    trait :team_two do
      team { 'two' }
    end

    trait :inactive do
      continue { false }
    end

    trait :with_choice do
      action_chosen { 1 }
      willpower_to_spend { 0 }
      chosen_when { Time.now }
    end

    trait :with_willpower do
      willpower_to_spend { 1 }
    end

    trait :helping do
      effort_chosen { 'help' }
    end

    trait :recovering do
      effort_chosen { 'recover' }
    end

    trait :injured do
      injured { true }
    end

    trait :no_willpower do
      willpower { 0 }
    end
  end

  factory :activity_round do
    transient do
      activity { nil }
    end

    sequence(:round_number) { |n| n }
    branch { 0 }
    rtype { 'standard' }
    emit { 'Round begins...' }
    succ_text { 'Success!' }
    fail_text { 'Failed!' }

    after(:build) do |round, evaluator|
      if evaluator.activity
        round.activity_id = evaluator.activity.id
      elsif round.activity_id.nil?
        round.activity_id = create(:activity).id
      end
    end

    trait :standard do
      rtype { 'standard' }
    end

    trait :reflex do
      rtype { 'reflex' }
    end

    trait :group_check do
      rtype { 'group_check' }
    end

    trait :combat do
      rtype { 'combat' }
    end

    trait :free_roll do
      rtype { 'free_roll' }
    end

    trait :persuade do
      rtype { 'persuade' }
      persuade_base_dc { 15 }
    end

    trait :rest do
      rtype { 'rest' }
    end

    trait :branch do
      rtype { 'branch' }
      branch_choice_one { 'Take the left path' }
      branch_choice_two { 'Take the right path' }
    end

    trait :knockout do
      knockout { true }
    end

    trait :can_repeat do
      fail_repeat { true }
    end

    trait :with_media do
      media_url { 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' }
      media_type { 'youtube' }
    end

    trait :finale do
      combat_is_finale { true }
    end
  end

  factory :activity_task do
    transient do
      round { nil }
    end

    task_number { 1 }
    description { 'Primary objective' }
    dc_reduction { 3 }
    min_participants { 1 }

    after(:build) do |task, evaluator|
      if evaluator.round
        task.activity_round_id = evaluator.round.id
      elsif task.activity_round_id.nil?
        task.activity_round_id = create(:activity_round).id
      end
    end

    trait :primary do
      task_number { 1 }
    end

    trait :secondary do
      task_number { 2 }
      description { 'Secondary objective' }
      min_participants { 3 }
    end
  end

  factory :activity_action do
    transient do
      activity { nil }
    end

    choice_string { 'Perform Action' }
    output_string { 'Action succeeded!' }
    fail_string { 'Action failed!' }
    skill_one { nil }
    skill_two { nil }

    after(:build) do |action, evaluator|
      if evaluator.activity
        action.activity_parent = evaluator.activity.id
      elsif action.activity_parent.nil?
        action.activity_parent = create(:activity).id
      end
    end

    trait :with_skills do
      skill_one { 1 }
      skill_two { 2 }
    end

  end

  factory :activity_log do
    transient do
      activity_instance { nil }
    end

    association :character
    log_type { 'action' }
    text { 'Test log entry' }
    round_number { 1 }
    sequence(:sequence) { |n| n }

    after(:build) do |log, evaluator|
      if evaluator.activity_instance
        log.activity_instance_id = evaluator.activity_instance.id
      elsif log.activity_instance_id.nil?
        log.activity_instance_id = create(:activity_instance).id
      end
    end

    trait :narrative do
      log_type { 'narrative' }
    end

    trait :round_start do
      log_type { 'round_start' }
    end

    trait :outcome do
      log_type { 'outcome' }
      outcome { 'success' }
    end
  end

  factory :activity_profile do
    association :character

    activity_buckets { {} }
    total_samples { 0 }
    weeks_tracked { 0 }
    tracking_enabled { true }
    share_schedule { true }

    trait :with_data do
      total_samples { 50 }
      weeks_tracked { 2 }
      activity_buckets { { 'mon_14' => 80, 'mon_15' => 75, 'tue_20' => 60, 'wed_18' => 45 } }
    end
  end

  # === TICKETS ===

  factory :ticket do
    association :user
    association :room
    category { 'bug' }
    subject { 'Test Ticket Subject' }
    content { 'This is the ticket content describing the issue.' }
    status { 'open' }

    trait :resolved do
      status { 'resolved' }
      association :resolved_by_user, factory: :user
      resolution_notes { 'Issue has been fixed.' }
      resolved_at { Time.now }
    end

    trait :closed do
      status { 'closed' }
      association :resolved_by_user, factory: :user
      resolution_notes { 'Closed as duplicate.' }
      resolved_at { Time.now }
    end

    trait :investigated do
      investigation_notes { 'AI analysis: This appears to be a display bug.' }
      investigated_at { Time.now }
    end

    trait :typo do
      category { 'typo' }
    end

    trait :bug do
      category { 'bug' }
    end

    trait :suggestion do
      category { 'suggestion' }
    end
  end

  factory :autohelper_request do
    association :user
    sequence(:query) { |n| "test query #{n}" }
    sequence(:clean_query) { |n| "test query #{n}" }
    success { false }
    sources { Sequel.pg_array([]) }
    ticket_created { false }
    ticket_id { nil }
    error_message { nil }
    created_at { Time.now }
  end

  # === CONTENT CONSENT ===

  factory :content_restriction do
    association :universe
    sequence(:name) { |n| "Content Type #{n}" }
    sequence(:code) { |n| "TYPE#{n}" }
    description { 'A content type for testing' }
    severity { 'moderate' }
    is_active { true }
    requires_mutual_consent { true }

    trait :violence do
      name { 'Violence' }
      code { 'VIOLENCE' }
      severity { 'moderate' }
    end

    trait :mature do
      name { 'Mature Content' }
      code { 'MATURE' }
      severity { 'mature' }
    end

    trait :inactive do
      is_active { false }
    end
  end

  factory :content_consent do
    association :character
    association :content_restriction
    consented { false }

    trait :consenting do
      consented { true }
      consented_at { Time.now }
    end
  end

  factory :consent_override do
    association :character
    association :target_character, factory: :character
    association :content_restriction
    allowed { false }
    granted_at { nil }
    revoked_at { nil }

    trait :allowed do
      allowed { true }
      granted_at { Time.now }
    end

    trait :revoked do
      allowed { false }
      revoked_at { Time.now }
    end
  end

  # === OOC REQUESTS ===

  factory :ooc_request do
    association :sender_user, factory: :user
    association :target_user, factory: :user
    message { 'I would like to discuss something OOC.' }
    status { 'pending' }

    transient do
      sender_character { nil }
      target_character { nil }
    end

    after(:build) do |request, evaluator|
      request[:sender_character_id] = evaluator.sender_character&.id if evaluator.sender_character
      request[:target_character_id] = evaluator.target_character&.id if evaluator.target_character
    end

    trait :accepted do
      status { 'accepted' }
      responded_at { Time.now }
    end

    trait :declined do
      status { 'declined' }
      responded_at { Time.now }
      cooldown_until { Time.now + 3600 }
    end
  end

  # === AUDIO QUEUE ===

  factory :audio_queue_item do
    association :character_instance
    sequence(:audio_url) { |n| "https://example.com/audio/#{n}.mp3" }
    content_type { 'narrator' }
    sequence(:sequence_number) { |n| n }
    played { false }
    queued_at { Time.now }
    expires_at { Time.now + 600 }

    trait :played do
      played { true }
      played_at { Time.now }
    end

    trait :expired do
      expires_at { Time.now - 60 }
    end
  end

  # === KEYS ===

  factory :key do
    association :character
    key_type { 'physical' }

    trait :for_exit do
      association :room_exit
    end

    trait :for_feature do
      association :room_feature
    end

    trait :for_container do
      association :item
    end

    trait :master do
      key_type { 'master' }
    end

    trait :temporary do
      key_type { 'temporary' }
      expires_at { Time.now + 3600 }
    end

    trait :expired do
      key_type { 'temporary' }
      expires_at { Time.now - 60 }
    end
  end

  # === CLUES ===

  factory :clue do
    sequence(:name) { |n| "Clue #{n}" }
    content { 'This is clue content with enough characters to pass validation.' }
    is_active { true }
    is_secret { false }
    share_likelihood { 0.5 }
    min_trust_required { 0.0 }

    trait :secret do
      is_secret { true }
      min_trust_required { 0.5 }
    end

    trait :high_likelihood do
      share_likelihood { 0.9 }
    end

    trait :low_likelihood do
      share_likelihood { 0.1 }
    end

    trait :scene_specific do
      association :arranged_scene
    end

    trait :inactive do
      is_active { false }
    end
  end

  factory :npc_clue do
    association :clue
    association :character

    trait :with_overrides do
      share_likelihood_override { 0.8 }
      min_trust_override { 0.3 }
    end
  end

  factory :clue_share do
    association :clue
    association :npc_character, factory: :character
    association :recipient_character, factory: :character
    shared_at { Time.now }
    context { 'During a conversation' }
  end

  # === TRIGGERS ===

  factory :trigger do
    association :created_by, factory: :user
    sequence(:name) { |n| "Trigger #{n}" }
    trigger_type { 'mission' }
    condition_type { 'exact' }
    action_type { 'code_block' }
    condition_value { 'test condition' }
    is_active { true }

    trait :npc_trigger do
      trigger_type { 'npc' }
      association :npc_character, factory: :character
    end

    trait :world_memory do
      trigger_type { 'world_memory' }
    end

    trait :llm_match do
      condition_type { 'llm_match' }
    end

    trait :staff_alert do
      action_type { 'staff_alert' }
    end

    trait :inactive do
      is_active { false }
    end
  end

  # === ECONOMY ===

  factory :currency do
    association :universe
    sequence(:name) { |n| "Currency #{n}" }
    sequence(:symbol) { |n| "C#{n}" }
    decimal_places { 2 }
    is_primary { false }

    trait :primary do
      is_primary { true }
    end

    # Alias for backwards compatibility
    trait :default do
      is_primary { true }
    end

    trait :whole_numbers do
      decimal_places { 0 }
    end
  end

  factory :wallet do
    association :character_instance
    association :currency
    balance { 100 }

    trait :empty do
      balance { 0 }
    end

    trait :rich do
      balance { 10000 }
    end
  end

  # === MESSAGING ===

  factory :memo do
    association :sender, factory: :character
    association :recipient, factory: :character
    sequence(:subject) { |n| "Subject #{n}" }
    content { 'This is the memo body text.' }
    read { false }

    transient do
      sender_character { nil }
      recipient_character { nil }
    end

    after(:build) do |memo, evaluator|
      memo[:sender_id] = evaluator.sender_character&.id || memo.sender&.id
      memo[:recipient_id] = evaluator.recipient_character&.id || memo.recipient&.id
    end

    trait :read do
      read { true }
    end

    trait :unread do
      read { false }
    end
  end

  # === GROUPS ===

  factory :group do
    association :universe
    sequence(:name) { |n| "Group #{n}" }
    group_type { 'faction' }
    status { 'active' }
    is_public { true }
    is_secret { false }

    trait :guild do
      group_type { 'guild' }
    end

    trait :party do
      group_type { 'party' }
    end

    trait :clan do
      group_type { 'clan' }
    end

    trait :secret do
      is_secret { true }
      is_public { false }
    end

    trait :inactive do
      status { 'inactive' }
    end

    trait :disbanded do
      status { 'disbanded' }
    end
  end

  factory :group_member do
    association :group
    association :character
    rank { 'member' }
    status { 'active' }
    joined_at { Time.now }

    trait :officer do
      rank { 'officer' }
    end

    trait :leader do
      rank { 'leader' }
    end

    trait :inactive do
      status { 'inactive' }
    end

    trait :suspended do
      status { 'suspended' }
    end

    trait :with_handle do
      handle { 'ShadowAgent' }
    end
  end

  factory :group_room_unlock do
    association :group
    association :room
    expires_at { nil }

    trait :permanent do
      expires_at { nil }
    end

    trait :temporary do
      expires_at { Time.now + 24 * 60 * 60 }
    end

    trait :expired do
      expires_at { Time.now - 1 }
    end
  end

  # === SOCIAL ===

  factory :saved_location do
    association :character
    association :room
    sequence(:location_name) { |n| "Location #{n}" }
  end

  # === NEWS ===

  factory :news_article do
    association :author, factory: :character
    sequence(:headline) { |n| "Breaking News #{n}" }
    body { 'This is the news article body content.' }
    category { 'local' }
    status { 'draft' }
    byline { 'Staff Reporter' }
    written_at { Time.now }

    trait :published do
      status { 'published' }
      published_at { Time.now }
    end

    trait :breaking do
      category { 'breaking' }
    end
  end

  factory :bulletin do
    association :character
    body { 'This is a bulletin message.' }
    posted_at { Time.now }
    from_text { 'Test Author' }
  end

  # === LOCATIONS & FURNITURE ===

  factory :place do
    association :room
    sequence(:name) { |n| "Place #{n}" }
    capacity { 4 }
    invisible { false }
    is_furniture { false }

    trait :furniture do
      is_furniture { true }
    end

    trait :invisible do
      invisible { true }
    end
  end

  factory :decoration do
    association :room
    sequence(:name) { |n| "Decoration #{n}" }
    description { 'A decorative item' }
    display_order { 0 }
  end

  factory :outfit do
    association :character_instance
    sequence(:name) { |n| "Outfit #{n}" }
  end

  factory :outfit_item do
    association :outfit
    association :pattern
    display_order { 0 }
  end

  # === BANKING ===

  factory :bank_account do
    association :character
    association :currency
    balance { 1000 }
    sequence(:account_name) { |n| "ACC#{n}" }
  end

  # === SHOPS ===

  factory :shop do
    association :room
    sequence(:name) { |n| "Shop #{n}" }
    free_items { false }
    cash_shop { false }

    trait :free do
      free_items { true }
    end

    trait :cash_only do
      cash_shop { true }
    end

    trait :closed do
      is_open { false }
    end
  end

  factory :shop_item do
    association :shop
    association :pattern
    price { 50 }
    stock { 10 }

    trait :unlimited do
      stock { -1 }
    end

    trait :out_of_stock do
      stock { 0 }
    end

    trait :free do
      price { 0 }
    end
  end

  # === VEHICLES ===

  factory :vehicle do
    association :owner, factory: :character
    association :current_room, factory: :room
    sequence(:name) { |n| "Vehicle #{n}" }
    status { 'parked' }
    health { 100 }
    convertible { false }
    roof_open { false }

    trait :convertible do
      convertible { true }
    end

    trait :roof_open do
      convertible { true }
      roof_open { true }
    end

    trait :damaged do
      health { 25 }
    end

    trait :moving do
      status { 'moving' }
    end
  end

  # === CARD GAMES ===

  factory :deck_pattern do
    association :creator, factory: :character
    sequence(:name) { |n| "Deck Pattern #{n}" }
    description { 'A test deck pattern' }
    is_public { true }
    cost { 0 }
  end

  factory :card do
    association :deck_pattern
    sequence(:name) { |n| "Card #{n}" }
    suit { 'Hearts' }
    rank { 'Ace' }
    sequence(:display_order) { |n| n }
  end

  factory :deck do
    association :deck_pattern
    association :dealer, factory: :character_instance
    card_ids { Sequel.pg_array([], :integer) }
    center_faceup { Sequel.pg_array([], :integer) }
    center_facedown { Sequel.pg_array([], :integer) }
    discard_pile { Sequel.pg_array([], :integer) }
  end

  # === STAT SYSTEM ===

  factory :stat_block do
    association :universe
    sequence(:name) { |n| "Stat Block #{n}" }
    block_type { 'single' }
    is_default { false }
    total_points { 50 }
    min_stat_value { 1 }
    max_stat_value { 10 }

    trait :default do
      is_default { true }
    end

    trait :paired do
      block_type { 'paired' }
      total_points { 25 }
      secondary_points { 25 }
      max_stat_value { 5 }
    end
  end

  factory :stat do
    association :stat_block
    sequence(:name) { |n| "Stat #{n}" }
    sequence(:abbreviation) { |n| "ST#{n}" }
    stat_category { 'primary' }
    min_value { 1 }
    max_value { 10 }
    default_value { 5 }
    display_order { 0 }

    trait :skill do
      stat_category { 'skill' }
    end

    trait :secondary do
      stat_category { 'secondary' }
    end

    trait :derived do
      stat_category { 'derived' }
    end
  end

  factory :character_stat do
    association :character_instance
    association :stat
    base_value { 5 }
    temp_modifier { 0 }

    trait :maxed do
      base_value { 10 }
    end

    trait :minimum do
      base_value { 1 }
    end

    trait :modified do
      temp_modifier { 2 }
      modifier_expires_at { Time.now + 3600 }
    end
  end

  # === CHARACTER SHAPE SYSTEM ===

  factory :character_shape do
    association :character
    sequence(:shape_name) { |n| "Shape #{n}" }
    shape_type { 'humanoid' }
    size { 'medium' }
    is_default_shape { false }

    trait :default do
      is_default_shape { true }
    end

    trait :animal do
      shape_type { 'animal' }
    end

    trait :elemental do
      shape_type { 'elemental' }
    end

    trait :large do
      size { 'large' }
    end

    trait :small do
      size { 'small' }
    end
  end

  # === BODY SYSTEM ===

  factory :body_position do
    sequence(:label) { |n| "body_position_#{n}" }
    region { 'torso' }
    is_private { false }
    display_order { 0 }

    trait :private do
      is_private { true }
    end

    trait :head do
      region { 'head' }
    end

    trait :torso do
      region { 'torso' }
    end

    trait :arms do
      region { 'arms' }
    end

    trait :hands do
      region { 'hands' }
    end

    trait :legs do
      region { 'legs' }
    end

    trait :feet do
      region { 'feet' }
    end
  end

  factory :item_body_position do
    association :object, factory: :item
    association :body_position
    covers { true }
  end

  factory :character_default_description do
    association :character
    association :body_position
    content { 'A description of this body part.' }
    active { true }
    concealed_by_clothing { false }
    display_order { 0 }
    description_type { 'natural' }

    trait :hidden do
      concealed_by_clothing { true }
    end

    trait :inactive do
      active { false }
    end

    trait :tattoo do
      description_type { 'tattoo' }
    end

    trait :makeup do
      description_type { 'makeup' }
    end

    trait :hairstyle do
      description_type { 'hairstyle' }
    end
  end

  factory :character_description_position do
    association :character_default_description
    association :body_position
  end

  factory :character_instance_description_position do
    transient do
      character_description { nil }
    end

    association :body_position
    character_description_id { nil }

    after(:build) do |position, evaluator|
      if evaluator.character_description
        position.character_description_id = evaluator.character_description.id
      end
    end
  end

  # === WORLD HEX SYSTEM ===

  factory :world_hex do
    association :world
    sequence(:globe_hex_id) { |n| n }
    terrain_type { 'grassy_plains' }
    elevation { 0 }

    trait :ocean do
      terrain_type { 'ocean' }
    end

    trait :mountain do
      terrain_type { 'mountain' }
      elevation { 100 }
    end

    trait :forest do
      terrain_type { 'dense_forest' }
    end

    trait :urban do
      terrain_type { 'urban' }
    end

    trait :desert do
      terrain_type { 'desert' }
    end

    trait :tundra do
      terrain_type { 'tundra' }
    end

    trait :jungle do
      terrain_type { 'jungle' }
    end

    trait :swamp do
      terrain_type { 'swamp' }
    end
  end

  factory :world_region do
    association :world
    region_x { 0 }
    region_y { 0 }
    zoom_level { 0 }
    dominant_terrain { 'grassy_plains' }
    avg_altitude { 0 }
    traversable_percentage { 100.0 }
    has_road { false }
    has_river { false }
    has_railway { false }
    is_generated { false }
    is_modified { false }

    trait :ocean do
      dominant_terrain { 'ocean' }
      traversable_percentage { 0.0 }
    end

    trait :with_features do
      has_road { true }
      has_river { true }
    end

    trait :generated do
      is_generated { true }
    end

    trait :hex_level do
      zoom_level { 7 }
    end
  end

  factory :world_terrain_raster do
    association :world
    resolution_x { 4096 }
    resolution_y { 2048 }
    generated_at { Time.now }
    hex_count { 0 }
    source_type { 'hexes' }

    trait :with_png do
      png_data { "\x89PNG\r\n\x1A\n" } # Minimal PNG header
    end

    trait :stale do
      world_modified_at { Time.now - 3600 }
    end

    trait :fresh do
      world_modified_at { Time.now }
    end
  end

  factory :world_journey do
    association :world
    association :origin_location, factory: :location
    association :destination_location, factory: :location
    current_globe_hex_id { 1 }
    travel_mode { 'land' }
    vehicle_type { 'car' }
    status { 'traveling' }
    started_at { Time.now }
    speed_modifier { 1.0 }

    trait :arrived do
      status { 'arrived' }
    end

    trait :cancelled do
      status { 'cancelled' }
    end

    trait :paused do
      status { 'paused' }
    end

    trait :by_train do
      travel_mode { 'rail' }
      vehicle_type { 'train' }
    end

    trait :by_ship do
      travel_mode { 'water' }
      vehicle_type { 'ferry' }
    end

    trait :by_air do
      travel_mode { 'air' }
      vehicle_type { 'airplane' }
    end

    trait :medieval do
      vehicle_type { 'horse' }
    end
  end

  factory :world_journey_passenger do
    association :world_journey
    association :character_instance
    is_driver { false }
    boarded_at { Time.now }

    trait :driver do
      is_driver { true }
    end
  end

  factory :delve do
    sequence(:name) { |n| "Test Dungeon #{n}" }
    difficulty { 'normal' }
    status { 'active' }
    max_depth { 10 }
    time_limit_minutes { 60 }
    seed { SecureRandom.hex(8) }
    levels_generated { 1 }

    trait :easy do
      difficulty { 'easy' }
    end

    trait :hard do
      difficulty { 'hard' }
    end

    trait :nightmare do
      difficulty { 'nightmare' }
    end

    trait :generating do
      status { 'generating' }
    end

    trait :completed do
      status { 'completed' }
      completed_at { Time.now }
    end
  end

  # === LLM SERVICES ===

  factory :llm_conversation, class: 'LLMConversation' do
    sequence(:conversation_id) { |n| "conv-#{SecureRandom.uuid[0..7]}-#{n}" }
    purpose { 'general' }
    system_prompt { 'You are a helpful assistant.' }
    metadata { {} }
    last_message_at { Time.now }

    trait :npc_chat do
      purpose { 'npc_chat' }
      system_prompt { 'You are an NPC in a fantasy game.' }
    end

    trait :room_description do
      purpose { 'room_description' }
      system_prompt { 'You are a creative writer describing game rooms.' }
    end
  end

  factory :llm_message, class: 'LLMMessage' do
    association :llm_conversation
    role { 'user' }
    content { 'Hello, how are you?' }
    token_count { 10 }

    trait :assistant do
      role { 'assistant' }
      content { 'I am doing well, thank you for asking!' }
    end

    trait :system do
      role { 'system' }
      content { 'You are a helpful assistant.' }
    end
  end

  factory :llm_request, class: 'LLMRequest' do
    sequence(:request_id) { |n| "req-#{SecureRandom.uuid[0..7]}-#{n}" }
    request_type { 'text' }
    status { 'pending' }
    prompt { 'Test prompt' }
    provider { 'openai' }
    model { 'gpt-5-mini' }
    callback_handler { nil }
    context { {} }
    options { {} }
    retry_count { 0 }
    max_retries { 3 }

    trait :text do
      request_type { 'text' }
      provider { 'openai' }
      model { 'gpt-5-mini' }
    end

    trait :image do
      request_type { 'image' }
      provider { 'openai' }
      model { 'dall-e-3' }
      prompt { 'A fantasy landscape' }
    end

    trait :embedding do
      request_type { 'embedding' }
      provider { 'voyage' }
      model { 'voyage-3-large' }
      options { { input_type: 'document' } }
    end

    trait :processing do
      status { 'processing' }
      started_at { Time.now }
    end

    trait :completed do
      status { 'completed' }
      started_at { Time.now - 2 }
      completed_at { Time.now }
      response_text { 'Test response' }
    end

    trait :failed do
      status { 'failed' }
      started_at { Time.now - 2 }
      completed_at { Time.now }
      error_message { 'Test error' }
    end

    trait :with_conversation do
      association :llm_conversation
    end

    trait :with_callback do
      callback_handler { 'TestCallbackHandler' }
    end
  end

# === MINI-GAMES ===

  factory :game_pattern do
    sequence(:name) { |n| "Test Game #{n}" }
    association :creator, factory: :character
    share_type { 'public' }
    has_scoring { false }
  end

  factory :game_instance do
    association :game_pattern
    association :room
    custom_name { nil }

    trait :for_item do
      room { nil }
      association :item
    end
  end

  factory :game_pattern_branch do
    association :game_pattern
    sequence(:name) { |n| "branch_#{n}" }
    sequence(:display_name) { |n| "Branch #{n}" }
    position { 1 }
    description { nil }
    stat { nil }
  end

  factory :game_pattern_result do
    association :game_pattern_branch
    position { 1 }
    message { 'You did something!' }
    # Note: the column is `points`, and `point_value` is a method that returns points || 0
  end

  # === WORLD MEMORY ===

  factory :world_memory do
    summary { 'A test world memory about events that happened.' }
    started_at { Time.now - 3600 }
    ended_at { Time.now }
    memory_at { Time.now }
    importance { 5 }
    message_count { 10 }
    abstraction_level { 1 }
    publicity_level { 'public' }
    source_type { 'session' }
    excluded_from_public { false }

    trait :private do
      publicity_level { 'private' }
    end

    trait :high_importance do
      importance { 9 }
    end

    trait :abstracted do
      association :abstracted_into, factory: :world_memory
    end
  end

  factory :world_memory_abstraction do
    association :source_memory, factory: :world_memory
    association :target_memory, factory: :world_memory
    branch_type { 'global' }
    branch_reference_id { nil }

    trait :location_branch do
      branch_type { 'location' }
      sequence(:branch_reference_id) { |n| n }
    end

    trait :character_branch do
      branch_type { 'character' }
      sequence(:branch_reference_id) { |n| n }
    end

    trait :npc_branch do
      branch_type { 'npc' }
      sequence(:branch_reference_id) { |n| n }
    end

    trait :lore_branch do
      branch_type { 'lore' }
      sequence(:branch_reference_id) { |n| n }
    end
  end

  factory :world_memory_npc do
    association :world_memory
    association :character
    role { 'involved' }

    trait :spawned do
      role { 'spawned' }
    end

    trait :mentioned do
      role { 'mentioned' }
    end
  end

  factory :world_memory_lore do
    association :world_memory
    association :helpfile
    reference_type { 'mentioned' }

    trait :central do
      reference_type { 'central' }
    end

    trait :background do
      reference_type { 'background' }
    end
  end

  # === AUTO GM ===

  factory :auto_gm_session do
    association :starting_room, factory: :room
    status { 'gathering' }
    chaos_level { 5 }
    current_stage { 0 }
    participant_ids { Sequel.pg_array([], :integer) }
    location_ids_used { Sequel.pg_array([], :integer) }

    trait :running do
      status { 'running' }
    end

    trait :resolved do
      status { 'resolved' }
      resolution_type { 'success' }
    end
  end

  factory :auto_gm_summary do
    association :session, factory: :auto_gm_session
    content { 'A test summary of events that occurred.' }
    abstraction_level { 1 }
    importance { 0.5 }
    abstracted { false }

    trait :scene_level do
      abstraction_level { 2 }
    end

    trait :act_level do
      abstraction_level { 3 }
    end

    trait :session_level do
      abstraction_level { 4 }
    end

    trait :abstracted do
      abstracted { true }
    end

    trait :with_embedding do
      sequence(:embedding_id) { |n| n }
    end
  end

  # === MEDIA SESSIONS ===

  factory :media_session do
    association :room
    association :host, factory: :character_instance
    session_type { 'youtube' }
    youtube_video_id { 'dQw4w9WgXcQ' }
    status { 'active' }
    is_playing { false }
    playback_position { 0 }
    playback_rate { 1.0 }
    last_heartbeat { Time.now }

    trait :youtube do
      session_type { 'youtube' }
      youtube_video_id { 'dQw4w9WgXcQ' }
    end

    trait :playing do
      is_playing { true }
      playback_started_at { Time.now }
    end

    trait :paused do
      status { 'paused' }
      is_playing { false }
    end

    trait :ended do
      status { 'ended' }
      ended_at { Time.now }
    end

    trait :screen_share do
      session_type { 'screen_share' }
      youtube_video_id { nil }
      peer_id { 'test-peer-id' }
    end

    trait :tab_share do
      session_type { 'tab_share' }
      youtube_video_id { nil }
      peer_id { 'test-peer-id' }
    end
  end

  factory :media_session_viewer do
    association :media_session
    association :character_instance
    connection_status { 'connected' }
    joined_at { Time.now }

    trait :disconnected do
      connection_status { 'disconnected' }
    end

    trait :pending do
      connection_status { 'pending' }
    end
  end

  # === ROOM TEMPLATES ===

  factory :room_template do
    association :universe
    sequence(:name) { |n| "Test Template #{n}" }
    template_type { 'vehicle_interior' }
    category { 'sedan' }
    short_description { 'A test vehicle interior' }
    long_description { 'This is a detailed description of the vehicle interior.' }
    width { 8.0 }
    length { 12.0 }
    height { 5.0 }
    passenger_capacity { 4 }
    default_places { Sequel.pg_jsonb_wrap([]) }
    active { true }

    trait :taxi do
      category { 'taxi' }
      template_type { 'taxi' }
    end

    trait :train do
      category { 'train' }
      template_type { 'train_compartment' }
      passenger_capacity { 20 }
    end

    trait :boat do
      category { 'rowboat' }
      template_type { 'boat_cabin' }
    end

    trait :inactive do
      is_active { false }
    end

    trait :with_places do
      default_places do
        Sequel.pg_jsonb_wrap([
          { name: 'Driver Seat', x: 2.0, y: 10.0, capacity: 1 },
          { name: 'Passenger Seat', x: 6.0, y: 10.0, capacity: 1 },
          { name: 'Back Seat', x: 4.0, y: 4.0, capacity: 3 }
        ])
      end
    end
  end

  # === EMBEDDINGS ===

  factory :embedding do
    content_type { 'world_memory' }
    sequence(:content_id) { |n| n }
    source_text { 'This is test content for embedding.' }
    embedding { Array.new(1024) { rand(-1.0..1.0) } }
    model { 'voyage-3-large' }
    input_type { 'document' }
    dimensions { 1024 }
  end

  # === ACTION COOLDOWNS ===

  factory :action_cooldown do
    association :character_instance
    ability_name { 'test_ability' }
    expires_at { Time.now + 60 }

    trait :expired do
      expires_at { Time.now - 60 }
    end

    trait :active do
      expires_at { Time.now + 300 }
    end
  end

  # === REMOTE OBSERVERS ===

  factory :activity_remote_observer do
    association :activity_instance
    association :character_instance
    role { 'support' }
    active { true }

    trait :supporter do
      role { 'support' }
    end

    trait :opposer do
      role { 'oppose' }
    end

    trait :inactive do
      active { false }
    end

    trait :with_action do
      action_type { 'reroll_ones' }
      action_submitted_at { Time.now }
    end
  end

  # === DELVE ROOMS ===

  factory :delve_room do
    association :delve
    sequence(:depth) { |n| n }
    room_type { 'branch' }
    explored { false }
    cleared { false }
    grid_x { 0 }
    grid_y { 0 }
    level { 1 }

    trait :explored do
      explored { true }
      explored_at { Time.now }
    end

    trait :cleared do
      cleared { true }
      cleared_at { Time.now }
    end

    trait :monster do
      room_type { 'corridor' }
      monster_type { 'goblin' }
    end

    trait :trap do
      room_type { 'corridor' }
      trap_damage { 10 }
    end

    trait :boss do
      room_type { 'branch' }
      monster_type { 'dragon' }
      is_boss { true }
    end

    trait :treasure do
      room_type { 'terminal' }
      has_treasure { true }
      loot_value { 100 }
    end

    trait :exit do
      room_type { 'terminal' }
      is_exit { true }
    end

    trait :entrance do
      room_type { 'corridor' }
      is_entrance { true }
    end

    trait :corridor do
      room_type { 'corridor' }
    end

    trait :puzzle do
      room_type { 'puzzle' }
    end

    trait :searched do
      searched { true }
      searched_at { Time.now }
    end

    trait :with_real_room do
      after(:create) do |delve_room|
        location = Location.first || create(:location)
        label = if delve_room.is_exit then 'Exit'
                elsif delve_room.is_entrance then 'Entrance'
                elsif delve_room.is_boss then 'Boss Chamber'
                else (delve_room.room_type || 'chamber').capitalize
                end
        room = create(:room,
          location: location,
          name: "Dungeon #{label} [#{delve_room.grid_x},#{delve_room.grid_y}]",
          room_type: 'dungeon',
          is_temporary: true,
          pool_status: 'in_use',
          min_x: delve_room.grid_x * 30.0,
          max_x: delve_room.grid_x * 30.0 + 30.0,
          min_y: delve_room.grid_y * 30.0,
          max_y: delve_room.grid_y * 30.0 + 30.0
        )
        delve_room.update(room_id: room.id)
      end
    end
  end

  # === ARRANGED SCENES ===

  factory :arranged_scene do
    association :npc_character, factory: :character
    association :pc_character, factory: :character
    association :meeting_room, factory: :room
    association :rp_room, factory: :room
    association :created_by, factory: :character
    status { 'pending' }
    scene_name { 'Test Meeting' }

    trait :active do
      status { 'active' }
    end

    trait :completed do
      status { 'completed' }
    end

    trait :cancelled do
      status { 'cancelled' }
    end

    trait :expired do
      status { 'expired' }
    end

    trait :with_time_window do
      available_from { Time.now - 3600 }
      expires_at { Time.now + 3600 }
    end

    trait :expired_window do
      available_from { Time.now - 7200 }
      expires_at { Time.now - 3600 }
    end

    trait :future_window do
      available_from { Time.now + 3600 }
      expires_at { Time.now + 7200 }
    end

    trait :with_invitation do
      invitation_message { 'You have been cordially invited to a private meeting.' }
    end
  end

  # === CHARACTER DESCRIPTIONS (Instance-level) ===

  factory :character_description do
    association :character_instance
    association :body_position  # Required by default - character_description must have body_position OR description_type
    content { 'A detailed description of the character.' }
    aesthetic_type { 'natural' }
    active { true }

    trait :with_body_position do
      association :body_position
    end

    trait :with_description_type do
      body_position { nil }
      body_position_id { nil }
      association :description_type
    end

    trait :tattoo do
      aesthetic_type { 'tattoo' }
    end

    trait :makeup do
      aesthetic_type { 'makeup' }
    end

    trait :hairstyle do
      aesthetic_type { 'hairstyle' }
    end

    trait :natural do
      aesthetic_type { 'natural' }
    end

    trait :inactive do
      active { false }
    end

    trait :concealed do
      concealed_by_clothing { true }
    end
  end

  # === DESCRIPTION TYPES ===

  factory :description_type do
    sequence(:name) { |n| "Description Type #{n}" }
    content_type { 'text' }
    display_order { 0 }

    trait :personality do
      name { 'Personality' }
    end

    trait :background do
      name { 'Background' }
    end

    trait :image do
      content_type { 'image_url' }
    end
  end

  # === MONSTERS ===

  factory :monster_template do
    sequence(:name) { |n| "Monster Template #{n}" }
    monster_type { 'colossus' }
    total_hp { 500 }
    hex_width { 3 }
    hex_height { 3 }
    climb_distance { 5 }
    defeat_threshold_percent { 25 }
    description { 'A massive creature' }

    trait :dragon do
      monster_type { 'dragon' }
      total_hp { 800 }
      hex_width { 5 }
      hex_height { 3 }
      climb_distance { 8 }
    end

    trait :behemoth do
      monster_type { 'behemoth' }
      total_hp { 1000 }
      hex_width { 4 }
      hex_height { 4 }
      climb_distance { 6 }
    end

    trait :small do
      hex_width { 2 }
      hex_height { 2 }
      total_hp { 200 }
      climb_distance { 3 }
    end
  end

  factory :large_monster_instance, class: 'LargeMonsterInstance' do
    association :monster_template
    association :fight
    current_hp { 500 }
    max_hp { 500 }
    center_hex_x { 5 }
    center_hex_y { 5 }
    status { 'active' }
    facing_direction { 0 }

    trait :damaged do
      current_hp { 250 }
    end

    trait :nearly_defeated do
      current_hp { 100 }
    end

    trait :collapsed do
      status { 'collapsed' }
    end

    trait :defeated do
      status { 'defeated' }
      current_hp { 0 }
    end
  end

  factory :monster_segment_template do
    association :monster_template
    sequence(:name) { |n| "Segment #{n}" }
    segment_type { 'body' }
    hp_percent { 25 }
    hex_offset_x { 0 }
    hex_offset_y { 0 }
    display_order { 0 }
    is_weak_point { false }
    required_for_mobility { false }
    attacks_per_round { 1 }
    attack_speed { 5 }
    reach { 1 }

    trait :weak_point do
      is_weak_point { true }
      name { 'Weak Point' }
    end

    trait :mobility do
      required_for_mobility { true }
      name { 'Leg' }
      segment_type { 'limb' }
    end

    trait :limb do
      segment_type { 'limb' }
    end
  end

  factory :monster_segment_instance do
    association :large_monster_instance
    association :monster_segment_template
    current_hp { 125 }
    max_hp { 125 }
    status { 'healthy' }
    can_attack { true }
    attacks_remaining_this_round { 1 }

    trait :damaged do
      status { 'damaged' }
      current_hp { 60 }
    end

    trait :destroyed do
      status { 'destroyed' }
      current_hp { 0 }
      can_attack { false }
    end
  end

  factory :monster_mount_state do
    association :large_monster_instance
    association :fight_participant
    climb_progress { 0 }
    mount_status { 'mounted' }
    mounted_at { Time.now }

    trait :climbing do
      mount_status { 'climbing' }
      climb_progress { 2 }
    end

    trait :at_weak_point do
      mount_status { 'at_weak_point' }
      climb_progress { 5 }
    end

    trait :thrown do
      mount_status { 'thrown' }
      scatter_hex_x { 3 }
      scatter_hex_y { 3 }
    end

    trait :dismounted do
      mount_status { 'dismounted' }
    end
  end

  # === PROFILE SYSTEM ===

  factory :profile_picture do
    association :character
    sequence(:url) { |n| "https://example.com/pic#{n}.jpg" }
    sequence(:position) { |n| n }
    caption { nil }
  end

  factory :profile_section do
    association :character
    sequence(:title) { |n| "Section #{n}" }
    sequence(:content) { |n| "Content for section #{n}" }
    sequence(:position) { |n| n }
  end

  factory :profile_video do
    association :character
    sequence(:youtube_id) { |n| "dQw4w9WgXc#{n % 10}" }  # 11 chars: valid YouTube ID format
    sequence(:title) { |n| "Video #{n}" }
    sequence(:position) { |n| n }
  end

  factory :profile_setting do
    association :character
    background_url { nil }
  end

  factory :travel_party do
    association :leader, factory: :character_instance
    association :destination, factory: :location
    association :origin_room, factory: :room
    status { 'assembling' }
    travel_mode { 'land' }
    flashback_mode { false }
  end

  factory :travel_party_member do
    association :party, factory: :travel_party
    association :character_instance
    status { 'pending' }
    responded_at { nil }
  end

  factory :npc_memory do
    association :character
    content { 'A memory of something that happened' }
    memory_type { 'interaction' }
    importance { 5 }
    abstraction_level { 1 }
    memory_at { Time.now }

    trait :important do
      importance { 8 }
    end

    trait :old do
      memory_at { Time.now - (30 * 86400) } # 30 days ago
    end

    trait :secret do
      memory_type { 'secret' }
    end

    trait :abstraction do
      memory_type { 'abstraction' }
      abstraction_level { 2 }
    end

    trait :with_about_character do
      association :about_character, factory: :character
    end

    trait :with_location do
      association :location
    end
  end

  # === WORLD MEMORY SESSIONS ===

  factory :world_memory_session do
    association :room
    status { 'active' }
    started_at { Time.now }
    last_activity_at { Time.now }
    message_count { 0 }
    publicity_level { 'public' }
    has_private_content { false }
    log_buffer { '' }

    trait :active do
      status { 'active' }
    end

    trait :finalizing do
      status { 'finalizing' }
      ended_at { Time.now }
    end

    trait :finalized do
      status { 'finalized' }
      ended_at { Time.now }
    end

    trait :abandoned do
      status { 'abandoned' }
      ended_at { Time.now }
    end

    trait :stale do
      last_activity_at { Time.now - (GameConfig::AutoGm::INACTIVITY_TIMEOUT_HOURS * 3600) - 60 }
    end

    trait :with_messages do
      message_count { 10 }
      log_buffer { "[12:00] Alice (say): Hello!\n[12:01] Bob (emote): waves back.\n" }
    end

    trait :sufficient_for_memory do
      message_count { WorldMemorySession::MIN_MESSAGES_FOR_MEMORY }
    end

    trait :insufficient_for_memory do
      message_count { WorldMemorySession::MIN_MESSAGES_FOR_MEMORY - 1 }
    end

    trait :private_content do
      has_private_content { true }
      log_buffer { '[PRIVATE CONTENT EXCLUDED]' }
    end

    trait :with_event do
      association :event
    end

    trait :with_parent do
      association :parent_session, factory: :world_memory_session
    end
  end

  factory :world_memory_session_character do
    association :session, factory: :world_memory_session
    association :character
    is_active { true }
    message_count { 0 }
    joined_at { Time.now }

    trait :inactive do
      is_active { false }
      left_at { Time.now }
    end

    trait :with_messages do
      message_count { 5 }
    end
  end

  factory :world_memory_session_room do
    association :session, factory: :world_memory_session
    association :room
    message_count { 0 }
    first_seen_at { Time.now }
    last_seen_at { Time.now }

    trait :with_messages do
      message_count { 5 }
    end
  end

  # === NARRATIVE INTELLIGENCE ===

  factory :narrative_entity do
    sequence(:name) { |n| "Test Entity #{n}" }
    entity_type { 'character' }
    importance { 5.0 }
    is_active { true }
    mention_count { 1 }
    aliases { [] }
    first_seen_at { Time.now }
    last_seen_at { Time.now }
  end

  factory :narrative_entity_memory do
    association :narrative_entity
    association :world_memory
    role { 'mentioned' }
    confidence { 0.8 }
    reputation_relevant { false }
  end

  factory :narrative_relationship do
    association :source_entity, factory: :narrative_entity
    association :target_entity, factory: :narrative_entity
    relationship_type { 'allied_with' }
    strength { 1.0 }
    evidence_count { 1 }
    is_current { true }
    is_bidirectional { false }
  end

  factory :narrative_thread do
    sequence(:name) { |n| "Test Thread #{n}" }
    status { 'emerging' }
    importance { 5.0 }
    entity_count { 0 }
    memory_count { 0 }
    themes { [] }
    key_events { [] }
    location_ids { [] }
    last_activity_at { Time.now }
  end

  factory :narrative_thread_entity do
    association :narrative_thread
    association :narrative_entity
    centrality { 0.5 }
    role { 'protagonist' }
  end

  factory :narrative_thread_memory do
    association :narrative_thread
    association :world_memory
    relevance { 0.5 }
  end

  factory :narrative_extraction_log do
    association :world_memory
    extraction_tier { 'batch' }
    entity_count { 0 }
    relationship_count { 0 }
    success { true }
  end
end
