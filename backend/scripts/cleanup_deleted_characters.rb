#!/usr/bin/env ruby
# frozen_string_literal: true

# Cleanup Deleted Characters Script
# Run via: bundle exec ruby scripts/cleanup_deleted_characters.rb
#
# This script permanently deletes:
# 1. Characters that have been soft deleted for more than 30 days
# 2. Abandoned draft characters older than 24 hours
#
# Recommended: Run via cron daily
# Example crontab entry:
#   0 3 * * * cd /path/to/backend && bundle exec ruby scripts/cleanup_deleted_characters.rb >> log/cleanup.log 2>&1

require_relative '../config/environment'

DRAFT_RETENTION_HOURS = 24

puts "[#{Time.now}] Starting character cleanup..."

# ====================
# Cleanup Draft Characters
# ====================
puts "\n[#{Time.now}] Cleaning up abandoned draft characters..."

draft_cutoff = Time.now - (DRAFT_RETENTION_HOURS * 3600)
abandoned_drafts = Character.where(is_draft: true).where { created_at < draft_cutoff }.all

if abandoned_drafts.empty?
  puts "[#{Time.now}] No abandoned drafts to clean up."
else
  puts "[#{Time.now}] Found #{abandoned_drafts.count} abandoned draft(s) to delete."

  abandoned_drafts.each do |draft|
    begin
      puts "  Deleting draft: ID #{draft.id}, created at #{draft.created_at}"
      draft.delete
      puts "    Deleted successfully."
    rescue StandardError => e
      warn "    ERROR deleting draft #{draft.id}: #{e.message}"
    end
  end
end

# ====================
# Cleanup Soft-Deleted Characters
# ====================
puts "\n[#{Time.now}] Cleaning up expired soft-deleted characters..."

# Find all characters past the retention period
expired_characters = Character.expired_deleted.all

if expired_characters.empty?
  puts "[#{Time.now}] No expired characters to clean up."
  exit 0
end

puts "[#{Time.now}] Found #{expired_characters.count} character(s) to permanently delete."

deleted_count = 0
error_count = 0

expired_characters.each do |character|
  begin
    puts "  Deleting: #{character.full_name} (ID: #{character.id}, deleted at: #{character.deleted_at})"

    # Delete associated records first
    # Character instances
    CharacterInstance.where(character_id: character.id).delete

    # Character descriptions
    CharacterDefaultDescription.where(character_id: character.id).delete rescue nil

    # Character shapes
    CharacterShape.where(character_id: character.id).delete rescue nil

    # Character knowledge (both sides)
    CharacterKnowledge.where(knower_character_id: character.id).delete rescue nil
    CharacterKnowledge.where(known_character_id: character.id).delete rescue nil

    # NPC memories and goals
    NpcMemory.where(character_id: character.id).delete rescue nil
    NpcGoal.where(character_id: character.id).delete rescue nil

    # Bank accounts
    BankAccount.where(character_id: character.id).delete rescue nil

    # Keys
    Key.where(character_id: character.id).delete rescue nil

    # Saved locations
    SavedLocation.where(character_id: character.id).delete rescue nil

    # Group memberships
    GroupMember.where(character_id: character.id).delete rescue nil

    # Memos
    Memo.where(sender_character_id: character.id).delete rescue nil
    Memo.where(recipient_character_id: character.id).delete rescue nil

    # Finally, delete the character
    character.delete

    deleted_count += 1
    puts "    Deleted successfully."
  rescue => e
    error_count += 1
    warn "    ERROR deleting #{character.full_name}: #{e.message}"
  end
end

puts "[#{Time.now}] Cleanup complete. Deleted: #{deleted_count}, Errors: #{error_count}"
