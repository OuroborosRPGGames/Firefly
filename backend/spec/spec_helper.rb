# frozen_string_literal: true

require 'simplecov'
SimpleCov.command_name "rspec#{ENV['TEST_ENV_NUMBER']}" if ENV['TEST_ENV_NUMBER']
SimpleCov.start do
  # Set coverage directories
  coverage_dir 'coverage'

  # Track all app and lib files
  track_files '{app,lib,config,plugins}/**/*.rb'

  # Ignore certain paths
  add_filter '/spec/'
  add_filter '/db/migrations/'
  add_filter '/vendor/'

  # Group coverage by category
  add_group 'Commands', 'app/commands'
  add_group 'Models', 'app/models'
  add_group 'Services', 'app/services'
  add_group 'Helpers', 'app/helpers'
  add_group 'Plugins', 'plugins/'
  add_group 'Library', 'lib/'
  add_group 'Config', 'config/'

  # Minimum coverage threshold (CI will fail below this)
  # Current: 56%, Target: 80% (increase gradually as tests are added)
  minimum_coverage 55

  # Per-file minimum disabled until we improve test coverage
  # minimum_coverage_by_file 30

  # Enable branch coverage (Ruby 2.5+)
  enable_coverage :branch

  # Track coverage changes (warn but don't fail)
  # refuse_coverage_drop
end

ENV['RACK_ENV'] = 'test'
ENV['RAILS_ENV'] = 'test'

# Load .env.test BEFORE anything else (overload to ensure test values are used)
require 'dotenv'
Dotenv.overload('.env.test')

# Run test schema setup on the test database BEFORE loading app
require 'sequel'
require_relative '../db/test_migration'

# Parallel test DB routing (parallel_tests sets TEST_ENV_NUMBER for workers 2+)
worker_number = ENV['TEST_ENV_NUMBER']
if worker_number && !worker_number.empty?
  ENV['DATABASE_URL'] = ENV['DATABASE_URL'].sub(/firefly_test\d*$/, "firefly_test#{worker_number}")
end

# Parallel Redis isolation (worker 2→DB3, 3→DB4, 4→DB5; worker 1 stays on DB1)
if worker_number && !worker_number.empty?
  redis_db = worker_number.to_i + 1
  ENV['REDIS_URL'] = ENV.fetch('REDIS_URL', 'redis://localhost:6379/1').sub(%r{/\d+$}, "/#{redis_db}")
end

# Connect with pool settings to prevent pool exhaustion during full suite
test_db = Sequel.connect(
  ENV['DATABASE_URL'],
  max_connections: ENV.fetch('DB_POOL_SIZE', 50).to_i,
  pool_timeout: ENV.fetch('DB_POOL_TIMEOUT', 30).to_i
)
test_db.extension :pg_json

# Only run migration if database doesn't already have the expected tables
# This allows using a pre-populated test database from pg_dump
expected_tables = [:users, :characters, :rooms, :character_instances, :gradients]
tables_exist = expected_tables.all? { |t| test_db.table_exists?(t) }

unless tables_exist || ENV['SKIP_TEST_MIGRATION']
  TestMigration.run(test_db)
end

# Patch existing test databases with columns added after initial schema creation
if test_db.table_exists?(:npc_archetypes)
  unless test_db.schema(:npc_archetypes).any? { |col, _| col == :npc_attacks }
    test_db.alter_table(:npc_archetypes) do
      add_column :npc_attacks, :jsonb, default: Sequel.lit("'[]'::jsonb")
    end
  end
end

if test_db.table_exists?(:character_instances)
  unless test_db.schema(:character_instances).any? { |col, _| col == :combat_preferences }
    test_db.alter_table(:character_instances) do
      add_column :combat_preferences, :jsonb, default: Sequel.lit("'{}'::jsonb")
    end
  end
end

if test_db.table_exists?(:rooms)
  unless test_db.schema(:rooms).any? { |col, _| col == :battle_map_object_metadata }
    test_db.alter_table(:rooms) do
      add_column :battle_map_object_metadata, :jsonb, default: Sequel.lit("'{}'::jsonb")
      add_column :battle_map_object_map_url, String, size: 500
    end
  end
end

if test_db.table_exists?(:battle_map_templates)
  unless test_db.schema(:battle_map_templates).any? { |col, _| col == :ai_object_metadata }
    test_db.alter_table(:battle_map_templates) do
      add_column :ai_object_metadata, :jsonb, default: Sequel.lit("'{}'::jsonb")
      add_column :object_map_url, String, size: 500
    end
  end
end

# Now load the app (which will connect to DB)
# Define DB BEFORE loading app so app doesn't override it
DB = test_db

require_relative '../app'

# Refresh model schemas to pick up new columns from migrations
# This is needed because Sequel caches schema at class load time
# The db.schema call forces a fresh schema lookup from the database
[CharacterInstance, User, Fight, FightParticipant, Ability, ParticipantStatusEffect, Item, Room, RoomFeature, RoomTemplate, Vehicle, WorldJourney, Deck, Pet, Trigger, WorldMemory, WorldMemoryLocation, Outfit, CharacterDefaultDescription, CharacterDescription, CharacterDescriptionPosition, CharacterInstanceDescriptionPosition, PetAnimationQueue, MonsterMountState, LargeMonsterInstance, MonsterTemplate, MonsterSegmentTemplate, MonsterSegmentInstance, WorldGenerationJob, MediaLibrary, Clue, NpcClue, ClueShare, WorldHex, RoomHex, Activity, ActivityAction, ActivityInstance, ActivityLog, ActivityParticipant, ActivityProfile, ActivityRemoteObserver, ActivityRound, ActivityTask, WorldTerrainRaster, WorldRegion, NarrativeEntity, NarrativeEntityMemory, NarrativeRelationship, NarrativeThread, NarrativeThreadEntity, NarrativeThreadMemory, NarrativeExtractionLog, Place, Decoration, World, MediaPlaylist, MediaPlaylistItem, MediaSession, LLMRequest, LlmBatch, BattleMapTemplate, Ticket, AutohelperRequest, GrammarLanguage, NpcArchetype].each do |model|
  if model.respond_to?(:set_dataset)
    model.db.schema(model.table_name, reload: true)
    model.set_dataset(model.table_name)

    # Force regeneration of column accessor methods by re-defining for all columns
    # This is needed because set_dataset refreshes the column list but doesn't
    # create accessor methods for columns that were added after class definition
    # We unconditionally define accessors to ensure both getter AND setter exist
    # (the old check only verified the getter, missing cases where setter was absent)
    # Use send because def_column_accessor is private
    model.columns.each do |col|
      model.send(:def_column_accessor, col)
    end
  end
end

require 'rspec'
require 'rack/test'
require 'database_cleaner/sequel'
require 'factory_bot'
require 'capybara/rspec'
require 'capybara/cuprite'

# Configure Capybara for system specs
Capybara.register_driver(:cuprite) do |app|
  Capybara::Cuprite::Driver.new(
    app,
    window_size: [1280, 800],
    headless: ENV.fetch('HEADLESS', 'true') != 'false',  # Set HEADLESS=false to see browser
    process_timeout: 30,
    timeout: 10,
    browser_options: {
      'no-sandbox': true,           # Required for CI environments
      'disable-gpu': true,
      'disable-dev-shm-usage': true # Prevents crashes in Docker/CI
    }
  )
end

Capybara.default_driver = :rack_test          # Fast driver for non-JS specs
Capybara.javascript_driver = :cuprite         # Headless Chrome for JS specs
Capybara.app = FireflyApp                     # Tell Capybara about our Roda app
Capybara.server = :puma, { Silent: true }     # Use Puma as the test server
Capybara.default_max_wait_time = 5            # Wait up to 5s for elements

# Load all support files
Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

# Test helper: Automatically add default room bounds if none specified
# This allows legacy test patterns (Room.create without bounds) to work
# while keeping strict validation in production
module RoomTestDefaults
  DEFAULT_BOUNDS = { min_x: 0, max_x: 100, min_y: 0, max_y: 100 }.freeze

  def create(values = {}, &block)
    # Add default bounds only if none are specified
    unless values.key?(:min_x) || values.key?(:max_x) || values.key?(:min_y) || values.key?(:max_y)
      values = DEFAULT_BOUNDS.merge(values)
    end
    super(values, &block)
  end

  def new(values = {}, &block)
    # Add default bounds only if none are specified
    unless values.key?(:min_x) || values.key?(:max_x) || values.key?(:min_y) || values.key?(:max_y)
      values = DEFAULT_BOUNDS.merge(values)
    end
    super(values, &block)
  end
end
Room.singleton_class.prepend(RoomTestDefaults)

RSpec.configure do |config|
  config.order = :random
  Kernel.srand config.seed

  config.include Rack::Test::Methods
  config.include TestHelpers

  config.before(:suite) do
    DatabaseCleaner[:sequel].db = DB
    DatabaseCleaner.allow_remote_database_url = true

    # Clean database before suite for system specs
    if RSpec.configuration.files_to_run.any? { |f| f.include?('spec/system') }
      # Truncate all tables except metadata
      tables = DB.tables - [:ar_internal_metadata, :schema_migrations]
      DB.run("TRUNCATE #{tables.join(', ')} CASCADE") unless tables.empty?
    end
  end

  # Use truncation strategy for system/browser tests (js: true)
  # This works with separate processes without requiring superuser privileges
  config.before(:each, type: :system) do
    DatabaseCleaner.strategy = :truncation, { except: ['ar_internal_metadata'] }
  end

  # Use transaction strategy for non-system tests (faster)
  config.before(:each) do |example|
    DatabaseCleaner.strategy = :transaction unless example.metadata[:type] == :system
  end

  config.around(:each) do |example|
    DatabaseCleaner.cleaning do
      # Clear Redis caches between tests for isolation
      GameSetting.clear_cache! if defined?(GameSetting)
      example.run
    end
  end
  
  config.include FactoryBot::Syntax::Methods
  
  config.before(:suite) do
    FactoryBot.find_definitions
    
    FactoryBot.define do
      to_create { |instance| instance.save }
    end
  end
end

def app
  FireflyApp
end