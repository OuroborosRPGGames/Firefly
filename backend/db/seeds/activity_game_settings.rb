# frozen_string_literal: true

# Activity System GameSettings for LLM-based rounds
# Run: bundle exec ruby db/seeds/activity_game_settings.rb

require_relative '../../config/application'

puts 'Creating Activity System GameSettings...'

# Free Roll (LLM-GM) settings
GameSetting.find_or_create(key: 'activity_free_roll_enabled') do |s|
  s.value = 'false'
  s.value_type = 'boolean'
  s.category = 'activity'
  s.description = 'Enable free roll rounds where LLM acts as GM'
end

GameSetting.find_or_create(key: 'activity_free_roll_model') do |s|
  s.value = 'claude-sonnet-4-6'
  s.value_type = 'string'
  s.category = 'activity'
  s.description = 'LLM model for free roll GM (Claude Sonnet recommended)'
end

# Persuade (LLM-NPC) settings
GameSetting.find_or_create(key: 'activity_persuade_enabled') do |s|
  s.value = 'false'
  s.value_type = 'boolean'
  s.category = 'activity'
  s.description = 'Enable persuade rounds where LLM plays NPC'
end

GameSetting.find_or_create(key: 'activity_persuade_model') do |s|
  s.value = 'deepseek/deepseek-v3.2'
  s.value_type = 'string'
  s.category = 'activity'
  s.description = 'LLM model for persuade NPCs (DeepSeek recommended)'
end

# Timeout settings
GameSetting.find_or_create(key: 'activity_reflex_timeout') do |s|
  s.value = '120'
  s.value_type = 'integer'
  s.category = 'activity'
  s.description = 'Timeout in seconds for reflex rounds (default 2 min)'
end

GameSetting.find_or_create(key: 'activity_standard_timeout') do |s|
  s.value = '480'
  s.value_type = 'integer'
  s.category = 'activity'
  s.description = 'Timeout in seconds for standard rounds (default 8 min)'
end

puts 'Activity System GameSettings created!'
puts ''
puts 'Settings created:'
puts '  activity_free_roll_enabled: false'
puts '  activity_free_roll_model: claude-sonnet-4-6'
puts '  activity_persuade_enabled: false'
puts '  activity_persuade_model: deepseek/deepseek-v3.2'
puts '  activity_reflex_timeout: 120'
puts '  activity_standard_timeout: 480'
puts ''
puts 'To enable LLM features, set the _enabled settings to true in admin.'
