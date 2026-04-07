# frozen_string_literal: true

# Backfill zone_subtype for existing area zones based on their names.
# Usage: cd backend && bundle exec ruby scripts/backfill_zone_subtypes.rb

require_relative '../app'

zones = Zone.where(zone_type: 'area', zone_subtype: nil).all
updated = 0

zones.each do |zone|
  subtype = Zone.infer_subtype_from_name(zone.name)
  next unless subtype

  zone.update(zone_subtype: subtype)
  puts "#{zone.name} => #{subtype}"
  updated += 1
end

puts "\nDone. Updated #{updated}/#{zones.length} area zones."
