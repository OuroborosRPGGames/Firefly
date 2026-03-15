# frozen_string_literal: true

# Test the CombatProseEnhancementService directly

require_relative '../app'

puts "=== Combat Prose Enhancement Test ==="
puts ""

# Check if enhancement is available and enabled
service = CombatProseEnhancementService.new
puts "Service available: #{service.available?}"
puts "Setting enabled: #{CombatProseEnhancementService.enabled?}"
puts ""

# Test paragraphs (simulated combat narrative)
test_paragraphs = [
  "Alpha attacks Beta, throwing three punches. Beta defends desperately, but Alpha lands two hits, inflicting moderate bruises.",
  "Beta retreats toward the door while Alpha presses the attack. Alpha swings with his knife, cutting Beta across the arm.",
  "Gamma fires twice with her pistol at Delta, missing both shots. Delta takes cover behind the table."
]

puts "=== Original Paragraphs ==="
test_paragraphs.each_with_index do |p, i|
  puts "#{i + 1}. #{p}"
end
puts ""

if service.available? && CombatProseEnhancementService.enabled?
  puts "=== Enhancing paragraphs... ==="
  start_time = Time.now
  enhanced = service.enhance_paragraphs(test_paragraphs)
  elapsed = Time.now - start_time

  puts "Enhancement completed in #{(elapsed * 1000).round}ms"
  puts ""
  puts "=== Enhanced Paragraphs ==="
  enhanced.each_with_index do |p, i|
    puts "#{i + 1}. #{p}"
    puts ""
  end
else
  puts "Enhancement not available or not enabled"
  puts "  - Available: #{service.available?}"
  puts "  - Enabled: #{CombatProseEnhancementService.enabled?}"
end
