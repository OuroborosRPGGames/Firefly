# frozen_string_literal: true

# Handles roving monster spawning, movement, and encounter triggering.
class DelveMonsterService
  class << self
    # Spawn roving monsters for a level
    # @param delve [Delve] the delve
    # @param level [Integer] the level number
    # @param rng [Random] optional random generator
    # @return [Array<DelveMonster>] spawned monsters
    def spawn_monsters!(delve, level, rng = nil)
      rng ||= Random.new

      count = calculate_spawn_count(delve, level, rng)
      rooms = available_spawn_rooms(delve, level)

      return [] if rooms.empty?

      monsters = []
      difficulty = delve.monster_difficulty_for_level(level)

      count.times do
        room = rooms.sample(random: rng)
        monster_type = pick_monster_type(level, rng)
        hp = calculate_monster_hp(difficulty)

        monster = DelveMonster.create(
          delve_id: delve.id,
          current_room_id: room.id,
          level: level,
          monster_type: monster_type,
          difficulty_value: difficulty,
          hp: hp,
          max_hp: hp,
          damage_bonus: calculate_damage_bonus(difficulty)
        )

        monster.pick_direction!(rng: rng)
        monsters << monster
      end

      monsters
    end

    # Tick monster movement after a time-consuming action
    # @param delve [Delve] the delve
    # @param time_spent_seconds [Integer] time spent on action
    # @return [Array<Hash>] collision events
    def tick_movement!(delve, time_spent_seconds)
      return [] unless time_spent_seconds >= GameConfig::DelveMonster::MOVEMENT_THRESHOLD_SECONDS

      delve.tick_monster_movement!(time_spent_seconds)
    end

    # Check for collision at a room (after player movement)
    # @param delve [Delve] the delve
    # @param room [DelveRoom] the room to check
    # @return [DelveMonster, nil] monster if collision occurred
    def check_collision(delve, room)
      delve.monsters_in_room(room).first
    end

    # Start combat between monster and participants
    # @param delve [Delve] the delve
    # @param monster [DelveMonster] the monster
    # @param participants [Array<DelveParticipant>] participants in combat
    # @return [Hash] combat start info
    def start_combat!(delve, monster, participants)
      DelveCombatService.create_fight!(delve, monster, participants)
    end

    # Spawn lurking monsters in terminal rooms
    # @param delve [Delve] the delve
    # @param level [Integer] the level number
    # @param rng [Random] optional random generator
    # @return [Array<DelveMonster>] spawned lurkers
    def spawn_lurkers!(delve, level, rng = nil)
      rng ||= Random.new

      lurker_chance = GameConfig::Delve::CONTENT[:lurker_chance] || 0.3
      terminals = delve.rooms_on_level(level)
                       .where(is_terminal: true)
                       .exclude(is_entrance: true)
                       .exclude(is_exit: true)
                       .exclude(is_boss: true)
                       .all

      lurkers = []
      difficulty = delve.monster_difficulty_for_level(level)

      terminals.each do |room|
        next unless rng.rand < lurker_chance

        monster_type = pick_monster_type(level, rng)
        hp = calculate_monster_hp(difficulty)

        lurker = DelveMonster.create(
          delve_id: delve.id,
          current_room_id: room.id,
          level: level,
          monster_type: monster_type,
          difficulty_value: difficulty,
          hp: hp,
          max_hp: hp,
          damage_bonus: calculate_damage_bonus(difficulty),
          lurking: true
        )

        lurkers << lurker
      end

      lurkers
    end

    private

    # Calculate how many monsters to spawn
    def calculate_spawn_count(delve, level, rng)
      spawn_config = GameConfig::DelveMonster::SPAWN
      multipliers = GameConfig::DelveMonster::DIFFICULTY_SPAWN_MULTIPLIERS

      base = rng.rand(spawn_config[:base_range])
      level_bonus = level / spawn_config[:level_divisor]
      difficulty_mult = multipliers[delve.difficulty] || 1.0

      ((base + level_bonus) * difficulty_mult).round
    end

    # Get rooms that can have monsters spawned
    def available_spawn_rooms(delve, level)
      delve.rooms_on_level(level)
           .exclude(is_entrance: true).exclude(is_exit: true).exclude(is_boss: true)
           .where(is_entrance: false, is_exit: false)
           .all
    end

    # Pick monster type based on level
    def pick_monster_type(level, rng)
      tier_config = GameConfig::DelveMonster::TIER_SELECTION
      types = DelveMonster::MONSTER_TYPES

      # Higher tier monsters at deeper levels
      max_index = types.length - 1
      tier = [level / tier_config[:level_divisor], max_index - 1].min
      variance = tier_config[:tier_variance]
      min_tier = [tier - variance, 0].max
      max_tier = [tier + variance, max_index - 1].min

      # Ensure valid range
      min_tier = [min_tier, max_tier].min

      types[rng.rand(min_tier..max_tier)]
    end

    # Calculate monster HP from difficulty
    def calculate_monster_hp(difficulty)
      scaling = GameConfig::DelveMonster::SCALING
      base = scaling[:base_hp]
      bonus = difficulty / scaling[:hp_divisor]

      base + bonus
    end

    # Calculate damage bonus from difficulty
    def calculate_damage_bonus(difficulty)
      scaling = GameConfig::DelveMonster::SCALING
      difficulty / scaling[:damage_divisor]
    end
  end
end
