# frozen_string_literal: true

# Pattern Import Script
# Imports patterns from JSON files into Firefly database.
# This script is idempotent - safe to run multiple times.
#
# Must be run AFTER migrations are applied.
#
# Can be run standalone or via full_setup.rb

require 'bundler/setup'
require 'dotenv/load'
require 'sequel'
require 'json'

# Connect to database if not already connected
unless defined?(DB)
  DATABASE_URL = ENV.fetch('DATABASE_URL', 'postgres://prom_user:prom_password@localhost/firefly')
  DB = Sequel.connect(DATABASE_URL)
  DB.extension :pg_json
end

require_relative 'helpers'
include SetupHelpers

DATA_DIR = File.expand_path('../../data/patterns', __dir__)

log 'Importing patterns from JSON files...'

# Check if data files exist
unless File.exist?(DATA_DIR)
  log "ERROR: Data directory not found: #{DATA_DIR}"
  log "Pattern data files are missing. See data/patterns/ for expected format."
  exit 1
end

# Load JSON files
def load_json(filename)
  filepath = File.join(DATA_DIR, filename)
  unless File.exist?(filepath)
    log "WARNING: File not found: #{filename}, skipping."
    return []
  end
  JSON.parse(File.read(filepath), symbolize_names: true)
end

DB.transaction do
  # ============================================
  # IMPORT TYPE TABLES → UNIFIED_OBJECT_TYPES
  # ============================================

  log 'Importing type tables into unified_object_types...'

  type_id_map = {}

  # === CTYPES (Clothing Types) ===
  ctypes = load_json('ctypes.json')
  ctypes_count = 0
  ctypes.each do |row|
    # Map bone fields to covered positions
    bone_fields = %i[bone btwo bthree bfour bfive bsix bseven beight bnine bten
                     beleven btwelve bthirteen bfourteen bfifteen bsixteen
                     bseventeen beighteen bnineteen btwenty]
    covered = bone_fields.map { |f| row[f] }.compact.reject { |v| v.to_s.empty? }

    # Map zone fields to zippable positions
    zone_fields = %i[zone ztwo zthree zfour zfive zsix zseven zeight znine zten]
    zones = zone_fields.map { |f| row[f] }.compact.reject { |v| v.to_s.empty? }

    attrs = {
      name: row[:cname],
      category: row[:ctype],
      subcategory: row[:csubtype],
      layer: row[:layer],
      sheer: row[:sheer] || false,
      dorder: row[:dorder] || 0
    }

    # Add covered positions
    covered.each_with_index do |pos, i|
      attrs[:"covered_position_#{i + 1}"] = pos if i < 20
    end

    # Add zones
    zones.each_with_index do |zone, i|
      attrs[:"zone_#{i + 1}"] = zone if i < 10
    end

    # Insert or find existing (by name, which is unique)
    existing = DB[:unified_object_types].where(name: row[:cname]).first
    if existing
      type_id_map[[:ctypes, row[:id]]] = existing[:id]
    else
      new_id = DB[:unified_object_types].insert(attrs.merge(created_at: Time.now, updated_at: Time.now))
      type_id_map[[:ctypes, row[:id]]] = new_id
      ctypes_count += 1
    end
  end
  log "  Imported #{ctypes_count} new ctypes (#{ctypes.count} total)"

  # === JTYPES (Jewelry Types) ===
  jtypes = load_json('jtypes.json')
  jtypes_count = 0
  jtypes.each do |row|
    bone_fields = %i[bone btwo]
    covered = bone_fields.map { |f| row[f] }.compact.reject { |v| v.to_s.empty? }

    attrs = {
      name: row[:jname],
      category: row[:jtype],
      layer: row[:layer],
      dorder: row[:dorder] || 0
    }

    covered.each_with_index do |pos, i|
      attrs[:"covered_position_#{i + 1}"] = pos if i < 20
    end

    existing = DB[:unified_object_types].where(name: row[:jname]).first
    if existing
      type_id_map[[:jtypes, row[:id]]] = existing[:id]
    else
      new_id = DB[:unified_object_types].insert(attrs.merge(created_at: Time.now, updated_at: Time.now))
      type_id_map[[:jtypes, row[:id]]] = new_id
      jtypes_count += 1
    end
  end
  log "  Imported #{jtypes_count} new jtypes (#{jtypes.count} total)"

  # === WTYPES (Weapon Types) ===
  wtypes = load_json('wtypes.json')
  wtypes_count = 0
  wtypes.each do |row|
    attrs = {
      name: row[:wname],
      category: row[:wtype],
      dorder: 0
    }

    existing = DB[:unified_object_types].where(name: row[:wname]).first
    if existing
      type_id_map[[:wtypes, row[:id]]] = existing[:id]
    else
      new_id = DB[:unified_object_types].insert(attrs.merge(created_at: Time.now, updated_at: Time.now))
      type_id_map[[:wtypes, row[:id]]] = new_id
      wtypes_count += 1
    end
  end
  log "  Imported #{wtypes_count} new wtypes (#{wtypes.count} total)"

  log ''

  # ============================================
  # IMPORT PATTERN TABLES
  # ============================================

  log 'Importing pattern tables...'

  # === CPATTERNS (Clothing Patterns) ===
  cpatterns = load_json('cpatterns.json')
  cpatterns_count = 0
  cpatterns.each do |row|
    # Find the unified type for this pattern
    unified_type_id = type_id_map[[:ctypes, row[:type]]]

    attrs = {
      description: row[:description],
      unified_object_type_id: unified_type_id,
      sheer: row[:sheer] || false,
      container: row[:container] || false,
      price: row[:price] || 0,
      created_by: row[:created_by],
      magic_type: row[:magic_type],
      min_year: row[:min_year],
      max_year: row[:max_year],
      desc_type: row[:desc_type],
      desc_desc: row[:desc_desc],
      arev_one: row[:arev_one],
      arev_two: row[:arev_two],
      acon_one: row[:acon_one],
      acon_two: row[:acon_two]
    }

    # Check for existing by description (patterns are unique by description)
    existing = DB[:patterns].where(description: row[:description]).first
    unless existing
      DB[:patterns].insert(attrs.merge(created_at: Time.now, updated_at: Time.now))
      cpatterns_count += 1
    end
  end
  log "  Imported #{cpatterns_count} new cpatterns (#{cpatterns.count} total)"

  # === JPATTERNS (Jewelry Patterns) ===
  jpatterns = load_json('jpatterns.json')
  jpatterns_count = 0
  jpatterns.each do |row|
    unified_type_id = type_id_map[[:jtypes, row[:jtypes_id]]]

    attrs = {
      description: row[:description],
      unified_object_type_id: unified_type_id,
      price: row[:price] || 0,
      created_by: row[:created_by],
      magic_type: row[:magic_type],
      min_year: row[:min_year],
      max_year: row[:max_year],
      desc_type: row[:desc_type],
      desc_desc: row[:desc_desc],
      metal: row[:metal],
      stone: row[:stone]
    }

    existing = DB[:patterns].where(description: row[:description]).first
    unless existing
      DB[:patterns].insert(attrs.merge(created_at: Time.now, updated_at: Time.now))
      jpatterns_count += 1
    end
  end
  log "  Imported #{jpatterns_count} new jpatterns (#{jpatterns.count} total)"

  # === WPATTERNS (Weapon Patterns) ===
  wpatterns = load_json('wpatterns.json')
  wpatterns_count = 0
  wpatterns.each do |row|
    unified_type_id = type_id_map[[:wtypes, row[:wtypes_id]]]

    attrs = {
      description: row[:description],
      unified_object_type_id: unified_type_id,
      price: row[:price] || 0,
      created_by: row[:created_by],
      magic_type: row[:magic_type],
      min_year: row[:min_year],
      max_year: row[:max_year],
      desc_type: row[:desc_type],
      desc_desc: row[:desc_desc],
      handle_desc: row[:handle_desc]
    }

    existing = DB[:patterns].where(description: row[:description]).first
    unless existing
      DB[:patterns].insert(attrs.merge(created_at: Time.now, updated_at: Time.now))
      wpatterns_count += 1
    end
  end
  log "  Imported #{wpatterns_count} new wpatterns (#{wpatterns.count} total)"

  # === TPATTERNS (Tattoo/Consumable Patterns) ===
  # First, create a generic "Consumable" type for tpatterns (since they don't have a type table)
  consumable_type = DB[:unified_object_types].where(name: 'Consumable').first
  unless consumable_type
    consumable_type_id = DB[:unified_object_types].insert(
      name: 'Consumable',
      category: 'consumable',
      dorder: 0,
      created_at: Time.now,
      updated_at: Time.now
    )
    log '  Created generic Consumable type for tpatterns'
  else
    consumable_type_id = consumable_type[:id]
  end

  tpatterns = load_json('tpatterns.json')
  tpatterns_count = 0
  tpatterns.each do |row|
    # Determine consume_type based on subtype (convert to string first)
    subtype_str = row[:subtype].to_s.downcase
    consume_type = case subtype_str
                   when 'food' then 'food'
                   when 'drink', 'beverage' then 'drink'
                   when 'smoke', 'cigarette', 'cigar' then 'smoke'
                   else nil
                   end

    attrs = {
      description: row[:description],
      unified_object_type_id: consumable_type_id, # Link to generic consumable type
      container: row[:container] || false,
      price: row[:price] || 0,
      created_by: row[:created_by],
      magic_type: row[:magic_type],
      min_year: row[:min_year],
      max_year: row[:max_year],
      desc_type: row[:desc_type],
      desc_desc: row[:desc_desc],
      consume_type: consume_type,
      consume_time: row[:consume_time] || 10,
      taste: row[:taste],
      effect: row[:effect]
    }

    existing = DB[:patterns].where(description: row[:description]).first
    unless existing
      DB[:patterns].insert(attrs.merge(created_at: Time.now, updated_at: Time.now))
      tpatterns_count += 1
    end
  end
  log "  Imported #{tpatterns_count} new tpatterns (#{tpatterns.count} total)"

  # ============================================
  # SUMMARY
  # ============================================

  log ''
  log 'Pattern import complete!'
  log "  - Unified Object Types: #{DB[:unified_object_types].count}"
  log "  - Patterns: #{DB[:patterns].count}"
end
