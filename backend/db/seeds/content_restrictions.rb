# frozen_string_literal: true

# Seeds for the Content Consent System
# Creates default content restriction types that players can consent to

# Require the app to load models
require_relative '../../app'

puts "Seeding content restrictions..."

# Find or create a default universe
universe = Universe.first || Universe.create(name: 'Default Universe', description: 'Default game universe')
puts "Using universe: #{universe.name}"

# === CONTENT RESTRICTIONS ===

violence = ContentRestriction.first(code: 'VIOLENCE') || ContentRestriction.create(
  universe_id: universe.id,
  code: 'VIOLENCE',
  name: 'Violence/Gore',
  description: 'Graphic descriptions of violence, blood, and gore. Includes detailed combat injuries, torture, and body horror.',
  severity: 'moderate',
  requires_mutual_consent: true,
  is_active: true
)
puts "  Created/found content restriction: #{violence.name} (#{violence.code})"

mature = ContentRestriction.first(code: 'MATURE') || ContentRestriction.create(
  universe_id: universe.id,
  code: 'MATURE',
  name: 'Mature Themes',
  description: 'Adult situations, romantic content, and mature subject matter. May include suggestive content and adult relationships.',
  severity: 'explicit',
  requires_mutual_consent: true,
  is_active: true
)
puts "  Created/found content restriction: #{mature.name} (#{mature.code})"

dark = ContentRestriction.first(code: 'DARK') || ContentRestriction.create(
  universe_id: universe.id,
  code: 'DARK',
  name: 'Dark Themes',
  description: 'Heavy emotional content including trauma, abuse, mental illness, death of children, and other emotionally difficult topics.',
  severity: 'moderate',
  requires_mutual_consent: true,
  is_active: true
)
puts "  Created/found content restriction: #{dark.name} (#{dark.code})"

horror = ContentRestriction.first(code: 'HORROR') || ContentRestriction.create(
  universe_id: universe.id,
  code: 'HORROR',
  name: 'Horror Elements',
  description: 'Psychological horror, jump scares, disturbing imagery, and fear-inducing content.',
  severity: 'moderate',
  requires_mutual_consent: true,
  is_active: true
)
puts "  Created/found content restriction: #{horror.name} (#{horror.code})"

substance = ContentRestriction.first(code: 'SUBSTANCE') || ContentRestriction.create(
  universe_id: universe.id,
  code: 'SUBSTANCE',
  name: 'Substance Use',
  description: 'Depictions of drug or alcohol use, addiction, and related themes.',
  severity: 'mild',
  requires_mutual_consent: false,
  is_active: true
)
puts "  Created/found content restriction: #{substance.name} (#{substance.code})"

puts "\nContent restrictions seeded!"
puts "Total content restrictions: #{ContentRestriction.count}"
