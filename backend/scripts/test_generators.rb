#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for world building generators
# Usage: bundle exec ruby scripts/test_generators.rb [generator] [options]
#
# Examples:
#   bundle exec ruby scripts/test_generators.rb seeds        # Test seed terms
#   bundle exec ruby scripts/test_generators.rb name         # Test name generation
#   bundle exec ruby scripts/test_generators.rb item         # Test item generation
#   bundle exec ruby scripts/test_generators.rb npc          # Test NPC generation
#   bundle exec ruby scripts/test_generators.rb room         # Test room generation
#   bundle exec ruby scripts/test_generators.rb place        # Test place generation
#   bundle exec ruby scripts/test_generators.rb city         # Test city name/streets
#   bundle exec ruby scripts/test_generators.rb village      # Generate full village
#   bundle exec ruby scripts/test_generators.rb all          # Run all tests

# Suppress plugin loading output
$VERBOSE_PLUGIN_LOADING = false
require_relative '../app'
require_relative '../app/services/seed_term_service'
require_relative '../app/services/name_generator_service'
require_relative '../app/services/generation_pipeline_service'

# Ensure all generators are loaded
Dir[File.join(__dir__, '../app/services/generators/*.rb')].each { |f| require f }

# Color output helpers
module Colors
  def self.green(text) = "\e[32m#{text}\e[0m"
  def self.red(text) = "\e[31m#{text}\e[0m"
  def self.yellow(text) = "\e[33m#{text}\e[0m"
  def self.blue(text) = "\e[34m#{text}\e[0m"
  def self.cyan(text) = "\e[36m#{text}\e[0m"
  def self.bold(text) = "\e[1m#{text}\e[0m"
end

class GeneratorTester
  def run(generator_name = 'all')
    puts Colors.bold("\n=== World Building Generator Tests ===\n")

    case generator_name.to_s.downcase
    when 'seeds', 'seed'
      test_seeds
    when 'name', 'names'
      test_names
    when 'item', 'items'
      test_items
    when 'npc', 'npcs'
      test_npcs
    when 'room', 'rooms'
      test_rooms
    when 'place', 'places'
      test_places
    when 'city'
      test_city_basics
    when 'village'
      generate_village
    when 'all'
      test_all
    else
      puts Colors.red("Unknown generator: #{generator_name}")
      puts "Available: seeds, name, item, npc, room, place, city, village, all"
    end
  end

  def test_all
    test_seeds
    test_names
    test_items(count: 2)
    test_npcs(count: 2)
    test_rooms(count: 2)
    test_places(count: 1)
    test_city_basics
    puts Colors.green("\n✓ All basic tests passed!")
  end

  # === Test SeedTermService ===
  def test_seeds
    puts Colors.bold("\n--- Testing SeedTermService ---")

    if SeedTermService.seeded?
      puts Colors.green("✓ Seed term tables are populated")
    else
      puts Colors.red("✗ Seed term tables are NOT populated!")
      puts "  Run: bundle exec ruby scripts/setup/seed_terms.rb"
      return
    end

    # Test each category
    %i[item npc room place city].each do |category|
      terms = SeedTermService.for_generation(category, count: 5)
      if terms.any?
        puts Colors.green("  ✓ #{category}: #{terms.join(', ')}")
      else
        puts Colors.red("  ✗ #{category}: no terms returned")
      end
    end

    # Show table info
    puts "\n  Available tables:"
    SeedTermService.table_info.each do |info|
      puts "    #{info[:name]}: #{info[:count]} entries"
    end
  end

  # === Test NameGeneratorService ===
  def test_names
    puts Colors.bold("\n--- Testing NameGeneratorService ---")

    # Character names
    puts "  Character names:"
    5.times do
      opts = NameGeneratorService.character_options(count: 1, gender: :any, setting: :fantasy)
      if opts.any?
        name = opts.first
        full = name.respond_to?(:full_name) ? name.full_name : "#{name.forename} #{name.surname}"
        puts Colors.cyan("    #{full}")
      end
    end

    # Shop names
    puts "\n  Shop names (taverns):"
    opts = NameGeneratorService.shop_options(count: 5, shop_type: :tavern, setting: :fantasy)
    opts.each do |shop|
      puts Colors.cyan("    #{shop.name}")
    end

    # Street names
    puts "\n  Street names:"
    opts = NameGeneratorService.street_options(count: 5, setting: :fantasy)
    opts.each do |street|
      puts Colors.cyan("    #{street.name}")
    end

    # City names
    puts "\n  City names:"
    opts = NameGeneratorService.city_options(count: 5, setting: :fantasy)
    opts.each do |city|
      puts Colors.cyan("    #{city.name}")
    end
  end

  # === Test ItemGeneratorService ===
  def test_items(count: 5)
    puts Colors.bold("\n--- Testing ItemGeneratorService ---")

    categories = %i[clothing jewelry weapon consumable furniture]

    categories.each do |category|
      puts "\n  #{category.to_s.capitalize}:"

      count.times do |i|
        result = Generators::ItemGeneratorService.generate(
          category: category,
          setting: :fantasy,
          generate_image: false
        )

        if result[:success]
          puts Colors.green("    [#{i + 1}] #{result[:name]}")
          puts "        #{result[:description]&.slice(0, 120)}..."
          puts Colors.blue("        Seeds used: #{result[:seed_terms]&.join(', ')}")
        else
          puts Colors.red("    [#{i + 1}] Failed: #{result[:errors]&.join(', ')}")
        end
      end
    end
  end

  # === Test NPCGeneratorService ===
  def test_npcs(count: 3)
    puts Colors.bold("\n--- Testing NPCGeneratorService ---")

    roles = %w[shopkeeper blacksmith innkeeper guard scholar priest]

    # Create a test location
    location = get_or_create_test_location

    roles.first(count).each do |role|
      puts "\n  Role: #{role}"

      result = Generators::NPCGeneratorService.generate(
        location: location,
        role: role,
        setting: :fantasy,
        generate_portrait: false,
        generate_schedule: true
      )

      if result[:success]
        puts Colors.green("    Name: #{result.dig(:name, :full_name)}")
        puts "    Appearance: #{result[:appearance]&.slice(0, 150)}..."
        puts "    Personality: #{result[:personality]&.slice(0, 100)}..."
        if result[:schedule]
          puts "    Schedule: #{result[:schedule].length} time slots"
        end
        puts Colors.blue("    Seeds: #{result[:seed_terms]&.join(', ')}")
      else
        puts Colors.red("    Failed: #{result[:errors]&.join(', ')}")
      end
    end
  end

  # === Test RoomGeneratorService ===
  def test_rooms(count: 3)
    puts Colors.bold("\n--- Testing RoomGeneratorService ---")

    room_types = %w[tavern_common bedroom forge temple_sanctuary street market]

    location = get_or_create_test_location

    room_types.first(count).each do |room_type|
      puts "\n  Room type: #{room_type}"

      result = Generators::RoomGeneratorService.generate(
        parent: location,
        room_type: room_type,
        setting: :fantasy,
        generate_background: false
      )

      if result[:success] || result[:description]
        puts Colors.green("    Name: #{result[:name]}")
        puts "    Description: #{result[:description]&.slice(0, 200)}..."
        puts Colors.blue("    Seeds: #{result[:seed_terms]&.join(', ')}")
      else
        puts Colors.red("    Failed: #{result[:errors]&.join(', ')}")
      end
    end
  end

  # === Test PlaceGeneratorService ===
  def test_places(count: 2)
    puts Colors.bold("\n--- Testing PlaceGeneratorService ---")

    place_types = %i[tavern blacksmith apothecary temple]

    location = get_or_create_test_location

    place_types.first(count).each do |place_type|
      puts "\n  Place type: #{place_type}"

      result = Generators::PlaceGeneratorService.generate(
        location: location,
        place_type: place_type,
        setting: :fantasy,
        generate_rooms: true,
        create_building: false,  # Don't create DB records for test
        generate_npcs: false,
        generate_inventory: place_type == :blacksmith
      )

      if result[:success]
        puts Colors.green("    Name: #{result[:name]}")
        puts "    Layout: #{result[:layout]&.length || 0} rooms"
        result[:layout]&.each do |room|
          puts "      - #{room[:room_type]} (floor #{room[:floor]})"
          if result[:room_descriptions] && result[:room_descriptions][room[:room_type]]
            desc = result[:room_descriptions][room[:room_type]]
            puts "        #{desc.slice(0, 80)}..." if desc
          end
        end
        if result[:inventory]&.any?
          puts "    Inventory: #{result[:inventory].length} items"
          result[:inventory].first(3).each do |item|
            puts "      - #{item[:name]}"
          end
        end
        puts Colors.blue("    Seeds: #{result[:seed_terms]&.join(', ')}")
      else
        puts Colors.red("    Failed: #{result[:errors]&.join(', ')}")
      end
    end
  end

  # === Test CityGeneratorService (basics only) ===
  def test_city_basics
    puts Colors.bold("\n--- Testing CityGeneratorService (names & planning) ---")

    # Generate city name
    puts "\n  City name generation:"
    3.times do
      result = Generators::CityGeneratorService.generate_name(setting: :fantasy)
      if result[:success]
        puts Colors.green("    #{result[:name]}")
        puts "      Alternatives: #{result[:alternatives]&.join(', ')}"
        puts Colors.blue("      Reasoning: #{result[:reasoning]}")
      else
        puts Colors.red("    Failed: #{result[:error]}")
      end
    end

    # Generate street names
    puts "\n  Street name generation:"
    result = Generators::CityGeneratorService.generate_street_names(count: 5, setting: :fantasy)
    if result[:names]&.any?
      result[:names].each { |name| puts Colors.green("    #{name}") }
    else
      puts Colors.red("    Failed: #{result[:error]}")
    end

    # Plan places for a village
    puts "\n  Place planning (village):"
    plan = Generators::CityGeneratorService.plan_places(size: :village, setting: :fantasy)
    puts "    Total places planned: #{plan.length}"
    plan.group_by { |p| p[:place_type] }.each do |type, places|
      puts "      #{type}: #{places.length}"
    end
  end

  # === Generate Full Village ===
  def generate_village
    puts Colors.bold("\n=== Generating Full Fantasy Village ===")
    puts "This will create actual database records...\n"

    # Check if we have seed terms
    unless SeedTermService.seeded?
      puts Colors.red("Error: Seed terms not populated!")
      puts "Run: bundle exec ruby scripts/setup/seed_terms.rb"
      return
    end

    location = get_or_create_test_location

    puts Colors.yellow("\nStarting village generation...")
    start_time = Time.now

    result = Generators::CityGeneratorService.generate(
      location: location,
      setting: :fantasy,
      size: :village,
      generate_places: true,
      generate_place_rooms: true,
      create_buildings: true,  # Actually create Room records
      generate_npcs: true
    )

    elapsed = Time.now - start_time

    if result[:success]
      puts Colors.green("\n✓ Village generated successfully!")
      puts "  City name: #{result[:city_name]}"
      puts "  Streets: #{result[:streets]}"
      puts "  Intersections: #{result[:intersections]}"
      puts "  Places generated: #{result[:places]&.length || 0}"

      # List all places
      result[:places]&.each do |place|
        building_info = place[:building_id] ? " (Building ##{place[:building_id]}, #{place[:room_ids]&.length || 0} rooms)" : ""
        puts Colors.cyan("    - #{place[:name]} (#{place[:type]})#{building_info}")
      end

      puts "\n  Seed terms: #{result[:seed_terms]&.join(', ')}"
      puts Colors.blue("  Generation time: #{elapsed.round(1)}s")

      # Summary of created records
      room_count = Room.where(location_id: location.id).count
      puts "\n  Database records created:"
      puts "    Rooms: #{room_count}"
    else
      puts Colors.red("\n✗ Village generation failed!")
      puts "  Errors:"
      result[:errors]&.each { |e| puts Colors.red("    - #{e}") }
    end
  end

  private

  def get_or_create_test_location
    # Find or create a test location
    area = Area.first || Area.create(
      name: 'Test Region',
      area_type: 'world'
    )

    Location.find(name: 'Test Village') || Location.create(
      area_id: area.id,
      name: 'Test Village',
      location_type: 'building',
      longitude: 0.0,
      latitude: 0.0,
      time_zone: 'UTC'
    )
  end
end

# Run the tester
generator = ARGV[0] || 'all'
GeneratorTester.new.run(generator)
