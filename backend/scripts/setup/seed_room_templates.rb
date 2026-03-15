#!/usr/bin/env ruby
# frozen_string_literal: true

# Seed default room templates for vehicle interiors, taxis, trains, etc.
#
# Usage:
#   bundle exec ruby scripts/setup/seed_room_templates.rb
#
# This creates standard templates that can be used by TemporaryRoomPoolService
# to instantiate temporary rooms for vehicles and world travel.

require_relative '../../config/application'

puts 'Seeding room templates...'

# Define all templates to create
ROOM_TEMPLATES = [
  # Vehicle Interiors - Land
  {
    name: 'Sedan Interior',
    template_type: 'vehicle_interior',
    category: 'sedan',
    short_description: 'Inside a comfortable sedan',
    long_description: 'The interior is clean with leather seats. A dashboard with various controls sits in front. Through the windows, you can see the world passing by.',
    width: 6.0,
    length: 8.0,
    height: 4.0,
    passenger_capacity: 4,
    default_places: [
      { 'name' => 'Driver Seat', 'description' => 'Behind the wheel', 'capacity' => 1, 'x' => 1.5, 'y' => 6.0 },
      { 'name' => 'Passenger Seat', 'description' => 'Beside the driver', 'capacity' => 1, 'x' => 4.5, 'y' => 6.0 },
      { 'name' => 'Back Seat', 'description' => 'Spacious back seat', 'capacity' => 2, 'x' => 3.0, 'y' => 2.0 }
    ]
  },
  {
    name: 'SUV Interior',
    template_type: 'vehicle_interior',
    category: 'suv',
    short_description: 'Inside a spacious SUV',
    long_description: 'A large vehicle with plenty of room. Three rows of seats provide ample space for passengers and cargo.',
    width: 8.0,
    length: 12.0,
    height: 5.0,
    passenger_capacity: 7,
    default_places: [
      { 'name' => 'Driver Seat', 'description' => 'Behind the wheel', 'capacity' => 1, 'x' => 2.0, 'y' => 10.0 },
      { 'name' => 'Passenger Seat', 'description' => 'Beside the driver', 'capacity' => 1, 'x' => 6.0, 'y' => 10.0 },
      { 'name' => 'Middle Row', 'description' => 'Second row bench', 'capacity' => 3, 'x' => 4.0, 'y' => 6.0 },
      { 'name' => 'Back Row', 'description' => 'Third row seating', 'capacity' => 2, 'x' => 4.0, 'y' => 2.0 }
    ]
  },
  {
    name: 'Bus Interior',
    template_type: 'vehicle_interior',
    category: 'bus',
    short_description: 'Inside a public bus',
    long_description: 'Rows of seats line both sides of the aisle. Handrails and straps hang from the ceiling for standing passengers.',
    width: 10.0,
    length: 30.0,
    height: 7.0,
    passenger_capacity: 30,
    default_places: [
      { 'name' => 'Front Row Left', 'description' => 'Priority seating near front', 'capacity' => 2, 'x' => 2.0, 'y' => 26.0 },
      { 'name' => 'Front Row Right', 'description' => 'Priority seating near front', 'capacity' => 2, 'x' => 8.0, 'y' => 26.0 },
      { 'name' => 'Middle Section', 'description' => 'General seating', 'capacity' => 12, 'x' => 5.0, 'y' => 15.0 },
      { 'name' => 'Back Section', 'description' => 'Bench seating in rear', 'capacity' => 6, 'x' => 5.0, 'y' => 4.0 },
      { 'name' => 'Standing Area', 'description' => 'Standing room in aisle', 'capacity' => 8, 'x' => 5.0, 'y' => 10.0 }
    ]
  },

  # Taxi Interior
  {
    name: 'Taxi Interior',
    template_type: 'taxi',
    category: 'taxi',
    short_description: 'Inside a taxi',
    long_description: 'A standard taxi interior. A meter runs on the dashboard, and a partition separates you from the driver.',
    width: 6.0,
    length: 8.0,
    height: 4.0,
    passenger_capacity: 4,
    default_places: [
      { 'name' => 'Back Seat', 'description' => 'Passenger seating behind partition', 'capacity' => 3, 'x' => 3.0, 'y' => 2.0 }
    ]
  },

  # Train Compartments
  {
    name: 'Train Compartment',
    template_type: 'train_compartment',
    category: 'train',
    short_description: 'A train compartment',
    long_description: 'A cozy train compartment with facing bench seats. A window shows the scenery rushing past outside.',
    width: 8.0,
    length: 10.0,
    height: 8.0,
    passenger_capacity: 6,
    default_places: [
      { 'name' => 'Window Seat (Forward)', 'description' => 'Facing forward by the window', 'capacity' => 2, 'x' => 2.0, 'y' => 8.0 },
      { 'name' => 'Window Seat (Backward)', 'description' => 'Facing backward by the window', 'capacity' => 2, 'x' => 2.0, 'y' => 2.0 },
      { 'name' => 'Aisle Seat (Forward)', 'description' => 'Facing forward by the aisle', 'capacity' => 1, 'x' => 6.0, 'y' => 8.0 },
      { 'name' => 'Aisle Seat (Backward)', 'description' => 'Facing backward by the aisle', 'capacity' => 1, 'x' => 6.0, 'y' => 2.0 }
    ]
  },
  {
    name: 'Subway Car',
    template_type: 'train_compartment',
    category: 'subway',
    short_description: 'Inside a subway car',
    long_description: 'A subway car with bench seats along the walls. Handrails and poles provide support for standing passengers.',
    width: 10.0,
    length: 50.0,
    height: 8.0,
    passenger_capacity: 50,
    default_places: [
      { 'name' => 'Left Bench', 'description' => 'Bench seating along left wall', 'capacity' => 15, 'x' => 2.0, 'y' => 25.0 },
      { 'name' => 'Right Bench', 'description' => 'Bench seating along right wall', 'capacity' => 15, 'x' => 8.0, 'y' => 25.0 },
      { 'name' => 'Standing Area', 'description' => 'Standing room in center', 'capacity' => 20, 'x' => 5.0, 'y' => 25.0 }
    ]
  },

  # Historical Vehicles
  {
    name: 'Hansom Cab Interior',
    template_type: 'vehicle_interior',
    category: 'hansom',
    short_description: 'Inside a hansom cab',
    long_description: 'The small enclosed cab has a leather bench seat. The driver sits outside above and behind. Through the small window you can see the street.',
    width: 4.0,
    length: 5.0,
    height: 5.0,
    passenger_capacity: 2,
    default_places: [
      { 'name' => 'Bench Seat', 'description' => 'The upholstered bench', 'capacity' => 2, 'x' => 2.0, 'y' => 2.5 }
    ]
  },
  {
    name: 'Carriage Interior',
    template_type: 'vehicle_interior',
    category: 'carriage',
    short_description: 'Inside a carriage',
    long_description: 'An elegant enclosed carriage with plush seating. Curtains frame the windows, and the carriage sways gently as it moves.',
    width: 6.0,
    length: 8.0,
    height: 6.0,
    passenger_capacity: 4,
    default_places: [
      { 'name' => 'Forward Seat', 'description' => 'Facing forward', 'capacity' => 2, 'x' => 3.0, 'y' => 6.0 },
      { 'name' => 'Backward Seat', 'description' => 'Facing backward', 'capacity' => 2, 'x' => 3.0, 'y' => 2.0 }
    ]
  },
  {
    name: 'Wagon Interior',
    template_type: 'vehicle_interior',
    category: 'wagon',
    short_description: 'Inside a covered wagon',
    long_description: 'A simple covered wagon. Canvas walls provide shelter from the elements, though the wooden floor is hard and uncomfortable.',
    width: 8.0,
    length: 12.0,
    height: 5.0,
    passenger_capacity: 8,
    default_places: [
      { 'name' => 'Wagon Bed', 'description' => 'The open cargo area', 'capacity' => 8, 'x' => 4.0, 'y' => 6.0 }
    ]
  },

  # Air Transport
  {
    name: 'Shuttle Interior',
    template_type: 'shuttle',
    category: 'shuttle',
    short_description: 'Inside a passenger shuttle',
    long_description: 'A sleek passenger shuttle with rows of comfortable seats. Small viewports show the sky or stars outside.',
    width: 12.0,
    length: 20.0,
    height: 8.0,
    passenger_capacity: 16,
    default_places: [
      { 'name' => 'Row A', 'description' => 'First row of seats', 'capacity' => 4, 'x' => 6.0, 'y' => 18.0 },
      { 'name' => 'Row B', 'description' => 'Second row of seats', 'capacity' => 4, 'x' => 6.0, 'y' => 14.0 },
      { 'name' => 'Row C', 'description' => 'Third row of seats', 'capacity' => 4, 'x' => 6.0, 'y' => 10.0 },
      { 'name' => 'Row D', 'description' => 'Fourth row of seats', 'capacity' => 4, 'x' => 6.0, 'y' => 6.0 }
    ]
  },
  {
    name: 'Airship Gondola',
    template_type: 'shuttle',
    category: 'airship',
    short_description: 'Inside an airship gondola',
    long_description: 'The gondola of an airship. Large windows provide panoramic views of the land far below. Comfortable seating and polished wood trim create an elegant atmosphere.',
    width: 15.0,
    length: 25.0,
    height: 10.0,
    passenger_capacity: 20,
    default_places: [
      { 'name' => 'Observation Area', 'description' => 'Standing area near windows', 'capacity' => 8, 'x' => 7.5, 'y' => 20.0 },
      { 'name' => 'Lounge Seating', 'description' => 'Comfortable chairs', 'capacity' => 8, 'x' => 7.5, 'y' => 10.0 },
      { 'name' => 'Bar Area', 'description' => 'Near the refreshment bar', 'capacity' => 4, 'x' => 7.5, 'y' => 4.0 }
    ]
  },

  # Water Transport
  {
    name: 'Ferry Deck',
    template_type: 'boat_cabin',
    category: 'ferry',
    short_description: 'On a ferry deck',
    long_description: 'The open deck of a passenger ferry. Benches line the railings, and the water stretches out in all directions.',
    width: 30.0,
    length: 50.0,
    height: 10.0,
    passenger_capacity: 50,
    default_places: [
      { 'name' => 'Port Railing', 'description' => 'Benches along the left side', 'capacity' => 15, 'x' => 3.0, 'y' => 25.0 },
      { 'name' => 'Starboard Railing', 'description' => 'Benches along the right side', 'capacity' => 15, 'x' => 27.0, 'y' => 25.0 },
      { 'name' => 'Center Deck', 'description' => 'Open deck space', 'capacity' => 20, 'x' => 15.0, 'y' => 25.0 }
    ]
  },
  {
    name: 'Rowboat',
    template_type: 'boat_cabin',
    category: 'rowboat',
    short_description: 'In a small rowboat',
    long_description: 'A simple wooden rowboat. The oars rest in their locks, and water laps gently against the hull.',
    width: 4.0,
    length: 10.0,
    height: 3.0,
    passenger_capacity: 4,
    default_places: [
      { 'name' => 'Rowing Position', 'description' => 'At the oars', 'capacity' => 1, 'x' => 2.0, 'y' => 5.0 },
      { 'name' => 'Bow', 'description' => 'Front of the boat', 'capacity' => 1, 'x' => 2.0, 'y' => 8.0 },
      { 'name' => 'Stern', 'description' => 'Back of the boat', 'capacity' => 2, 'x' => 2.0, 'y' => 2.0 }
    ]
  }
].freeze

# Create or update each template
created = 0
updated = 0

ROOM_TEMPLATES.each do |template_data|
  existing = RoomTemplate.first(name: template_data[:name], template_type: template_data[:template_type])

  if existing
    # Update existing template
    existing.update(
      category: template_data[:category],
      short_description: template_data[:short_description],
      long_description: template_data[:long_description],
      width: template_data[:width],
      length: template_data[:length],
      height: template_data[:height],
      passenger_capacity: template_data[:passenger_capacity],
      default_places: Sequel.pg_jsonb_wrap(template_data[:default_places]),
      active: true
    )
    updated += 1
    puts "  Updated: #{template_data[:name]}"
  else
    # Create new template
    RoomTemplate.create(
      name: template_data[:name],
      template_type: template_data[:template_type],
      category: template_data[:category],
      short_description: template_data[:short_description],
      long_description: template_data[:long_description],
      width: template_data[:width],
      length: template_data[:length],
      height: template_data[:height],
      passenger_capacity: template_data[:passenger_capacity],
      default_places: Sequel.pg_jsonb_wrap(template_data[:default_places]),
      active: true
    )
    created += 1
    puts "  Created: #{template_data[:name]}"
  end
end

puts
puts "Done! Created #{created} templates, updated #{updated} templates."
puts "Total room templates: #{RoomTemplate.count}"
