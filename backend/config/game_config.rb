# frozen_string_literal: true

# Centralized game configuration constants.
# All magic numbers and tuning parameters should be defined here
# to make game balance adjustments easy to find and modify.
#
# @example
#   GameConfig::Combat::THREAT_WEIGHTS[:targeted_by_enemy]
#   GameConfig::Power::WEIGHTS[:hp]
#   GameConfig::Tts::MAX_TEXT_LENGTH
#
module GameConfig
  # ============================================
  # Combat AI Configuration
  # ============================================
  module Combat
    # Weight factors for threat calculation in select_highest_threat
    THREAT_WEIGHTS = {
      targeted_by_enemy: 5,    # Bonus if enemy is targeting us
      max_proximity_bonus: 10, # Maximum bonus for being close
      no_cover_bonus: 3,       # Bonus if target has no cover
      elevation_advantage: 2,  # Bonus for having elevation
      significant_elevation: 2, # Threshold for elevation damage bonus
      cover_penalty: 5,        # Penalty if shot passes through cover (increased for AI awareness)
      inactive_penalty: 1,     # Penalty if target hasn't moved/acted
      ranged_vs_cover_penalty: 6 # Extra penalty for ranged attacks when target is behind cover
    }.freeze

    # HP percentage thresholds for decision making
    HP_THRESHOLDS = {
      wounded: 0.5,            # Below this = wounded (defend chance)
      critically_wounded: 0.25, # Below this = critical
      low_hp_targeted: 0.5,    # Threshold for healing priority
      shield_priority: 0.4,    # HP% to prioritize shield abilities
      terrain_caution: 0.3     # Minimum caution to avoid terrain
    }.freeze

    # Target scoring bonuses
    TARGET_SCORING = {
      wounded_bonus: 2,        # Bonus for targeting wounded enemies
      critical_bonus: 1,       # Additional bonus for critically wounded
      in_range_bonus: 1        # Bonus if target is in weapon range
    }.freeze

    # Terrain and pathfinding
    TERRAIN = {
      cost_threshold_base: 1.5, # Base multiplier for terrain avoidance
      cost_threshold_bonus: 1.0 # Added based on (1 - terrain_caution)
    }.freeze

    # AI positioning for movement decisions
    AI_POSITIONING = {
      # Combat role thresholds (compare weapon damage ratios)
      ranged_focus_threshold: 0.7,    # Prefer ranged if ranged_damage/total > this
      melee_focus_threshold: 0.7,     # Prefer melee if melee_damage/total > this

      # Range preferences (in hexes) — scaled for 2ft hex system
      optimal_ranged_distance: 6,     # Ideal hex distance for ranged attackers (4 × 1.5)
      min_ranged_distance: 5,         # Back off if closer than this (3 × 1.5, rounded up)

      # Cover seeking weights (used in position scoring)
      cover_seek_priority: 3,         # Score bonus for hexes that provide cover
      los_clear_priority: 4,          # Score bonus for clear line of sight

      # Movement decision thresholds
      reposition_threshold: 2,        # Only reposition if score improvement > this
      max_reposition_hexes: 5         # Don't consider moves beyond this distance (3 × 1.5, rounded up)
    }.freeze

    # Hazard scoring for forced movement AI
    HAZARD_SCORING = {
      pit_bonus: 50,           # High priority for pits (instant removal)
      damage_per_round_mult: 5, # Multiplier for hazard_damage_per_round
      danger_level_mult: 3,    # Multiplier for danger_level
      fire_bonus: 10,          # Bonus for fire hazards
      explosive_bonus: 20,     # Bonus for explosives (chain reaction)
      wounded_target_bonus: 15, # Bonus if target HP < 30%
      hurt_target_bonus: 5     # Bonus if target HP < 50%
    }.freeze

    # Battle balancing service parameters
    BALANCING = {
      stat_adjustment_increment: 0.05,
      stat_adjustment_min: -0.4,
      stat_adjustment_max: 0.4,
      fine_tune_adjustment: 0.05,
      fine_tune_limit: 0.3,
      difficulty_easy_modifier: -0.20,
      difficulty_hard_modifier: 0.15,
      difficulty_nightmare_modifier: 0.30,
      difficulty_clamp_min: -0.5,
      difficulty_clamp_max: 0.5
    }.freeze
  end

  # ============================================
  # Effective Power Calculator Configuration
  # Used by CombatAIService for smart ability selection
  # ============================================
  module EffectivePower
    # Environmental bonus caps (multipliers)
    AOE_CLUSTER_MAX_MULTIPLIER = 2.0      # Max bonus when enemies clustered
    HAZARD_KNOCKBACK_MAX_MULTIPLIER = 2.5 # Max bonus for knockback into hazard
    EXECUTE_INSTANT_KILL_MULTIPLIER = 3.0 # Bonus for instant-kill execute
    COMBO_BONUS_MULTIPLIER = 1.5          # Bonus when target has combo status

    # Vulnerability matching bonus
    # Applied when ability damage type matches target's vulnerability
    # e.g., fire ability vs target with vulnerable_fire
    VULNERABILITY_MATCH_MULTIPLIER = 1.5

    # Friendly fire AoE penalty
    # Each ally in AoE counts as this many "negative enemies" for effective power
    # 1.0 = ally hit cancels out one enemy hit
    # 1.5 = ally hit is worse than missing an enemy (conservative AI)
    FRIENDLY_FIRE_ALLY_PENALTY = 1.5

    # Minimum net targets for friendly fire AoE to be considered
    # Below this, AI will avoid using the ability entirely
    FRIENDLY_FIRE_MIN_NET_TARGETS = 0.5
  end

  # ============================================
  # Power Calculator Configuration
  # ============================================
  module Power
    # Weight factors for power calculation
    WEIGHTS = {
      hp: 10,                  # Each point of HP
      damage_bonus: 15,        # Each point of damage bonus
      defense_bonus: 10,       # Each point of defense bonus
      speed: 5,                # Each point of speed modifier
      dice_base: 16            # Base dice expectation (2d8 = 9 avg, 2d6 = 7 avg)
    }.freeze

    # Balance ratios
    BALANCE = {
      npc_to_pc_ratio: 0.9,    # NPCs should be ~90% of combined PC power
      dice_factor_mult: 3,     # Multiplier for dice calculation
      pc_dice_factor: 2.5      # PC dice factor (2d8 exploding = ~10.5 avg)
    }.freeze

    # Default stat values
    DEFAULTS = {
      hp_divisor: 10,          # stat_block.total_points / this
      hp_base: 5,              # Added to hp calculation
      hp_floor: 3,             # Minimum HP
      stat_default: 10,        # Default STR/DEX
      stat_baseline: 20        # Sum baseline for stat calculations
    }.freeze

    # AI profile modifiers
    AI_MODIFIERS = {
      'berserker' => 1.2,
      'aggressive' => 1.1,
      'guardian' => 1.0,
      'balanced' => 1.0,
      'defensive' => 0.9,
      'coward' => 0.8
    }.freeze
  end

  # ============================================
  # Text-to-Speech Configuration
  # ============================================
  module Tts
    # File paths
    def self.audio_dir
      ENV.fetch('TTS_AUDIO_DIR', 'public/audios')
    end

    # Limits
    MAX_TEXT_LENGTH = 5000
    AUDIO_CLEANUP_MINUTES = 60

    # Voice parameter ranges
    SPEED_RANGE = (0.25..4.0)
    PITCH_RANGE = (-20.0..20.0)

    # Defaults
    DEFAULT_VOICE = 'Kore'
    DEFAULT_LOCALE = 'en-US'
  end

  # ============================================
  # Delve System Configuration
  # ============================================
  module Delve
    # Time costs for each action type (in seconds)
    ACTION_TIMES = {
      move: 10,
      combat: 300,      # 5 minutes
      recover: 300,     # 5 minutes
      focus: 30,
      study: 60,        # 1 minute
      trap_listen: 10,
      easier: 30,
      puzzle_attempt: 15,
      puzzle_hint: 30
    }.freeze

  # ============================================
  # Delve Generator Configuration
  # ============================================
    # Grid density and layout
    DENSITY = {
      room_ratio: 0.4,         # 40% of grid cells become rooms
      main_tunnel_ratio: 0.25, # 25% of rooms in main tunnel
      min_main_rooms: 5,       # Minimum rooms in main tunnel
      min_boss_rooms: 5        # Need at least this many rooms for boss
    }.freeze

    # Fractal branching algorithm parameters
    FRACTAL = {
      initial_branch_chance: 9,  # 1-in-9 (~11%), ramps down by 2 each non-branch step
      branch_chance_ramp: 2,     # Decrease denominator by 2 after each non-branch segment
      sub_branch_chance: 4,      # Sub-tunnels: fixed 1-in-4 (25%)
      min_branch_budget: 6,      # Need 6+ rooms in sub-budget to branch
      segment_cost: 3            # Each segment costs exactly 3 rooms
    }.freeze

    # Content placement
    CONTENT = {
      blocker_chance: 0.15,    # 15% chance per exit to have a blocker
      trap_chance: 0.10,       # 10% chance per exit to have a trap
      lurker_chance: 0.30      # 30% chance per terminal room to have a lurking monster
    }.freeze

    # Content assignment weights by difficulty (what spawns in rooms)
    # Treasure handled by add_treasures! (terminal rooms), traps/blockers independent
    CONTENT_WEIGHTS = {
      easy:      { empty: 60, monster: 10, puzzle: 5 },
      normal:    { empty: 45, monster: 20, puzzle: 8 },
      hard:      { empty: 30, monster: 30, puzzle: 12 },
      nightmare: { empty: 15, monster: 40, puzzle: 15 }
    }.freeze

    # Loot base values
    LOOT = {
      treasure_base: 50,
      chamber_base: 20,
      boss_base: 200,
      level_variance: 0.4      # +/- 40% variance
    }.freeze

    # Trap damage calculation
    TRAPS = {
      base_damage: 5,
      damage_per_level: 3,
      damage_variance: 0.6     # 0.7 to 1.3 multiplier
    }.freeze

    # Session parameters
    SESSION = {
      time_limit_minutes: 60,
      monster_tick_initial: 300,   # 5 minutes for first monster tick
      monster_tick_normal: 60      # 1 minute for subsequent ticks
    }.freeze
  end

  # ============================================
  # Activity/Game Mechanics Configuration
  # ============================================
  module Activity
    # Participant defaults
    DEFAULTS = {
      initial_willpower: 10,
      initial_willpower_ticks: 10
    }.freeze

    # Timeouts
    TIMEOUTS = {
      input_seconds: 480       # 8 minutes
    }.freeze
  end

  # ============================================
  # Distance & Spatial Configuration
  # ============================================
  module Distance
    # Movement timing
    TIMING = {
      ms_per_unit: 100         # Milliseconds per coordinate unit
    }.freeze

    # Default room bounds
    DEFAULT_BOUNDS = {
      min_x: 0.0,
      max_x: 100.0,
      min_y: 0.0,
      max_y: 100.0,
      max_z: 10.0
    }.freeze

    # Spatial limits
    LIMITS = {
      max_room_dimension: 1000.0,   # Maximum room size (1km)
      z_diff_threshold: 100,        # Threshold for planar check
      z_diff_multiplier: 10,        # Z-difference weight multiplier
      diagonal_divisor: 2.0         # Divisor for diagonal movement calculation
    }.freeze
  end

  # ============================================
  # Combat Mechanics Configuration
  # ============================================
  module Mechanics
    # Damage threshold system (NOT direct HP damage)
    # Raw damage is converted to HP loss using these thresholds:
    #   Miss:  < 10 (0-9 damage = 0 HP)
    #   1 HP:  10-17
    #   2 HP:  18-29
    #   3 HP:  30-99
    #   4 HP:  100-199
    #   5 HP:  200-299
    #   6+ HP: 100 damage bands thereafter
    DAMAGE_THRESHOLDS = {
      miss: 9,         # Damage <= this = miss (0 HP) - so <10 misses
      one_hp: 17,      # Damage 10-17 = 1 HP loss
      two_hp: 29,      # Damage 18-29 = 2 HP loss
      three_hp: 99     # Damage 30-99 = 3 HP loss, 100+ scales by bands
    }.freeze
    # Damage scaling for high damage (100+):
    # HP = 4 + floor((damage - 100) / 100)
    HIGH_DAMAGE_BASE_HP = 4       # Base HP loss at 100 damage
    HIGH_DAMAGE_BAND_SIZE = 100   # Size of each damage band after 100

    # Default HP values
    DEFAULT_HP = {
      max: 6,          # Default max HP for new participants
      current: 6       # Default starting HP
    }.freeze

    # Willpower system
    # Attack/ability willpower: Each die rolls 1d8 exploding on 8, adds to damage
    # Defense willpower: Each die rolls 1d8 exploding on 8, provides as armor
    # Movement willpower: Each die rolls 1d8 exploding on 8, half total = bonus hexes
    WILLPOWER = {
      initial_dice: 1.0,           # Starting willpower dice
      gain_per_hp_lost: 0.25,      # Willpower dice gained per HP lost
      max_dice: 3.0,               # Maximum willpower dice cap
      bonus_per_die: 2,            # Bonus per willpower die spent on defense rolls
      max_spend_per_action: 2      # Max willpower dice that can be spent per action
    }.freeze

    # Movement (hexes per round)
    # Scaled by 1.5x for migration from 4ft to 2ft hexes (2026-02-16)
    MOVEMENT = {
      base: 6,                     # Base movement hexes (scaled from 4)
      sprint_bonus: 5,             # Bonus when sprinting (scaled from 3)
      quick_tactic_bonus: 2        # Bonus from quick tactic (scaled from 1)
    }.freeze

    # Segment system (100-segment round)
    SEGMENTS = {
      total: 100,                  # Total segments per round (0-100)
      movement_base: 50,           # When movement happens (fallback)
      movement_variance: 2,        # ±2 variance on movement segment (fallback)
      movement_randomization: 0.1, # 10% variance on distributed movement timing
      attack_randomization: 0.1,   # 10% variance on attack timing
      tactical_fallback: 20,       # Default segment for tactical abilities
      melee_catchup_window: 15     # Segments to look ahead for melee catch-up
    }.freeze

    # Weapon Reach System
    # Melee reach determines attack timing advantage based on starting distance.
    # Non-adjacent: Longer weapon attacks first (segments 1-66)
    # Adjacent: Shorter weapon attacks first (segments 1-66)
    # Equal reach: Normal distribution (no compression)
    REACH = {
      unarmed_reach: 2,            # Unarmed default reach (same as short weapons)
      segment_compression: 0.66,   # Attacks compress to 66% of segments
      long_weapon_start: 1,        # Long weapon advantage: segments 1-66
      long_weapon_end: 66,
      short_weapon_start: 34,      # Short weapon disadvantage: segments 34-100
      short_weapon_end: 100
    }.freeze

    # Cooldown system
    COOLDOWNS = {
      ability_penalty: -6,         # Penalty applied after using ability
      decay_per_round: 2           # Penalty decay towards 0 per round
    }.freeze

    # Attack dice configuration
    DICE = {
      pc_count: 2,                 # PCs roll 2 dice
      pc_sides: 8,                 # d8s
      explode_on: 8                # Explode on 8
    }.freeze

    # Unified Roll System (PC main action abilities)
    # PCs use a single 2d8+willpower exploding on 8s roll for both
    # attack success and damage. This creates consistent scaling.
    UNIFIED_ROLL = {
      expected_value: 10.3,        # E[2d8 exploding on 8s] = 2 * (4.5 / 0.875)
      dice_count: 2,
      dice_sides: 8,
      explode_on: 8
    }.freeze

    # Unarmed attack segments (speed 5)
    UNARMED_SEGMENTS = [20, 40, 60, 80, 100].freeze

    # Default weapon speed
    DEFAULT_WEAPON_SPEED = 5

    # Default stat value
    DEFAULT_STAT = 10

    # Stat calculation parameters (for skill checks)
    STAT_CALCULATION = {
      base: 10,              # Stat modifier base (stat - 10)
      divisor: 2,            # Modifier divisor ((stat - 10) / 2)
      skill_dice_sides: 8    # d8s for skill checks
    }.freeze
  end

  # ============================================
  # NPC Natural Attacks Configuration
  # ============================================
  module NpcAttacks
    # Standard weapon templates for quick NPC attack setup
    # These provide default values that can be overridden
    WEAPON_TEMPLATES = {
      # Melee weapons - ALL require adjacency (1 hex)
      'sword' => { damage_dice: '2d6', damage_type: 'physical', attack_speed: 5, range_hexes: 1, attack_type: 'melee', melee_reach: 3 },
      'dagger' => { damage_dice: '1d6', damage_type: 'physical', attack_speed: 7, range_hexes: 1, attack_type: 'melee', melee_reach: 1 },
      'greataxe' => { damage_dice: '3d6', damage_type: 'physical', attack_speed: 3, range_hexes: 1, attack_type: 'melee', melee_reach: 5 },
      'mace' => { damage_dice: '2d6', damage_type: 'physical', attack_speed: 4, range_hexes: 1, attack_type: 'melee', melee_reach: 3 },
      'spear' => { damage_dice: '2d6', damage_type: 'physical', attack_speed: 5, range_hexes: 1, attack_type: 'melee', melee_reach: 4 },
      'staff' => { damage_dice: '1d8', damage_type: 'physical', attack_speed: 5, range_hexes: 1, attack_type: 'melee', melee_reach: 4 },
      'greatsword' => { damage_dice: '3d6', damage_type: 'physical', attack_speed: 3, range_hexes: 1, attack_type: 'melee', melee_reach: 5 },
      'rapier' => { damage_dice: '1d8', damage_type: 'physical', attack_speed: 6, range_hexes: 1, attack_type: 'melee', melee_reach: 3 },

      # Ranged weapons (scaled by 1.5x)
      'bow' => { damage_dice: '2d6', damage_type: 'physical', attack_speed: 5, range_hexes: 15, attack_type: 'ranged' },
      'crossbow' => { damage_dice: '2d8', damage_type: 'physical', attack_speed: 3, range_hexes: 23, attack_type: 'ranged' },
      'throwing_knife' => { damage_dice: '1d6', damage_type: 'physical', attack_speed: 7, range_hexes: 8, attack_type: 'ranged' },
      'javelin' => { damage_dice: '2d6', damage_type: 'physical', attack_speed: 4, range_hexes: 12, attack_type: 'ranged' },

      # Natural attacks - melee (1 hex)
      'bite' => { damage_dice: '2d6', damage_type: 'physical', attack_speed: 5, range_hexes: 1, attack_type: 'melee', melee_reach: 1 },
      'claw' => { damage_dice: '1d8', damage_type: 'physical', attack_speed: 6, range_hexes: 1, attack_type: 'melee', melee_reach: 2 },
      'tail' => { damage_dice: '2d8', damage_type: 'physical', attack_speed: 4, range_hexes: 1, attack_type: 'melee', melee_reach: 4 },
      'horns' => { damage_dice: '2d6', damage_type: 'physical', attack_speed: 4, range_hexes: 1, attack_type: 'melee', melee_reach: 2 },
      'slam' => { damage_dice: '2d8', damage_type: 'physical', attack_speed: 3, range_hexes: 1, attack_type: 'melee', melee_reach: 2 },
      'sting' => { damage_dice: '1d6', damage_type: 'poison', attack_speed: 6, range_hexes: 1, attack_type: 'melee', melee_reach: 2 },

      # Natural attacks - ranged (scaled)
      'breath_fire' => { damage_dice: '3d6', damage_type: 'fire', attack_speed: 2, range_hexes: 6, attack_type: 'ranged' },
      'breath_ice' => { damage_dice: '3d6', damage_type: 'ice', attack_speed: 2, range_hexes: 6, attack_type: 'ranged' },
      'spit' => { damage_dice: '2d4', damage_type: 'poison', attack_speed: 5, range_hexes: 9, attack_type: 'ranged' }
    }.freeze

    # Available damage types
    DAMAGE_TYPES = %w[physical fire ice lightning poison holy shadow psychic].freeze

    # Attack speed ranges (attacks per round equivalent)
    ATTACK_SPEED_RANGE = (1..10).freeze

    # Default messages for attack types (used when no custom message provided)
    DEFAULT_MESSAGES = {
      'bite' => {
        hit: '%{attacker} bites %{target}!',
        miss: '%{attacker} snaps at %{target} but misses!',
        critical: '%{attacker} savagely bites %{target}!'
      },
      'claw' => {
        hit: '%{attacker} claws %{target}!',
        miss: '%{attacker} swipes at %{target} but misses!',
        critical: '%{attacker} rakes %{target} with vicious claws!'
      },
      'sword' => {
        hit: '%{attacker} slashes %{target}!',
        miss: '%{attacker} swings at %{target} but misses!',
        critical: '%{attacker} delivers a devastating blow to %{target}!'
      },
      'bow' => {
        hit: '%{attacker} shoots %{target}!',
        miss: '%{attacker}\'s arrow misses %{target}!',
        critical: '%{attacker} lands a perfect shot on %{target}!'
      },
      'default' => {
        hit: '%{attacker} attacks %{target}!',
        miss: '%{attacker} misses %{target}!',
        critical: '%{attacker} critically hits %{target}!'
      }
    }.freeze
  end

  # ============================================
  # Tactic Modifiers Configuration
  # ============================================
  module Tactics
    # Outgoing damage modifiers (added to attacker's damage)
    OUTGOING_DAMAGE = {
      'aggressive' => 2,           # +2 damage when aggressive
      'defensive' => -2,           # -2 damage when defensive
      'quick' => -1                # -1 damage when quick
    }.freeze

    # Incoming damage modifiers (added to target's received damage)
    INCOMING_DAMAGE = {
      'aggressive' => 2,           # Take +2 damage when aggressive
      'defensive' => -2,           # Take -2 damage when defensive
      'quick' => 1                 # Take +1 damage when quick
    }.freeze

    # Movement bonuses
    MOVEMENT = {
      'quick' => 2                 # +2 hex movement when quick (scaled from 1)
    }.freeze

    # Guard/Back-to-Back mechanics
    PROTECTION = {
      guard_redirect_chance: 50,   # % chance per guard to redirect attack
      guard_damage_bonus: 2,       # +2 damage when attack is redirected to guard
      btb_mutual_chance: 50,       # % chance for mutual back-to-back redirect
      btb_single_chance: 25,       # % chance for single-sided back-to-back redirect
      btb_mutual_damage_mod: -1    # -1 damage when mutual back-to-back
    }.freeze

    # Dodge penalty to incoming attacks
    DODGE_PENALTY = 5              # -5 to each incoming attack when dodging
  end

  # ============================================
  # Timeout Configuration
  # ============================================
  module Timeouts
    # Time unit constants
    SECONDS_PER_MINUTE = 60
    SECONDS_PER_HOUR = 3600
    SECONDS_PER_DAY = 86_400

    # AFK/Idle timeouts (in minutes)
    PLAYER_ALONE = 60              # Auto-AFK when alone in room
    PLAYER_WITH_OTHERS = 17        # Auto-AFK when others present
    AGENT_LOGOUT = 120             # Agent auto-logout (2 hours)
    HARD_DISCONNECT = 180          # Force logout for all (3 hours)
    WEBSOCKET_STALE = 5            # No WebSocket ping = disconnected
    HEARTBEAT_TIMEOUT_SECONDS = 120 # Media sync heartbeat timeout (2 minutes)

    # Activity tracking
    ACTIVITY_TIMEOUT_MINUTES = 15
    ACTIVITY_DEFAULT_THRESHOLD = 20

    # Character cooldowns
    NAME_CHANGE_COOLDOWN_DAYS = 21
    NAME_CHANGE_COOLDOWN_SECONDS = NAME_CHANGE_COOLDOWN_DAYS * SECONDS_PER_DAY

    # Fight timeouts (in seconds)
    FIGHT_INPUT_TIMEOUT = 480       # 8 minutes for fights with human players
    FIGHT_NPC_ONLY_TIMEOUT = 30     # 30 seconds for NPC-only fights
    FIGHT_STALE_TIMEOUT = 900       # 15 minutes - fight considered stale

    # Interaction context timeout (in seconds)
    INTERACTION_CONTEXT_TIMEOUT = 5 * SECONDS_PER_MINUTE

    # Rate limiting windows (in seconds)
    RATE_LIMIT_WINDOW_SECONDS = 3600      # 1 hour window for rate limiting
    ABUSE_CHECK_WINDOW_SECONDS = 86_400   # 24 hours for abuse monitoring
    NPC_RESPONSE_WINDOW_SECONDS = 3600    # 1 hour window for NPC responses
    STAFF_BROADCAST_WINDOW_SECONDS = 86_400 # 24 hours for staff broadcast dedup

    # Job/Task timeouts (in seconds)
    GENERATION_JOB_TIMEOUT_SECONDS = 1800 # 30 minutes for image/content generation

    # LLM retry delays (in seconds)
    LLM_RETRY_DELAYS = [1, 2, 4].freeze
  end

  # ============================================
  # NPC Animation Configuration
  # ============================================
  module NpcAnimation
    # Decay factor for each recent NPC animator (halves the probability)
    MEDIUM_DECAY_FACTOR = 0.5

    # Recent window for RNG decay calculation (seconds)
    RECENT_WINDOW_SECONDS = 300    # 5 minutes

    # Rate limiting
    MAX_RESPONSES_PER_MINUTE = 3   # Per room
    MAX_RESPONSES_PER_HOUR = 20    # Per NPC
    MAX_CONSECUTIVE_RESPONSES = 2  # Before requiring PC action

    # LLM temperature for response generation
    RESPONSE_TEMPERATURE = 0.8

    # Atmospheric emit cooldown
    ATMOSPHERIC_COOLDOWN_SECONDS = 3600
  end

  # ============================================
  # Ability Defaults
  # ============================================
  module AbilityDefaults
    ACTIVATION_SEGMENT = 50        # Default segment when ability activates
    DEFAULT_RANGE_HEXES = 8        # Default range for ranged abilities (5 × 1.5, rounded up)
    COOLDOWN_SECONDS = 0           # Default cooldown
  end

  # ============================================
  # Combat Simulator Configuration
  # ============================================
  module Simulator
    # Maximum rounds before fight ends in draw
    MAX_ROUNDS = 50

    # Base movement speed per round (hexes)
    BASE_MOVEMENT = 4

    # Movement segment in the 100-segment system
    MOVEMENT_SEGMENT = 50

    # Arena configuration
    ARENA_DEFAULTS = {
      width: 10,
      height: 10,
      obstacle_ratio: 0.1,        # 10% of arena is obstacles
      hazard_ratio: 0.05          # 5% of arena is hazards
    }.freeze

    # Hazard types for the arena (simplified from RoomHex)
    HAZARD_TYPES = {
      fire: { damage_per_round: 4, danger_level: 3 },
      pit: { instant_kill: true, danger_level: 5 },
      poison: { damage_per_round: 2, danger_level: 2 },
      spikes: { damage_per_round: 3, danger_level: 3 }
    }.freeze

    # AI Profiles for combat simulation
    AI_PROFILES = {
      'aggressive' => {
        attack_weight: 0.8,
        defend_weight: 0.1,
        flee_threshold: 0.1,
        target_strategy: :weakest
      },
      'defensive' => {
        attack_weight: 0.4,
        defend_weight: 0.5,
        flee_threshold: 0.3,
        target_strategy: :threat
      },
      'balanced' => {
        attack_weight: 0.6,
        defend_weight: 0.3,
        flee_threshold: 0.2,
        target_strategy: :closest
      },
      'berserker' => {
        attack_weight: 0.95,
        defend_weight: 0.0,
        flee_threshold: 0.0,
        target_strategy: :weakest
      },
      'coward' => {
        attack_weight: 0.3,
        defend_weight: 0.4,
        flee_threshold: 0.5,
        target_strategy: :random
      },
      'guardian' => {
        attack_weight: 0.5,
        defend_weight: 0.6,
        flee_threshold: 0.15,
        target_strategy: :threat
      }
    }.freeze

    # Status effect penalties and bonuses
    STATUS_EFFECT_PENALTIES = {
      dazed_attack: 0.5,
      prone_defense: 0.8,
      frightened_attack: 0.75
    }.freeze

    # Vulnerability damage multiplier
    VULNERABLE_DAMAGE_MULT = 2.0

    # Damage over time values
    DOT_DAMAGE = {
      burning: 4,
      poisoned: 2,
      bleeding: 3,
      freezing: 3
    }.freeze

    # Protection and buff values
    PROTECTION_VALUES = {
      empowered_bonus: 5,
      protected_reduction: 5,
      armored_reduction: 2,
      shielded_hp: 10,
      regenerating_fraction: 0.5
    }.freeze

    # Movement behavior
    MOVEMENT_BEHAVIOR = {
      random_chance: 0.4,           # 40% random, 60% tactical
      tactical_chance: 0.6
    }.freeze
  end

  # ============================================
  # LLM Configuration
  # ============================================
  module LLM
    # Default temperatures by task type
    TEMPERATURES = {
      summary: 0.3,               # Factual summaries
      creative: 0.8,              # NPC responses
      default: 0.7
    }.freeze

    # Default max tokens by task type
    MAX_TOKENS = {
      summary: 150,
      short_response: 200,
      long_response: 1000,
      default: 500
    }.freeze

    # Default embedding similarity thresholds
    SIMILARITY_THRESHOLDS = {
      memory_search: 0.4,
      lore_search: 0.4
    }.freeze

    # Autohelper configuration
    AUTOHELPER = {
      similarity_threshold: 0.3,
      max_recent_logs: 10
    }.freeze

    # Combat prose enhancement
    COMBAT_PROSE = {
      min_paragraph_length: 20,
      total_timeout: 10,
      request_timeout: 8
    }.freeze

    # HTTP timeouts (in seconds)
    TIMEOUTS = {
      default: 60,
      gemini: 60,
      image_generation: 120,
      voyage_embedding: 30,
      image_download: 30,
      http_open: 10,
      trigger_code: 5,
      discord_webhook: 5,
      discord_open: 3,
      combat_prose: 60,
      battle_map_hex: 180,
      battle_map_chunk: 120
    }.freeze

    # File size limits (bytes)
    FILE_LIMITS = {
      max_image_size: 10 * 1024 * 1024  # 10 MB
    }.freeze

    # Default values
    DEFAULTS = {
      max_tokens: 1024,
      rate_limit_window: 3600  # 1 hour check window
    }.freeze

    # Embedding model dimensions
    MODEL_DIMENSIONS = {
      'voyage-3': 1024,
      'voyage-3-lite': 512
    }.freeze

    # Per-provider concurrency limits for worker pool
    # Maximum simultaneous API calls per provider.
    # Auto-backoff reduces dynamically on 429; recovery restores up to these values.
    CONCURRENCY_LIMITS = {
      google_gemini: 200,
      anthropic: 100,
      openai: 100,
      openrouter: 50,
      voyage: 10
    }.freeze

    # Auto-backoff settings
    BACKOFF = {
      reduce_factor: 0.75,           # Reduce limit by 25% on 429
      recovery_streak: 20,           # Consecutive successes before increasing limit
      recovery_factor: 1.10,         # Increase limit by 10% on recovery
      initial_backoff_seconds: 2,    # First 429 backoff
      max_backoff_seconds: 60,       # Maximum backoff duration
      backoff_multiplier: 2          # Double backoff on consecutive 429s
    }.freeze
  end

  # ============================================
  # NPC Memory Configuration
  # ============================================
  module NpcMemory
    # Abstraction system
    ABSTRACTION_THRESHOLD = 8     # Memories before abstraction triggers
    MAX_ABSTRACTION_LEVEL = 4     # Maximum depth of abstraction hierarchy

    # Memory retrieval
    DEFAULT_MIN_AGE_HOURS = 3     # Minimum age to prevent echo
    DEFAULT_LIMIT = 5             # Default memories to retrieve
    OVER_FETCH_MULTIPLIER = 3     # Fetch 3x limit for filtering

    # Embedding type identifier
    EMBEDDING_TYPE = 'npc_memory'

    # Raw log retention
    RAW_LOG_RETENTION_MONTHS = 6
  end

  # ============================================
  # Delve Monster Configuration
  # ============================================
  module DelveMonster
    # Movement threshold - monsters only move after actions taking this long
    MOVEMENT_THRESHOLD_SECONDS = 10

    # Monster spawn config
    SPAWN = {
      base_range: 2..5,       # Random base monster count
      level_divisor: 3         # +1 monster per N levels
    }.freeze

    # Difficulty multipliers for spawn counts
    DIFFICULTY_SPAWN_MULTIPLIERS = {
      'easy' => 0.7,
      'normal' => 1.0,
      'hard' => 1.3,
      'nightmare' => 1.6
    }.freeze

    # Tier selection based on level
    TIER_SELECTION = {
      level_divisor: 3,        # Higher tier monsters every N levels
      tier_variance: 1         # +/- variance in tier selection
    }.freeze

    # Monster stat scaling
    SCALING = {
      base_hp: 3,              # Base monster HP
      hp_divisor: 2,           # +1 HP per N difficulty
      damage_divisor: 3        # +1 damage per N difficulty
    }.freeze
  end

  # ============================================
  # Delve Trap Configuration
  # ============================================
  module DelveTrap
    # Initial sequence parameters
    SEQUENCE_START_RANGE = (2..7).freeze  # Range for start point
    INITIAL_SEQUENCE_LENGTH = 12          # Initial display length (must be >= max timing value to always show TRAP!)
    LISTEN_EXTEND_LENGTH = 10             # How much listening extends sequence
  end

  # ============================================
  # Queue & Cleanup Configuration
  # ============================================
  module QueueManagement
    # NPC Animation Queue
    NPC_QUEUE_BATCH_SIZE = 10             # Items to fetch per processing batch
    NPC_CLEANUP_SECONDS = 3600            # 1 hour
    RATE_WINDOW_SECONDS = 60              # 1 minute for rate limiting

    # General queue defaults
    DEFAULT_PRIORITY = 5
  end

  # ============================================
  # Rendering Configuration
  # Canvas rendering constants for maps and displays
  # ============================================
  module Rendering
    # Minimap dimensions and sizes
    MINIMAP = {
      canvas_width: 400,
      canvas_height: 376,
      center_room_size: 120,
      exit_room_size: 100,
      door_width: 16,
      door_height: 6,
      spatial_max_viewport_feet: 500,
      spatial_char_dot_radius: 5,
      spatial_min_room_px: 15
    }.freeze

    # Roommap dimensions and sizes
    ROOMMAP = {
      max_canvas_size: 800,
      min_canvas_size: 400,
      padding: 30,
      char_radius: 8,
      self_radius: 10,
      place_min_size: 30,
      exit_size: 24,
      legend_height: 80,
      room_name_height: 40
    }.freeze

    # Areamap dimensions and sizes
    AREAMAP = {
      canvas_size: 600,
      grid_size: 9,                # Number of hex cells per side (9x9 grid)
      margin: 15,                  # Pixel margin around the hex grid
      feature_width: 2,            # Line width for roads/rivers
      title_height: 36             # Height reserved for title area
    }.freeze

    # Battle map dimensions
    BATTLE_MAP = {
      min_hex_width: 57,           # ~1.5cm at 96dpi
      max_hex_width: 94,           # ~2.5cm at 96dpi
      container_width: 280         # #lobserve width minus padding
    }.freeze

    # Battlemap V2 pipeline: SAM2G + Gemini wall/door recolor (replaces L1/L2/L3 grid classification)
    BATTLEMAP_V2_ENABLED = true

    # Delve map dimensions
    DELVE_MAP = {
      cell_size: 20,
      padding: 10
    }.freeze

    # Lab color space reference (for gradient calculations)
    LAB_REFERENCE = {
      x: 95.047,
      y: 100.0,
      z: 108.883
    }.freeze
  end

  # ============================================
  # Messenger Configuration
  # Delivery time delays for era-appropriate messaging
  # ============================================
  module Messenger
    # Medieval era (courier-based delivery)
    MEDIEVAL = {
      base_delay_seconds: 300,     # 5 minutes minimum
      per_room_delay_seconds: 30   # 30 seconds per room distance
    }.freeze

    # Gaslight era (telegram-based delivery)
    GASLIGHT = {
      base_delay_seconds: 60,      # 1 minute minimum
      per_area_delay_seconds: 120  # 2 minutes per area distance
    }.freeze
  end

  # ============================================
  # Auto-GM Configuration
  # Adventure generation and context management
  # ============================================
  module AutoGm
    # Compression hierarchy (how many items at each level)
    COMPRESSION = {
      actions_per_event: 5,        # Actions summarized per event
      events_per_scene: 5,         # Event summaries per scene
      scenes_per_act: 3,           # Scene summaries per act
      acts_per_session: 3          # Act summaries per session
    }.freeze

    # Context gathering limits
    CONTEXT = {
      max_nearby_memories: 10,
      max_character_memories: 5,
      max_location_search_depth: 15,
      max_nearby_locations: 8
    }.freeze

    # Chaos level range
    CHAOS = {
      minimum: 1,
      maximum: 9,
      default: 5
    }.freeze

    # Session timeout
    INACTIVITY_TIMEOUT_HOURS = 2

    # Loot distribution limits
    LOOT = {
      max_per_hour: 500,              # Maximum currency value per character per hour
      default_reward_value: 50,       # Value when no currency amount specified in reward
      currency_patterns: [            # Patterns to extract currency amounts
        /(\d+)\s*(?:dollars?|bucks?)/i,
        /(\d+)\s*(?:gold|gp)/i,
        /(\d+)\s*(?:credits?|cr)/i,
        /\$(\d+)/
      ]
    }.freeze

    # LLM operation timeouts (in seconds)
    TIMEOUTS = {
      synthesis: 180,           # Mission/context synthesis (3 min)
      brainstorm: 180,          # Mission brainstorming (3 min)
      event: 30,                # Event generation
      decision: 60,             # Decision making
      resolution: 30            # Resolution generation
    }.freeze
  end

  # ============================================
  # Pet Animation Configuration
  # ============================================
  module PetAnimation
    # Cooldowns (in seconds)
    PET_COOLDOWN_SECONDS = 120           # 2 minute cooldown between pet animations
    MAX_ROOM_ANIMATIONS_PER_MINUTE = 3   # Per room

    # Idle animation interval range (seconds)
    IDLE_MIN_SECONDS = 120               # 2 minutes
    IDLE_MAX_SECONDS = 300               # 5 minutes
  end

  # ============================================
  # Time Configuration
  # Day/night cycle and calendar constants
  # ============================================
  module Time
    # Dawn/dusk hours (24-hour format)
    DEFAULT_DAWN_HOUR = 6
    DEFAULT_DUSK_HOUR = 18

    # Lunar cycle
    LUNAR_CYCLE_DAYS = 29.53059
  end

  # ============================================
  # Navigation Configuration
  # Pathfinding and grid settings
  # ============================================
  module Navigation
    # Smart navigation limits (scaled by 1.5x for 2ft hex system)
    SMART_NAV = {
      max_direct_walk: 23,         # Max distance for direct walking (15 × 1.5, rounded up)
      max_building_path: 30        # Max building pathfinding distance (20 × 1.5)
    }.freeze

    # Combat pathfinding (scaled by 1.5x for 2ft hex system)
    COMBAT_PATHFINDING = {
      max_path_length: 75          # 50 × 1.5
    }.freeze

    # Grid calculation (for street/city layouts)
    GRID = {
      cell_size_feet: 175,         # Grid cell size in feet
      street_width_feet: 25        # Street width in feet
    }.freeze

    # World travel timing
    WORLD_TRAVEL = {
      base_time_per_hex: 300       # Seconds per hex
    }.freeze

    # Autodrive prompt threshold
    AUTODRIVE_THRESHOLD_FEET = 500
  end

  # ============================================
  # World Travel Configuration
  # ============================================
  module WorldTravel
    # Era-scaled water terrain bonuses (boats are faster on water)
    # Higher = faster. Applied when travel_mode == 'water'
    WATER_ERA_BONUSES = {
      medieval: 2.0,      # Boats were fastest long-distance travel
      gaslight: 1.8,      # Steamships competitive with early rail
      modern: 1.2,        # Ferries slower than cars/planes
      near_future: 1.0,   # Neutral - other options better
      scifi: 0.8          # Hovercrafts work but not optimal
    }.freeze

    # Railway speed bonus when traveling on tracks
    RAILWAY_SPEED_BONUS = 3.0

    # Land terrain penalty for water travel (boats can't cross land)
    WATER_MODE_LAND_PENALTY = 100

    # Water terrain penalty for land travel (can't walk on water)
    LAND_MODE_WATER_PENALTY = 100
  end

  # ============================================
  # Forms Configuration
  # Input validation constraints
  # ============================================
  module Forms
    # Maximum input lengths
    MAX_LENGTHS = {
      # Base character customization
      description: 300,
      roomtitle: 200,
      graffiti: 220,
      name: 50,
      nickname: 50,
      custom_description: 500,

      # Communication
      memo_subject: 200,
      memo_body: 10_000,
      ooc_message: 500,
      bulletin_body: 2_000,
      ticket_subject: 200,
      ticket_content: 10_000,

      # Building/Content creation
      item_name: 200,
      item_description: 2_000,
      room_name: 100,
      room_short_desc: 500,
      room_long_desc: 5_000,
      url: 2_048,
      location_name: 100,
      shop_name: 100,
      picture_url: 500,
      event_name: 200,
      background_url: 2_048,

      # Timeline snapshots
      snapshot_name: 100,
      snapshot_description: 500
    }.freeze
  end

  # ============================================
  # Character Configuration
  # ============================================
  module Character
    LEVEL_RANGE = (1..100).freeze
    NAME_COUNTER_PADDING = 3       # Padding for NPC name counters (e.g., 001, 002)
  end

  # ============================================
  # Name Generation Configuration
  # Markov chain and procedural name settings
  # ============================================
  module NameGeneration
    # Name length constraints
    MIN_NAME_LENGTH = 3
    MAX_NAME_LENGTH = 15

    # Markov chain settings
    MARKOV_ORDER = 2

    # Weighting tracker settings
    WEIGHTING = {
      max_history: 100,
      decay_rate: 0.1,
      base_penalty: 3.0
    }.freeze

    # Markov probabilities
    MARKOV_PROBABILITY = {
      city: 0.15,
      street: 0.1
    }.freeze
  end

  # ============================================
  # Cache Configuration
  # TTL values for various caches
  # ============================================
  module Cache
    # TTL values in seconds
    SYNC_TTL = 300                 # 5 minutes - media sync
    HELP_REQUEST_TTL = 300         # 5 minutes - help request cache
    WEATHER_PROSE_TTL = 2700       # 45 minutes - weather prose
    AUTOHELPER_WINDOW = 600        # 10 minutes - autohelper context window
    GAME_SETTING_TTL = 300         # 5 minutes - game settings
  end

  # ============================================
  # Content Configuration
  # User-generated content settings
  # ============================================
  module Content
    # Display limits
    BULLETIN_MAX_DISPLAY = 15
    BULLETIN_EXPIRATION_DAYS = 10

    # Audio queue
    AUDIO_QUEUE_EXPIRY_MINUTES = 10

    # Chapter boundaries for character stories
    CHAPTER_MAX_WORDS = 4000
    CHAPTER_MIN_WORDS = 300
    CHAPTER_TIME_GAP_HOURS = 6
  end

  # ============================================
  # Files Configuration
  # File upload and download settings
  # ============================================
  module Files
    # Size limits
    MAX_IMAGE_SIZE_BYTES = 10 * 1024 * 1024  # 10 MB
  end

  # ============================================
  # Autobattle Configuration
  # ============================================
  module Autobattle
    STYLES = %w[aggressive defensive supportive].freeze

    # Ability valuation multipliers by style and category
    ABILITY_MULTIPLIERS = {
      'aggressive' => {
        attack: 1.3,
        healing: 0.6,
        buff: 0.7,
        shield: 0.7,
        default: 1.0
      },
      'defensive' => {
        attack: 0.7,
        healing: 1.3,
        buff: 1.2,
        shield: 1.4,
        default: 1.0
      },
      'supportive' => {
        attack: 0.5,
        healing: 1.5,
        buff: 1.5,
        shield: 1.5,
        default: 0.8
      }
    }.freeze

    # Movement tendencies (probability weights)
    MOVEMENT_WEIGHTS = {
      'aggressive' => { charge: 0.8, retreat: 0.1, hold: 0.1 },
      'defensive' => { charge: 0.2, retreat: 0.5, hold: 0.3 },
      'supportive' => { charge: 0.1, retreat: 0.3, hold: 0.6 }
    }.freeze

    # Tactic assignments
    TACTICS = {
      'aggressive' => 'aggressive',
      'defensive' => 'defensive',
      'supportive' => nil  # Uses guard/back_to_back dynamically
    }.freeze

    # Willpower rules
    WILLPOWER = {
      top_ability_count: 2  # Top 2 abilities = spend all willpower
    }.freeze
  end

  # ============================================
  # Moderation Configuration
  # Auto-moderation action durations
  # ============================================
  module Moderation
    # Duration constants (in seconds)
    DURATIONS = {
      ip_ban: 90 * 24 * 3600,           # 90 days
      range_ban: 24 * 3600,              # 24 hours
      registration_freeze: 3600,         # 1 hour
      suspension: 7 * 24 * 3600,         # 7 days (1 week)
      temp_mute: 15 * 60                 # 15 minutes
    }.freeze

    # Abuse monitoring thresholds
    ABUSE_THRESHOLD_HOURS = 100          # Playtime threshold for exemption
    ABUSE_EXEMPTION_SECONDS = 360_000    # Same threshold in seconds (100 hours)

    # Emote rate limiting
    EMOTE_RATE_LIMIT = {
      room_threshold: 8,                 # People in room before limiting
      emote_limit: 3,                    # Max emotes per window
      window_seconds: 60                 # Window duration
    }.freeze

    # Consent system
    CONSENT_DISPLAY_TIMER_SECONDS = 600  # Timer display threshold

    # OOC request cooldown
    OOC_REQUEST_COOLDOWN_HOURS = 1
  end

  # ============================================
  # Dice Configuration
  # Limits for dice rolling commands
  # ============================================
  module Dice
    LIMITS = {
      max_count: 20,
      max_sides: 100,
      min_sides: 2
    }.freeze

    # Service-level limits used by DiceRollService
    SERVICE_LIMITS = {
      count_range: 1..100,
      sides_range: 2..1000,
      max_explosions: 10
    }.freeze

    # Animation settings for dice roll display
    ANIMATION = {
      base_frames: 2..4,       # Random frames per base die
      explosion_frames: 2..3   # Random frames per explosion die
    }.freeze
  end

  # ============================================
  # Display Configuration
  # Truncation lengths and query limits
  # ============================================
  module Display
    # String truncation lengths for display
    TRUNCATE_LENGTHS = {
      memo_subject: 33,
      ooc_message: 50,
      help_summary: 60,
      opponent_desc: 33,
      autogm_context: 200,
      room_name_map: 8,
      generated_text: 100
    }.freeze

    # Query result limits
    QUERY_LIMITS = {
      default_search: 10,
      character_search: 100,
      help_search: 15,
      taxi_destinations: 8,
      reskin_patterns: 20,
      ticket_list: 20,
      storage_items: 50,
      events_upcoming: 10,
      events_all: 20,
      events_character: 20,
      events_location: 10,
      scenes_recent: 50,
      scenes_completed: 20,
      scenes_cancelled: 20,
      pattern_search: 10,
      missed_messages: 100,
      recent_contacts: 10,
      activity_min_samples: 20,
      activity_peak_times: 5,
      activity_schedule_threshold: 20
    }.freeze
  end

  # ============================================
  # City Builder Configuration
  # ============================================
  # Default building height when location doesn't specify one
  DEFAULT_BUILDING_HEIGHT = 200

  # Sky room starts this many feet above the tallest building
  SKY_CLEARANCE_FEET = 100

  # Vertical extent of the sky room in feet
  SKY_HEIGHT_FEET = 500

  module CityBuilder
    DEFAULTS = {
      horizontal_streets: 10,
      vertical_streets: 10,
      max_building_height: DEFAULT_BUILDING_HEIGHT
    }.freeze

    LIMITS = {
      min_streets: 2,
      max_streets: 50,
      min_avenues: 2,
      max_avenues: 50,
      min_building_height: 50,
      max_building_height: 1000
    }.freeze
  end

  # ============================================
  # Clothing / Visibility Configuration
  # ============================================
  module Clothing
    DEFAULT_WORN_LAYER = 1
    DEFAULT_DISPLAY_ORDER = 100
    FULLY_TORN_THRESHOLD = 10
  end

  # ============================================
  # Weather Simulation Configuration
  # ============================================
  module Weather
    # Base temperatures by climate type (Celsius)
    CLIMATE_TEMPS = {
      tropical: 30,
      temperate: 15,
      continental: 10,
      polar: -10,
      arid: 35
    }.freeze

    # Simulation parameters
    SIMULATION = {
      temp_clamp_min: -60,
      temp_clamp_max: 60,
      precipitation_divisor: 100.0,
      seasonal_probability: 0.75,
      severe_clamp_min: 1,
      severe_clamp_max: 100,
      humidity_variance_min: -10,
      humidity_variance_max: 10,
      wind_clamp_min: 0,
      wind_clamp_max: 120,
      cloud_clamp_min: 0,
      cloud_clamp_max: 100
    }.freeze

    # Wind base speeds by climate
    WIND_BASES = {
      tropical: 20,
      temperate: 15,
      continental: 12,
      polar: 20,
      arid: 15
    }.freeze

    # Clear sky base percentages by climate
    CLEAR_SKY_BASES = {
      arid: 80,
      tropical: 65,
      temperate: 55,
      continental: 50,
      polar: 40
    }.freeze

    # Season adjustments
    SEASON_ADJUSTMENTS = {
      summer_clear_bonus: 10,
      winter_clear_penalty: -10
    }.freeze

    # Max change multipliers
    MAX_CHANGE = {
      temperature: { min: 1, max: 10, multiplier: 2 },
      humidity: { min: 2, max: 15, multiplier: 5 },
      wind: { min: 3, max: 20, multiplier: 8 },
      cloud: { min: 5, max: 25, multiplier: 10 }
    }.freeze

    # Update delay between weather calculations
    UPDATE_DELAY_SECONDS = 1.1
  end

  # ============================================
  # Weather Simulator Configuration
  # ============================================
  # Constants used by WeatherSimulatorService for realistic weather generation.
  module WeatherSimulator
    # Base temperatures by climate (Celsius) with seasonal deltas
    CLIMATE_TEMPS = {
      'tropical'    => { base: 28, summer_delta: 4, winter_delta: -2 },
      'subtropical' => { base: 22, summer_delta: 8, winter_delta: -5 },
      'temperate'   => { base: 15, summer_delta: 10, winter_delta: -10 },
      'subarctic'   => { base: 0,  summer_delta: 12, winter_delta: -15 },
      'arctic'      => { base: -15, summer_delta: 10, winter_delta: -20 }
    }.freeze

    # Seasonal multipliers for spring/fall interpolation
    SEASONAL_MULTIPLIERS = {
      spring: 0.5,
      fall: 0.5
    }.freeze

    # Time of day temperature variations (Celsius)
    TIME_OF_DAY_VARIATIONS = {
      dawn: -3,
      morning: -1,
      midday: 2,
      afternoon: 3,
      evening: 0,
      night: -4,
      midnight: -5
    }.freeze

    # Polar regions have reduced day/night variation
    POLAR_VARIATION_MULTIPLIER = 0.3

    # Daily random variation range
    DAILY_VARIATION_RANGE = (-3..3)

    # Temperature bounds (Celsius)
    TEMPERATURE_BOUNDS = (-60..60)

    # Probability of using seasonal pool vs any valid condition
    SEASONAL_POOL_WEIGHT = 0.75

    # Weight clamp range for storm/precip condition weighting
    CONDITION_WEIGHT_CLAMP = (1..10)

    # Intensity weights by climate { light: N, moderate: N, heavy: N, severe: N }
    INTENSITY_WEIGHTS = {
      'tropical'    => { light: 20, moderate: 40, heavy: 30, severe: 10 },
      'subtropical' => { light: 25, moderate: 40, heavy: 25, severe: 10 },
      'temperate'   => { light: 30, moderate: 40, heavy: 20, severe: 10 },
      'subarctic'   => { light: 25, moderate: 35, heavy: 25, severe: 15 },
      'arctic'      => { light: 20, moderate: 30, heavy: 30, severe: 20 }
    }.freeze

    # Base humidity by climate (percentage)
    HUMIDITY_BASES = {
      'tropical'    => 80,
      'subtropical' => 65,
      'temperate'   => 55,
      'subarctic'   => 45,
      'arctic'      => 30
    }.freeze

    # Tropical humidity seasonal adjustments
    TROPICAL_HUMIDITY = {
      wet_season: 15,
      dry_season: -15
    }.freeze

    # Humidity random variation range and bounds
    HUMIDITY_VARIATION_RANGE = (-10..10)
    HUMIDITY_BOUNDS = (0..100)

    # Wind base speeds by climate (kph)
    WIND_BASES = {
      'tropical'    => 15,
      'subtropical' => 12,
      'temperate'   => 18,
      'subarctic'   => 22,
      'arctic'      => 25
    }.freeze

    # Wind random variation range and bounds
    WIND_VARIATION_RANGE = (-5..10)
    WIND_BOUNDS = (0..120)

    # Cloud cover base by season (percentage)
    CLOUD_BASES = {
      'summer' => 35,
      'winter' => 65,
      'spring' => 50,
      'fall'   => 55
    }.freeze

    # Cloud cover random variation range and bounds
    CLOUD_VARIATION_RANGE = (-10..15)
    CLOUD_BOUNDS = (0..100)
  end

  # ============================================
  # Clan Configuration
  # ============================================
  module Clan
    LIMITS = {
      max_name_length: 100,
      max_handle_length: 50,
      min_prefix_length: 2
    }.freeze
  end

  # ============================================
  # Pathfinding Configuration
  # ============================================
  module Pathfinding
    MAX_PATH_LENGTH = 75           # 50 × 1.5 (scaled for 2ft hex system)
  end

  # ============================================
  # Prisoner/Restraint Configuration
  # ============================================
  module Prisoner
    WAKE_DELAY_SECONDS = 60      # 1 minute before manual wake is allowed
    AUTO_WAKE_SECONDS = 600      # 10 minutes until auto-wake
    DRAG_SPEED_MODIFIER = 1.5    # 50% slower when dragging/carrying
  end

  # ============================================
  # Combat Name Alternation Configuration
  # ============================================
  module Combat
    # Name alternation for prose variety
    NAME_ALTERNATION = {
      name_probability: 70,        # % chance to use actual name vs descriptor
      descriptor_probabilities: {
        name_part: 20,             # "the woman"
        eye_color: 10,             # "the blue-eyed woman"
        body_type: 10,             # "the slim fighter"
        height: 10,                # "the tall man"
        hair: 10,                  # "the blonde fighter"
        weapon: 10                 # "the sword-wielding man"
      }
    }.freeze

    # Height thresholds for descriptors (cm)
    HEIGHT_THRESHOLDS = {
      short_max: 158,              # Below this = "short"
      tall_min: 182,               # Above this = "tall"
      significant_diff: 20         # Minimum height diff to use descriptor
    }.freeze

    # Post-combat entry cooldown
    POST_COMBAT_ENTRY_COOLDOWN_SECONDS = 600

    # Modifier cap for game play calculations
    MODIFIER_CAP = 0.4
  end

  # ============================================
  # Battle Map Generator Configuration
  # ============================================
  module BattleMap
    # Global scale factor applied to all cover density values (category + per-room-type).
    # Tune this to make maps more open (< 1.0) or more cluttered (> 1.0).
    COVER_DENSITY_SCALE = 0.6

    # Category-level defaults
    CATEGORY_DEFAULTS = {
      indoor: { cover_density: 0.20, hazard_chance: 0.02, elevation_variance: 0, water_chance: 0.0 },
      outdoor: { cover_density: 0.15, hazard_chance: 0.03, elevation_variance: 1, water_chance: 0.03 },
      underground: { cover_density: 0.20, hazard_chance: 0.06, elevation_variance: 2, water_chance: 0.06 }
    }.freeze

    # AI generation batch settings
    AI_GENERATION = {
      chunk_threshold: 100,
      chunk_size: 50,
      draw_batch_size: 50
    }.freeze

    # Hazard types by category
    CATEGORY_HAZARDS = {
      indoor: %w[fire electricity sharp],
      outdoor: %w[fire sharp unstable_floor poison],
      underground: %w[gas poison spike_trap pressure_plate unstable_floor]
    }.freeze

    # Water type weights by depth likelihood
    WATER_TYPE_WEIGHTS = {
      'puddle' => 50,
      'wading' => 30,
      'swimming' => 15,
      'deep' => 5
    }.freeze

    # Hazard damage ranges by type
    HAZARD_DAMAGE = {
      fire: 1..3,
      electricity: 2..4,
      sharp: 1..2,
      gas: 1..1,
      poison: 1..2,
      spike_trap: 2..4,
      explosion: 5..15
    }.freeze

    # Hazard save difficulties
    HAZARD_SAVE_DIFFICULTY = {
      spike_trap: 10..15
    }.freeze

    # Transition feature probability
    TRANSITION_FEATURE_CHANCE = 0.3

    # Water spread probability
    WATER_SPREAD_CHANCE = 0.2

    # Elevation zone counts
    ELEVATION_ZONES = 2..4
    ELEVATION_SPREAD_RADIUS = 2..4
  end

  # ============================================
  # Clue System Configuration
  # ============================================
  module Clue
    EMBEDDING_TYPE = 'clue'
    DEFAULT_LIMIT = 3              # Default clues to return
    SIMILARITY_THRESHOLD = 0.4    # Embedding similarity threshold
    OVER_FETCH_MULTIPLIER = 2     # Fetch 2x limit for filtering
    MEMORY_IMPORTANCE = 6         # Importance level for clue share memories
  end

  # ============================================
  # Journey/Flashback Configuration
  # ============================================
  module Journey
    FLASHBACK_MAX_SECONDS = 12 * 3600  # 12 hours maximum
    BACKLOADED_DEBT_MULTIPLIER = 2     # Return takes 2x the travel time
  end

  # ============================================
  # Fabrication Configuration
  # Era-based crafting times and facility requirements
  # ============================================
  module Fabrication
    # Room types that allow fabrication by pattern category
    # Keys are unified_object_type categories
    # Universal facilities can fabricate any pattern type
    FACILITY_REQUIREMENTS = {
      'clothing' => %w[tailor shop fashion_studio],
      'jewelry' => %w[jeweler shop crafting_studio],
      'weapon' => %w[forge armory blacksmith],
      'tattoo' => %w[tattoo_parlor clinic],
      'pet' => %w[pet_shop breeder cloning_lab]
    }.freeze

    # These facilities can fabricate any pattern type
    UNIVERSAL_FACILITIES = %w[replicator materializer fabrication_bay].freeze

    # Fabrication times by era (base time in seconds)
    # Medieval/gaslight are in hours, modern in minutes, near_future in seconds
    ERA_TIMES = {
      medieval:    { base_seconds: 14_400, complexity_mult: 1.0 },  # 4 hours
      gaslight:    { base_seconds: 7200,   complexity_mult: 1.0 },  # 2 hours
      modern:      { base_seconds: 1800,   complexity_mult: 1.0 },  # 30 min
      near_future: { base_seconds: 60,     complexity_mult: 1.0 },  # 1 min
      scifi:       { base_seconds: 3,      complexity_mult: 1.0 }   # instant
    }.freeze

    # Below this threshold (in seconds), fabrication is considered instant
    INSTANT_THRESHOLD_SECONDS = 10

    # Pattern type complexity multipliers (by pattern type method)
    COMPLEXITY_MULTIPLIERS = {
      'clothing' => 1.0,    # Clothing - standard
      'jewelry' => 1.5,     # Jewelry - more intricate
      'weapon' => 2.0,      # Weapons - heavy work
      'tattoo' => 0.5,      # Tattoos - quicker
      'pet' => 3.0          # Pets - breeding/cloning takes longer
    }.freeze

    # Order statuses
    STATUSES = %w[crafting ready delivered cancelled].freeze

    # Delivery methods
    DELIVERY_METHODS = %w[pickup delivery].freeze

    # Helper to get pattern type key for config lookups
    def self.pattern_type_key(pattern)
      return 'pet' if pattern.pet?
      return 'weapon' if pattern.weapon?
      return 'jewelry' if pattern.jewelry?

      'clothing' # Default
    end
  end

  # ============================================
  # Activity Profile Configuration
  # User activity tracking and decay
  # ============================================
  module ActivityProfile
    SLOTS_PER_WEEK = 168
    DECAY_HALF_LIFE_WEEKS = 4.0
    DEFAULT_THRESHOLD = 20
  end

  # ============================================
  # Ability Power Calculator Configuration
  # ============================================
  module AbilityPower
    DEFAULT_POWER_PER_DAMAGE = 100.0 / 15.0
    DEFAULT_DOT_PENALTY = 0.7
    DEFAULT_HEALING_MULTIPLIER = 0.8
    DEFAULT_STAT_BONUS = 3
    FINAL_THRESHOLD = 5.0
  end

  # ============================================
  # Room Management Configuration
  # ============================================
  module Rooms
    TEMP_POOL_RELEASE_DELAY_SECONDS = 300
  end

  # ============================================
  # NPC Relationship Configuration
  # ============================================
  module NpcRelationship
    REJECTION_COOLDOWN_SECONDS = 3600
  end

  # ============================================
  # RP Logging Configuration
  # ============================================
  module Logging
    DEDUP_WINDOW_SECONDS = 120
  end

  # ============================================
  # World Map Configuration
  # ============================================
  module WorldMap
    MAX_ZOOM_LEVEL = 7
    MIN_ZOOM_LEVEL = 0
    GRID_SIZE = 3
  end

  # ============================================
  # Season System Configuration
  # Astronomical season calculations and latitude bands
  # ============================================
  module Season
    # Astronomical boundaries (approximate day of year)
    # These represent Northern Hemisphere solstices/equinoxes
    BOUNDARIES = {
      vernal_equinox: 79,    # ~Mar 20
      summer_solstice: 172,  # ~Jun 21
      autumnal_equinox: 265, # ~Sep 22
      winter_solstice: 355   # ~Dec 21
    }.freeze

    # Latitude bands for different season systems
    # Ranges are in degrees from equator (absolute value)
    LATITUDE_BANDS = {
      tropical:      { min: 0,    max: 23.5 },  # Wet/Dry seasons
      subtropical:   { min: 23.5, max: 35.0 },  # Mild 4 seasons
      temperate:     { min: 35.0, max: 55.0 },  # Traditional 4 seasons
      high_latitude: { min: 55.0, max: 66.5 },  # Extended winters
      polar:         { min: 66.5, max: 90.0 }   # Polar day/night
    }.freeze

    # Transition period in days between seasons
    TRANSITION_DAYS = 21

    # Default latitude when none provided (temperate zone)
    DEFAULT_LATITUDE = 45.0

    # Standard 4 seasons (temperate/subtropical/high_latitude)
    TEMPERATE_SEASONS = %i[spring summer fall winter].freeze

    # Tropical seasons (mapped to summer/winter for compatibility)
    TROPICAL_SEASONS = %i[wet dry].freeze

    # Polar seasons (mapped to summer/winter for compatibility)
    POLAR_SEASONS = %i[polar_day polar_night].freeze

    # Mapping from raw seasons to temperate equivalents
    # Used for backward compatibility with seasonal content lookups
    RAW_TO_TEMPERATE = {
      wet: :summer,
      dry: :winter,
      polar_day: :summer,
      polar_night: :winter,
      spring: :spring,
      summer: :summer,
      fall: :fall,
      winter: :winter
    }.freeze
  end

  # ============================================
  # Narrative Intelligence Configuration
  # ============================================
  module Narrative
    THREADS = {
      min_cluster_size: 3,           # Minimum entities for a thread
      jaccard_match_threshold: 0.3,  # Jaccard similarity to match cluster to existing thread
      dormant_days: 30,              # Days of inactivity before thread becomes dormant
      resolved_days: 90,             # Days of inactivity before dormant becomes resolved
      summary_model: 'claude-haiku-4-5',
      summary_provider: 'anthropic'
    }.freeze

    EXTRACTION = {
      batch_limit: 50,                     # Max memories per batch extraction
      max_entities_per_memory: 10,         # Max entities extracted from one memory
      max_relationships_per_memory: 15,    # Max relationships extracted from one memory
      comprehensive_model: 'claude-haiku-4-5',
      comprehensive_provider: 'anthropic',
      batch_model: 'claude-haiku-4-5',
      batch_provider: 'anthropic',
      dedup_embedding_threshold: 0.85,     # Cosine similarity for entity deduplication
      importance_threshold_comprehensive: 7 # Min importance for comprehensive extraction
    }.freeze
  end

  # ============================================
  # Game Cleanup Configuration
  # Periodic health check thresholds for fights, activities, and Auto-GM
  # ============================================
  module Cleanup
    FIGHT_ALL_LEFT_ROOM_SECONDS = 120      # 2 min grace for left-room
    ACTIVITY_ALL_LEFT_ROOM_SECONDS = 300   # 5 min grace
    ACTIVITY_INACTIVITY_SECONDS = 1800     # 30 min no round progress
    ACTIVITY_MAX_DURATION_SECONDS = 86_400 # 24 hours
    ACTIVITY_STUCK_SETUP_SECONDS = 900     # 15 min stuck in setup
    AUTO_GM_ORPHAN_SECONDS = 1800          # 30 min no heartbeat + no actions
    AUTO_GM_ALL_LEFT_ROOM_SECONDS = 600    # 10 min grace
    AUTO_GM_MAX_DURATION_SECONDS = 28_800  # 8 hours
  end
end
