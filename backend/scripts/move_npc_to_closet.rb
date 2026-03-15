# frozen_string_literal: true

require_relative '../app'

$stdout.sync = true
$stderr.sync = true

STDERR.puts "=== SCRIPT OUTPUT ==="

# Find an NPC to move to the closet
npc_chars = Character.where(npc: true).all
STDERR.puts "Found #{npc_chars.count} NPC characters"

npc = CharacterInstance.eager(:character).all.find { |ci| ci.character&.npc? }
if npc
  STDERR.puts "Moving NPC #{npc.character.full_name} (CI##{npc.id}) to Closet (room 182)"
  npc.update(room_id: 182)
  STDERR.puts "Done - NPC is now in room #{npc.room_id}"
else
  STDERR.puts "No NPC character instance found"
end

STDERR.puts "=== END SCRIPT ==="
