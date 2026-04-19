# frozen_string_literal: true

module Battlemap
  class BattleMapElementPlacementService
    PLACEMENT_CAP_RATIO = 0.05
    CLIFF_CHANCE = 0.5
    ELEMENT_APPEARANCE_RANGE = (0.4..0.6)
    MIN_SPACING = 2
    CLUSTER_SIZE_RANGE = (2..3)

    def initialize(fight)
      @fight = fight
      @room = fight.room
    end

    def place_elements
      return [] unless @room.respond_to?(:eligible_battle_elements)
      # Check if this fight has an active battlemap (room has hex records)
      return [] unless RoomHex.where(room_id: @room.id).any?

      eligible = parse_eligible_elements
      return [] if eligible.empty?

      placed = []
      open_hexes = find_open_hexes
      return [] if open_hexes.empty?

      max_elements = (open_hexes.size * PLACEMENT_CAP_RATIO).floor
      used_hexes = Set.new
      spawn_hexes = find_spawn_adjacent_hexes

      # Handle cliff edge separately
      if eligible.include?('cliff_edge') && rand < CLIFF_CHANCE
        place_cliff_edge
        placed << 'cliff_edge'
      end

      # Place other elements
      placeable = eligible.select { |t| BattleMapElement::PLACEABLE_TYPES.include?(t) }
      placeable.shuffle.each do |element_type|
        break if placed.size >= max_elements

        appearance_chance = rand(ELEMENT_APPEARANCE_RANGE)
        next unless rand < appearance_chance

        if BattleMapElement::CLUSTER_TYPES.include?(element_type)
          hexes = pick_cluster_hexes(open_hexes, used_hexes, spawn_hexes)
          next if hexes.empty?

          hexes.each do |hx, hy|
            asset = BattleMapElementAsset.random_for_type(element_type)
            BattleMapElement.create(
              fight_id: @fight.id, element_type: element_type,
              hex_x: hx, hex_y: hy, state: 'intact',
              image_url: asset&.image_url
            )
            used_hexes.add("#{hx},#{hy}")
            placed << element_type
          end
        else
          hex = pick_single_hex(open_hexes, used_hexes, spawn_hexes)
          next unless hex

          asset = BattleMapElementAsset.random_for_type(element_type)
          BattleMapElement.create(
            fight_id: @fight.id, element_type: element_type,
            hex_x: hex[0], hex_y: hex[1], state: 'intact',
            image_url: asset&.image_url
          )
          used_hexes.add("#{hex[0]},#{hex[1]}")
          placed << element_type
        end
      end

      placed
    end

    private

    def parse_eligible_elements
      elements = @room.eligible_battle_elements
      return [] if elements.nil?

      case elements
      when Array then elements
      when String then JSON.parse(elements) rescue []
      else elements.to_a rescue []
      end
    end

    def find_open_hexes
      RoomHex.where(room_id: @room.id, traversable: true)
        .exclude(hex_type: %w[wall door window])
        .select_map([:hex_x, :hex_y])
    end

    def find_spawn_adjacent_hexes
      spawn_set = Set.new
      @fight.fight_participants.each do |p|
        next unless p.hex_x && p.hex_y

        spawn_set.add("#{p.hex_x},#{p.hex_y}")
        HexGrid.hex_neighbors(p.hex_x, p.hex_y).each do |nx, ny|
          spawn_set.add("#{nx},#{ny}")
        end
      end
      spawn_set
    end

    def pick_single_hex(open_hexes, used_hexes, spawn_hexes)
      candidates = open_hexes.select do |hx, hy|
        key = "#{hx},#{hy}"
        next false if used_hexes.include?(key)
        next false if spawn_hexes.include?(key)
        next false if too_close_to_used?(hx, hy, used_hexes)

        true
      end
      candidates.sample
    end

    def pick_cluster_hexes(open_hexes, used_hexes, spawn_hexes)
      open_set = open_hexes.map { |hx, hy| "#{hx},#{hy}" }.to_set
      cluster_size = rand(CLUSTER_SIZE_RANGE)

      # Try up to 20 times to find a valid cluster seed
      20.times do
        seed = pick_single_hex(open_hexes, used_hexes, spawn_hexes)
        next unless seed

        cluster = [seed]
        neighbors = HexGrid.hex_neighbors(seed[0], seed[1]).to_a.shuffle
        neighbors.each do |nx, ny|
          break if cluster.size >= cluster_size

          key = "#{nx},#{ny}"
          next unless open_set.include?(key)
          next if used_hexes.include?(key)
          next if spawn_hexes.include?(key)

          cluster << [nx, ny]
        end

        return cluster if cluster.size >= 2
      end

      []
    end

    def too_close_to_used?(hx, hy, used_hexes)
      used_hexes.any? do |key|
        ux, uy = key.split(',').map(&:to_i)
        HexGrid.hex_distance(hx, hy, ux, uy) < MIN_SPACING
      end
    end

    def place_cliff_edge
      edge = %w[north south east west].sample
      boundary_hexes = find_boundary_hexes(edge)

      BattleMapElement.create(
        fight_id: @fight.id, element_type: 'cliff_edge',
        edge_side: edge, state: 'intact'
      )

      boundary_hexes.each do |hx, hy|
        FightHex.create(fight_id: @fight.id, hex_x: hx, hex_y: hy, hex_type: 'long_fall')
      end
    end

    def find_boundary_hexes(edge)
      all_hexes = RoomHex.where(room_id: @room.id).select_map([:hex_x, :hex_y])
      return [] if all_hexes.empty?

      case edge
      when 'north'
        min_y = all_hexes.map(&:last).min
        all_hexes.select { |_, hy| hy == min_y }
      when 'south'
        max_y = all_hexes.map(&:last).max
        all_hexes.select { |_, hy| hy == max_y }
      when 'east'
        all_hexes.group_by(&:last).flat_map { |_y, row| [row.max_by(&:first)] }
      when 'west'
        all_hexes.group_by(&:last).flat_map { |_y, row| [row.min_by(&:first)] }
      end
    end
  end
end
