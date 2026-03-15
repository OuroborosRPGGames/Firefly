# frozen_string_literal: true

require 'bundler/setup'
require 'dotenv/load'
require 'roda'
require 'sequel'
require 'redis'
require 'connection_pool'
require 'json'
require 'oj'
Oj.mimic_JSON # Replace stdlib JSON.parse/JSON.generate with Oj for performance
require 'securerandom'
require 'bcrypt'
require 'fileutils'
require 'faye/websocket'
require 'time'

# Feature flags with opt-in pattern
require_relative 'lib/feature_flags'

# Load game configuration constants (centralized magic numbers/tuning values)
require_relative 'config/game_config'

# Load GamePrompts module (required by services before they load)
require_relative 'config/game_prompts'

# Load centralized room type definitions
require_relative 'config/room_type_config'

# Database setup with connection pooling
require_relative 'config/database'

unless defined?(DB)
  DB = FireflyDatabase.connect
end

# Load helpers first (models and services depend on them)
Dir[File.join(__dir__, 'app/helpers/*.rb')].sort.each { |file| require file }

# Load model concerns (they're dependencies for models)
Dir[File.join(__dir__, 'app/models/concerns/*.rb')].sort.each { |file| require file }

# Load models (auto-discovery)
Dir[File.join(__dir__, 'app/models/*.rb')].each { |file| require file }

# Load lib files (value objects, utilities used by services)
Dir[File.join(__dir__, 'app/lib/*.rb')].sort.each { |file| require file }

# Load service concerns first (they're dependencies for other services)
Dir[File.join(__dir__, 'app/services/concerns/*.rb')].sort.each { |file| require file }

# Load services (auto-discovery, including subdirectories)
# Load subdirectory modules first (e.g., battlemap_v2/) since top-level services may depend on them
service_dir = File.join(__dir__, 'app/services')
service_files = Dir[File.join(service_dir, '**/*.rb')].sort
subdirs, top_level = service_files.partition { |f| File.dirname(f) != service_dir && !f.include?('/concerns/') }
(subdirs + top_level).each { |file| require file }

# Load handler concerns first (they're dependencies for handlers)
Dir[File.join(__dir__, 'app/handlers/concerns/*.rb')].each { |file| require file }

# Load handlers (auto-discovery)
Dir[File.join(__dir__, 'app/handlers/*.rb')].each { |file| require file }

# Load jobs (Sidekiq workers)
Dir[File.join(__dir__, 'app/jobs/*.rb')].sort.each { |file| require file }

# Load command system
require_relative 'app/commands/base/command'
require_relative 'app/commands/base/registry'

# Load plugin system and discover plugins
require_relative 'config/initializers/plugins'
require_relative 'lib/firefly/help_manager'
require_relative 'lib/firefly/cron'
require_relative 'lib/firefly/scheduler'
require_relative 'lib/firefly/timed_action_processor'
require_relative 'lib/firefly/panels'
require_relative 'config/initializers/scheduler'

# Load commands from plugins
load_firefly_plugins!

# Redis setup with expanded pool (50 connections for 100+ users)
unless defined?(REDIS_POOL)
  REDIS_POOL = ConnectionPool.new(size: 50, timeout: 5) do
    Redis.new(
      url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
      timeout: 5,
      reconnect_attempts: 3
    )
  end
end

# Helper with graceful degradation when Redis is unavailable
def with_redis(&block)
  REDIS_POOL.with(&block)
rescue Redis::BaseError => e
  warn "[Redis] Unavailable: #{e.message}"
  nil
end

# Rate limiting (feature flag: FEATURE_RATE_LIMITING, opt-in)
if FeatureFlags.enabled?('RATE_LIMITING')
  require_relative 'config/rack_attack'
end

# Agent mode detection middleware
require_relative 'app/middleware/agent_mode_detector'

# Load route helpers
require_relative 'app/routes/helpers'

# Load API route handlers
require_relative 'app/routes/builder_api'

PATCHABLE_HELPFILE_FIELDS = %w[summary description syntax examples staff_notes].freeze

class FireflyApp < Roda
  # Include route helpers
  include RouteHelpers

  # Middleware stack (order matters: compression outermost, then detection, then rate limiting)
  # Feature flags use opt-in pattern (disabled by default)
  use Rack::Deflater
  use AgentModeDetector if FeatureFlags.enabled?('DUAL_OUTPUT')
  use Rack::Attack if FeatureFlags.enabled?('RATE_LIMITING') && defined?(Rack::Attack)

  plugin :render, engine: 'erb', views: 'app/views'
  plugin :public, root: 'public'
  plugin :cookies
  plugin :sessions,
    secret: ENV.fetch('SESSION_SECRET', SecureRandom.hex(64)),
    key: '_firefly_session',
    same_site: :lax
  plugin :route_csrf
  plugin :flash
  plugin :json
  plugin :assets,
    css: ['application.css'],
    js: ['application.js'],
    path: 'app/assets'
  plugin :content_for
  plugin :h
  plugin :all_verbs


  # Main routes
  route do |r|
    r.public
    r.assets

    @current_user = current_user

    # Homepage
    r.root do
      view 'home/index'
    end

    # ====== PUBLIC ROUTES ======

    # Registration
    r.on 'register' do
      r.get do
        view 'auth/register'
      end

      r.post do
        username = r.params['username']
        email = r.params['email']
        password = r.params['password']
        password_confirmation = r.params['password_confirmation']
        discord_handle_input = r.params['discord_handle'] || r.params['discord_username']
        discord_handle = User.normalize_discord_handle(discord_handle_input)

        if password != password_confirmation
          flash['error'] = 'Passwords do not match'
          r.redirect '/register'
        end

        if password.length < 6
          flash['error'] = 'Password must be at least 6 characters'
          r.redirect '/register'
        end

        if discord_handle_input && !discord_handle_input.to_s.strip.empty? && discord_handle.nil?
          flash['error'] = User::DISCORD_HANDLE_ERROR
          r.redirect '/register'
        end

        begin
          user = User.new(username: username, email: email, discord_username: discord_handle)
          user.set_password(password)
          user.save

          session['user_id'] = user.id
          user.last_login_at = Time.now
          user.save(validate: false)

          # Check if email verification is required
          if GameSetting.get_boolean('email_require_verification') && EmailService.configured?
            EmailService.send_verification_email(user)
            flash['info'] = 'Please check your email to verify your account before creating a character.'
            r.redirect '/verify-email'
          else
            flash['success'] = 'Registration successful! Welcome aboard!'
            r.redirect '/dashboard'
          end
        rescue Sequel::ValidationFailed => e
          flash['error'] = e.message
          r.redirect '/register'
        rescue Sequel::UniqueConstraintViolation => e
          if e.message.include?('username')
            flash['error'] = 'Username is already taken'
          elsif e.message.include?('email')
            flash['error'] = 'Email is already registered'
          else
            flash['error'] = 'Registration failed. Please try again.'
          end
          r.redirect '/register'
        end
      end
    end

    # Email Verification
    r.on 'verify-email' do
      r.is do
        r.get do
          require_login!
          @user = current_user
          view 'auth/verify_email'
        end
      end

      # Token verification route
      r.on String do |token|
        r.get do
          # Find user by token
          user = User.where(confirmation_token: token).first

          unless user
            flash['error'] = 'Invalid verification link. Please request a new one.'
            r.redirect logged_in? ? '/verify-email' : '/login'
          end

          result = user.confirm_email!(token)

          case result
          when :success
            flash['success'] = 'Email verified successfully! You can now create a character.'
            session['user_id'] = user.id unless logged_in?
            r.redirect '/dashboard'
          when :expired
            flash['error'] = 'Verification link has expired. Please request a new one.'
            r.redirect logged_in? ? '/verify-email' : '/login'
          else
            flash['error'] = 'Invalid verification link. Please request a new one.'
            r.redirect logged_in? ? '/verify-email' : '/login'
          end
        end
      end
    end

    # Resend verification email
    r.post 'resend-verification' do
      require_login!

      if current_user.email_verified?
        flash['info'] = 'Your email is already verified.'
      elsif EmailService.configured?
        EmailService.send_verification_email(current_user)
        flash['success'] = 'Verification email sent! Please check your inbox.'
      else
        flash['error'] = 'Email service is not configured. Please contact an administrator.'
      end

      r.redirect '/verify-email'
    end

    # Login
    r.on 'login' do
      r.get do
        view 'auth/login'
      end

      r.post do
        username_or_email = r.params['username_or_email']
        password = r.params['password']
        remember_me = r.params['remember_me']

        # Check if IP is banned before attempting login
        if AccessControlService.ip_banned?(request.ip)
          ban = IpBan.find_matching_ban(request.ip)
          ConnectionLog.log_connection(
            user_id: nil,
            ip_address: request.ip,
            connection_type: 'web_login',
            outcome: 'banned_ip',
            user_agent: request.user_agent,
            failure_reason: "IP banned: #{ban&.reason}"
          )
          flash['error'] = 'Access denied. Your IP address has been banned.'
          r.redirect '/login'
        end

        user = User.authenticate(username_or_email, password)

        if user
          # Block disabled test accounts
          if user.is_test_account && !GameSetting.get_boolean('test_account_enabled')
            flash['error'] = 'Test account access is disabled'
            r.redirect '/login'
          end

          # Check access control (suspension)
          access = AccessControlService.check_access(
            user: user,
            ip_address: request.ip,
            connection_type: 'web_login',
            user_agent: request.user_agent
          )

          unless access[:allowed]
            flash['error'] = access[:reason]
            r.redirect '/login'
          end

          session['user_id'] = user.id
          user.last_login_at = Time.now
          user.save(validate: false)

          if remember_me
            token = user.generate_remember_token!
            response.set_cookie('remember_token',
              value: token,
              expires: Time.now + (30 * 24 * 60 * 60),
              httponly: true,
              same_site: :lax,
              secure: ENV['RACK_ENV'] == 'production'
            )
          end

          flash['success'] = 'Welcome back!'
          r.redirect '/dashboard'
        else
          # Log failed login attempt
          AccessControlService.log_failed_login(
            username_or_email: username_or_email,
            ip_address: request.ip,
            user_agent: request.user_agent
          )
          flash['error'] = 'Invalid username/email or password'
          r.redirect '/login'
        end
      end
    end

    # Logout (support both GET and POST for convenience)
    r.on 'logout' do
      r.is do
        r.get do
          session.clear
          response.delete_cookie('remember_token')
          flash['success'] = 'You have been logged out'
          r.redirect '/'
        end

        r.post do
          session.clear
          response.delete_cookie('remember_token')
          flash['success'] = 'You have been logged out'
          r.redirect '/'
        end
      end
    end

    # News page (public)
    r.on 'news' do
      r.get do
        @news = nil
        view 'news/index'
      end
    end

    # Info pages (public)
    r.on 'info' do
      r.is do
        r.get { view 'info/index' }
      end
      r.get('rules') { view 'info/rules' }
      r.get('getting-started') { view 'info/getting_started' }
      r.get('terms') { view 'info/terms' }
      r.get('privacy') { view 'info/privacy' }
      r.get('contact') { view 'info/contact' }

      # Public commands listing (auto-generated from command DSL)
      r.get 'commands' do
        @helpfiles = Helpfile.exclude(hidden: true).exclude(admin_only: true)
                             .where(auto_generated: true).order(:command_name).all
        @categories = @helpfiles.map(&:category).compact.uniq.sort
        @letters = @helpfiles.map { |h| h.command_name[0].upcase }.uniq.sort
        @is_admin = current_user&.admin?
        @page_title = 'Commands'
        view 'info/commands'
      end

      # Public help topics listing (manually created help content)
      r.get 'helps' do
        @helpfiles = Helpfile.exclude(hidden: true).exclude(admin_only: true)
                             .where(auto_generated: false).or(auto_generated: nil).order(:topic).all
        @categories = @helpfiles.map(&:category).compact.uniq.sort
        @letters = @helpfiles.map { |h| (h.topic || h.command_name)[0].upcase }.uniq.sort
        @is_admin = current_user&.admin?
        @page_title = 'Help Topics'
        view 'info/helps'
      end

      # Public systems listing
      r.get 'systems' do
        @help_systems = defined?(HelpSystem) ? HelpSystem.ordered : []
        @is_admin = current_user&.admin?
        @page_title = 'Game Systems'
        view 'info/systems'
      end
    end

    # World pages (public)
    r.on 'world' do
      r.is do
        r.get do
          @worlds = World.where(is_test: false).order(:name).all rescue []
          view 'world/index'
        end
      end
      r.get('lore') { view 'world/lore' }
      r.get('locations') { view 'world/locations' }
      r.get('factions') { view 'world/factions' }

      # Globe view - /world/:id
      r.on Integer do |world_id|
        @world = World[world_id]
        unless @world
          flash['error'] = 'World not found'
          r.redirect '/world'
        end

        # Get player location if logged in
        @player_location = nil
        if current_character
          instance = current_character.active_instances.first
          if instance&.room
            # Try to find the world hex for this location
            hex = WorldHex.where(location_id: instance.room.location_id).first
            if hex
              @player_location = {
                lat: hex.latitude || 0,
                lng: hex.longitude || 0
              }
            end
          end
        end

        r.is do
          r.get do
            @page_title = "#{@world.name} - Globe View"
            view 'world/globe'
          end
        end
      end
    end

    # Public API for world map data
    r.on 'api', 'world', Integer do |world_id|
      world = World[world_id]

      unless world
        response['Content-Type'] = 'application/json'
        response.status = 404
        next { success: false, error: 'World not found' }.to_json
      end

      # GET /api/world/:id/map - Return public map data (cities only, terrain via texture)
      r.get 'map' do
        # Get cities (zones with type city)
        cities = world.zones.select { |z| z.zone_type == 'city' }.map do |city|
          center = city.center_point
          {
            id: city.id,
            name: city.name,
            lat: center ? (center[:y] || center['y'] || 0).to_f : 0,
            lng: center ? (center[:x] || center['x'] || 0).to_f : 0
          }
        end

        response['Content-Type'] = 'application/json'
        {
          success: true,
          world: { id: world.id, name: world.name },
          cities: cities
        }.to_json
      end

      # GET /api/world/:id/terrain_texture.png - Pre-rendered terrain texture
      r.get 'terrain_texture.png' do
        response['Content-Type'] = 'image/png'
        response['Cache-Control'] = 'public, max-age=3600'

        cache_dir = File.join(Dir.pwd, 'tmp', 'textures')
        cache_path = File.join(cache_dir, "world_#{world.id}.png")

        needs_regeneration = !File.exist?(cache_path) ||
                             (world.updated_at && File.mtime(cache_path) < world.updated_at)

        if needs_regeneration
          begin
            png_data = TerrainTextureService.new(world).generate
            FileUtils.mkdir_p(cache_dir)
            File.binwrite(cache_path, png_data)
          rescue StandardError => e
            warn "[TerrainTexture] Public generation failed: #{e.message}"
            response.status = 500
            next ''
          end
        end

        File.binread(cache_path)
      end

      # GET /api/world/:id/nearest_hex - Find nearest hex to lat/lng
      r.get 'nearest_hex' do
        lat = request.params['lat']&.to_f
        lng = request.params['lng']&.to_f

        unless lat && lng
          response['Content-Type'] = 'application/json'
          response.status = 400
          next { success: false, error: 'lat and lng parameters required' }.to_json
        end

        hex = WorldHex.find_nearest_by_latlon(world.id, lat, lng)

        response['Content-Type'] = 'application/json'
        if hex
          {
            success: true,
            hex: {
              id: hex.globe_hex_id || hex.id,
              lat: hex.latitude || 0,
              lng: hex.longitude || 0,
              terrain: hex.terrain_type,
              traversable: hex.traversable,
              altitude: hex.altitude
            }
          }.to_json
        else
          { success: true, hex: nil }.to_json
        end
      end
    end

    # Character Profiles (public)
    r.on 'profiles' do
      r.is do
        r.get do
          @page = (r.params['page'] || 1).to_i
          @per_page = 24

          base_query = Character.publicly_visible
            .order(Sequel.desc(:profile_score), Sequel.desc(:last_seen_at))

          # Optional: filter by online status
          if r.params['online'] == '1'
            online_char_ids = CharacterInstance.where(online: true).select(:character_id)
            base_query = base_query.where(id: online_char_ids)
          end

          # Optional: search by name
          search = r.params['search'].to_s.strip
          if !search.empty?
            search_term = "%#{search}%"
            base_query = base_query.where(
              Sequel.ilike(:forename, search_term) |
              Sequel.ilike(:surname, search_term) |
              Sequel.ilike(:nickname, search_term)
            )
          end

          @total_count = base_query.count
          @characters = base_query.limit(@per_page).offset((@page - 1) * @per_page).all
          @total_pages = (@total_count.to_f / @per_page).ceil
          @page_title = 'Character Directory'

          view 'profiles/index'
        end
      end

      r.on Integer do |character_id|
        r.get do
          @character = Character[character_id]

          unless @character&.publicly_visible?
            flash['error'] = 'Character profile not found'
            r.redirect '/profiles'
          end

          @profile = ProfileDisplayService.new(@character, viewer: current_character).build_profile
          @page_title = "#{@character.full_name} - Profile"

          view 'profiles/show'
        end
      end
    end

    # ====== WEBSOCKET ROUTE ======
    r.on 'cable' do
      if Faye::WebSocket.websocket?(r.env)
        char_instance = authenticate_websocket(r)

        if char_instance
          handler = WebsocketHandler.new(r.env, char_instance)
          r.halt handler.rack_response
        else
          r.halt [401, { 'Content-Type' => 'application/json' }, ['{"error":"Unauthorized"}']]
        end
      else
        # Not a WebSocket request
        response.status = 400
        next { error: 'WebSocket connection required' }.to_json
      end
    end

    # ====== API ROUTES ======
    r.on 'api' do
      response['Content-Type'] = 'application/json'

      # Serve lit battlemap images for dynamic lighting.
      # Intentionally unauthenticated: MCP agents and webclient both need direct URL access.
      # Fight IDs are not sensitive; the image itself contains no PII.
      r.on 'fights', Integer, 'lit_battlemap.webp' do |fight_id|
        path = File.join('tmp', 'fights', fight_id.to_s, 'lit_battlemap.webp')
        if File.exist?(path)
          response['Content-Type'] = 'image/webp'
          response['Cache-Control'] = 'no-cache'
          File.binread(path)
        else
          response.status = 404
          ''
        end
      end

      # Builder API (admin-only endpoints for MCP building tools)
      r.on 'builder' do
        r.run BuilderApi
      end

      # TTS API (voice preview for character creation)
      r.on 'tts' do
        r.post 'preview' do
          char_instance = character_instance_from_token || current_character_instance
          unless char_instance
            response.status = 401
            next { success: false, error: 'Unauthorized' }.to_json
          end
          begin
            data = JSON.parse(request.body.read)
            voice_type = data['voice_type']
            voice_speed = data['voice_speed']&.to_f || 1.0
            voice_pitch = data['voice_pitch']&.to_f || 0.0

            unless voice_type && !voice_type.strip.empty?
              response.status = 400
              next { success: false, error: 'voice_type is required' }.to_json
            end

            # Validate voice exists
            unless TtsService.valid_voice?(voice_type)
              response.status = 400
              next { success: false, error: "Unknown voice: #{voice_type}" }.to_json
            end

            # Generate preview audio with speed/pitch settings
            result = TtsService.generate_preview(voice_type, speed: voice_speed, pitch: voice_pitch)

            if result[:success]
              { success: true, audio_url: result[:data][:audio_url], voice: voice_type }.to_json
            else
              { success: false, error: result[:error] || 'TTS preview failed' }.to_json
            end
          rescue JSON::ParserError
            response.status = 400
            { success: false, error: 'Invalid JSON' }.to_json
          rescue StandardError => e
            warn "[TTS API] Preview error: #{e.message}"
            { success: false, error: 'TTS service error' }.to_json
          end
        end

        # Intentionally unauthenticated: voice list is static metadata used during character creation
        # before a user account exists. No PII, no cost, no write operations.
        r.get 'voices' do
          { success: true, voices: TtsService.available_voices }.to_json
        end
      end

      # Intentionally unauthenticated: body position labels are static reference data used by the
      # description manager before a character session is established. No PII, no write operations.
      r.get 'body-positions' do
        positions = BodyPosition.order(:region, :display_order, :label).all
        grouped = positions.group_by(&:region)

        result = {}
        grouped.each do |region, region_positions|
          result[region] = region_positions.map do |pos|
            {
              id: pos.id,
              label: pos.label,
              display_label: pos.label.to_s.tr('_', ' ').split.map(&:capitalize).join(' '),
              region: pos.region,
              is_private: pos.is_private
            }
          end
        end

        { success: true, positions: result }.to_json
      end

      # Events API
      r.on 'events' do
        ci = current_character_instance
        if !ci && current_user
          fallback_char = current_user.characters_dataset.order(:id).first
          if fallback_char
            ci = fallback_char.default_instance || CharacterInstance.where(character_id: fallback_char.id).first
          end
        end
        unless ci
          response.status = 401
          next({ success: false, error: 'Unauthorized' }.to_json)
        end

        # POST /api/events - Create event from web calendar
        r.is do
          r.post do
            begin
              data = JSON.parse(request.body.read)

              name = data['name'].to_s.strip
              starts_at_raw = data['starts_at']

              if name.empty?
                response.status = 400
                next({ success: false, error: 'Event name is required' }.to_json)
              end

              starts_at = begin
                Time.iso8601(starts_at_raw.to_s)
              rescue ArgumentError, TypeError
                nil
              end

              unless starts_at
                response.status = 400
                next({ success: false, error: 'Valid starts_at is required' }.to_json)
              end

              ends_at = begin
                raw = data['ends_at']
                raw && !raw.to_s.strip.empty? ? Time.iso8601(raw.to_s) : nil
              rescue ArgumentError, TypeError
                nil
              end

              max_attendees = data['max_attendees']
              max_attendees = max_attendees.to_i if max_attendees && !max_attendees.to_s.strip.empty?
              max_attendees = nil unless max_attendees&.positive?

              room = ci.current_room
              event = EventService.create_event(
                organizer: ci.character,
                name: name,
                starts_at: starts_at,
                room: room,
                event_type: data['event_type'],
                ends_at: ends_at,
                is_public: data.key?('is_public') ? data['is_public'] : true,
                description: data['description'],
                logs_visible_to: data['logs_visible_to'],
                max_attendees: max_attendees
              )

              event.add_attendee(ci.character, rsvp: 'yes')

              {
                success: true,
                event: {
                  id: event.id,
                  name: event.name,
                  starts_at: event.starts_at&.iso8601,
                  status: event.status
                }
              }.to_json
            rescue JSON::ParserError
              response.status = 400
              { success: false, error: 'Invalid JSON' }.to_json
            rescue Sequel::ValidationFailed => e
              response.status = 422
              { success: false, error: e.message }.to_json
            rescue StandardError => e
              warn "[EventsAPI] Error creating event: #{e.message}"
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end
        end
      end

      # Wardrobe API
      r.on 'wardrobe' do
        ci = current_character_instance
        unless ci
          response.status = 401
          next { success: false, error: 'Unauthorized' }.to_json
        end

        wardrobe = WardrobeService.new(ci)

        # GET /api/wardrobe - Overview
        r.is do
          r.get do
            wardrobe.overview.merge(success: true).to_json
          end
        end

        # GET /api/wardrobe/items?category=clothing&subcategory=tops&room_id=123
        r.get 'items' do
          category = r.params['category'] || 'clothing'
          subcategory = r.params['subcategory']
          room_id = r.params['room_id']
          items = wardrobe.items_by_category(category, subcategory, room_id: room_id)
          patterns = wardrobe.patterns_by_category(category)

          cards = items.map { |i| wardrobe_item_json(i) } +
                  patterns.map { |p| wardrobe_pattern_json(p, ci) }

          {
            success: true,
            vault_accessible: wardrobe.vault_accessible?,
            cards: cards,
            available_subcategories: wardrobe.available_subcategories(category)
          }.to_json
        end

        # GET /api/wardrobe/inventory - Items in inventory that can be stored
        r.get 'inventory' do
          storable = ci.objects_dataset
                       .where(stored: false, held: false)
                       .exclude(worn: true)
                       .exclude(equipped: true)
                       .order(:name)
                       .all

          {
            success: true,
            vault_accessible: wardrobe.vault_accessible?,
            items: storable.map { |i| wardrobe_item_json(i) }
          }.to_json
        end

        r.on 'items', Integer do |item_id|
          # GET /api/wardrobe/items/:id
          r.is do
            r.get do
              wardrobe.sync_transfers!
              item = Item.available_stored_items_for(ci).where(id: item_id).first
              next { success: false, error: 'Item not found' }.to_json unless item
              { success: true, item: wardrobe_item_json(item) }.to_json
            end
          end

          # POST /api/wardrobe/items/:id/fetch
          r.post 'fetch' do
            result = wardrobe.fetch_item(item_id)
            wardrobe_result_json(result)
          end

          # POST /api/wardrobe/items/:id/fetch-wear
          r.post 'fetch-wear' do
            result = wardrobe.fetch_and_wear(item_id)
            wardrobe_result_json(result)
          end

          # POST /api/wardrobe/items/:id/trash
          r.post 'trash' do
            result = wardrobe.trash_item(item_id)
            wardrobe_result_json(result)
          end

          # POST /api/wardrobe/items/:id/store
          r.post 'store' do
            unless wardrobe.vault_accessible?
              next { success: false, error: 'No vault access in this room' }.to_json
            end

            item = ci.objects_dataset.where(id: item_id, stored: false).first
            unless item
              next { success: false, error: 'Item not found in inventory' }.to_json
            end

            if item.worn?
              next { success: false, error: "You need to remove #{item.name} first." }.to_json
            end

            if item.equipped?
              next { success: false, error: "You need to unequip #{item.name} first." }.to_json
            end

            room = ci.current_room
            item.store!(room)
            plain_name = item.name.to_s.gsub(/<[^>]+>/, '')
            { success: true, message: "You store #{plain_name}." }.to_json
          end
        end

        r.on 'patterns', Integer do |pattern_id|
          # POST /api/wardrobe/patterns/:id/create
          r.post 'create' do
            result = wardrobe.create_from_pattern(pattern_id)
            wardrobe_result_json(result)
          end
        end

        # GET /api/wardrobe/stash-rooms
        r.get 'stash-rooms' do
          { success: true, rooms: wardrobe.stash_rooms }.to_json
        end

        r.on 'transfers' do
          # GET /api/wardrobe/transfers
          r.is do
            r.get do
              { success: true, transfers: wardrobe.active_transfers }.to_json
            end

            # POST /api/wardrobe/transfers - Start new transfer
            r.post do
              from_id = r.params['from_room_id']
              to_id = r.params['to_room_id']
              result = wardrobe.start_transfer(from_id, to_id)
              wardrobe_result_json(result)
            end
          end

          # POST /api/wardrobe/transfers/cancel
          r.post 'cancel' do
            from_id = r.params['from_room_id']
            to_id = r.params['to_room_id']
            result = wardrobe.cancel_transfer(from_id, to_id)
            wardrobe_result_json(result)
          end
        end
      end

      # Gradients API (for description editor gradient text)
      r.on 'gradients' do
        current_user_id = current_user&.id

        # List all gradients (user's + shared; shared are publicly readable by design)
        r.is do
          r.get do
            gradients = []
            gradients += Gradient.for_user(current_user_id) if current_user_id
            gradients += Gradient.shared
            gradients.map(&:to_api_hash).to_json
          end

          # Create new gradient
          r.post do
            unless current_user_id
              response.status = 401
              next { success: false, error: 'Must be logged in to create gradients' }.to_json
            end

            begin
              data = JSON.parse(request.body.read)
              gradient = Gradient.new(
                user_id: current_user_id,
                name: data['name'],
                colors: data['colors'],
                easings: data['easings'] || [],
                interpolation: data['interpolation'] || 'ciede2000'
              )

              if gradient.valid?
                gradient.save
                gradient.to_api_hash.to_json
              else
                response.status = 422
                { success: false, error: gradient.errors.full_messages.join(', ') }.to_json
              end
            rescue JSON::ParserError
              response.status = 400
              { success: false, error: 'Invalid JSON' }.to_json
            end
          end
        end

        # Recent gradients for current user
        r.get 'recent' do
          if current_user_id
            Gradient.recent_for_user(current_user_id).map(&:to_api_hash).to_json
          else
            [].to_json
          end
        end

        # Operations on specific gradient
        r.on Integer do |gradient_id|
          gradient = Gradient[gradient_id]

          unless gradient
            response.status = 404
            next { success: false, error: 'Gradient not found' }.to_json
          end

          # Update gradient
          r.is do
            r.put do
              # Only owner can update
              unless gradient.user_id == current_user_id
                response.status = 403
                next { success: false, error: 'Not authorized to update this gradient' }.to_json
              end

              begin
                data = JSON.parse(request.body.read)
                gradient.name = data['name'] if data.key?('name')
                gradient.colors = data['colors'] if data.key?('colors')
                gradient.easings = data['easings'] if data.key?('easings')
                gradient.interpolation = data['interpolation'] if data.key?('interpolation')

                if gradient.valid?
                  gradient.save
                  gradient.to_api_hash.to_json
                else
                  response.status = 422
                  { success: false, error: gradient.errors.full_messages.join(', ') }.to_json
                end
              rescue JSON::ParserError
                response.status = 400
                { success: false, error: 'Invalid JSON' }.to_json
              end
            end

            # Delete gradient
            r.delete do
              unless gradient.user_id == current_user_id
                response.status = 403
                next { success: false, error: 'Not authorized to delete this gradient' }.to_json
              end

              gradient.destroy
              { success: true }.to_json
            end
          end

          # Track usage (requires login to prevent anonymous write spam)
          r.post 'use' do
            unless current_user_id
              response.status = 401
              next { success: false, error: 'Must be logged in to track gradient usage' }.to_json
            end
            gradient.record_use!
            { success: true }.to_json
          end
        end
      end

      # Agent API (Bearer token auth, no session)
      r.on 'agent' do
        char_instance = character_instance_from_token
        unless char_instance
          response.status = 401
          next { success: false, error: 'Unauthorized' }.to_json
        end

        r.post 'command' do
          begin
            # Auto-set API agents online when they execute commands
            unless char_instance.online
              char_instance.update(online: true)
              char_instance.start_session! if char_instance.respond_to?(:start_session!)
            end

            data = JSON.parse(request.body.read)
            command = data['command'].to_s.strip

            if command.empty?
              response.status = 400
              next { success: false, error: 'Command cannot be blank' }.to_json
            end

            # Try input interception first (quickmenu shortcuts, activity shortcuts)
            result = InputInterceptorService.intercept(char_instance, command)

            # If not intercepted, rewrite for context and use normal command processing
            unless result
              rewritten_command = InputInterceptorService.rewrite_for_context(char_instance, command)
              result = Commands::Base::Registry.execute_command(char_instance, rewritten_command, request_env: request.env)

              # If command was not recognized, try room name fallback
              # Only exact room name matches work - user must type the full room name
              if !result[:success] && result[:attempted_command]
                room_fallback = RoomNameFallbackService.try_fallback(char_instance, rewritten_command)
                if room_fallback
                  result = Commands::Base::Registry.execute_command(char_instance, room_fallback, request_env: request.env)
                end
              end
            end

            if result[:success]
              # Ensure description is always set for agent API compatibility
              description = result[:description] || result[:message]

              # If response contains a quickmenu, store it as a pending interaction
              structured = result[:structured]
              if structured.is_a?(Hash) && structured[:quickmenu]
                qm = structured[:quickmenu]
                interaction_id = SecureRandom.uuid
                menu_data = {
                  interaction_id: interaction_id,
                  type: 'quickmenu',
                  prompt: qm[:prompt],
                  options: qm[:options],
                  context: qm[:context] || {},
                  created_at: Time.now.iso8601
                }
                OutputHelper.store_agent_interaction(char_instance, interaction_id, menu_data)
                structured = structured.merge(interaction_id: interaction_id)
              elsif result[:type]&.to_sym == :quickmenu && structured.is_a?(Hash) && structured[:handler]
                # Disambiguation-style quickmenu (handler/context at top level of structured)
                interaction_id = SecureRandom.uuid
                # Merge handler into context so response routing can find it
                stored_context = (structured[:context] || {}).merge(handler: structured[:handler])
                menu_data = {
                  interaction_id: interaction_id,
                  type: 'quickmenu',
                  prompt: structured[:prompt],
                  options: structured[:options],
                  context: stored_context,
                  created_at: Time.now.iso8601
                }
                OutputHelper.store_agent_interaction(char_instance, interaction_id, menu_data)
                structured = structured.merge(interaction_id: interaction_id)
              end

              # Also detect quickmenus embedded in result[:data] (fight/spar commands)
              embedded_qm = nil
              data_hash = result[:data]
              if data_hash.is_a?(Hash) && data_hash[:quickmenu].is_a?(Hash)
                qm = data_hash[:quickmenu]
                qm_interaction_id = SecureRandom.uuid
                qm_menu_data = {
                  interaction_id: qm_interaction_id,
                  type: 'quickmenu',
                  prompt: qm[:prompt],
                  options: qm[:options],
                  context: qm[:context] || {},
                  created_at: Time.now.iso8601
                }
                OutputHelper.store_agent_interaction(char_instance, qm_interaction_id, qm_menu_data)
                embedded_qm = {
                  interaction_id: qm_interaction_id,
                  prompt: qm[:prompt],
                  options: qm[:options]
                }
              end

              response_hash = {
                success: true,
                type: result[:type],
                target_panel: result[:target_panel],
                description: description,
                structured: structured,
                message: result[:message],
                timestamp: result[:timestamp],
                status_bar: result[:status_bar]
              }
              response_hash[:quickmenu] = embedded_qm if embedded_qm
              if result[:animation_data]
                response_hash[:animation_data] = result[:animation_data]
                response_hash[:roll_modifier] = result[:roll_modifier]
                response_hash[:roll_total] = result[:roll_total]
              end
              response_hash.to_json
            else
              # Ensure error is always set
              error_msg = result[:error] || result[:message] || 'Command failed'
              {
                success: false,
                error: error_msg,
                target_panel: result[:target_panel],
                suggestions: result[:suggestions]
              }.to_json
            end
          rescue JSON::ParserError
            response.status = 400
            { success: false, error: 'Invalid request format' }.to_json
          rescue => e
            $stderr.puts "[API_ERROR] /api/agent/command: #{e.class}: #{e.message}"
            $stderr.puts e.backtrace.first(10).join("\n")
            File.open('/tmp/firefly_errors.log', 'a') { |f| f.puts "#{Time.now} [COMMAND]: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}" }
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        r.get 'room' do
          begin
            room = char_instance.current_room
            unless room
              next { success: false, error: 'Character not in a room' }.to_json
            end

            chars_here = room.characters_here(char_instance.reality_id).exclude(id: char_instance.id).eager(:character).all
            objects = room.objects_here.all

            # Use spatial exits (no more RoomExit records)
            # Deduplicate by destination room - keep only the closest direction for each room
            spatial_exits = room.spatial_exits
            exits_by_room = {}
            direction_priority = %i[north south east west northeast northwest southeast southwest up down]

            spatial_exits.each do |direction, rooms|
              dir_priority = direction_priority.index(direction.to_sym) || 999
              rooms.each do |to_room|
                existing = exits_by_room[to_room.id]
                if existing.nil? || dir_priority < existing[:priority]
                  exits_by_room[to_room.id] = {
                    room: to_room,
                    direction: direction,
                    priority: dir_priority
                  }
                end
              end
            end

            exit_data = exits_by_room.values.map do |exit_info|
              to_room = exit_info[:room]
              passable = RoomPassabilityService.can_pass?(room, to_room, exit_info[:direction])
              {
                id: to_room.id,
                direction: exit_info[:direction].to_s,
                display_name: to_room.name,
                locked: !passable,
                to_room_id: to_room.id
              }
            end

            {
              success: true,
              room: { id: room.id, name: room.name, description: room.description, room_type: room.room_type },
              characters: chars_here.map { |ci| { id: ci.id, character_id: ci.character.id, name: ci.character.display_name_for(char_instance), short_desc: ci.character.short_desc } },
              objects: objects.map { |obj| { id: obj.id, name: obj.name, description: obj.description } },
              exits: exit_data
            }.to_json
          rescue => e
            puts "[API_ERROR] /api/agent/room: #{e.class}: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        r.get 'commands' do
          begin
            available = Commands::Base::Registry.list_commands_for_character(char_instance)
            { success: true, commands: available.map { |cmd| { name: cmd[:name], aliases: cmd[:aliases], category: cmd[:category], help: cmd[:help] } } }.to_json
          rescue => e
            puts "[API_ERROR] /api/agent/commands: #{e.class}: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        r.post 'online' do
          begin
            # Reset any stale combat/activity state before going online
            cleaned = char_instance.reset_combat_and_activities!(end_fights: true)

            char_instance.update(online: true)
            char_instance.start_session!

            {
              success: true,
              message: "#{char_instance.character.full_name} is now online",
              character_name: char_instance.character.full_name,
              cleaned: cleaned
            }.to_json
          rescue => e
            puts "[API_ERROR] /api/agent/online: #{e.class}: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        r.post 'teleport' do
          begin
            data = JSON.parse(request.body.read)
            room_id = data['room_id']
            room_name = data['room_name']

            target_room = nil
            if room_id
              target_room = Room[room_id]
            elsif room_name
              target_room = Room.where(Sequel.ilike(:name, "%#{room_name}%")).first
            end

            unless target_room
              response.status = 404
              next { success: false, error: 'Room not found' }.to_json
            end

            from_room = char_instance.current_room
            # Use teleport_to_room! to set position within room bounds
            char_instance.teleport_to_room!(target_room)
            {
              success: true,
              message: "Teleported to #{target_room.name}",
              from_room: from_room ? { id: from_room.id, name: from_room.name } : nil,
              to_room: { id: target_room.id, name: target_room.name },
              position: char_instance.position
            }.to_json
          rescue JSON::ParserError
            response.status = 400
            { success: false, error: 'Invalid request format' }.to_json
          rescue => e
            puts "[API_ERROR] /api/agent/teleport: #{e.class}: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        r.get 'locations' do
          begin
            locations = Location.order(:id).all
            {
              success: true,
              locations: locations.map { |loc|
                {
                  id: loc.id,
                  name: loc.name,
                  location_type: loc.location_type,
                  zone_id: loc.zone_id,
                  zone_name: loc.zone&.name,
                  is_city: loc.is_city? ? true : false,
                  room_count: loc.rooms_dataset.count
                }
              }
            }.to_json
          rescue => e
            puts "[API_ERROR] /api/agent/locations: #{e.class}: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        r.get 'rooms' do
          begin
            location_id = r.params['location_id']&.to_i
            unless location_id && location_id > 0
              response.status = 400
              next { success: false, error: 'location_id parameter is required' }.to_json
            end

            location = Location[location_id]
            unless location
              response.status = 404
              next { success: false, error: "Location #{location_id} not found" }.to_json
            end

            rooms = location.rooms_dataset.order(:id).all
            {
              success: true,
              location_id: location.id,
              location_name: location.name,
              rooms: rooms.map { |r|
                {
                  id: r.id,
                  name: r.name,
                  room_type: r.room_type,
                  inside_room_id: r.inside_room_id
                }
              }
            }.to_json
          rescue => e
            puts "[API_ERROR] /api/agent/rooms: #{e.class}: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        r.get 'status' do
          begin
            char = char_instance.character
            {
              success: true,
              character: { id: char.id, name: char.full_name, short_desc: char.short_desc },
              instance: { id: char_instance.id, room_id: char_instance.current_room_id, reality_id: char_instance.reality_id, status: char_instance.status }
            }.to_json
          rescue => e
            puts "[API_ERROR] /api/agent/status: #{e.class}: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # Messages endpoint - get witnessed events (what the character actually saw)
        # Agents receive ALL room broadcasts, not just IC types
        r.get 'messages' do
          begin
            # Parse since parameter - defaults to last 30 seconds
            since_param = r.params['since']
            since = since_param ? Time.parse(since_param) : (Time.now - 30)

            messages = []

            # Get buffered broadcasts from Redis (agents get ALL broadcasts)
            if defined?(REDIS_POOL) && REDIS_POOL
              REDIS_POOL.with do |redis|
                key = "agent_broadcasts:#{char_instance.id}"
                broadcasts = redis.lrange(key, 0, -1)
                redis.del(key) # Clear after reading

                broadcasts.each do |broadcast_json|
                  broadcast = JSON.parse(broadcast_json, symbolize_names: true)
                  # Filter by timestamp
                  broadcast_time = Time.parse(broadcast[:timestamp]) rescue nil
                  next if broadcast_time && broadcast_time < since

                  messages << {
                    type: broadcast[:type] || 'broadcast',
                    sender: 'System',
                    content: broadcast[:content],
                    timestamp: broadcast[:timestamp],
                    source: 'broadcast'
                  }
                end
              end
            end

            # Also get witnessed messages from RpLog (IC content)
            witnessed = RpLog.where(character_instance_id: char_instance.id)
                             .where { logged_at > since }
                             .order(:logged_at)
                             .limit(50)
                             .all

            # Get direct private messages to this character
            direct_msgs = Message.where(target_character_instance_id: char_instance.id)
                                 .where { created_at > since }
                                 .order(:created_at)
                                 .limit(20)
                                 .all

            # Add witnessed RP events
            witnessed.each do |log|
              messages << {
                type: log.log_type || 'event',
                sender: log.sender_character&.display_name_for(char_instance) || 'Unknown',
                content: log.text,
                timestamp: log.display_timestamp&.iso8601,
                source: 'witnessed'
              }
            end

            # Add direct messages
            direct_msgs.each do |msg|
              messages << {
                type: msg.message_type || 'message',
                sender: msg.sender_character_instance&.character&.display_name_for(char_instance) || 'Someone',
                content: msg.content,
                timestamp: msg.created_at&.iso8601,
                source: 'direct'
              }
            end

            # Sort by timestamp and deduplicate by content
            messages.sort_by! { |m| m[:timestamp] || '' }
            messages.uniq! { |m| [m[:content], m[:type]] }

            {
              success: true,
              messages: messages,
              since: since.iso8601,
              server_time: Time.now.iso8601
            }.to_json
          rescue ArgumentError => e
            # Handle invalid time parse
            response.status = 400
            { success: false, error: "Invalid 'since' parameter: #{e.message}" }.to_json
          rescue => e
            puts "[API_ERROR] /api/agent/messages: #{e.class}: #{e.message}"
            puts e.backtrace.first(5).join("\n")
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # Fight status endpoint - get agent's current fight state
        r.get 'fight' do
          begin
            participant = FightParticipant.where(character_instance_id: char_instance.id)
                                          .exclude(defeated_at: nil)
                                          .eager(:fight)
                                          .first

            # Try to find active fight (not defeated)
            participant ||= FightParticipant.where(character_instance_id: char_instance.id, defeated_at: nil)
                                            .eager(:fight)
                                            .order(Sequel.desc(:id))
                                            .first

            unless participant
              next { success: true, in_fight: false }.to_json
            end

            fight = participant.fight
            participants = fight.fight_participants_dataset.eager(:character_instance).all

            {
              success: true,
              in_fight: true,
              fight: {
                id: fight.id,
                status: fight.status,
                round_number: fight.round_number,
                battle_map_generating: fight.battle_map_generating,
                can_accept_combat_input: fight.can_accept_combat_input?,
                started_at: fight.started_at&.iso8601,
                ended_at: fight.combat_ended_at&.iso8601
              },
              self: {
                id: participant.id,
                current_hp: participant.current_hp,
                max_hp: participant.max_hp,
                input_complete: participant.input_complete,
                defeated_at: participant.defeated_at&.iso8601
              },
              participants: participants.map do |p|
                ci = p.character_instance
                {
                  id: p.id,
                  character_name: ci&.character&.name || 'Unknown',
                  current_hp: p.current_hp,
                  max_hp: p.max_hp,
                  input_complete: p.input_complete,
                  defeated: !p.defeated_at.nil?
                }
              end
            }.to_json
          rescue => e
            warn "[API_ERROR] /api/agent/fight: #{e.class}: #{e.message}"
            warn e.backtrace.first(3).join("\n")
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # Help API endpoints
        r.on 'help' do
          r.get 'search' do
            begin
              query = r.params['q'] || r.params['query']
              category = r.params['category']
              results = Firefly::HelpManager.search(query, category: category)
              { success: true, results: results }.to_json
            rescue => e
              puts "[API_ERROR] /api/agent/help/search: #{e.class}: #{e.message}"
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end

          r.get 'topics' do
            begin
              category = r.params['category']
              topics = Firefly::HelpManager.list_topics(category: category)
              { success: true, topics: topics }.to_json
            rescue => e
              puts "[API_ERROR] /api/agent/help/topics: #{e.class}: #{e.message}"
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end

          r.get do
            begin
              topic = r.params['topic']
              if topic.nil? || topic.strip.empty?
                # Return table of contents
                toc = Firefly::HelpManager.table_of_contents
                { success: true, toc: toc }.to_json
              else
                help = Firefly::HelpManager.get_help(topic, char_instance)
                if help
                  { success: true, help: help }.to_json
                else
                  response.status = 404
                  { success: false, error: "No help found for '#{topic}'" }.to_json
                end
              end
            rescue => e
              puts "[API_ERROR] /api/agent/help: #{e.class}: #{e.message}"
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end
        end

        # Timed Actions API endpoints
        r.on 'actions' do
          r.get do
            begin
              actions = TimedAction.active_for_character(char_instance.id)
              {
                success: true,
                actions: actions.map(&:to_api_format)
              }.to_json
            rescue => e
              puts "[API_ERROR] /api/agent/actions: #{e.class}: #{e.message}"
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end

          r.on Integer do |action_id|
            r.post 'cancel' do
              begin
                action = TimedAction[action_id]
                unless action && action.character_instance_id == char_instance.id
                  response.status = 404
                  next { success: false, error: 'Action not found' }.to_json
                end

                if action.cancel!
                  { success: true, message: 'Action cancelled' }.to_json
                else
                  { success: false, error: 'Cannot cancel this action' }.to_json
                end
              rescue => e
                puts "[API_ERROR] /api/agent/actions/cancel: #{e.class}: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end

            r.post 'interrupt' do
              begin
                action = TimedAction[action_id]
                unless action && action.character_instance_id == char_instance.id
                  response.status = 404
                  next { success: false, error: 'Action not found' }.to_json
                end

                if action.interrupt!('manual')
                  { success: true, message: 'Action interrupted' }.to_json
                else
                  { success: false, error: 'Cannot interrupt this action' }.to_json
                end
              rescue => e
                puts "[API_ERROR] /api/agent/actions/interrupt: #{e.class}: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end

            r.get do
              begin
                action = TimedAction[action_id]
                unless action && action.character_instance_id == char_instance.id
                  response.status = 404
                  next { success: false, error: 'Action not found' }.to_json
                end

                { success: true, action: action.to_api_format }.to_json
              rescue => e
                puts "[API_ERROR] /api/agent/actions/:id: #{e.class}: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end
          end
        end

        # Cooldowns API endpoints
        r.get 'cooldowns' do
          begin
            cooldowns = ActionCooldown.active_for_character(char_instance.id)
            {
              success: true,
              cooldowns: cooldowns.map(&:to_api_format)
            }.to_json
          rescue => e
            puts "[API_ERROR] /api/agent/cooldowns: #{e.class}: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # Agent Interactions API (quickmenus, forms)
        r.on 'interactions' do
          # Get all pending interactions
          r.get do
            begin
              interactions = OutputHelper.get_pending_interactions(char_instance.id)
              {
                success: true,
                interactions: interactions.map do |i|
                  {
                    interaction_id: i[:interaction_id],
                    type: i[:type],
                    prompt: i[:prompt],
                    title: i[:title],
                    options: i[:options],
                    fields: i[:fields],
                    created_at: i[:created_at]
                  }.compact
                end
              }.to_json
            rescue => e
              puts "[API_ERROR] /api/agent/interactions: #{e.class}: #{e.message}"
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end

          # Respond to a specific interaction
          r.on String do |interaction_id|
            r.post 'respond' do
              begin
                data = JSON.parse(request.body.read)
                response_value = data['response'] || data['value']

                # Get the interaction
                interaction = OutputHelper.get_agent_interaction(char_instance.id, interaction_id)
                unless interaction
                  response.status = 404
                  next { success: false, error: 'Interaction not found or expired' }.to_json
                end

                # Validate response based on type
                case interaction[:type]
                when 'quickmenu'
                  valid_keys = interaction[:options].map { |o| o[:key].to_s }
                  unless valid_keys.include?(response_value.to_s)
                    response.status = 400
                    next {
                      success: false,
                      error: "Invalid option. Valid keys: #{valid_keys.join(', ')}"
                    }.to_json
                  end
                when 'form'
                  # Validate required fields
                  unless response_value.is_a?(Hash)
                    response.status = 400
                    next { success: false, error: 'Form response must be an object with field values' }.to_json
                  end

                  missing = interaction[:fields]
                    .select { |f| f[:required] }
                    .reject { |f| response_value.key?(f[:name].to_s) || response_value.key?(f[:name].to_sym) }
                    .map { |f| f[:name] }

                  if missing.any?
                    response.status = 400
                    next { success: false, error: "Missing required fields: #{missing.join(', ')}" }.to_json
                  end
                end

                # Handle different context types
                context = interaction[:context] || {}
                complete_interaction = -> { OutputHelper.complete_interaction(char_instance.id, interaction_id) }

                # Combat quickmenu
                if context[:combat] || context['combat']
                  fight_id = context[:fight_id] || context['fight_id']
                  participant_id = context[:participant_id] || context['participant_id']
                  fight_id = fight_id.to_i if fight_id

                  participant = FightParticipant[participant_id]
                  if participant && participant.fight_id == fight_id && participant.character_instance_id == char_instance.id
                    # Process the combat menu selection
                    handler = CombatQuickmenuHandler.new(participant, char_instance)
                    result = handler.handle_response(response_value)

                    # Get the new menu (if any) - result can be the new menu or nil if input complete
                    new_menu = result.is_a?(Hash) && result[:type] == :quickmenu ? result : nil
                    new_interaction_id = nil

                    # Store new menu as interaction if one exists
                    if new_menu && new_menu[:options]&.any?
                      new_interaction_id = SecureRandom.uuid
                      new_menu_data = {
                        interaction_id: new_interaction_id,
                        type: 'quickmenu',
                        prompt: new_menu[:prompt],
                        options: new_menu[:options],
                        context: new_menu[:context] || {},
                        created_at: Time.now.iso8601
                      }
                      OutputHelper.store_agent_interaction(char_instance, new_interaction_id, new_menu_data)
                    end

                    # Determine message based on result
                    message = if result.nil?
                      'Combat round submitted - waiting for other participants'
                    elsif result.is_a?(Hash) && result[:message]
                      result[:message]
                    else
                      'Combat action selected'
                    end

                    complete_interaction.call
                    next {
                      success: true,
                      message: message,
                      data: result.is_a?(Hash) && result[:type] != :quickmenu ? result : nil,
                      next_menu: new_menu,
                      interaction_id: new_interaction_id,
                      interaction_type: interaction[:type],
                      context: interaction[:context]
                    }.to_json
                  elsif participant
                    response.status = 403
                    next { success: false, error: 'Not authorized for this combat interaction' }.to_json
                  end
                end

                # Activity quickmenu
                if context[:activity] || context['activity']
                  participant_id = context[:participant_id] || context['participant_id']
                  participant = ActivityParticipant[participant_id] if participant_id

                  if participant && participant.char_id == char_instance.character_id
                    handler = ActivityQuickmenuHandler.new(participant, char_instance)
                    result = handler.handle_response(response_value)

                    new_menu = result.is_a?(Hash) && result[:type] == :quickmenu ? result : nil
                    new_interaction_id = nil

                    if new_menu && new_menu[:options]&.any?
                      new_interaction_id = SecureRandom.uuid
                      new_menu_data = {
                        interaction_id: new_interaction_id,
                        type: 'quickmenu',
                        prompt: new_menu[:prompt],
                        options: new_menu[:options],
                        context: new_menu[:context] || {},
                        created_at: Time.now.iso8601
                      }
                      OutputHelper.store_agent_interaction(char_instance, new_interaction_id, new_menu_data)
                    end

                    message = if result.nil?
                      'Activity choice submitted - waiting for other participants'
                    elsif result == :round_resolved
                      'Round resolved'
                    elsif result.is_a?(Hash) && result[:message]
                      result[:message]
                    else
                      'Activity action selected'
                    end

                    complete_interaction.call
                    next {
                      success: true,
                      message: message,
                      data: result.is_a?(Hash) && result[:type] != :quickmenu ? result : nil,
                      next_menu: new_menu,
                      interaction_id: new_interaction_id,
                      interaction_type: interaction[:type],
                      context: interaction[:context]
                    }.to_json
                  elsif participant
                    response.status = 403
                    next { success: false, error: 'Not authorized for this activity interaction' }.to_json
                  end
                end

                # Disambiguation for movement commands
                if context[:action] == 'walk' || context['action'] == 'walk'
                  result = DisambiguationHandler.process_response(
                    char_instance,
                    interaction,
                    response_value
                  )

                  complete_interaction.call if result.respond_to?(:success) ? result.success : true
                  next {
                    success: result.success,
                    message: result.message,
                    data: result.data,
                    interaction_type: interaction[:type],
                    context: interaction[:context]
                  }.to_json
                end

                # Route quickmenu responses through InputInterceptorService handlers
                handler = context[:handler] || context['handler']
                command = context[:command] || context['command']
                warn "[RESPOND_CONTEXT] handler=#{handler}, command=#{command}, context_keys=#{context.keys.inspect}, interaction_type=#{interaction[:type]}"
                if (handler || command) && interaction[:type] == 'quickmenu'
                  result = InputInterceptorService.send(
                    :handle_quickmenu_response,
                    char_instance,
                    interaction,
                    response_value
                  )

                  warn "[CARDS] Result from handle_quickmenu_response: type=#{result[:type]}, prompt=#{result[:prompt]&.inspect}, options=#{result[:options]&.length}"
                  complete_interaction.call if result[:success] != false
                  next {
                    success: result[:success] != false,
                    type: result[:type],
                    message: result[:message] || result[:error],
                    error: result[:error],
                    prompt: result[:prompt],
                    options: result[:options],
                    data: result[:data],
                    interaction_type: interaction[:type],
                    context: result[:context],
                    interaction_id: result[:interaction_id]
                  }.compact.to_json
                end

                # Form handling based on command context
                if interaction[:type] == 'form'
                  result = FormHandlerService.process(char_instance, context, response_value)
                  complete_interaction.call if result[:success]
                  next {
                    success: result[:success],
                    message: result[:message],
                    error: result[:error],
                    interaction_type: interaction[:type],
                    context: interaction[:context]
                  }.compact.to_json
                end

                # Default response for other interaction types
                complete_interaction.call
                {
                  success: true,
                  message: 'Response recorded',
                  interaction_type: interaction[:type],
                  response: response_value,
                  context: interaction[:context]
                }.to_json
              rescue JSON::ParserError
                response.status = 400
                { success: false, error: 'Invalid JSON in request body' }.to_json
              rescue => e
                puts "[API_ERROR] /api/agent/interactions/respond: #{e.class}: #{e.message}"
                puts e.backtrace.first(10).join("\n")
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end

            # Get a specific interaction
            r.get do
              begin
                interaction = OutputHelper.get_agent_interaction(char_instance.id, interaction_id)
                unless interaction
                  response.status = 404
                  next { success: false, error: 'Interaction not found or expired' }.to_json
                end

                {
                  success: true,
                  interaction: {
                    interaction_id: interaction[:interaction_id],
                    type: interaction[:type],
                    prompt: interaction[:prompt],
                    title: interaction[:title],
                    options: interaction[:options],
                    fields: interaction[:fields],
                    created_at: interaction[:created_at]
                  }.compact
                }.to_json
              rescue => e
                puts "[API_ERROR] /api/agent/interactions/:id: #{e.class}: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end

            # Cancel/dismiss an interaction
            r.post 'cancel' do
              begin
                interaction = OutputHelper.get_agent_interaction(char_instance.id, interaction_id)
                unless interaction
                  response.status = 404
                  next { success: false, error: 'Interaction not found or expired' }.to_json
                end

                OutputHelper.complete_interaction(char_instance.id, interaction_id)
                { success: true, message: 'Interaction cancelled' }.to_json
              rescue => e
                puts "[API_ERROR] /api/agent/interactions/cancel: #{e.class}: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end
          end
        end

        # Cleanup endpoint - for test cleanup after multi-agent tests
        r.post 'cleanup' do
          begin
            data = JSON.parse(request.body.read)
            cleaned = { interactions: 0, online_status: false, fights: 0, activities: 0, teleported: false }

            # Clear pending interactions for this agent
            if data['clear_interactions'] != false
              if defined?(REDIS_POOL)
                REDIS_POOL.with do |redis|
                  # Get all pending interaction IDs
                  list_key = "agent_pending:#{char_instance.id}"
                  interaction_ids = redis.smembers(list_key)

                  interaction_ids.each do |iid|
                    key = "agent_interaction:#{char_instance.id}:#{iid}"
                    redis.del(key)
                    cleaned[:interactions] += 1
                  end

                  redis.del(list_key)
                end
              end
            end

            # Leave any activities this agent is participating in
            if data['leave_activities'] != false
              ActivityParticipant.where(char_id: char_instance.character_id).each do |participant|
                activity_instance = ActivityInstance[participant.instance_id]
                if activity_instance && activity_instance.completed_at.nil?
                  # Remove participant from activity
                  participant.delete
                  cleaned[:activities] += 1

                  # If no participants left, complete the activity
                  remaining = ActivityParticipant.where(instance_id: activity_instance.id).count
                  if remaining == 0
                    activity_instance.update(completed_at: Time.now, running: false)
                  end
                end
              end
            end

            # Teleport to a specific room (for combat arena tests)
            if data['teleport_to_room']
              room_id = data['teleport_to_room'].to_i
              target_room = Room[room_id]
              if target_room
                # Calculate center position with small offset based on agent index
                center_x = ((target_room.min_x || 0) + (target_room.max_x || 40)) / 2.0
                center_y = ((target_room.min_y || 0) + (target_room.max_y || 40)) / 2.0

                # Apply small offset if set_position_offset is provided (e.g., 0, 1, 2...)
                offset = (data['set_position_offset'] || 0).to_i
                offset_x = (offset % 3 - 1) * 4  # -4, 0, or 4 feet
                offset_y = (offset / 3 - 1) * 4  # -4, 0, or 4 feet

                char_instance.update(
                  current_room_id: room_id,
                  x: center_x + offset_x,
                  y: center_y + offset_y
                )
                cleaned[:teleported] = true
                cleaned[:room_id] = room_id
                cleaned[:room_name] = target_room.name
                cleaned[:position] = { x: center_x + offset_x, y: center_y + offset_y }
              end
            end

            # Set agent offline
            if data['set_offline'] != false
              char_instance.update(online: false)
              cleaned[:online_status] = true
            end

            # End active fights for this agent (optional, requires flag)
            if data['end_fights']
              FightParticipant.where(character_instance_id: char_instance.id).each do |fp|
                fight = fp.fight
                next unless fight && !%w[complete completed].include?(fight.status)

                # Remove participant from fight by marking as knocked out
                fp.update(defeated_at: Time.now, is_knocked_out: true)
                cleaned[:fights] += 1

                # Reload fight to get fresh participant data
                fight.reload

                # If fight has no active participants, end it
                if fight.active_participants.count == 0
                  fight.update(status: 'complete', ended_at: Time.now)
                end
              end
            end

            { success: true, cleaned: cleaned }.to_json
          rescue JSON::ParserError
            response.status = 400
            { success: false, error: 'Invalid request format' }.to_json
          rescue => e
            puts "[API_ERROR] /api/agent/cleanup: #{e.class}: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # Submit a ticket from agent (for simulated testers/players)
        r.post 'ticket' do
          begin
            data = JSON.parse(request.body.read)

            category = data['category']&.to_s&.strip
            subject = data['subject']&.to_s&.strip
            content = data['content']&.to_s&.strip

            # Validate required fields
            if category.nil? || category.empty?
              response.status = 400
              next { success: false, error: 'Category is required' }.to_json
            end

            if subject.nil? || subject.empty?
              response.status = 400
              next { success: false, error: 'Subject is required' }.to_json
            end

            if content.nil? || content.empty?
              response.status = 400
              next { success: false, error: 'Content is required' }.to_json
            end

            # Validate category
            valid_categories = %w[bug typo behaviour behavior request suggestion other]
            unless valid_categories.include?(category.downcase)
              response.status = 400
              next { success: false, error: "Invalid category. Valid: #{valid_categories.join(', ')}" }.to_json
            end

            # Normalize category (behaviour -> behavior for US spelling support)
            category = 'behaviour' if category.downcase == 'behavior'

            # Build game context from current state
            room = char_instance.current_room
            game_context = {
              room_id: room&.id,
              room_name: room&.name,
              character_id: char_instance.character_id,
              character_name: char_instance.character&.name,
              submitted_by_agent: true,
            }.to_json

            # Create the ticket (character_id stored in game_context)
            ticket = Ticket.create(
              user_id: char_instance.character&.user_id,
              room_id: room&.id,
              category: category.downcase,
              subject: subject,
              content: content,
              game_context: game_context,
              status: 'open'
            )

            {
              success: true,
              ticket_id: ticket.id,
              message: "Ticket ##{ticket.id} submitted successfully"
            }.to_json
          rescue JSON::ParserError
            response.status = 400
            { success: false, error: 'Invalid JSON' }.to_json
          rescue => e
            puts "[API_ERROR] /api/agent/ticket: #{e.class}: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end
      end

      # Journey API (Bearer token or session auth, for world travel GUI)
      r.on 'journey' do
        char_instance = character_instance_from_token || current_character_instance
        unless char_instance
          response.status = 401
          next { success: false, error: 'Unauthorized' }.to_json
        end

        # GET /api/journey/map - World map data for player's current world
        r.get 'map' do
          begin
            result = JourneyService.world_map_data(char_instance)
            result.to_json
          rescue StandardError => e
            warn "[JourneyAPI] Error getting map: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # GET /api/journey/hexes - Chunked hex data for bounding box region
        r.get 'hexes' do
          begin
            world = char_instance.current_room&.location&.world
            unless world
              response.status = 404
              next { success: false, error: 'No world found for current location' }.to_json
            end

            # Parse bounding box params, cap at 60x60 degrees
            min_lat = (r.params['min_lat'] || 0).to_f
            max_lat = (r.params['max_lat'] || 0).to_f
            min_lon = (r.params['min_lon'] || 0).to_f
            max_lon = (r.params['max_lon'] || 0).to_f

            # Clamp region size to prevent abuse
            max_span = 60.0
            if (max_lat - min_lat) > max_span
              max_lat = min_lat + max_span
            end
            if (max_lon - min_lon) > max_span
              max_lon = min_lon + max_span
            end

            traversable_only = r.params['traversable_only'] != 'false'

            # DISTINCT ON query: one hex per 1-degree grid cell (matches ZonemapService pattern)
            sql = +"SELECT DISTINCT ON (cell_x, cell_y) " \
                  "id, terrain_type, latitude, longitude, traversable, " \
                  "feature_n, feature_ne, feature_se, feature_s, feature_sw, feature_nw, " \
                  "FLOOR(longitude - ?::float8)::int AS cell_x, " \
                  "FLOOR(?::float8 - latitude)::int AS cell_y " \
                  "FROM world_hexes " \
                  "WHERE world_id = ? AND longitude >= ? AND longitude < ? AND latitude > ? AND latitude <= ?"

            bind_params = [min_lon, max_lat, world.id, min_lon - 0.5, max_lon + 1.5, min_lat - 0.5, max_lat + 0.5]

            if traversable_only
              sql << " AND (traversable IS NULL OR traversable = true)"
            end

            sql << " ORDER BY cell_x, cell_y, " \
                   "((longitude - ?) - FLOOR(longitude - ?) - 0.5)^2 + " \
                   "((? - latitude) - FLOOR(? - latitude) - 0.5)^2"
            bind_params.concat([min_lon, min_lon, max_lat, max_lat])

            rows = DB.fetch(sql, *bind_params).all

            max_cell_x = (max_lon - min_lon).ceil
            max_cell_y = (max_lat - min_lat).ceil

            hexes = rows.filter_map do |row|
              cx = row[:cell_x]
              cy = row[:cell_y]
              next unless cx >= 0 && cx < max_cell_x && cy >= 0 && cy < max_cell_y

              features = {}
              %w[n ne se s sw nw].each do |dir|
                val = row[:"feature_#{dir}"]
                features[dir] = val if val
              end

              {
                cell_x: cx, cell_y: cy,
                lat: row[:latitude]&.round(2), lon: row[:longitude]&.round(2),
                terrain: row[:terrain_type],
                traversable: row[:traversable].nil? ? true : row[:traversable],
                features: features.empty? ? nil : features
              }.compact
            end

            # Locations in the same region
            w_id = world.id
            locations = Location.where(world_id: w_id)
                                .exclude(globe_hex_id: nil)
                                .where { (longitude >= min_lon) & (longitude < max_lon + 1) }
                                .where { (latitude >= min_lat) & (latitude < max_lat + 1) }
                                .all
                                .map do |loc|
              {
                id: loc.id, name: loc.name,
                city_name: loc.respond_to?(:city_name) ? loc.city_name : nil,
                latitude: loc.latitude&.round(2), longitude: loc.longitude&.round(2),
                has_port: loc.respond_to?(:has_port?) ? loc.has_port? : false,
                has_station: loc.respond_to?(:has_train_station?) ? loc.has_train_station? : false
              }.compact
            end

            {
              success: true,
              region: { min_lat: min_lat, max_lat: max_lat, min_lon: min_lon, max_lon: max_lon },
              hexes: hexes,
              locations: locations
            }.to_json
          rescue StandardError => e
            warn "[JourneyAPI] Error getting hexes: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # GET /api/journey/destinations - Available destinations with distance/time
        r.get 'destinations' do
          begin
            destinations = JourneyService.available_destinations(char_instance)
            { success: true, destinations: destinations }.to_json
          rescue StandardError => e
            warn "[JourneyAPI] Error getting destinations: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # GET /api/journey/options/:location_id - Travel options for destination
        r.get 'options', Integer do |location_id|
          begin
            destination = Location[location_id]
            unless destination
              response.status = 404
              next { success: false, error: 'Destination not found' }.to_json
            end

            result = JourneyService.travel_options(char_instance, destination)
            result.to_json
          rescue StandardError => e
            warn "[JourneyAPI] Error getting options: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # POST /api/journey/start - Start solo journey
        r.post 'start' do
          begin
            params = JSON.parse(request.body.read, symbolize_names: true)
            destination = Location[params[:destination_id]]

            unless destination
              response.status = 404
              next { success: false, error: 'Destination not found' }.to_json
            end

            result = JourneyService.start_journey(
              char_instance,
              destination: destination,
              travel_mode: params[:travel_mode],
              flashback_mode: params[:flashback_mode]
            )

            result.to_json
          rescue JSON::ParserError
            response.status = 400
            { success: false, error: 'Invalid JSON' }.to_json
          rescue StandardError => e
            warn "[JourneyAPI] Error starting journey: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # GET /api/journey/party - Get current assembling party
        r.get 'party' do
          begin
            party = TravelParty.where(leader_id: char_instance.id, status: 'assembling').first
            party ||= TravelPartyMember.where(character_instance_id: char_instance.id)
                                       .eager(:party)
                                       .all
                                       .map(&:party)
                                       .find { |p| p&.status == 'assembling' }

            if party
              { success: true, party: party.status_summary }.to_json
            else
              { success: true, party: nil }.to_json
            end
          rescue StandardError => e
            warn "[JourneyAPI] Error getting party: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # POST /api/journey/party/create - Create travel party
        r.post 'party', 'create' do
          begin
            params = JSON.parse(request.body.read, symbolize_names: true)
            destination = Location[params[:destination_id]]

            unless destination
              response.status = 404
              next { success: false, error: 'Destination not found' }.to_json
            end

            # Check for existing assembling party
            existing = TravelParty.where(leader_id: char_instance.id, status: 'assembling').first
            if existing
              response.status = 400
              next { success: false, error: 'You already have an assembling party. Cancel it first.' }.to_json
            end

            party = TravelParty.create_for(
              char_instance,
              destination,
              travel_mode: params[:travel_mode],
              flashback_mode: params[:flashback_mode]
            )

            { success: true, party: party.status_summary }.to_json
          rescue JSON::ParserError
            response.status = 400
            { success: false, error: 'Invalid JSON' }.to_json
          rescue StandardError => e
            warn "[JourneyAPI] Error creating party: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # POST /api/journey/party/invite - Send party invite
        r.post 'party', 'invite' do
          begin
            params = JSON.parse(request.body.read, symbolize_names: true)
            target_name = params[:name]&.strip

            if target_name.nil? || target_name.empty?
              response.status = 400
              next({ success: false, error: 'Target name is required' }.to_json)
            end

            party = TravelParty.where(leader_id: char_instance.id, status: 'assembling').first
            unless party
              response.status = 400
              next { success: false, error: 'You have no assembling party' }.to_json
            end

            # Find target by name - must be in same location
            current_location = char_instance.current_room&.location
            unless current_location
              response.status = 400
              next({ success: false, error: 'You must be in a valid location to invite party members' }.to_json)
            end

            target = CharacterInstance
                     .eager(:character)
                     .where(online: true)
                     .where(current_room_id: Room.where(location_id: current_location.id).select(:id))
                     .all
                     .find { |ci| ci.character&.name&.downcase&.include?(target_name.downcase) }

            unless target
              response.status = 404
              next { success: false, error: "Cannot find '#{target_name}' in this area" }.to_json
            end

            if target.id == char_instance.id
              response.status = 400
              next { success: false, error: 'You are already in the party' }.to_json
            end

            invite_result = party.invite!(target)
            if invite_result[:success]
              { success: true, message: "Invited #{target.full_name}", party: party.status_summary }.to_json
            else
              response.status = 400
              { success: false, error: invite_result[:error] || 'Could not send invite' }.to_json
            end
          rescue JSON::ParserError
            response.status = 400
            { success: false, error: 'Invalid JSON' }.to_json
          rescue StandardError => e
            warn "[JourneyAPI] Error inviting: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # POST /api/journey/party/respond - Accept/decline party invite
        r.post 'party', 'respond' do
          begin
            params = JSON.parse(request.body.read, symbolize_names: true)
            party_id = params[:party_id]
            response_action = params[:response]&.to_s # 'accept' or 'decline'

            party = TravelParty[party_id]
            unless party
              response.status = 404
              next { success: false, error: 'Party not found' }.to_json
            end

            membership = party.get_membership(char_instance)
            unless membership
              response.status = 403
              next { success: false, error: 'You are not invited to this party' }.to_json
            end

            case response_action
            when 'accept'
              if membership.accept!
                { success: true, message: 'You have joined the travel party' }.to_json
              else
                { success: false, error: 'Could not accept invite' }.to_json
              end
            when 'decline'
              if membership.decline!
                { success: true, message: 'You have declined the invitation' }.to_json
              else
                { success: false, error: 'Could not decline invite' }.to_json
              end
            else
              response.status = 400
              { success: false, error: "Invalid response. Use 'accept' or 'decline'" }.to_json
            end
          rescue JSON::ParserError
            response.status = 400
            { success: false, error: 'Invalid JSON' }.to_json
          rescue StandardError => e
            warn "[JourneyAPI] Error responding to invite: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # POST /api/journey/party/launch - Launch party journey
        r.post 'party', 'launch' do
          begin
            party = TravelParty.where(leader_id: char_instance.id, status: 'assembling').first
            unless party
              response.status = 400
              next { success: false, error: 'You have no assembling party to launch' }.to_json
            end

            result = party.launch!
            result.to_json
          rescue StandardError => e
            warn "[JourneyAPI] Error launching party: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end

        # POST /api/journey/party/cancel - Cancel assembling party
        r.post 'party', 'cancel' do
          begin
            party = TravelParty.where(leader_id: char_instance.id, status: 'assembling').first
            unless party
              response.status = 400
              next { success: false, error: 'You have no assembling party to cancel' }.to_json
            end

            party.cancel!
            { success: true, message: 'Party cancelled' }.to_json
          rescue StandardError => e
            warn "[JourneyAPI] Error cancelling party: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end
      end

      # Media Sync API (Bearer token or session auth, for YouTube watch parties)
      r.on 'media' do
        response['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'

        char_instance = character_instance_from_token || current_character_instance
        unless char_instance
          response.status = 401
          next { success: false, error: 'Unauthorized' }.to_json
        end

        room_id = char_instance.current_room_id

        # Get current session state for polling
        r.get 'session' do
          begin
            session_data = MediaSyncService.fetch_room_session(room_id)
            { success: true, session: session_data }.to_json
          rescue StandardError => e
            warn "[MediaSync] Error getting session: #{e.message}"
            { success: true, session: nil }.to_json
          end
        end

        # Get events since timestamp for polling
        r.get 'events' do
          begin
            since = request.params['since']
            events = MediaSyncService.room_events(room_id, since_timestamp: since)
            { success: true, events: events, timestamp: Time.now.iso8601 }.to_json
          rescue StandardError => e
            warn "[MediaSync] Error getting events: #{e.message}"
            { success: true, events: [], timestamp: Time.now.iso8601 }.to_json
          end
        end

        # Start YouTube sync session
        r.post 'youtube' do
          begin
            data = JSON.parse(request.body.read)
            video_id = data['video_id']
            title = data['title']
            duration = data['duration']

            unless video_id
              response.status = 400
              next { success: false, error: 'video_id is required' }.to_json
            end

            session = MediaSyncService.start_youtube(
              room_id: room_id,
              host: char_instance,
              video_id: video_id,
              title: title,
              duration: duration
            )

            { success: true, session: session.to_sync_hash }.to_json
          rescue MediaSyncService::SessionConflictError => e
            response.status = 409
            { success: false, error: e.message }.to_json
          rescue StandardError => e
            warn "[MediaSync] Error starting YouTube: #{e.message}"
            response.status = 500
            { success: false, error: e.message }.to_json
          end
        end

        # Register screen/tab share
        r.post 'register_share' do
          begin
            data = JSON.parse(request.body.read)
            peer_id = data['peer_id']
            share_type = data['share_type'] || 'screen'
            has_audio = data['has_audio'] || false

            unless peer_id
              response.status = 400
              next { success: false, error: 'peer_id is required' }.to_json
            end

            session = MediaSyncService.start_screen_share(
              room_id: room_id,
              host: char_instance,
              peer_id: peer_id,
              share_type: share_type,
              has_audio: has_audio
            )

            { success: true, session: session.to_sync_hash }.to_json
          rescue MediaSyncService::SessionConflictError => e
            response.status = 409
            { success: false, error: e.message }.to_json
          rescue StandardError => e
            warn "[MediaSync] Error starting share: #{e.message}"
            response.status = 500
            { success: false, error: e.message }.to_json
          end
        end

        # Request screen/tab share from popout — sends event to webclient
        r.post 'request_share' do
          begin
            data = JSON.parse(request.body.read)
            share_type = data['share_type'] || 'screen'
            request_audio = data['request_audio'] || false

            # Broadcast event to room — webclient picks it up via polling
            # and calls getDisplayMedia() in its own context
            MediaSyncService.send(:broadcast_to_room, room_id, {
              type: 'share_requested',
              share_type: share_type,
              request_audio: request_audio,
              requester_id: char_instance.id,
              requester_name: char_instance.character.full_name
            })

            { success: true }.to_json
          rescue StandardError => e
            warn "[MediaSync] Error requesting share: #{e.message}"
            response.status = 500
            { success: false, error: e.message }.to_json
          end
        end

        # Playback control (host only)
        r.post 'control' do
          begin
            data = JSON.parse(request.body.read)
            session_id = data['session_id']
            action = data['action']

            session = MediaSession[session_id]
            unless session
              response.status = 404
              next { success: false, error: 'Session not found' }.to_json
            end

            if session.room_id != room_id
              response.status = 403
              next { success: false, error: 'Session is not in your room' }.to_json
            end

            unless session.host_id == char_instance.id
              response.status = 403
              next { success: false, error: 'Only the host can control playback' }.to_json
            end

            result = case action
                     when 'play'
                       MediaSyncService.play(session, position: data['position'])
                     when 'pause'
                       MediaSyncService.pause(session)
                     when 'seek'
                       MediaSyncService.seek(session, data['position'])
                     when 'buffering'
                       MediaSyncService.buffering(session, position: data['position'])
                     when 'rate'
                       MediaSyncService.set_rate(session, data['playback_rate'])
                     when 'next_track'
                       if session.playlist_id
                         playlist = MediaPlaylist[session.playlist_id]
                         next_pos = (session.playlist_position || 0) + 1
                         next_item = playlist&.items_dataset&.where(position: next_pos)&.first
                         if next_item
                           session.update(
                             youtube_video_id: next_item.youtube_video_id,
                             youtube_title: next_item.display_title,
                             youtube_duration_seconds: next_item.duration_seconds,
                             playlist_position: next_pos,
                             playback_position: 0.0,
                             playback_started_at: Time.now,
                             is_playing: true
                           )
                           MediaSyncService.broadcast_update(session)
                         else
                           # End of playlist
                           MediaSyncService.end_room_session(session.room_id)
                           { success: true, ended: true }
                         end
                       else
                         { success: false, error: 'No playlist associated with session' }
                       end
                     when 'end'
                       MediaSyncService.end_room_session(session.room_id)
                       { success: true }
                     else
                       { success: false, error: "Unknown action: #{action}" }
                     end

            result.to_json
          rescue JSON::ParserError
            response.status = 400
            { success: false, error: 'Invalid JSON' }.to_json
          rescue StandardError => e
            warn "[MediaSync] Control error: #{e.message}"
            response.status = 500
            { success: false, error: e.message }.to_json
          end
        end

        # Signal all clients in room to open the media player
        r.post 'open_player' do
          begin
            session = MediaSession.active_in_room(room_id)
            unless session
              response.status = 404
              next { success: false, error: 'No active session' }.to_json
            end

            MediaSyncService.send(:broadcast_to_room, room_id, {
              type: 'media_open_player',
              session: session.to_sync_hash
            })

            { success: true }.to_json
          rescue StandardError => e
            warn "[MediaSync] Open player error: #{e.message}"
            response.status = 500
            { success: false, error: e.message }.to_json
          end
        end

        # Host heartbeat
        r.post 'heartbeat' do
          begin
            session = MediaSession.active_in_room(room_id)
            if session && session.host_id == char_instance.id
              MediaSyncService.heartbeat(session)
            end
            { success: true }.to_json
          rescue StandardError => e
            warn "[MediaSync] Heartbeat error: #{e.message}"
            { success: true }.to_json
          end
        end

        # Viewer join session
        r.post 'join' do
          begin
            data = JSON.parse(request.body.read)
            session_id = data['session_id']
            peer_id = data['peer_id']

            session = MediaSession[session_id]
            unless session
              response.status = 404
              next { success: false, error: 'Session not found' }.to_json
            end

            if session.room_id != room_id
              response.status = 403
              next { success: false, error: 'Session is not in your room' }.to_json
            end

            unless session.active? || session.paused?
              response.status = 409
              next { success: false, error: 'Session is not active' }.to_json
            end

            session_data = MediaSyncService.viewer_join(session, char_instance, peer_id)
            { success: true, session: session_data }.to_json
          rescue StandardError => e
            warn "[MediaSync] Join error: #{e.message}"
            response.status = 500
            { success: false, error: e.message }.to_json
          end
        end

        # Viewer connected (WebRTC established)
        r.post 'viewer_connected' do
          begin
            data = JSON.parse(request.body.read)
            session_id = data['session_id']

            session = MediaSession[session_id]
            if session && session.room_id == room_id && (session.active? || session.paused?)
              MediaSyncService.viewer_connected(session, char_instance)
            end
            { success: true }.to_json
          rescue StandardError => e
            warn "[MediaSync] Viewer connected error: #{e.message}"
            { success: true }.to_json
          end
        end

        # Viewer disconnected
        r.post 'viewer_disconnected' do
          begin
            data = JSON.parse(request.body.read)
            session_id = data['session_id']

            session = MediaSession[session_id]
            if session && session.room_id == room_id && (session.active? || session.paused?)
              MediaSyncService.viewer_disconnected(session, char_instance)
            end
            { success: true }.to_json
          rescue StandardError => e
            warn "[MediaSync] Viewer disconnected error: #{e.message}"
            { success: true }.to_json
          end
        end

        # YouTube video info lookup
        r.on 'youtube' do
          r.post 'info' do
            begin
              data = JSON.parse(request.body.read)
              url = data['url']

              unless url && !url.strip.empty?
                response.status = 400
                next { success: false, error: 'url is required' }.to_json
              end

              info = YouTubeMetadataService.fetch_from_url(url)
              unless info
                response.status = 422
                next { success: false, error: 'Could not fetch video info. Check the URL or try again.' }.to_json
              end

              { success: true, video: info }.to_json
            rescue JSON::ParserError
              response.status = 400
              { success: false, error: 'Invalid JSON' }.to_json
            rescue StandardError => e
              warn "[MediaSync] YouTube info error: #{e.message}"
              response.status = 500
              { success: false, error: e.message }.to_json
            end
          end
        end

        # Playlist management
        r.on 'playlists' do
          character = char_instance.character

          # List character's playlists
          r.is do
            r.get do
              playlists = MediaPlaylist.where(character_id: character.id).order(:name).all
              { success: true, playlists: playlists.map(&:to_hash) }.to_json
            end

            # Create playlist
            r.post do
              begin
                data = JSON.parse(request.body.read)
                name = data['name']&.strip

                if name.nil? || name.empty?
                  response.status = 400
                  next { success: false, error: 'name is required' }.to_json
                end

                playlist = MediaPlaylist.create(character_id: character.id, name: name)
                { success: true, playlist: playlist.to_hash }.to_json
              rescue Sequel::UniqueConstraintViolation
                response.status = 409
                { success: false, error: 'A playlist with that name already exists' }.to_json
              rescue JSON::ParserError
                response.status = 400
                { success: false, error: 'Invalid JSON' }.to_json
              rescue StandardError => e
                warn "[MediaSync] Create playlist error: #{e.message}"
                response.status = 500
                { success: false, error: e.message }.to_json
              end
            end
          end

          r.on Integer do |playlist_id|
            playlist = MediaPlaylist[playlist_id]
            unless playlist && playlist.character_id == character.id
              response.status = 404
              next { success: false, error: 'Playlist not found' }.to_json
            end

            r.is do
              # Delete playlist
              r.delete do
                playlist.destroy
                { success: true }.to_json
              end
            end

            # Playlist items
            r.on 'items' do
              # Add item to playlist
              r.is do
                r.post do
                  begin
                    data = JSON.parse(request.body.read)
                    video_id = data['youtube_video_id']

                    unless video_id && !video_id.strip.empty?
                      response.status = 400
                      next { success: false, error: 'youtube_video_id is required' }.to_json
                    end

                    item = playlist.add_item!(
                      youtube_video_id: video_id,
                      title: data['title'],
                      thumbnail_url: data['thumbnail_url'],
                      duration_seconds: data['duration_seconds'],
                      is_embeddable: data.fetch('is_embeddable', true)
                    )
                    { success: true, item: item.to_hash }.to_json
                  rescue JSON::ParserError
                    response.status = 400
                    { success: false, error: 'Invalid JSON' }.to_json
                  rescue StandardError => e
                    warn "[MediaSync] Add playlist item error: #{e.message}"
                    response.status = 500
                    { success: false, error: e.message }.to_json
                  end
                end
              end

              # Remove item by ID
              r.on Integer do |item_id|
                r.delete do
                  item = MediaPlaylistItem[item_id]
                  unless item && item.media_playlist_id == playlist.id
                    response.status = 404
                    next { success: false, error: 'Item not found' }.to_json
                  end
                  playlist.remove_item!(item.position)
                  { success: true }.to_json
                end
              end
            end

            # Play playlist as sync session
            r.post 'play' do
              begin
                first_item = playlist.items_dataset.order(:position).first
                unless first_item
                  response.status = 400
                  next { success: false, error: 'Playlist is empty' }.to_json
                end

                session = MediaSyncService.start_youtube(
                  room_id: room_id,
                  host: char_instance,
                  video_id: first_item.youtube_video_id,
                  title: first_item.display_title,
                  duration: first_item.duration_seconds,
                  playlist_id: playlist.id,
                  playlist_position: 0
                )

                { success: true, session: session.to_sync_hash }.to_json
              rescue MediaSyncService::SessionConflictError => e
                response.status = 409
                { success: false, error: e.message }.to_json
              rescue StandardError => e
                warn "[MediaSync] Play playlist error: #{e.message}"
                response.status = 500
                { success: false, error: e.message }.to_json
              end
            end
          end
        end

        # Media library (saved videos)
        r.on 'library' do
          character = char_instance.character

          r.is do
            r.get do
              videos = MediaLibrary.where(character_id: character.id, media_type: 'vid').order(:name).all
              items = videos.map { |v| { id: v.id, name: v.name, youtube_video_id: v.content } }
              { success: true, videos: items }.to_json
            end

            r.post do
              begin
                data = JSON.parse(request.body.read)
                name = data['name']&.strip
                video_id = data['youtube_video_id']&.strip

                if name.nil? || name.empty? || video_id.nil? || video_id.empty?
                  response.status = 400
                  next { success: false, error: 'name and youtube_video_id are required' }.to_json
                end

                entry = MediaLibrary.create(
                  character_id: character.id,
                  media_type: 'vid',
                  name: name,
                  content: video_id
                )
                { success: true, video: { id: entry.id, name: entry.name, youtube_video_id: entry.content } }.to_json
              rescue JSON::ParserError
                response.status = 400
                { success: false, error: 'Invalid JSON' }.to_json
              rescue StandardError => e
                warn "[MediaSync] Save to library error: #{e.message}"
                response.status = 500
                { success: false, error: e.message }.to_json
              end
            end
          end

          r.on Integer do |lib_id|
            r.delete do
              entry = MediaLibrary[lib_id]
              unless entry && entry.character_id == char_instance.character.id
                response.status = 404
                next { success: false, error: 'Not found' }.to_json
              end
              entry.destroy
              { success: true }.to_json
            end
          end
        end

        # User media preferences
        r.on 'preferences' do
          user = char_instance.character.user

          r.is do
            r.get do
              { success: true, preferences: user.media_preferences }.to_json
            end

            r.post do
              begin
                data = JSON.parse(request.body.read)
                allowed = {}
                allowed['autoplay'] = !!data['autoplay'] if data.key?('autoplay')
                allowed['start_muted'] = !!data['start_muted'] if data.key?('start_muted')

                user.update_media_preferences!(allowed)
                { success: true, preferences: user.media_preferences }.to_json
              rescue JSON::ParserError
                response.status = 400
                { success: false, error: 'Invalid JSON' }.to_json
              rescue StandardError => e
                warn "[MediaSync] Preferences error: #{e.message}"
                response.status = 500
                { success: false, error: e.message }.to_json
              end
            end
          end
        end
      end

      # Profile API (for profile pictures, sections, videos, settings)
      r.on 'profiles' do
        r.on Integer do |character_id|
          # Verify character exists before any operations
          profile_character = Character[character_id]
          unless profile_character
            response.status = 404
            r.halt({ success: false, error: 'Character not found' }.to_json)
          end

          # Helper to verify ownership - only profile owner can modify
          owner_only = lambda {
            char_instance = character_instance_from_token
            unless char_instance&.character_id == character_id
              response.status = 403
              r.halt({ success: false, error: 'Not authorized' }.to_json)
            end
            char_instance
          }

          # Limits for profile elements to prevent abuse
          max_pictures = 20
          max_sections = 20
          max_videos = 10

          # Pictures
          r.on 'pictures' do
            r.is do
              r.post do
                begin
                  char_instance = owner_only.call

                  # Check element limit
                  if ProfilePicture.where(character_id: character_id).count >= max_pictures
                    response.status = 400
                    next { success: false, error: "Maximum pictures limit reached (#{max_pictures})" }.to_json
                  end

                  result = ProfileUploadService.upload_picture(r.params['file'], character_id)

                  if result[:success]
                    max_pos = ProfilePicture.where(character_id: character_id).max(:position) || -1
                    picture = ProfilePicture.create(
                      character_id: character_id,
                      url: result[:data][:url],
                      position: max_pos + 1
                    )
                    { success: true, picture: { id: picture.id, url: picture.url, position: picture.position } }.to_json
                  else
                    response.status = 400
                    { success: false, error: result[:message] }.to_json
                  end
                rescue StandardError => e
                  warn "[ProfileAPI] Upload picture error: #{e.message}"
                  response.status = 500
                  { success: false, error: 'Internal server error' }.to_json
                end
              end
            end

            r.is 'reorder' do
              r.patch do
                begin
                  owner_only.call
                  data = JSON.parse(request.body.read)
                  positions = data['positions'] || {}

                  positions.each do |id, pos|
                    next unless pos.to_s.match?(/\A\d+\z/) && pos.to_i >= 0
                    pic = ProfilePicture[id.to_i]
                    pic&.update(position: pos.to_i) if pic&.character_id == character_id
                  end

                  { success: true }.to_json
                rescue JSON::ParserError
                  response.status = 400
                  { success: false, error: 'Invalid JSON' }.to_json
                rescue StandardError => e
                  warn "[ProfileAPI] Reorder pictures error: #{e.message}"
                  response.status = 500
                  { success: false, error: 'Internal server error' }.to_json
                end
              end
            end

            r.on Integer do |picture_id|
              r.is do
                r.delete do
                  begin
                    owner_only.call
                    picture = ProfilePicture[picture_id]

                    if picture&.character_id == character_id
                      ProfileUploadService.delete(picture.url)
                      picture.delete
                      { success: true }.to_json
                    else
                      response.status = 404
                      { success: false, error: 'Picture not found' }.to_json
                    end
                  rescue StandardError => e
                    warn "[ProfileAPI] Delete picture error: #{e.message}"
                    response.status = 500
                    { success: false, error: 'Internal server error' }.to_json
                  end
                end
              end
            end
          end

          # Sections
          r.on 'sections' do
            r.is do
              r.post do
                begin
                  owner_only.call

                  # Check element limit
                  if ProfileSection.where(character_id: character_id).count >= max_sections
                    response.status = 400
                    next { success: false, error: "Maximum sections limit reached (#{max_sections})" }.to_json
                  end

                  data = JSON.parse(request.body.read)
                  max_pos = ProfileSection.where(character_id: character_id).max(:position) || -1

                  section = ProfileSection.create(
                    character_id: character_id,
                    title: data['title'],
                    content: data['content'],
                    position: max_pos + 1
                  )

                  {
                    success: true,
                    section: {
                      id: section.id,
                      title: section.title,
                      content: section.content,
                      position: section.position
                    }
                  }.to_json
                rescue JSON::ParserError
                  response.status = 400
                  { success: false, error: 'Invalid JSON' }.to_json
                rescue StandardError => e
                  warn "[ProfileAPI] Create section error: #{e.message}"
                  response.status = 500
                  { success: false, error: 'Internal server error' }.to_json
                end
              end
            end

            r.is 'reorder' do
              r.patch do
                begin
                  owner_only.call
                  data = JSON.parse(request.body.read)
                  positions = data['positions'] || {}

                  positions.each do |id, pos|
                    next unless pos.to_s.match?(/\A\d+\z/) && pos.to_i >= 0
                    section = ProfileSection[id.to_i]
                    section&.update(position: pos.to_i) if section&.character_id == character_id
                  end

                  { success: true }.to_json
                rescue JSON::ParserError
                  response.status = 400
                  { success: false, error: 'Invalid JSON' }.to_json
                rescue StandardError => e
                  warn "[ProfileAPI] Reorder sections error: #{e.message}"
                  response.status = 500
                  { success: false, error: 'Internal server error' }.to_json
                end
              end
            end

            r.on Integer do |section_id|
              r.is do
                r.patch do
                  begin
                    owner_only.call
                    section = ProfileSection[section_id]

                    if section&.character_id == character_id
                      data = JSON.parse(request.body.read)
                      # Only update fields that were provided
                      updates = {}
                      updates[:title] = data['title'] if data.key?('title')
                      updates[:content] = data['content'] if data.key?('content')
                      section.update(updates) unless updates.empty?
                      {
                        success: true,
                        section: {
                          id: section.id,
                          title: section.title,
                          content: section.content,
                          position: section.position
                        }
                      }.to_json
                    else
                      response.status = 404
                      { success: false, error: 'Section not found' }.to_json
                    end
                  rescue JSON::ParserError
                    response.status = 400
                    { success: false, error: 'Invalid JSON' }.to_json
                  rescue StandardError => e
                    warn "[ProfileAPI] Update section error: #{e.message}"
                    response.status = 500
                    { success: false, error: 'Internal server error' }.to_json
                  end
                end

                r.delete do
                  begin
                    owner_only.call
                    section = ProfileSection[section_id]

                    if section&.character_id == character_id
                      section.delete
                      { success: true }.to_json
                    else
                      response.status = 404
                      { success: false, error: 'Section not found' }.to_json
                    end
                  rescue StandardError => e
                    warn "[ProfileAPI] Delete section error: #{e.message}"
                    response.status = 500
                    { success: false, error: 'Internal server error' }.to_json
                  end
                end
              end
            end
          end

          # Videos
          r.on 'videos' do
            r.is do
              r.post do
                begin
                  owner_only.call

                  # Check element limit
                  if ProfileVideo.where(character_id: character_id).count >= max_videos
                    response.status = 400
                    next { success: false, error: "Maximum videos limit reached (#{max_videos})" }.to_json
                  end

                  data = JSON.parse(request.body.read)
                  youtube_id = data['youtube_id'].to_s.strip

                  unless youtube_id.match?(/\A[a-zA-Z0-9_-]{11}\z/)
                    response.status = 400
                    next { success: false, error: 'Invalid YouTube video ID' }.to_json
                  end

                  max_pos = ProfileVideo.where(character_id: character_id).max(:position) || -1
                  video = ProfileVideo.create(
                    character_id: character_id,
                    youtube_id: youtube_id,
                    title: data['title'],
                    position: max_pos + 1
                  )

                  {
                    success: true,
                    video: {
                      id: video.id,
                      youtube_id: video.youtube_id,
                      title: video.title,
                      position: video.position
                    }
                  }.to_json
                rescue JSON::ParserError
                  response.status = 400
                  { success: false, error: 'Invalid JSON' }.to_json
                rescue StandardError => e
                  warn "[ProfileAPI] Create video error: #{e.message}"
                  response.status = 500
                  { success: false, error: 'Internal server error' }.to_json
                end
              end
            end

            r.is 'reorder' do
              r.patch do
                begin
                  owner_only.call
                  data = JSON.parse(request.body.read)
                  positions = data['positions'] || {}

                  positions.each do |id, pos|
                    next unless pos.to_s.match?(/\A\d+\z/) && pos.to_i >= 0
                    video = ProfileVideo[id.to_i]
                    video&.update(position: pos.to_i) if video&.character_id == character_id
                  end

                  { success: true }.to_json
                rescue JSON::ParserError
                  response.status = 400
                  { success: false, error: 'Invalid JSON' }.to_json
                rescue StandardError => e
                  warn "[ProfileAPI] Reorder videos error: #{e.message}"
                  response.status = 500
                  { success: false, error: 'Internal server error' }.to_json
                end
              end
            end

            r.on Integer do |video_id|
              r.is do
                r.delete do
                  begin
                    owner_only.call
                    video = ProfileVideo[video_id]

                    if video&.character_id == character_id
                      video.delete
                      { success: true }.to_json
                    else
                      response.status = 404
                      { success: false, error: 'Video not found' }.to_json
                    end
                  rescue StandardError => e
                    warn "[ProfileAPI] Delete video error: #{e.message}"
                    response.status = 500
                    { success: false, error: 'Internal server error' }.to_json
                  end
                end
              end
            end
          end

          # Settings (background image)
          r.on 'settings' do
            r.on 'background' do
              r.is do
                r.post do
                  begin
                    owner_only.call
                    result = ProfileUploadService.upload_background(r.params['file'], character_id)

                    if result[:success]
                      setting = ProfileSetting.find_or_create(character_id: character_id)
                      ProfileUploadService.delete(setting.background_url) if setting.background_url
                      setting.update(background_url: result[:data][:url])

                      { success: true, background_url: setting.background_url }.to_json
                    else
                      response.status = 400
                      { success: false, error: result[:message] }.to_json
                    end
                  rescue StandardError => e
                    warn "[ProfileAPI] Upload background error: #{e.message}"
                    response.status = 500
                    { success: false, error: 'Internal server error' }.to_json
                  end
                end

                r.delete do
                  begin
                    owner_only.call
                    setting = ProfileSetting.first(character_id: character_id)

                    if setting&.background_url
                      ProfileUploadService.delete(setting.background_url)
                      setting.update(background_url: nil)
                    end

                    { success: true }.to_json
                  rescue StandardError => e
                    warn "[ProfileAPI] Delete background error: #{e.message}"
                    response.status = 500
                    { success: false, error: 'Internal server error' }.to_json
                  end
                end
              end
            end
          end
        end
      end

      # Test API (for Playwright browser testing) - disabled when development mode is off
      r.on 'test' do
        unless GameSetting.get_boolean('test_account_enabled')
          response.status = 403
          next { success: false, error: 'Test endpoints are disabled in production mode' }.to_json
        end

        # Get session cookies for browser testing (Bearer token auth)
        r.is 'session' do
          r.post do
            begin
              char_instance = character_instance_from_token
              unless char_instance
                response.status = 401
                next { success: false, error: 'Unauthorized - Bearer token required' }.to_json
              end

              # Get the user from the character
              user = char_instance.character&.user
              unless user
                response.status = 401
                next { success: false, error: 'No user associated with this character' }.to_json
              end

              # Set session for browser access
              session['user_id'] = user.id
              session['character_id'] = char_instance.character_id

              # Extract session cookie info - The session cookie is set by Roda automatically
              # We need to return the cookie that was set in the response
              {
                success: true,
                cookies: [
                  {
                    name: '_firefly_session',
                    value: 'session-set-by-response-cookie',
                    path: '/'
                  }
                ],
                user_id: user.id,
                character_id: char_instance.character_id,
                message: 'Session created. Use the Set-Cookie header from this response.'
              }.to_json
            rescue => e
              puts "[API_ERROR] /api/test/session: #{e.class}: #{e.message}"
              puts e.backtrace.first(5).join("\n")
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end
        end

        # Render a page for testing (returns HTML or error info)
        r.is 'render' do
          r.post do
            begin
              char_instance = character_instance_from_token
              unless char_instance
                response.status = 401
                next { success: false, error: 'Unauthorized - Bearer token required' }.to_json
              end

              data = JSON.parse(request.body.read)
              path = data['path'] || '/'

              # Set up session for rendering
              user = char_instance.character&.user
              session['user_id'] = user.id if user
              session['character_id'] = char_instance.character_id

              # Note: Full page rendering would require a more complex approach
              # For now, just verify the route exists and return basic info
              {
                success: true,
                path: path,
                message: 'Page render not yet implemented - use fetch_page MCP tool for now'
              }.to_json
            rescue JSON::ParserError
              response.status = 400
              { success: false, error: 'Invalid request format' }.to_json
            rescue => e
              puts "[API_ERROR] /api/test/render: #{e.class}: #{e.message}"
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end
        end

        # Grant a test item to the agent's character
        r.is 'grant_item' do
          r.post do
            begin
              char_instance = character_instance_from_token
              unless char_instance
                response.status = 401
                next { success: false, error: 'Unauthorized' }.to_json
              end

              data = begin
                JSON.parse(request.body.read)
              rescue JSON::ParserError
                {}
              end

              item_name = data['name'] || 'Test Sword'
              item_type = data['type'] || 'weapon'
              item_desc = data['description'] || "A #{item_name} created for testing."

              attrs = {
                name: item_name,
                description: item_desc,
                character_instance_id: char_instance.id,
                quantity: data['quantity']&.to_i || 1,
                condition: 'good',
                properties: Sequel.pg_jsonb_wrap({ 'item_type' => item_type })
              }

              item = Item.create(attrs)

              {
                success: true,
                item_id: item.id,
                name: item.name,
                message: "Created '#{item.name}' in inventory"
              }.to_json
            rescue => e
              warn "[TEST_API] grant_item failed: #{e.message}"
              response.status = 500
              { success: false, error: e.message }.to_json
            end
          end
        end

        # Grant currency to the agent's character
        r.is 'grant_currency' do
          r.post do
            begin
              char_instance = character_instance_from_token
              unless char_instance
                response.status = 401
                next { success: false, error: 'Unauthorized' }.to_json
              end

              data = begin
                JSON.parse(request.body.read)
              rescue JSON::ParserError
                {}
              end

              amount = data['amount']&.to_i || 1000

              # Find or create a wallet for the primary currency
              currency = nil
              if char_instance.wallets.any?
                currency = char_instance.wallets.first.currency
              else
                universe = Universe.first
                currency = universe ? Currency.default_for(universe) : Currency.first
              end

              # Auto-create a test currency if none exists
              unless currency
                universe ||= Universe.first
                if universe
                  currency = Currency.create(
                    universe_id: universe.id,
                    name: 'Gold',
                    symbol: 'G',
                    decimal_places: 0,
                    is_primary: true
                  )
                else
                  next { success: false, error: 'No universe or currency configured' }.to_json
                end
              end

              wallet = Wallet.find_or_create(
                character_instance_id: char_instance.id,
                currency_id: currency.id
              ) { |w| w.balance = 0 }

              wallet.add(amount)

              {
                success: true,
                balance: wallet.balance,
                currency: currency.name,
                message: "Granted #{currency.format_amount(amount)}"
              }.to_json
            rescue => e
              warn "[TEST_API] grant_currency failed: #{e.message}"
              response.status = 500
              { success: false, error: e.message }.to_json
            end
          end
        end

        # Reset character state (HP, posture, effects, combat)
        r.is 'reset_character' do
          r.post do
            begin
              char_instance = character_instance_from_token
              unless char_instance
                response.status = 401
                next { success: false, error: 'Unauthorized' }.to_json
              end

              # Reset HP to max
              updates = {
                health: char_instance.max_health,
                stance: 'standing',
                afk: false,
                semiafk: false,
                status: 'alive',
                in_event_id: nil
              }
              updates[:is_helpless] = false if char_instance.respond_to?(:is_helpless)
              updates[:is_blindfolded] = false if char_instance.respond_to?(:is_blindfolded)
              updates[:is_gagged] = false if char_instance.respond_to?(:is_gagged)
              updates[:hands_bound] = false if char_instance.respond_to?(:hands_bound)
              updates[:feet_bound] = false if char_instance.respond_to?(:feet_bound)
              char_instance.update(updates)

              # End any active fights
              if char_instance.in_combat?
                begin
                  FightParticipant.where(character_instance_id: char_instance.id)
                    .eager(:fight)
                    .all
                    .each do |p|
                      p.fight&.update(status: 'complete') if p.fight&.ongoing?
                    end
                rescue => e
                  warn "[TEST_API] Failed to end fight: #{e.message}"
                end
              end

              # Clear test items from inventory (items with "Workflow" or "Test" in name)
              begin
                char_instance.objects_dataset
                  .where(Sequel.ilike(:name, '%Workflow%') | Sequel.ilike(:name, '%Test%'))
                  .delete
              rescue => e
                warn "[TEST_API] Failed to clear test items: #{e.message}"
              end

              # Clear agent interactions from Redis
              begin
                if defined?(REDIS_POOL)
                  REDIS_POOL.with do |redis|
                    keys = redis.keys("agent_interaction:#{char_instance.id}:*")
                    redis.del(*keys) if keys.any?
                  end
                end
              rescue => e
                warn "[TEST_API] clear interactions partial failure: #{e.message}"
              end

              # End any active events hosted by this character
              begin
                Event.where(organizer_id: char_instance.character_id)
                  .where(status: ['scheduled', 'active'])
                  .each do |event|
                    event.end_for_all! if event.respond_to?(:end_for_all!)
                    event.update(status: 'completed') rescue nil
                  end
              rescue => e
                warn "[TEST_API] Failed to clean up events: #{e.message}"
              end

              {
                success: true,
                message: 'Character state reset',
                hp: char_instance.current_hp,
                max_hp: char_instance.max_hp,
                stance: char_instance.stance
              }.to_json
            rescue => e
              warn "[TEST_API] reset_character failed: #{e.message}"
              response.status = 500
              { success: false, error: e.message }.to_json
            end
          end
        end

        # Get full character state dump
        r.is 'get_state' do
          r.get do
            begin
              char_instance = character_instance_from_token
              unless char_instance
                response.status = 401
                next { success: false, error: 'Unauthorized' }.to_json
              end

              inventory = char_instance.objects.map do |item|
                {
                  id: item.id,
                  name: item.name,
                  worn: item.worn,
                  held: item.held,
                  equipped: item.equipped
                }
              end

              wallets = char_instance.wallets.map do |w|
                {
                  currency: w.currency&.name,
                  balance: w.balance
                }
              end

              room = char_instance.current_room
              {
                success: true,
                character: {
                  name: char_instance.character&.full_name,
                  hp: char_instance.current_hp,
                  max_hp: char_instance.max_hp,
                  stance: char_instance.stance || 'standing',
                  afk: char_instance.afk,
                  semiafk: char_instance.semiafk,
                  online: char_instance.online,
                  status: char_instance.status
                },
                room: {
                  id: room&.id,
                  name: room&.name
                },
                inventory: inventory,
                wallets: wallets,
                in_combat: char_instance.in_combat?,
                effects: []
              }.to_json
            rescue => e
              warn "[TEST_API] get_state failed: #{e.message}"
              response.status = 500
              { success: false, error: e.message }.to_json
            end
          end
        end
      end

      # Admin API (Bearer token auth with admin requirement)
      # Used by MCP tools for ticket investigation and log queries
      r.on 'admin' do
        char_instance = character_instance_from_token
        unless char_instance
          response.status = 401
          next { success: false, error: 'Unauthorized - Bearer token required' }.to_json
        end

        user = char_instance.character&.user
        unless user&.admin?
          response.status = 403
          next { success: false, error: 'Admin access required' }.to_json
        end

        # Tickets API
        r.on 'tickets' do
          # GET /api/admin/tickets - List tickets (optionally filtered by status)
          r.is do
            r.get do
              begin
                status_filter = r.params['status']
                limit = [r.params['limit']&.to_i || 100, 500].min

                dataset = Ticket.order(Sequel.desc(:created_at)).limit(limit)
                dataset = dataset.where(status: status_filter) if status_filter && Ticket::STATUSES.include?(status_filter)

                { success: true, tickets: dataset.map(&:to_admin_hash) }.to_json
              rescue => e
                warn "[API_ERROR] GET /api/admin/tickets: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end
          end

          r.on Integer do |id|
            ticket = Ticket[id]
            unless ticket
              response.status = 404
              next { success: false, error: 'Ticket not found' }.to_json
            end

            # GET /api/admin/tickets/:id - Fetch ticket details
            r.is do
              r.get do
                { success: true, ticket: ticket.to_admin_hash }.to_json
              end
            end

            # PATCH /api/admin/tickets/:id/investigate - Update investigation notes
            r.patch 'investigate' do
              begin
                data = JSON.parse(request.body.read)
                notes = data['investigation_notes']
                if notes.nil? || notes.to_s.strip.empty?
                  response.status = 400
                  next { success: false, error: 'investigation_notes is required' }.to_json
                end

                ticket.investigate!(notes: notes)
                { success: true, ticket: ticket.to_admin_hash }.to_json
              rescue JSON::ParserError
                response.status = 400
                { success: false, error: 'Invalid request format' }.to_json
              rescue => e
                warn "[API_ERROR] /api/admin/tickets/#{id}/investigate: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end
          end
        end

        # Logs API for ticket investigation
        r.on 'logs' do
          # RP Logs by user
          r.on 'rp' do
            r.get do
              begin
                user_id = r.params['user_id']&.to_i
                limit = [r.params['limit']&.to_i || 100, 500].min

                unless user_id && user_id > 0
                  response.status = 400
                  next { success: false, error: 'user_id is required' }.to_json
                end

                # Get character IDs for this user
                target_user = User[user_id]
                unless target_user
                  response.status = 404
                  next { success: false, error: 'User not found' }.to_json
                end

                char_ids = target_user.characters.map(&:id)
                if char_ids.empty?
                  next { success: true, logs: [] }.to_json
                end

                logs = RpLog.where(sender_character_id: char_ids)
                            .order(Sequel.desc(:created_at))
                            .limit(limit)
                            .all

                {
                  success: true,
                  logs: logs.map do |log|
                    {
                      id: log.id,
                      content: log.content,
                      log_type: log.log_type,
                      room_id: log.room_id,
                      sender_character_id: log.sender_character_id,
                      created_at: log.created_at&.iso8601
                    }
                  end
                }.to_json
              rescue => e
                warn "[API_ERROR] /api/admin/logs/rp: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end
          end

          # Abuse checks by user
          r.on 'abuse' do
            r.get do
              begin
                user_id = r.params['user_id']&.to_i
                limit = [r.params['limit']&.to_i || 50, 200].min

                unless user_id && user_id > 0
                  response.status = 400
                  next { success: false, error: 'user_id is required' }.to_json
                end

                checks = AbuseCheck.where(user_id: user_id)
                                   .order(Sequel.desc(:created_at))
                                   .limit(limit)
                                   .all

                {
                  success: true,
                  checks: checks.map do |check|
                    {
                      id: check.id,
                      message_type: check.message_type,
                      message_content: check.message_content,
                      status: check.status,
                      gemini_flagged: check.gemini_flagged,
                      gemini_reasoning: check.gemini_reasoning,
                      claude_confirmed: check.claude_confirmed,
                      claude_reasoning: check.claude_reasoning,
                      abuse_category: check.abuse_category,
                      severity: check.severity,
                      created_at: check.created_at&.iso8601
                    }
                  end
                }.to_json
              rescue => e
                warn "[API_ERROR] /api/admin/logs/abuse: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end
          end

          # Connection logs by user
          r.on 'connections' do
            r.get do
              begin
                user_id = r.params['user_id']&.to_i
                limit = [r.params['limit']&.to_i || 50, 200].min

                unless user_id && user_id > 0
                  response.status = 400
                  next { success: false, error: 'user_id is required' }.to_json
                end

                logs = ConnectionLog.where(user_id: user_id)
                                    .order(Sequel.desc(:created_at))
                                    .limit(limit)
                                    .all

                {
                  success: true,
                  logs: logs.map do |log|
                    {
                      id: log.id,
                      ip_address: log.ip_address,
                      connection_type: log.connection_type,
                      outcome: log.outcome,
                      failure_reason: log.failure_reason,
                      created_at: log.created_at&.iso8601
                    }
                  end
                }.to_json
              rescue => e
                warn "[API_ERROR] /api/admin/logs/connections: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end
          end

          # Moderation actions by user
          r.on 'moderation' do
            r.get do
              begin
                user_id = r.params['user_id']&.to_i
                limit = [r.params['limit']&.to_i || 50, 200].min

                unless user_id && user_id > 0
                  response.status = 400
                  next { success: false, error: 'user_id is required' }.to_json
                end

                actions = ModerationAction.where(user_id: user_id)
                                          .order(Sequel.desc(:created_at))
                                          .limit(limit)
                                          .all

                {
                  success: true,
                  actions: actions.map do |action|
                    {
                      id: action.id,
                      action_type: action.action_type,
                      reason: action.reason,
                      triggered_by: action.triggered_by,
                      reversed: action.reversed,
                      expires_at: action.expires_at&.iso8601,
                      created_at: action.created_at&.iso8601
                    }
                  end
                }.to_json
              rescue => e
                warn "[API_ERROR] /api/admin/logs/moderation: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end
          end
        end

        # Autohelp API
        r.on 'autohelp' do
          r.on 'unmatched' do
            r.get do
              begin
                since_str = r.params['since']
                limit = [r.params['limit']&.to_i || 200, 500].min
                since_time = since_str ? Time.parse(since_str) : nil

                queries = AutohelperRequest.unmatched_since(since_time, limit: limit)
                { success: true, queries: queries }.to_json
              rescue ArgumentError => e
                response.status = 400
                { success: false, error: "Invalid since parameter: #{e.message}" }.to_json
              rescue => e
                warn "[API_ERROR] /api/admin/autohelp/unmatched: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end
          end
        end

        # Helpfiles API
        r.on 'helpfiles' do
          # GET /api/admin/helpfiles/search?q=<query> - Search helpfiles by topic
          r.on 'search' do
            r.get do
              begin
                query = r.params['q']
                unless query && !query.strip.empty?
                  response.status = 400
                  next { success: false, error: 'q parameter required' }.to_json
                end

                results = Helpfile.where(Sequel.ilike(:topic, "%#{query}%"))
                                 .or(Sequel.ilike(:command_name, "%#{query}%"))
                                 .limit(10)
                                 .all
                { success: true, helpfiles: results.map { |h| h.to_agent_format.merge(id: h.id) } }.to_json
              rescue => e
                warn "[API_ERROR] /api/admin/helpfiles/search: #{e.message}"
                response.status = 500
                { success: false, error: 'Internal server error' }.to_json
              end
            end
          end

          r.on Integer do |id|
            hf = Helpfile[id]
            unless hf
              response.status = 404
              next { success: false, error: 'Helpfile not found' }.to_json
            end

            r.is do
              r.patch do
                begin
                  data = JSON.parse(request.body.read)
                  allowed = data.slice(*PATCHABLE_HELPFILE_FIELDS)
                  if allowed.empty?
                    response.status = 400
                    next { success: false, error: "No patchable fields provided. Allowed: #{PATCHABLE_HELPFILE_FIELDS.join(', ')}" }.to_json
                  end
                  hf.update(allowed)
                  { success: true, helpfile: hf.to_agent_format.merge(id: hf.id) }.to_json
                rescue JSON::ParserError
                  response.status = 400
                  { success: false, error: 'Invalid JSON' }.to_json
                rescue => e
                  warn "[API_ERROR] PATCH /api/admin/helpfiles/#{id}: #{e.message}"
                  response.status = 500
                  { success: false, error: 'Internal server error' }.to_json
                end
              end
            end
          end

          # POST /api/admin/helpfiles
          r.post do
            begin
              data = JSON.parse(request.body.read)
              required = %w[topic command_name summary plugin]
              missing = required.reject { |f| data[f]&.to_s&.strip&.length&.> 0 }
              if missing.any?
                response.status = 400
                next { success: false, error: "Missing required fields: #{missing.join(', ')}" }.to_json
              end

              hf = Helpfile.create(
                topic: data['topic'],
                command_name: data['command_name'],
                summary: data['summary'],
                description: data['description'],
                plugin: data['plugin'],
                category: data['category'],
                auto_generated: data['auto_generated'] == true
              )
              response.status = 201
              { success: true, helpfile: hf.to_agent_format.merge(id: hf.id) }.to_json
            rescue Sequel::ValidationFailed => e
              response.status = 422
              { success: false, error: e.message }.to_json
            rescue JSON::ParserError
              response.status = 400
              { success: false, error: 'Invalid JSON' }.to_json
            rescue => e
              warn "[API_ERROR] POST /api/admin/helpfiles: #{e.message}"
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end
        end
      end

      # Lightweight status bar poll (session or token auth)
      r.on('status') do
        r.get do
          ci = current_character_instance || character_instance_from_token
          next({}.to_json) unless ci

          StatusBarService.new(ci).build_status_data.to_json
        end
      end

      # Session-based API routes (require login)
      require_login!

      # Messages API
      r.on 'messages' do
        r.on('ack') { r.post { handle_message_ack(r) } }
        r.on('resync') { r.get { handle_message_resync(r) } }
        r.on('reconnect') { r.post { handle_message_reconnect(r) } }
        r.on('seen') { r.post { handle_message_seen(r) } }
        r.on('roleplay') do
          r.get do
            char_instance = current_character_instance
            if char_instance
              RpLoggingService.backfill_for(char_instance).to_json
            else
              [].to_json
            end
          end
        end
        r.on('cycle') { r.post { handle_address_cycle(r) } }
        r.get { handle_get_messages(r) }
        r.post { handle_post_message(r) }
      end

      # Client info
      r.on('client') { r.on('info') { r.post { handle_client_info(r) } } }

      # Typing indicators
      r.on 'typing' do
        r.post { handle_typing_post(r) }
        r.get { handle_typing_get(r) }
      end

      # Popup responses
      r.on('popup') { r.on('response') { r.post { handle_popup_response(r) } } }

      # Settings
      r.on 'settings' do
        r.post { handle_settings_post(r) }
        r.get { handle_settings_get(r) }
      end

      # Room status
      r.on('room') { r.on('status') { r.get { handle_room_status(r) } } }

      # Minimap refresh (periodic pulse fallback)
      r.on('minimap') do
        r.get do
          char_instance = current_character_instance
          unless char_instance
            next { success: false, error: 'No character selected' }.to_json
          end

          # Skip minimap rendering when character is in a delve (delve has its own map)
          if DelveParticipant.first(character_instance_id: char_instance.id, status: 'active')
            next { success: true, in_delve: true }.to_json
          end

          room = char_instance.current_room
          unless room
            next { success: false }.to_json
          end

          begin
            result = CityMapRenderService.render(viewer: char_instance, mode: :minimap)
            {
              success: true,
              minimap_data: { svg: result[:svg], metadata: result[:metadata] },
              room_name: room.name,
              room_id: room.id
            }.to_json
          rescue StandardError => e
            warn "[Minimap API] Error: #{e.message}"
            { success: false }.to_json
          end
        end
      end

      # Delve state (for periodic HUD/map refresh)
      r.on('delve_state') do
        r.get do
          char_instance = current_character_instance
          unless char_instance
            next { success: false, error: 'No character selected' }.to_json
          end

          participant = DelveParticipant.first(
            character_instance_id: char_instance.id,
            status: 'active'
          )
          unless participant
            next { success: false, in_delve: false }.to_json
          end

          begin
            map_result = DelveMapPanelService.render(participant: participant)
            room_data = DelveMovementService.build_current_room_data(participant)

            {
              success: true,
              in_delve: true,
              delve_map_svg: map_result[:svg],
              current_room: room_data,
              delve_name: participant.delve&.name,
              current_level: participant.current_level,
              time_remaining: participant.time_remaining_seconds,
              current_hp: participant.current_hp,
              max_hp: participant.max_hp,
              willpower_dice: participant.willpower_dice,
              loot_collected: participant.loot_collected
            }.to_json
          rescue StandardError => e
            warn "[DelveState API] Error: #{e.message}"
            { success: false }.to_json
          end
        end
      end

      # Character status
      r.on('character') { r.get('status') { handle_character_status(r) } }

      # Fight/Combat API (session-based)
      r.on 'fight' do
        char_instance = current_character_instance
        unless char_instance
          next { success: false, error: 'No character selected' }.to_json
        end

        # GET /api/fight/status - Check if character is in combat
        r.get 'status' do
          participant = FightParticipant.where(character_instance_id: char_instance.id, defeated_at: nil)
                                        .eager(:fight)
                                        .order(Sequel.desc(:id))
                                        .first

          if participant && participant.fight && !%w[complete completed].include?(participant.fight.status)
            fight = participant.fight
            {
              success: true,
              in_combat: true,
              fight_id: fight.id,
              round: fight.round_number,
              status: fight.status,
              battle_map_generating: fight.battle_map_generating,
              can_accept_combat_input: fight.can_accept_combat_input?
            }.to_json
          else
            { success: true, in_combat: false }.to_json
          end
        end

        # GET /api/fight/battle_map - Get battle map visualization data
        r.get 'battle_map' do
          participant = FightParticipant.where(character_instance_id: char_instance.id, defeated_at: nil)
                                        .eager(:fight)
                                        .order(Sequel.desc(:id))
                                        .first

          unless participant && participant.fight && !%w[complete completed].include?(participant.fight.status)
            next { success: false, error: 'not_in_combat' }.to_json
          end

          fight = participant.fight
          service = BattleMapViewService.new(fight, char_instance)
          service.build_map_state.to_json
        end

        # GET /api/fight/round_events - Get movement events for animation
        r.get 'round_events' do
          participant = FightParticipant.where(character_instance_id: char_instance.id, defeated_at: nil)
                                        .eager(:fight)
                                        .order(Sequel.desc(:id))
                                        .first

          unless participant && participant.fight
            next { success: false, error: 'not_in_combat' }.to_json
          end

          fight = participant.fight
          prev_round = fight.round_number - 1
          return { success: true, round: prev_round, events: [] }.to_json if prev_round < 1

          events = FightEvent.where(fight_id: fight.id, round_number: prev_round, event_type: 'movement_step')
                             .order(:segment)
                             .all

          {
            success: true,
            round: prev_round,
            events: events.map do |e|
              details = e.details || {}
              {
                segment: e.segment,
                actor_id: e.actor_participant_id,
                actor_name: e.actor_name,
                old_x: details['old_x'] || details[:old_x],
                old_y: details['old_y'] || details[:old_y],
                new_x: details['new_x'] || details[:new_x],
                new_y: details['new_y'] || details[:new_y],
                step: details['step'] || details[:step],
                total_steps: details['total_steps'] || details[:total_steps]
              }
            end
          }.to_json
        end

        # POST /api/fight/action - Submit combat action
        r.post 'action' do
          begin
            data = JSON.parse(request.body.read)
            action = data['action']
            value = data['value']

            participant = FightParticipant.where(character_instance_id: char_instance.id, defeated_at: nil)
                                          .eager(:fight)
                                          .order(Sequel.desc(:id))
                                          .first

            unless participant && participant.fight
              response.status = 400
              next { success: false, error: 'Not in combat' }.to_json
            end

            fight = participant.fight

            # Check if battle map is still generating
            if fight.awaiting_battle_map?
              response.status = 400
              next { success: false, error: 'Battle map is still generating. Please wait...', code: 'generation_in_progress' }.to_json
            end

            unless fight.can_accept_combat_input?
              response.status = 400
              if fight.round_locked?
                next {
                  success: false,
                  error: 'Combat round is resolving. Wait for the next round to change your choices.',
                  code: 'round_resolving'
                }.to_json
              end

              next { success: false, error: 'Combat input is currently closed for this round.', code: 'input_closed' }.to_json
            end

            result = CombatActionService.process_map_action(participant, action, value)

            if result[:success]
              { success: true, message: result[:message], input_complete: participant.reload.input_complete }.to_json
            else
              response.status = 400
              { success: false, error: result[:error] }.to_json
            end
          rescue JSON::ParserError
            response.status = 400
            { success: false, error: 'Invalid JSON' }.to_json
          rescue => e
            warn "[API_ERROR] /api/fight/action: #{e.message}"
            response.status = 500
            { success: false, error: 'Internal server error' }.to_json
          end
        end
      end

      # Character Story API (session-based auth for story export/viewing)
      r.on 'character_story' do
        r.on Integer do |character_id|
          character = Character[character_id]

          unless character
            response.status = 404
            next { success: false, error: 'Character not found' }.to_json
          end

          # Authorization: user must own this character
          unless current_user && character.user_id == current_user.id
            response.status = 403
            next { success: false, error: 'Not authorized' }.to_json
          end

          # GET /api/character_story/:id/summary
          r.get 'summary' do
            begin
              summary = ChapterService.summary_for(character)
              { success: true, summary: summary }.to_json
            rescue StandardError => e
              warn "[CharacterStoryAPI] Error getting summary: #{e.message}"
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end

          # GET /api/character_story/:id/chapters
          r.get 'chapters' do
            begin
              chapters = ChapterService.chapters_for(character)
              chapters_with_titles = chapters.map.with_index do |chapter, idx|
                chapter.merge(title: ChapterService.chapter_title(character, idx))
              end
              { success: true, chapters: chapters_with_titles }.to_json
            rescue StandardError => e
              warn "[CharacterStoryAPI] Error getting chapters: #{e.message}"
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end

          # GET /api/character_story/:id/chapter/:index
          r.get 'chapter', Integer do |index|
            begin
              logs = ChapterService.chapter_content(character, index)
              chapters = ChapterService.chapters_for(character)
              chapter = chapters[index]

              {
                success: true,
                title: chapter ? ChapterService.chapter_title(character, index, logs: logs) : "Chapter #{index + 1}",
                chapter: chapter,
                logs: logs.map { |l| l.to_api_hash }
              }.to_json
            rescue StandardError => e
              warn "[CharacterStoryAPI] Error getting chapter content: #{e.message}"
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end

          # GET /api/character_story/:id/download
          r.get 'download' do
            begin
              response['Content-Type'] = 'text/plain; charset=utf-8'
              filename = "#{character.full_name.gsub(/[^a-zA-Z0-9]/, '_')}_story.txt"
              response['Content-Disposition'] = "attachment; filename=\"#{filename}\""
              CharacterStoryExporter.to_text(character)
            rescue StandardError => e
              warn "[CharacterStoryAPI] Error generating download: #{e.message}"
              response.status = 500
              { success: false, error: 'Internal server error' }.to_json
            end
          end
        end
      end
    end

    # Puzzle test page (no auth required - development mode only)
    r.on 'test' do
      unless GameSetting.get_boolean('test_account_enabled')
        response.status = 404
        next 'Not found'
      end

      r.is 'puzzles' do
        render 'test/puzzles'
      end
    end

    # Events pages (public calendar + per-event details/logs)
    r.on 'events' do
      current_ci = current_character_instance
      current_char = current_ci&.character

      r.is do
        r.get do
          upcoming_events = EventService.upcoming_events(limit: 50, include_private: false).all
          my_events = current_char ? EventService.events_for_character(current_char, limit: 30).all : []

          @events = EventService.calendar_data(upcoming_events)
          @my_events = EventService.calendar_data(my_events)

          view 'events/calendar'
        end
      end

      r.on Integer do |event_id|
        @event = Event[event_id]
        unless @event
          flash['error'] = 'Event not found'
          next r.redirect('/events')
        end

        build_event_logs_page = lambda do
          @logs = RpLoggingService.logs_for_event(@event, character: current_char)
          @access_denied = !@event.can_view_logs?(current_char)
          view 'events/logs'
        end

        r.is do
          r.get do
            build_event_logs_page.call
          end
        end

        r.on 'logs' do
          r.is do
            r.get do
              build_event_logs_page.call
            end
          end
        end
      end
    end

    # ====== PROTECTED ROUTES ======
    r.on do
      require_login!

      # Dashboard
      r.on 'dashboard' do
        @characters = current_user.characters_dataset
          .where { (deleted_at =~ nil) | (deleted_at > Time.now - 30 * 24 * 3600) }
          .order(:forename).all
        @players_online = CharacterInstance
          .where(online: true)
          .join(:characters, id: :character_id)
          .where(Sequel[:characters][:is_npc] => false)
          .count
        @upcoming_events = Event.where { starts_at > Time.now }
          .where(is_public: true)
          .order(:starts_at)
          .limit(5)
          .all rescue []
        @owned_rooms = Room.where(owner_id: current_user.id).limit(10).all rescue []
        view 'dashboard/index'
      end

      # Settings
      r.on 'settings' do
        r.get { view 'settings/index' }
        r.post('profile') { handle_profile_update(r) }
        r.post('password') { handle_password_update(r) }
        r.post('preferences') { flash['success'] = 'Preferences saved'; r.redirect '/settings' }
        r.post('webclient') { handle_webclient_settings(r) }
        r.post('delete') { handle_account_delete(r) }
      end

      # Wardrobe
      r.on 'wardrobe' do
        ci = current_character_instance
        next r.redirect('/play') unless ci

        @character = ci.character
        @character_instance = ci
        @wardrobe = WardrobeService.new(ci)

        r.is do
          r.get do
            @popout = r.params['popout'] == 'true'
            @title = 'Wardrobe'
            @popout_icon = 'handbag'
            @overview = @wardrobe.overview

            if @popout
              view 'wardrobe/index', layout: :popout
            else
              view 'wardrobe/index'
            end
          end
        end
      end

      # Media popout
      r.on 'media-popout' do
        ci = current_character_instance
        next r.redirect('/play') unless ci

        @character = ci.character
        @character_instance = ci
        @popout = r.params['popout'] == 'true'
        @title = 'Media'
        @popout_icon = 'music-note-beamed'
        @playlists = MediaPlaylist.where(character_id: @character.id).order(:name).all
        @media_prefs = @character.user.media_preferences

        if @popout
          view 'media/index', layout: :popout
        else
          view 'media/index'
        end
      end

      # Characters
      r.on 'characters' do
        # Gate character creation if email verification is required
        r.get('new') do
          if current_user.verification_required?
            flash['warning'] = 'Please verify your email before creating a character'
            r.redirect '/verify-email'
          end
          view 'characters/new'
        end

        r.post('create') do
          if current_user.verification_required?
            flash['warning'] = 'Please verify your email before creating a character'
            r.redirect '/verify-email'
          end
          handle_character_create(r)
        end

        # Draft character API for live preview during creation
        r.on 'draft' do
          response['Content-Type'] = 'application/json'

          # Create a new draft character
          r.post do
            handle_draft_character_create(r)
          end

          r.on Integer do |draft_id|
            draft = Character.where(id: draft_id, user_id: current_user.id, is_draft: true).first
            unless draft
              response.status = 404
              next { success: false, error: 'Draft not found' }.to_json
            end

            # Update draft character fields (PATCH or POST)
            r.is do
              if request.request_method == 'PATCH' || request.request_method == 'POST'
                handle_draft_character_update(r, draft)
              end
            end

            # Get rendered preview HTML
            r.get('preview') do
              handle_draft_character_preview(draft)
            end

            # Finalize draft into real character
            r.post('finalize') do
              handle_draft_character_finalize(r, draft)
            end

            # Import content from ZIP package into draft
            r.post('import') do
              handle_draft_character_import(r, draft)
            end
          end
        end

        r.on Integer do |character_id|
          @character = Character.where(id: character_id, user_id: current_user.id).first
          unless @character
            # Return JSON error for API requests, redirect for HTML requests
            is_json_request = request.content_type&.include?('application/json') ||
                              request.env['HTTP_ACCEPT']&.include?('application/json')
            if is_json_request
              response['Content-Type'] = 'application/json'
              response.status = 404
              next { success: false, error: 'Character not found' }.to_json
            end
            flash['error'] = 'Character not found'
            r.redirect '/dashboard'
          end

          # Character descriptions API (for description manager)
          r.on 'descriptions' do
            # Check if JSON request
            is_json = request.content_type&.include?('application/json') ||
                      request.env['HTTP_ACCEPT']&.include?('application/json')

            if is_json
              response['Content-Type'] = 'application/json'
            end

            # POST /characters/:id/descriptions/reorder - Reorder descriptions
            r.post 'reorder' do
              begin
                data = JSON.parse(request.body.read)
                orders = data['orders'] || []

                orders.each do |order|
                  desc = CharacterDefaultDescription.where(
                    id: order['id'],
                    character_id: @character.id
                  ).first
                  desc&.update(display_order: order['display_order'])
                end

                { success: true }.to_json
              rescue => e
                warn "[CharacterDescriptions] Reorder error: #{e.message}"
                response.status = 500
                { success: false, error: 'Failed to reorder' }.to_json
              end
            end

            # GET /characters/:id/descriptions/preview - Server-rendered preview HTML
            r.get 'preview' do
              response['Content-Type'] = 'application/json'
              service = DraftCharacterPreviewService.new(@character)
              html = service.render_html
              { success: true, html: html }.to_json
            end

            # Routes for specific description
            r.on Integer do |desc_id|
              desc = CharacterDefaultDescription.where(id: desc_id, character_id: @character.id).first
              unless desc
                response.status = 404
                next { success: false, error: 'Description not found' }.to_json
              end

              # POST /characters/:id/descriptions/:desc_id/toggle - Toggle active state
              r.post 'toggle' do
                desc.update(active: !desc.active)

                # Sync to live instance if character is online
                instance = CharacterInstance.first(character_id: @character.id, online: true)
                if instance
                  if desc.active
                    DescriptionCopyService.sync_single(@character, instance, desc.id)
                  else
                    DescriptionCopyService.cleanup_orphaned(@character, instance)
                  end
                end

                { success: true, active: desc.active }.to_json
              end

              # POST /characters/:id/descriptions/:desc_id/upload-image - Upload image for description
              r.post 'upload-image' do
                begin
                  uploaded = r.params['image']
                  unless uploaded&.dig(:tempfile)
                    response.status = 400
                    next { success: false, error: 'No image file provided' }.to_json
                  end

                  # Validate file type
                  content_type = uploaded[:type] || ''
                  unless content_type.start_with?('image/')
                    response.status = 400
                    next { success: false, error: 'File must be an image' }.to_json
                  end

                  # Save file
                  filename = "desc_#{desc.id}_#{SecureRandom.hex(8)}_#{uploaded[:filename]}"
                  upload_dir = File.join(__dir__, 'public', 'uploads', 'descriptions')
                  FileUtils.mkdir_p(upload_dir)
                  File.open(File.join(upload_dir, filename), 'wb') { |f| f.write(uploaded[:tempfile].read) }

                  image_url = "/uploads/descriptions/#{filename}"
                  desc.update(image_url: image_url)

                  { success: true, image_url: image_url }.to_json
                rescue StandardError => e
                  warn "[CharacterDescriptions] Image upload error: #{e.message}"
                  response.status = 500
                  { success: false, error: 'Failed to upload image' }.to_json
                end
              end

              # PUT /characters/:id/descriptions/:desc_id - Update description
              r.is do
                r.put do
                  begin
                    data = JSON.parse(request.body.read)
                    updates = {}
                    updates[:content] = data['content'] if data['content']
                    updates[:concealed_by_clothing] = data['concealed_by_clothing'] if data.key?('concealed_by_clothing')
                    updates[:display_order] = data['display_order'] if data['display_order']
                    updates[:description_type] = data['description_type'] if data['description_type']
                    updates[:suffix] = data['suffix'] if data['suffix']
                    updates[:prefix] = data['prefix'] if data['prefix']

                    desc.update(updates)

                    # Sync to live instance if character is online
                    instance = CharacterInstance.first(character_id: @character.id, online: true)
                    if instance
                      DescriptionCopyService.sync_single(@character, instance, desc.id)
                    end

                    {
                      success: true,
                      description: {
                        id: desc.id,
                        content: desc.content,
                        body_position_id: desc.body_position_id,
                        body_position_label: desc.position_label,
                        region: desc.region,
                        concealed_by_clothing: desc.concealed_by_clothing,
                        display_order: desc.display_order,
                        description_type: desc.description_type,
                        suffix: desc.suffix,
                        prefix: desc.prefix,
                        active: desc.active,
                        image_url: desc.image_url
                      }
                    }.to_json
                  rescue => e
                    warn "[CharacterDescriptions] Update error: #{e.message}"
                    response.status = 500
                    { success: false, error: 'Failed to update' }.to_json
                  end
                end

                # DELETE /characters/:id/descriptions/:desc_id - Delete description
                r.delete do
                  # Remove matching instance description if character is online
                  instance = CharacterInstance.first(character_id: @character.id, online: true)
                  if instance
                    DescriptionCopyService.cleanup_orphaned(@character, instance)
                  end

                  desc.destroy

                  # Clean up again after default is deleted
                  if instance
                    DescriptionCopyService.cleanup_orphaned(@character, instance)
                  end

                  { success: true }.to_json
                end
              end
            end

            # GET/POST /characters/:id/descriptions
            r.is do
              # GET - List all descriptions (HTML view or JSON API)
              r.get do
                # Return HTML view for browser requests, JSON for API requests
                unless is_json
                  @popout = r.params['popout'] == 'true'
                  if @popout
                    @title = 'Description Editor'
                    @popout_icon = 'body-text'
                    return view 'characters/descriptions', layout: :popout
                  end
                  return view 'characters/descriptions'
                end

                descriptions = CharacterDefaultDescription.where(character_id: @character.id)
                                                          .eager(:body_position, :body_positions)
                                                          .order(:display_order, :id)
                                                          .all

                json_descriptions = descriptions.map do |d|
                  bp = d.body_position
                  all_positions = d.body_positions.any? ? d.body_positions : (bp ? [bp] : [])

                  {
                    id: d.id,
                    body_position_id: d.body_position_id,
                    body_position: bp ? { id: bp.id, label: bp.label, region: bp.region } : nil,
                    body_position_label: bp&.label&.tr('_', ' ')&.split&.map(&:capitalize)&.join(' '),
                    content: d.content,
                    image_url: d.image_url,
                    concealed_by_clothing: d.concealed_by_clothing,
                    display_order: d.display_order,
                    description_type: d.description_type,
                    suffix: d.suffix,
                    prefix: d.prefix,
                    active: d.active,
                    region: all_positions.first&.region || bp&.region,
                    body_positions: all_positions.map { |p| { id: p.id, label: p.label, region: p.region } },
                    body_position_ids: all_positions.map(&:id)
                  }
                end

                { success: true, descriptions: json_descriptions }.to_json
              end

              # POST - Create new description
              r.post do
                begin
                  data = JSON.parse(request.body.read)

                  desc = CharacterDefaultDescription.new(
                    character_id: @character.id,
                    body_position_id: data['body_position_id'],
                    content: data['content'] || '',
                    concealed_by_clothing: data['concealed_by_clothing'] || false,
                    display_order: data['display_order'] || 0,
                    description_type: data['description_type'] || 'natural',
                    suffix: data['suffix'] || 'period',
                    prefix: data['prefix'] || 'none',
                    active: true
                  )

                  # Validate and save
                  unless desc.valid?
                    error_messages = desc.errors.full_messages.join(', ')
                    warn "[CharacterDescriptions] Validation failed: #{error_messages}"
                    response.status = 422
                    next { success: false, error: error_messages }.to_json
                  end

                  desc.save

                  # Handle multiple body positions if provided
                  if data['body_position_ids'].is_a?(Array)
                    data['body_position_ids'].each do |bp_id|
                      CharacterDescriptionPosition.create(
                        character_default_description_id: desc.id,
                        body_position_id: bp_id
                      )
                    end
                  end

                  # Sync to live instance if character is online
                  instance = CharacterInstance.first(character_id: @character.id, online: true)
                  if instance
                    DescriptionCopyService.sync_single(@character, instance, desc.id)
                  end

                  # Reload to get associations
                  desc.refresh
                  bp = desc.body_position
                  json_desc = {
                    id: desc.id,
                    body_position_id: desc.body_position_id,
                    body_position: bp ? { id: bp.id, label: bp.label, region: bp.region } : nil,
                    content: desc.content,
                    concealed_by_clothing: desc.concealed_by_clothing,
                    display_order: desc.display_order,
                    description_type: desc.description_type,
                    suffix: desc.suffix,
                    prefix: desc.prefix,
                    active: desc.active,
                    body_positions: desc.body_positions.map { |p| { id: p.id, label: p.label, region: p.region } }
                  }

                  { success: true, description: json_desc }.to_json
                rescue => e
                  warn "[CharacterDescriptions] Create error: #{e.message}"
                  response.status = 500
                  { success: false, error: 'Failed to create description' }.to_json
                end
              end
            end
          end

          r.is do
            r.get { view 'characters/show' }
          end
          r.get('edit') { view 'characters/edit' }
          r.post('update') { handle_character_update(r, character_id) }
          r.post('select') { session['character_id'] = character_id; flash['success'] = "Now playing as #{@character.name}"; r.redirect "/webclient?character=#{character_id}" }
          r.post('delete') { handle_character_delete(r, character_id) }
          r.post('recover') { handle_character_recover(r, character_id) }

          # Export character content as ZIP
          r.get('export') do
            handle_character_export(r, @character)
          end

          # Import page (legacy full-page flow)
          r.get('import') do
            view 'characters/import'
          end

          # Import content from ZIP package into character
          r.post('import') do
            handle_character_import(r, @character)
          end
        end
      end

      # Property blueprint export/import
      r.on 'properties' do
        r.on Integer do |room_id|
          @room = Room[room_id]
          unless @room
            flash['error'] = 'Property not found'
            r.redirect '/dashboard'
          end

          unless can_manage_property_room?(@room)
            flash['error'] = 'You do not have permission to manage that property'
            r.redirect '/dashboard'
          end

          r.is do
            r.get do
              view 'properties/show'
            end
          end

          r.get('export') do
            handle_property_export(r, @room)
          end

          r.get('import') do
            view 'properties/import'
          end

          r.post('import') do
            handle_property_import(r, @room)
          end
        end
      end

      # Mission Logs
      r.on 'missions' do
        r.is do
          r.get do
            # List all missions the user has participated in
            @character = current_character
            if @character
              participant_ids = ActivityParticipant.where(char_id: @character.id).select(:instance_id)
              @missions = ActivityInstance.where(id: participant_ids)
                                          .where { completed_at !~ nil }
                                          .order(Sequel.desc(:completed_at))
                                          .limit(50)
                                          .all
            else
              @missions = []
            end
            view 'missions/index'
          end
        end

        r.on Integer do |instance_id|
          @instance = ActivityInstance[instance_id]
          unless @instance
            flash['error'] = 'Mission not found'
            r.redirect '/missions'
          end

          # Check view permissions
          viewer = current_character
          unless ActivityLoggingService.can_view_logs?(@instance, viewer)
            flash['error'] = 'You do not have permission to view this mission log'
            r.redirect '/missions'
          end

          r.get do
              @logs = ActivityLog.for_instance(@instance.id).all
              @activity = @instance.activity
              @participants = @instance.participants.map do |p|
                { id: p.id, character: p.character, score: p.score, status: p.status_text }
              end
              view 'missions/show'
            end

          # Download as HTML file
          r.get 'download' do
            html = ActivityLoggingService.logs_as_html(@instance, viewer: viewer)
            response['Content-Type'] = 'text/html'
            response['Content-Disposition'] = "attachment; filename=\"mission-#{instance_id}.html\""
            html
          end
        end
      end

      # Webclient
      r.on 'webclient' do
        handle_character_selection_from_params(r)
        ensure_character_for_play(r)

        # Build initial room data so background image renders on page load
        @room = @character_instance&.current_room
        if @room && @character_instance
          begin
            service = RoomDisplayService.new(@room, @character_instance)
            @initial_room_data = service.build_display
          rescue StandardError => e
            warn "[Webclient] Failed to build initial room data: #{e.message}"
          end
        end

        # Check if character is in an active delve (for HUD auto-activation)
        @in_delve = @character_instance &&
          DelveParticipant.where(character_instance_id: @character_instance.id, status: 'active').count > 0

        view 'webclient/index', layout: :play
      end

      # Legacy /play route - redirect to webclient
      r.on 'play' do
        # Preserve any query params when redirecting
        query = r.query_string && !r.query_string.empty? ? "?#{r.query_string}" : ''
        r.redirect "/webclient#{query}"
      end

      # ====== ADMIN CONSOLE ======
      r.on 'admin' do
        require_admin!

        # Track last visited admin page for redirect
        admin_sub_path = request.path.sub(%r{^/admin/?}, '')
        unless admin_sub_path.empty? || request.request_method != 'GET'
          session[:last_admin_path] = request.path
        end

        # Admin landing — redirect to last visited page, or users by default
        r.is do
          last_path = session[:last_admin_path]
          if last_path && last_path != '/admin'
            r.redirect last_path
          else
            r.redirect '/admin/users'
          end
        end

        # Server management
        r.on 'server' do
          r.on 'restart' do
            r.is do
              r.post do
                type = r.params['type'] || 'phased'
                delay = r.params['delay'].to_i

                result = ServerRestartService.schedule(type: type, delay: delay)

                if result[:error]
                  flash['error'] = result[:error]
                else
                  flash['success'] = delay.zero? ? 'Server restart triggered.' : "Server restart scheduled in #{delay} seconds."
                end

                r.redirect session[:last_admin_path] || '/admin'
              end
            end

            r.on 'cancel' do
              r.is do
                r.post do
                  result = ServerRestartService.cancel

                  if result[:error]
                    flash['error'] = result[:error]
                  else
                    flash['success'] = 'Server restart cancelled.'
                  end

                  r.redirect session[:last_admin_path] || '/admin'
                end
              end
            end

            r.on 'status' do
              r.is do
                r.get do
                  response['Content-Type'] = 'application/json'
                  ServerRestartService.status.to_json
                end
              end
            end
          end
        end

        # User management
        r.on 'users' do
          r.is do
            r.get do
              @users = User.order(:username).all
              view 'admin/users/index'
            end
          end

          r.on Integer do |user_id|
            @target_user = User[user_id]
            unless @target_user
              flash['error'] = 'User not found'
              r.redirect '/admin/users'
            end

            r.is do
              r.get do
                @user_characters = @target_user.characters
                @permissions = Permission::PERMISSIONS
                view 'admin/users/show'
              end
            end

            r.post 'toggle_admin' do
              if @target_user.id == current_user.id
                flash['error'] = 'You cannot change your own admin status.'
              elsif @target_user.admin?
                @target_user.update(is_admin: false)
                flash['success'] = "Removed admin privileges from #{@target_user.username}."
              else
                @target_user.update(is_admin: true)
                flash['success'] = "Granted admin privileges to #{@target_user.username}."
              end
              r.redirect "/admin/users/#{user_id}"
            end

            r.post 'permissions' do
              Permission.all.each do |perm_key|
                if r.params[perm_key] == '1'
                  @target_user.grant_permission!(perm_key)
                else
                  @target_user.revoke_permission!(perm_key)
                end
              end
              flash['success'] = 'Permissions updated successfully.'
              r.redirect "/admin/users/#{user_id}"
            end
          end
        end

        # Admin settings
        r.on 'settings' do
          r.is do
            r.get do
              setup_admin_settings_vars
              view 'admin/settings/index'
            end
          end

          r.get 'rooms_for_location' do
            location_id = r.params['location_id'].to_i
            rooms = Room.where(location_id: location_id)
                        .where(Sequel.lit("publicity IS NULL OR publicity = 'public'"))
                        .order(:name).all
                        .map { |rm| { id: rm.id, name: rm.name, room_type: rm.room_type } }
            response['Content-Type'] = 'application/json'
            rooms.to_json
          end

          r.post 'general' do
            GameSetting.set('game_name', r.params['game_name'], type: 'string')
            GameSetting.set('world_type', r.params['world_type'], type: 'string')
            GameSetting.set('time_period', r.params['time_period'], type: 'string')
            GameSetting.set('test_account_enabled', r.params['test_account_enabled'] == 'on', type: 'boolean')

            # Spawn location settings - clear if empty (auto-detect)
            %w[spawn_location_id spawn_room_id tutorial_spawn_room_id].each do |key|
              val = r.params[key].to_s.strip
              if val.empty?
                setting = GameSetting.first(key: key)
                if setting
                  GameSetting.invalidate_cache(key)
                  setting.destroy
                end
              else
                GameSetting.set(key, val.to_i, type: 'integer')
              end
            end

            flash['success'] = 'General settings saved'
            r.redirect '/admin/settings'
          end

          r.post 'time' do
            GameSetting.set('clock_mode', r.params['clock_mode'], type: 'string')
            GameSetting.set('earth_timezone', r.params['earth_timezone'], type: 'string')
            GameSetting.set('fictional_time_ratio', r.params['fictional_time_ratio'], type: 'string')
            GameSetting.set('fictional_current_date', r.params['fictional_current_date'], type: 'string')
            flash['success'] = 'Time settings saved'
            r.redirect '/admin/settings#time'
          end

          r.post 'weather' do
            GameSetting.set('weather_source', r.params['weather_source'], type: 'string')
            if r.params['weather_api_key'] && !r.params['weather_api_key'].empty?
              GameSetting.set('weather_api_key', r.params['weather_api_key'], type: 'string')
            end
            flash['success'] = 'Weather settings saved'
            r.redirect '/admin/settings#weather'
          end

          r.post 'ai' do
            # Save API keys only if provided (non-empty)
            %w[anthropic openai google_gemini openrouter replicate voyage].each do |provider|
              key_name = "#{provider}_api_key"
              if r.params[key_name] && !r.params[key_name].empty?
                GameSetting.set(key_name, r.params[key_name], type: 'string')
              end
            end
            GameSetting.set('ai_provider_order', r.params['ai_provider_order'], type: 'string') if r.params['ai_provider_order']
            GameSetting.set('default_embedding_model', r.params['default_embedding_model'], type: 'string') if r.params['default_embedding_model']

            # LLM Feature Toggles
            GameSetting.set('combat_llm_enhancement_enabled', r.params['combat_llm_enhancement_enabled'] == 'on', type: 'boolean')
            GameSetting.set('ai_battle_maps_enabled', r.params['ai_battle_maps_enabled'] == 'on', type: 'boolean')
            GameSetting.set('ai_weather_prose_enabled', r.params['ai_weather_prose_enabled'] == 'on', type: 'boolean')
            GameSetting.set('activity_free_roll_enabled', r.params['activity_free_roll_enabled'] == 'on', type: 'boolean')
            GameSetting.set('activity_persuade_enabled', r.params['activity_persuade_enabled'] == 'on', type: 'boolean')
            GameSetting.set('auto_gm_enabled', r.params['auto_gm_enabled'] == 'on', type: 'boolean')
            GameSetting.set('abuse_monitoring_enabled', r.params['abuse_monitoring_enabled'] == 'on', type: 'boolean')
            GameSetting.set('autohelper_enabled', r.params['autohelper_enabled'] == 'on', type: 'boolean')
            GameSetting.set('autohelper_ticket_threshold', r.params['autohelper_ticket_threshold'] || 'notable')

            flash['success'] = 'AI settings saved'
            r.redirect '/admin/settings#ai'
          end

          r.post 'delve' do
            # Skill check stats
            GameSetting.set('delve_barricade_stat', r.params['delve_barricade_stat'], type: 'string')
            GameSetting.set('delve_lockpick_stat', r.params['delve_lockpick_stat'], type: 'string')
            GameSetting.set('delve_jump_stat', r.params['delve_jump_stat'], type: 'string')
            GameSetting.set('delve_balance_stat', r.params['delve_balance_stat'], type: 'string')

            # Difficulty scaling
            GameSetting.set('delve_base_skill_dc', r.params['delve_base_skill_dc'].to_i, type: 'integer')
            GameSetting.set('delve_dc_per_level', r.params['delve_dc_per_level'].to_i, type: 'integer')
            GameSetting.set('delve_monster_move_threshold', r.params['delve_monster_move_threshold'].to_i, type: 'integer')

            # Time costs
            GameSetting.set('delve_time_move', r.params['delve_time_move'].to_i, type: 'integer')
            GameSetting.set('delve_time_combat_round', r.params['delve_time_combat_round'].to_i, type: 'integer')
            GameSetting.set('delve_time_skill_check', r.params['delve_time_skill_check'].to_i, type: 'integer')
            GameSetting.set('delve_time_trap_listen', r.params['delve_time_trap_listen'].to_i, type: 'integer')
            GameSetting.set('delve_time_puzzle_attempt', r.params['delve_time_puzzle_attempt'].to_i, type: 'integer')
            puzzle_help_seconds = r.params['delve_time_puzzle_help'].to_i
            GameSetting.set('delve_time_puzzle_help', puzzle_help_seconds, type: 'integer')
            GameSetting.set('delve_time_puzzle_hint', puzzle_help_seconds, type: 'integer')
            GameSetting.set('delve_time_easier', r.params['delve_time_easier'].to_i, type: 'integer')
            GameSetting.set('delve_time_recover', r.params['delve_time_recover'].to_i, type: 'integer')
            GameSetting.set('delve_time_focus', r.params['delve_time_focus'].to_i, type: 'integer')
            GameSetting.set('delve_time_study', r.params['delve_time_study'].to_i, type: 'integer')

            # Treasure settings
            GameSetting.set('delve_base_treasure_min', r.params['delve_base_treasure_min'].to_i, type: 'integer')
            GameSetting.set('delve_base_treasure_max', r.params['delve_base_treasure_max'].to_i, type: 'integer')

            flash['success'] = 'Delve settings saved'
            r.redirect '/admin/settings#delve'
          end

          # Email settings
          r.on 'email' do
            r.post do
              # Check if this is the first time enabling verification
              was_enabled = GameSetting.get_boolean('email_require_verification')
              now_enabled = r.params['email_require_verification'] == 'on'

              # Auto-verify existing users when first enabling
              if now_enabled && !was_enabled
                User.where(confirmed_at: nil).update(confirmed_at: Time.now)
              end

              GameSetting.set('email_require_verification', now_enabled, type: 'boolean')

              # Only update API key if provided (not empty)
              if r.params['sendgrid_api_key'] && !r.params['sendgrid_api_key'].empty?
                GameSetting.set('sendgrid_api_key', r.params['sendgrid_api_key'], type: 'string')
              end

              GameSetting.set('email_from_address', r.params['email_from_address'], type: 'string')
              GameSetting.set('email_from_name', r.params['email_from_name'], type: 'string')
              GameSetting.set('email_verification_subject', r.params['email_verification_subject'], type: 'string')

              flash['success'] = 'Email settings saved'
              r.redirect '/admin/settings#email'
            end

            r.post 'test' do
              if EmailService.send_test_email(current_user.email)
                flash['success'] = "Test email sent to #{current_user.email}"
              else
                flash['error'] = 'Failed to send test email. Check your SendGrid configuration.'
              end
              r.redirect '/admin/settings#email'
            end
          end

          # Storage settings (Cloudflare R2)
          r.on 'storage' do
            r.post do
              # Enable/disable toggle
              GameSetting.set('storage_r2_enabled', r.params['storage_r2_enabled'] == 'on', type: 'boolean')

              # Non-secret settings
              GameSetting.set('storage_r2_endpoint', r.params['storage_r2_endpoint'].to_s.strip, type: 'string')
              GameSetting.set('storage_r2_bucket', r.params['storage_r2_bucket'].to_s.strip, type: 'string')
              GameSetting.set('storage_r2_public_url', r.params['storage_r2_public_url'].to_s.strip, type: 'string')

              # Only update secrets if provided (not empty)
              if r.params['storage_r2_access_key'] && !r.params['storage_r2_access_key'].empty?
                GameSetting.set('storage_r2_access_key', r.params['storage_r2_access_key'], type: 'string')
              end
              if r.params['storage_r2_secret_key'] && !r.params['storage_r2_secret_key'].empty?
                GameSetting.set('storage_r2_secret_key', r.params['storage_r2_secret_key'], type: 'string')
              end

              # Clear client cache to pick up new config
              CloudStorageService.reset_client!

              flash['success'] = 'Storage settings saved'
              r.redirect '/admin/settings#storage'
            end

            r.post 'test' do
              response.headers['Content-Type'] = 'application/json'
              begin
                result = CloudStorageService.test_connection!
                result.to_json
              rescue StandardError => e
                { success: false, error: e.message }.to_json
              end
            end
          end

          r.post 'clear_api_key' do
            key_name = r.params['key_name']
            allowed_keys = %w[
              weather_api_key anthropic_api_key openai_api_key google_gemini_api_key
              openrouter_api_key replicate_api_key voyage_api_key sendgrid_api_key
              storage_r2_access_key storage_r2_secret_key
            ]
            if key_name && allowed_keys.include?(key_name)
              GameSetting.where(key: key_name).delete
              flash['success'] = 'API key cleared'
            else
              flash['error'] = 'Invalid key name'
            end
            r.redirect '/admin/settings'
          end
        end

        # Combat Round Logs viewer
        r.on 'combat_logs' do
          r.is do
            r.get do
              @selected_date = r.params['date'] || Time.now.strftime('%Y-%m-%d')
              @log_dates = combat_log_dates
              @fights = parse_combat_log_index(@selected_date)
              view 'admin/combat_logs/index'
            end
          end

          r.on Integer do |fight_id|
            r.is do
              r.get do
                @fight_id = fight_id
                @selected_date = r.params['date'] || Time.now.strftime('%Y-%m-%d')
                @rounds = parse_combat_log_fight(@selected_date, fight_id)
                view 'admin/combat_logs/show'
              end
            end
          end
        end

        # Stat Blocks (character stat configuration)
        r.on 'stat_blocks' do
          r.is do
            r.get do
              @stat_blocks = StatBlock.order(:name).all
              view 'admin/stat_blocks/index'
            end
          end

          r.get 'new' do
            @stat_block = StatBlock.new
            view 'admin/stat_blocks/edit'
          end

          r.on Integer do |id|
            @stat_block = StatBlock[id]
            unless @stat_block
              flash['error'] = 'Stat block not found'
              r.redirect '/admin/stat_blocks'
            end

            r.is do
              r.get do
                view 'admin/stat_blocks/edit'
              end

              r.post do
                @stat_block.update(
                  name: r.params['name'],
                  description: r.params['description'],
                  block_type: r.params['block_type'],
                  total_points: r.params['total_points'].to_i,
                  secondary_points: r.params['secondary_points'].to_i,
                  min_stat_value: r.params['min_stat_value'].to_i,
                  max_stat_value: r.params['max_stat_value'].to_i,
                  cost_formula: r.params['cost_formula'],
                  primary_label: r.params['primary_label'],
                  secondary_label: r.params['secondary_label'],
                  is_active: r.params['is_active'] == 'on'
                )
                flash['success'] = 'Stat block updated'
                r.redirect "/admin/stat_blocks/#{id}"
              end
            end

            r.post 'set_default' do
              StatBlock.where(universe_id: @stat_block.universe_id).update(is_default: false)
              @stat_block.update(is_default: true)
              flash['success'] = "#{@stat_block.name} is now the default stat block"
              r.redirect '/admin/stat_blocks'
            end

            r.post 'delete' do
              name = @stat_block.name
              @stat_block.destroy
              flash['success'] = "Stat block '#{name}' deleted"
              r.redirect '/admin/stat_blocks'
            end
          end
        end

        # Ability Simulator (combat balance tuning)
        r.on 'ability_simulator' do
          r.is do
            r.get do
              AbilityPowerWeights.reload!
              @coefficients = AbilityPowerWeights.all_coefficients
              @locked = AbilityPowerWeights.locked_coefficients
              @locked_weights = AbilityPowerWeights.locked_weights
              @last_run = AbilityPowerWeights.last_run
              @baseline = {
                damage: AbilityPowerWeights.baseline('damage'),
                hp: AbilityPowerWeights.baseline('hp'),
                hits_per_round: AbilityPowerWeights.baseline('hits_per_round'),
                rounds_per_fight: AbilityPowerWeights.baseline('rounds_per_fight')
              }
              view 'admin/ability_simulator/index'
            end

            r.post do
              # Handle the new form structure: weights[weights.status.stunned] or weights[coefficients.cc_stun_1r]
              r.params['weights']&.each do |key, value|
                if key.start_with?('coefficients.')
                  # Coefficient: coefficients.cc_stun_1r -> cc_stun_1r
                  coef_key = key.sub('coefficients.', '')
                  AbilityPowerWeights.set_coefficient(coef_key, value.to_f)
                elsif key.start_with?('weights.')
                  # Weight: weights.status.stunned -> status.stunned
                  weight_path = key.sub('weights.', '')
                  AbilityPowerWeights.set_weight(weight_path, value.to_f)
                end
              end

              # Legacy support for old form structure
              r.params['coefficients']&.each do |key, value|
                AbilityPowerWeights.set_coefficient(key, value.to_f)
              end

              # Update locked status - all keys not in locked[] become unlocked
              all_keys = AbilityPowerWeights.all_coefficients.keys
              locked_keys = Array(r.params['locked'])
              all_keys.each { |key| AbilityPowerWeights.set_locked(key, locked_keys.include?(key)) }

              # Update locked weights status
              locked_weight_paths = Array(r.params['locked_weights'])
              # Collect all weight paths from the form
              all_weight_paths = (r.params['weights'] || {}).keys
                .select { |k| k.start_with?('weights.') }
                .map { |k| k.sub('weights.', '') }
              all_weight_paths.each { |path| AbilityPowerWeights.set_weight_locked(path, locked_weight_paths.include?(path)) }

              AbilityPowerWeights.save!
              flash['success'] = 'Settings saved'
              r.redirect '/admin/ability_simulator'
            end
          end

          r.post 'run' do
            mode = r.params['mode'] == 'fresh' ? :fresh : :refine
            iterations = (r.params['iterations'] || 200).to_i.clamp(10, 1000)

            begin
              service = AbilitySimulatorRunnerService.new(mode: mode, iterations: iterations)
              service.run!
              flash['success'] = "Auto-tune completed (#{iterations} iterations, #{mode} mode)"
            rescue StandardError => e
              warn "[AbilitySimulator] Auto-tune failed: #{e.message}"
              flash['error'] = "Auto-tune failed: #{e.message}"
            end

            r.redirect '/admin/ability_simulator'
          end
        end

        # Spawn Settings (where 'enter game' takes new players)
        r.on 'spawn_settings' do
          r.is do
            r.get do
              @spawn_locations = begin
                Location.order(:name).all.map { |l| { id: l.id, name: l.display_name, is_city: l.is_city? } }
              rescue StandardError => e
                warn "[SpawnSettings] Failed to load locations: #{e.message}"
                []
              end

              spawn_location_id = GameSetting.get('spawn_location_id')&.to_i
              spawn_room_id = GameSetting.get('spawn_room_id')&.to_i
              tutorial_spawn_room_id = GameSetting.get('tutorial_spawn_room_id')&.to_i
              @spawn_location_id = spawn_location_id && spawn_location_id > 0 ? spawn_location_id : nil
              @spawn_room_id = spawn_room_id && spawn_room_id > 0 ? spawn_room_id : nil
              @tutorial_spawn_room_id = tutorial_spawn_room_id && tutorial_spawn_room_id > 0 ? tutorial_spawn_room_id : nil

              @spawn_rooms = begin
                if @spawn_location_id
                  Room.where(location_id: @spawn_location_id)
                      .where(Sequel.lit("publicity IS NULL OR publicity = 'public'"))
                      .order(:name).all
                      .map { |r| { id: r.id, name: r.name, room_type: r.room_type } }
                else
                  []
                end
              rescue StandardError => e
                warn "[SpawnSettings] Failed to load rooms: #{e.message}"
                []
              end

              @current_spawn_room = begin
                if @spawn_room_id
                  room = Room.first(id: @spawn_room_id)
                  if room
                    loc = room.location
                    { name: room.name, location_name: loc ? loc.display_name : 'Unknown' }
                  end
                elsif @spawn_location_id
                  loc = Location.first(id: @spawn_location_id)
                  if loc
                    { name: "Auto-detected room", location_name: loc.display_name }
                  end
                end
              rescue StandardError => e
                warn "[SpawnSettings] Failed to resolve current spawn room #{@spawn_room_id}: #{e.message}"
                nil
              end

              @current_tutorial_room = begin
                if @tutorial_spawn_room_id
                  room = Room.first(id: @tutorial_spawn_room_id)
                  if room
                    loc = room.location
                    { name: room.name, location_name: loc ? loc.display_name : 'Unknown' }
                  end
                end
              rescue StandardError => e
                warn "[SpawnSettings] Failed to resolve tutorial spawn room #{@tutorial_spawn_room_id}: #{e.message}"
                nil
              end

              @all_rooms = begin
                Room.order(:name).limit(500).all.map { |rm| { id: rm.id, name: rm.name, location_name: rm.location&.display_name } }
              rescue StandardError
                []
              end

              view 'admin/spawn_settings/index'
            end

            r.post do
              %w[spawn_location_id spawn_room_id tutorial_spawn_room_id].each do |key|
                val = r.params[key].to_s.strip
                if val.empty?
                  setting = GameSetting.first(key: key)
                  if setting
                    GameSetting.invalidate_cache(key)
                    setting.destroy
                  end
                else
                  GameSetting.set(key, val.to_i, type: 'integer')
                end
              end

              flash['success'] = 'Spawn settings saved'
              r.redirect '/admin/spawn_settings'
            end
          end

          r.get 'rooms_for_location' do
            location_id = r.params['location_id'].to_i
            rooms = Room.where(location_id: location_id)
                        .where(Sequel.lit("publicity IS NULL OR publicity = 'public'"))
                        .order(:name).all
                        .map { |rm| { id: rm.id, name: rm.name, room_type: rm.room_type } }
            response['Content-Type'] = 'application/json'
            rooms.to_json
          end
        end

        # World Builder (location/world management)
        r.on 'world_builder' do
          r.is do
            r.get do
              @worlds = World.order(:name).all rescue []
              @universes = Universe.order(:name).all rescue []

              # Batch-load counts to avoid N+1 queries (individual COUNTs timeout on large worlds)
              @region_counts = begin
                DB.transaction do
                  DB.run('SET LOCAL statement_timeout = 0')
                  WorldRegion.group_and_count(:world_id).to_hash(:world_id, :count)
                end
              rescue StandardError => e
                warn "[WorldBuilder] region count query failed: #{e.message}"
                {}
              end

              @hex_counts = begin
                DB.transaction do
                  DB.run('SET LOCAL statement_timeout = 0')
                  WorldHex.group_and_count(:world_id).to_hash(:world_id, :count)
                end
              rescue StandardError => e
                warn "[WorldBuilder] hex count query failed: #{e.message}"
                {}
              end

              view 'admin/world_builder/index'
            end

            r.post do
              name = request.params['name']
              universe_id = request.params['universe_id']

              begin
                world = World.create(
                  name: name,
                  universe_id: universe_id,
                  gravity_multiplier: 1.0,
                  world_size: 100.0
                )
                WorldRegion.create_initial_regions(world)
                flash['success'] = "World '#{name}' created successfully"
                r.redirect "/admin/world_builder/#{world.id}"
              rescue Sequel::ValidationFailed => e
                flash['error'] = "Failed to create world: #{e.message}"
                r.redirect '/admin/world_builder'
              rescue StandardError => e
                warn "[WorldBuilder] Failed to create world: #{e.message}"
                flash['error'] = "Failed to create world: #{e.message}"
                r.redirect '/admin/world_builder'
              end
            end
          end

          r.on Integer do |id|
            @world = World[id]
            unless @world
              flash['error'] = 'World not found'
              r.redirect '/admin/world_builder'
            end

            r.is do
              r.get do
                view 'admin/world_builder/editor'
              end
            end

            r.post 'delete' do
              name = @world.name
              DB.transaction do
                # Raise timeout for this transaction only - world deletion can be slow
                DB.run("SET LOCAL statement_timeout = '120s'")

                # Delete world journey passengers before journeys (no CASCADE on world_id)
                journey_ids = WorldJourney.where(world_id: @world.id).select_map(:id)
                WorldJourneyPassenger.where(world_journey_id: journey_ids).delete if journey_ids.any?
                WorldJourney.where(world_id: @world.id).delete

                # Collect room IDs to handle RESTRICT FK on character_instances
                zone_ids = Zone.where(world_id: @world.id).select_map(:id)
                location_ids = Location.where(zone_id: zone_ids).select_map(:id) if zone_ids.any?
                room_ids = Room.where(location_id: location_ids).select_map(:id) if location_ids&.any?

                if room_ids&.any?
                  # character_instances.current_room_id has ON DELETE RESTRICT - must clear first
                  CharacterInstance.where(current_room_id: room_ids).delete
                end

                # Delete world - CASCADE handles zones, locations, rooms, world_hexes,
                # world_regions, world_terrain_rasters, world_generation_jobs, and
                # all room child records (features, hexes, decorations, etc.)
                @world.delete
              end
              flash['success'] = "World '#{name}' deleted"
              r.redirect '/admin/world_builder'
            end

            # Location Editor - for editing individual locations within a world
            r.on 'location', Integer do |location_id|
              @location = Location[location_id]
              unless @location
                flash['error'] = 'Location not found'
                r.redirect "/admin/world_builder/#{@world.id}"
              end

              r.is do
                r.get do
                  view 'admin/world_builder/location_editor'
                end

                r.post do
                  # Update location details
                  update_params = {}
                  update_params[:name] = request.params['name'] if request.params['name'].to_s.strip != ''
                  update_params[:description] = request.params['description'] if request.params.key?('description')
                  update_params[:default_description] = request.params['default_description'] if request.params.key?('default_description')
                  update_params[:default_background_url] = request.params['default_background_url'] if request.params.key?('default_background_url')

                  @location.update(update_params) unless update_params.empty?

                  # Handle seasonal backgrounds
                  if request.params['seasonal_backgrounds'].is_a?(Hash)
                    request.params['seasonal_backgrounds'].each do |key, url|
                      next if url.to_s.strip.empty?
                      parts = key.split('_', 2)  # "dawn_spring" → ["dawn", "spring"]
                      time, season = parts[0], parts[1]
                      @location.set_default_background!(time, season, url.to_s.strip) if time && season
                    end
                  end

                  flash['success'] = 'Location updated'
                  r.redirect request.path
                end
              end

              r.on 'api' do
                response['Content-Type'] = 'application/json'

                r.post 'upload_image' do
                  file = request.params['image']
                  unless file && file[:tempfile]
                    next { success: false, error: 'No file provided' }.to_json
                  end
                  allowed_types = %w[image/jpeg image/png image/gif image/webp]
                  unless allowed_types.include?(file[:type])
                    next { success: false, error: 'Invalid file type' }.to_json
                  end
                  ext = File.extname(file[:filename].to_s).downcase
                  ext = '.jpg' if ext.empty?
                  filename = "location_#{@location.id}_#{Time.now.to_i}#{ext}"
                  upload_dir = File.join(Dir.pwd, 'public', 'uploads', 'locations')
                  FileUtils.mkdir_p(upload_dir)
                  File.open(File.join(upload_dir, filename), 'wb') { |f| f.write(file[:tempfile].read) }
                  url = "/uploads/locations/#{filename}"
                  { success: true, url: url }.to_json
                rescue StandardError => e
                  warn "[LocationEditor] Upload failed: #{e.message}"
                  { success: false, error: e.message }.to_json
                end

                r.post 'generate_background' do
                  unless WorldBuilderImageService.available?
                    next { success: false, error: 'Image generation not available' }.to_json
                  end
                  desc = @location.description.to_s
                  desc = @location.name if desc.strip.empty?
                  result = WorldBuilderImageService.generate(type: :room_background, description: desc)
                  result.to_json
                rescue StandardError => e
                  warn "[LocationEditor] AI generate failed: #{e.message}"
                  { success: false, error: e.message }.to_json
                end

                r.post 'generate_description' do
                  # Build a temporary room-like object for the generator
                  room_type = @location.location_type || 'standard'
                  result = Generators::RoomGeneratorService.generate_description_for_type(
                    name: @location.name,
                    room_type: room_type,
                    parent: nil,
                    setting: :fantasy,
                    seed_terms: SeedTermService.for_generation(:room, count: 5),
                    existing_description: @location.default_description,
                    options: {}
                  )
                  if result[:success]
                    { success: true, description: result[:content] }.to_json
                  else
                    { success: false, error: result[:error] || 'Generation failed' }.to_json
                  end
                rescue StandardError => e
                  warn "[LocationEditor] Generate description failed: #{e.message}"
                  { success: false, error: e.message }.to_json
                end
              end

              # Create a room in this location
              r.post 'rooms' do
                room_name = request.params['name'].to_s.strip
                if room_name.empty?
                  flash['error'] = 'Room name is required'
                  r.redirect "/admin/world_builder/#{@world.id}/location/#{@location.id}"
                end
                room_type = request.params['room_type'].to_s.strip
                room_type = 'standard' if room_type.empty? || !Room::VALID_ROOM_TYPES.include?(room_type)

                # Infer indoors from room type; outdoor_nature + outdoor_urban + water → outdoors
                outdoor_types = (Room::ROOM_TYPES[:outdoor_nature] || []) +
                                (Room::ROOM_TYPES[:outdoor_urban] || []) +
                                (Room::ROOM_TYPES[:water] || [])
                indoors_param = request.params['indoors']
                indoors = if !indoors_param.nil?
                  indoors_param == 'true' || indoors_param == '1'
                else
                  !outdoor_types.include?(room_type)
                end

                # Use zone polygon bounding box if available, otherwise 200x200
                polygon = @location.zone_polygon_in_feet rescue nil
                if polygon&.length.to_i >= 3
                  xs = polygon.map { |p| (p[:x] || p['x']).to_f }
                  ys = polygon.map { |p| (p[:y] || p['y']).to_f }
                  min_x, max_x = xs.minmax
                  min_y, max_y = ys.minmax
                  room_polygon = polygon
                else
                  min_x, max_x, min_y, max_y = 0, 200, 0, 200
                  room_polygon = nil
                end

                create_params = {
                  name: room_name,
                  location_id: @location.id,
                  short_description: request.params['short_description'].to_s.strip,
                  room_type: room_type,
                  indoors: indoors,
                  min_x: min_x, max_x: max_x,
                  min_y: min_y, max_y: max_y
                }
                create_params[:room_polygon] = Sequel.pg_jsonb_wrap(room_polygon) if room_polygon

                room = Room.create(create_params)
                flash['success'] = "Room \"#{room.name}\" created"
                r.redirect "/admin/room_builder/#{room.id}"
              end

              # Convert location to city
              r.post 'convert_to_city' do
                horizontal_streets = (request.params['horizontal_streets'] || 10).to_i.clamp(2, 50)
                vertical_streets = (request.params['vertical_streets'] || 10).to_i.clamp(2, 50)
                max_building_height = (request.params['max_building_height'] || 200).to_i.clamp(20, 1000)
                setting = request.params['setting'] || 'fantasy'
                city_name_override = request.params['city_name_override']&.strip
                generate_city_name = !request.params['generate_city_name'].nil?
                generate_street_names = !request.params['generate_street_names'].nil?
                generate_building_names = !request.params['generate_building_names'].nil?
                populate_npcs = !request.params['populate_npcs'].nil?
                populate_inventories = !request.params['populate_inventories'].nil?
                generate_location_images = !request.params['generate_location_images'].nil?
                generate_location_seasonal = !request.params['generate_location_seasonal'].nil?
                generate_location_timeofday = !request.params['generate_location_timeofday'].nil?
                generate_shop_images = !request.params['generate_shop_images'].nil?
                generate_shop_seasonal = !request.params['generate_shop_seasonal'].nil?
                city_name = (!city_name_override.nil? && !city_name_override.empty?) ? city_name_override : @location.name

                result = CityBuilderService.build_city(
                  location: @location,
                  params: {
                    city_name: city_name,
                    horizontal_streets: horizontal_streets,
                    vertical_streets: vertical_streets,
                    max_building_height: max_building_height,
                    setting: setting,
                    generate_city_name: generate_city_name,
                    use_llm_names: generate_street_names,  # maps form field to service param
                    generate_building_names: generate_building_names,
                    populate_npcs: populate_npcs,
                    populate_inventories: populate_inventories,
                    generate_location_images: generate_location_images,
                    generate_location_seasonal: generate_location_seasonal,
                    generate_location_timeofday: generate_location_timeofday,
                    generate_shop_images: generate_shop_images,
                    generate_shop_seasonal: generate_shop_seasonal
                  }
                )

                if result[:success]
                  begin
                    @location.reload
                  rescue StandardError => e
                    warn "[CityBuilder] Failed to reload location after city build: #{e.message}"
                  end  # Ensure city_built_at is visible from fresh DB load
                  flash['success'] = "City grid created with #{result[:intersections]&.length || 0} intersections"
                  r.redirect "/admin/city_builder/#{@location.id}"
                else
                  flash['error'] = "Failed to create city: #{result[:error]}"
                  r.redirect request.referer || "/admin/world_builder/#{@world.id}/location/#{@location.id}"
                end
              end
            end

            # World Builder API endpoints
            r.on 'api' do
              # Helper to determine hex direction from one hex to another
              determine_hex_direction = ->(from_x, from_y, to_x, to_y) do
                dx = to_x - from_x
                dy = to_y - from_y

                # Normalize direction to compass points
                # In offset hex grid: n/s is vertical, ne/se/nw/sw are diagonals
                if dx == 0 && dy < 0
                  'n'
                elsif dx == 0 && dy > 0
                  's'
                elsif dx > 0 && dy <= 0
                  'ne'
                elsif dx > 0 && dy > 0
                  'se'
                elsif dx < 0 && dy <= 0
                  'nw'
                elsif dx < 0 && dy > 0
                  'sw'
                else
                  nil
                end
              end

              # GET /admin/world_builder/:id/api/regions
              r.on 'regions' do
                r.get do
                  zoom_level = (request.params['zoom'] || 0).to_i
                  center_x = (request.params['center_x'] || 1).to_i
                  center_y = (request.params['center_y'] || 1).to_i

                  # Ensure initial regions exist at zoom level 0
                  if WorldRegion.where(world_id: @world.id, zoom_level: 0).count == 0
                    WorldRegion.create_initial_regions(@world)
                  end

                  regions = WorldRegion.region_view(@world, center_x, center_y, zoom_level)

                  response['Content-Type'] = 'application/json'
                  {
                    success: true,
                    regions: regions.map(&:to_api_hash),
                    zoom_level: zoom_level,
                    center_x: center_x,
                    center_y: center_y
                  }.to_json
                end
              end

              # GET /admin/world_builder/:id/api/cities
              r.on 'cities' do
                r.get do
                  cities = @world.zones.select { |z| z.zone_type == 'city' }

                  response['Content-Type'] = 'application/json'
                  {
                    success: true,
                    cities: cities.map do |city|
                      center = city.center_point
                      location = city.locations&.first
                      cx = center ? center[:x] : 0
                      cy = center ? center[:y] : 0

                      # Derive lat/lng from the location's globe_hex_id → WorldHex
                      lat = nil
                      lng = nil
                      if location&.globe_hex_id
                        world_hex = WorldHex.where(world_id: @world.id, globe_hex_id: location.globe_hex_id).first
                        if world_hex
                          lat = world_hex.latitude
                          lng = world_hex.longitude
                        end
                      end

                      {
                        id: city.id,
                        name: city.name,
                        zone_type: city.zone_type,
                        center_x: cx,
                        center_y: cy,
                        x: cx,
                        y: cy,
                        lat: lat,
                        lng: lng,
                        globe_hex_id: location&.globe_hex_id,
                        location_id: location&.id,
                        polygon_points: city.polygon_points
                      }
                    end
                  }.to_json
                end
              end

              # GET /admin/world_builder/:id/api/zones
              r.on 'zones' do
                r.get do
                  zones = @world.zones.reject { |z| z.zone_type == 'city' }

                  response['Content-Type'] = 'application/json'
                  {
                    success: true,
                    zones: zones.map do |zone|
                      {
                        id: zone.id,
                        name: zone.name,
                        zone_type: zone.zone_type,
                        polygon_points: zone.polygon_points,
                        danger_level: zone.danger_level
                      }
                    end
                  }.to_json
                end
              end

              # GET/POST /admin/world_builder/:id/api/features - Road/river/railway features
              r.on 'features' do
                r.get do
                  # Return features from WorldHex directional features
                  response['Content-Type'] = 'application/json'

                  # Only query hexes that actually have features (using partial indexes)
                  # Filter by lat/lng bounds if provided for region-scoped queries
                  feature_columns = %i[feature_n feature_ne feature_se feature_s feature_sw feature_nw]
                  has_feature_condition = Sequel.|(
                    *feature_columns.map { |col| Sequel.~(col => nil) }
                  )

                  query = WorldHex.where(world_id: @world.id).where(has_feature_condition)

                  # Support optional bounding box for region-scoped queries
                  if request.params['lat'] && request.params['lng']
                    lat = request.params['lat'].to_f
                    lng = request.params['lng'].to_f
                    radius = (request.params['radius'] || 10).to_f
                    query = query.where { (latitude >= lat - radius) & (latitude <= lat + radius) }
                    query = query.where { (longitude >= lng - radius) & (longitude <= lng + radius) }
                  end

                  features_from_hexes = []
                  query.limit(10_000).each do |hex|
                    hex.directional_features.each do |direction, feature_type|
                      features_from_hexes << {
                        hex_id: hex.id,
                        globe_hex_id: hex.globe_hex_id,
                        lat: hex.latitude,
                        lng: hex.longitude,
                        direction: direction,
                        type: feature_type
                      }
                    end
                  end

                  # Also return legacy features_json for backwards compatibility
                  legacy_features = @world.features_json || []

                  {
                    success: true,
                    features: legacy_features,
                    directional_features: features_from_hexes
                  }.to_json
                end

                r.post do
                  # Save features - supports both legacy format and directional format
                  data = JSON.parse(request.body.read) rescue {}
                  response['Content-Type'] = 'application/json'

                  # Handle directional features (new format)
                  if data['directional_features'].is_a?(Array)
                    saved_count = 0
                    errors = []

                    data['directional_features'].each do |feature|
                      begin
                        globe_hex_id = feature['globe_hex_id']
                        lat = feature['lat']
                        lng = feature['lng']
                        direction = feature['direction']&.to_s&.downcase
                        feature_type = feature['type']

                        next unless WorldHex::DIRECTIONS.include?(direction)
                        next unless WorldHex::FEATURE_TYPES.include?(feature_type) || feature_type.nil?

                        # Find hex by globe_hex_id or lat/lng
                        hex = if globe_hex_id
                                WorldHex.find_by_globe_hex(@world.id, globe_hex_id)
                              elsif lat && lng
                                WorldHex.find_nearest_by_latlon(@world.id, lat.to_f, lng.to_f)
                              end

                        if hex
                          hex.set_directional_feature(direction, feature_type)
                          saved_count += 1
                        else
                          errors << "Hex not found for feature at #{lat},#{lng}"
                        end
                      rescue StandardError => e
                        errors << e.message
                      end
                    end

                    next {
                      success: true,
                      saved_count: saved_count,
                      errors: errors.empty? ? nil : errors
                    }.to_json
                  end

                  # Handle legacy features format (array of {type, points})
                  features = data['features'] || []

                  # Validate features format
                  valid_types = %w[road river railway highway street trail canal]
                  validated_features = features.select do |f|
                    f.is_a?(Hash) &&
                      valid_types.include?(f['type']) &&
                      f['points'].is_a?(Array) &&
                      f['points'].length >= 2
                  end

                  @world.update(features_json: validated_features)

                  {
                    success: true,
                    features: validated_features,
                    saved_count: validated_features.length
                  }.to_json
                end
              end

              # POST /admin/world_builder/:id/api/region - Update a region
              r.on 'region' do
                r.post do
                  data = JSON.parse(request.body.read) rescue {}
                  region_x = data['region_x'].to_i
                  region_y = data['region_y'].to_i
                  zoom_level = data['zoom_level'].to_i
                  terrain = data['terrain']

                  region = WorldRegion.find_or_create(
                    world_id: @world.id,
                    region_x: region_x,
                    region_y: region_y,
                    zoom_level: zoom_level
                  ) do |r|
                    r.dominant_terrain = terrain || 'ocean'
                    r.is_generated = true
                    r.is_modified = true
                  end

                  if terrain && region
                    region.update(dominant_terrain: terrain, is_modified: true)
                  end

                  response['Content-Type'] = 'application/json'
                  { success: true, region: region&.to_api_hash }.to_json
                end
              end

              # POST /admin/world_builder/:id/api/city - Create a city
              r.on 'city' do
                r.post do
                  data = JSON.parse(request.body.read) rescue {}
                  name = data['name'].to_s.strip
                  name = nil if name.empty? # Allow blank name for AI generation
                  center_x = data['center_x'].to_f
                  center_y = data['center_y'].to_f
                  size = (data['size'] || 0.5).to_f
                  globe_hex_id = data['globe_hex_id']&.to_i

                  # Generation parameters (individual controls replace old ai_level radio)
                  generate_buildings = data['generate_buildings'] != false
                  generate_room_descriptions = data['generate_room_descriptions'] != false
                  green_space_ratio = data['green_space_ratio']&.to_f
                  horizontal_streets = (data['horizontal_streets'] || 10).to_i.clamp(2, 50)
                  vertical_streets = (data['vertical_streets'] || 10).to_i.clamp(2, 50)
                  max_building_height = (data['max_building_height'] || 200).to_i.clamp(20, 1000)
                  use_earth_names = data['use_earth_names'] == true
                  latitude = data['latitude']&.to_f
                  longitude = data['longitude']&.to_f

                  # Enhanced parameters
                  description = data['description'].to_s.strip
                  description = nil if description.empty?
                  setting = (data['setting'] || 'fantasy').to_sym
                  generate_name = data['generate_name'] != false
                  generate_npcs = data['generate_npcs'] == true
                  generate_portraits = data['generate_portraits'] == true
                  generate_schedules = data['generate_schedules'] == true
                  npc_density = (data['npc_density'] || 2).to_i.clamp(1, 3)
                  generate_images = data['generate_images'] || {}
                  zone_id = data['zone_id']&.to_i
                  use_ai_names = data.key?('use_ai_names') ? data['use_ai_names'] : nil
                  generate_inventory = data['generate_inventory'] != false

                  response['Content-Type'] = 'application/json'

                  begin
                    # Use existing zone if provided (from sub-hex editor), otherwise create one
                    if zone_id && zone_id > 0
                      zone = Zone[zone_id]
                      return { success: false, error: 'Zone not found' }.to_json unless zone
                      # Update zone name if a name was provided
                      zone.update(name: name) if name && zone.name != name
                    else
                      # Create a square polygon centered on the city point
                      polygon_points = [
                        { x: center_x - size, y: center_y - size },
                        { x: center_x + size, y: center_y - size },
                        { x: center_x + size, y: center_y + size },
                        { x: center_x - size, y: center_y + size }
                      ]

                      zone = Zone.create(
                        world_id: @world.id,
                        name: name || "City #{SecureRandom.hex(3)}",
                        zone_type: 'city',
                        danger_level: 1,
                        polygon_points: polygon_points
                      )

                      unless zone.valid?
                        return { success: false, errors: zone.errors.full_messages }.to_json
                      end
                    end

                    # Determine city size based on street count
                    city_size = case [horizontal_streets, vertical_streets].max
                                when 2..3 then :village
                                when 4..5 then :town
                                when 6..7 then :small_city
                                when 8..12 then :medium
                                when 13..17 then :large_city
                                else :metropolis
                                end

                    # Always create a Location for the city (needed for navigation)
                    location = Location.create(
                      world_id: @world.id,
                      zone_id: zone.id,
                      name: zone.name,
                      location_type: 'building', # Cities are building-type locations
                      city_name: zone.name,
                      horizontal_streets: horizontal_streets,
                      vertical_streets: vertical_streets,
                      max_building_height: max_building_height,
                      latitude: latitude,
                      longitude: longitude,
                      globe_hex_id: globe_hex_id
                    )

                    unless location.valid?
                      zone.destroy # Cleanup zone if location creation fails
                      return { success: false, errors: location.errors.full_messages }.to_json
                    end

                    # Always mark as city-built so it appears in city builder list.
                    # Minimal level creates the Location without rooms; moderate/full
                    # will overwrite this timestamp when CityBuilderService runs.
                    location.update(city_built_at: Time.now) unless location.city_built_at

                    result = {
                      success: true,
                      city: {
                        id: zone.id,
                        name: zone.name,
                        center_x: center_x,
                        center_y: center_y,
                        x: center_x, # Alias for hex-editor.js
                        y: center_y, # Alias for hex-editor.js
                        globe_hex_id: globe_hex_id
                      },
                      location_id: location.id
                    }

                    # Build city if buildings are requested (otherwise just Zone + Location)
                    if generate_buildings
                      gen_result = Generators::CityGeneratorService.generate(
                        location: location,
                        setting: setting,
                        size: city_size,
                        generate_places: true,
                        generate_place_rooms: generate_room_descriptions,
                        create_buildings: true,
                        generate_npcs: generate_npcs,
                        options: {
                          description: description,
                          generate_portraits: generate_portraits,
                          generate_schedules: generate_schedules,
                          npc_density: npc_density,
                          generate_images: generate_images,
                          green_space_ratio: green_space_ratio,
                          use_ai_names: use_ai_names,
                          generate_inventory: generate_inventory
                        }.compact
                      )

                      if gen_result[:success]
                        result[:city_name] = gen_result[:city_name] if gen_result[:city_name]
                        result[:streets] = gen_result[:streets] || 0
                        result[:intersections] = gen_result[:intersections] || 0
                        result[:places] = gen_result[:places]&.length || 0
                      else
                        result[:build_error] = gen_result[:errors]&.first
                      end
                    end

                    result.to_json
                  rescue StandardError => e
                    warn "[WorldBuilder] City creation failed: #{e.message}"
                    { success: false, error: e.message }.to_json
                  end
                end
              end

              # POST /admin/world_builder/:id/api/zone - Create a zone
              r.on 'zone' do
                r.is do
                  r.post do
                    response['Content-Type'] = 'application/json'

                    begin
                      data = JSON.parse(request.body.read) rescue {}
                      name = data['name'] || "Zone #{SecureRandom.hex(3)}"
                      zone_type = data['zone_type'] || 'area'
                      polygon_points = data['polygon_points'] || []

                      zone = Zone.create(
                        world_id: @world.id,
                        name: name,
                        zone_type: zone_type,
                        danger_level: (data['danger_level'] || 1).to_i,
                        polygon_points: polygon_points
                      )

                      {
                        success: zone.valid?,
                        zone: zone.valid? ? {
                          id: zone.id,
                          name: zone.name,
                          zone_type: zone.zone_type,
                          polygon_points: zone.polygon_points,
                          danger_level: zone.danger_level
                        } : nil,
                        errors: zone.errors.full_messages
                      }.to_json
                    rescue StandardError => e
                      warn "[WorldBuilder] zone create failed: #{e.message}"
                      { success: false, error: e.message }.to_json
                    end
                  end
                end

                # PATCH/DELETE /admin/world_builder/:id/api/zone/:zone_id
                r.on Integer do |zone_id|
                  zone = Zone[zone_id]

                  r.patch do
                    return { success: false, error: 'Zone not found' }.to_json unless zone

                    data = JSON.parse(request.body.read) rescue {}

                    update_params = {}
                    update_params[:name] = data['name'] if data.key?('name')
                    update_params[:zone_type] = data['zone_type'] if data.key?('zone_type')
                    update_params[:danger_level] = data['danger_level'].to_i if data.key?('danger_level')
                    update_params[:polygon_points] = data['polygon_points'] if data.key?('polygon_points')

                    zone.update(update_params) unless update_params.empty?

                    response['Content-Type'] = 'application/json'
                    {
                      success: true,
                      zone: {
                        id: zone.id,
                        name: zone.name,
                        zone_type: zone.zone_type,
                        polygon_points: zone.polygon_points,
                        danger_level: zone.danger_level
                      }
                    }.to_json
                  end

                  r.delete do
                    return { success: false, error: 'Zone not found' }.to_json unless zone

                    zone.destroy
                    response['Content-Type'] = 'application/json'
                    { success: true }.to_json
                  end
                end
              end

              # GET /admin/world_builder/:id/api/hex_details - Get zones/locations within a hex
              r.on 'hex_details' do
                r.get do
                  globe_hex_id = request.params['globe_hex_id']
                  hex_x = request.params['x']&.to_i
                  hex_y = request.params['y']&.to_i

                  response['Content-Type'] = 'application/json'

                  begin
                    if globe_hex_id
                      globe_hex_id = globe_hex_id.to_i
                      zones = Zone.where(world_id: @world.id, polygon_scale: 'local', globe_hex_id: globe_hex_id).all rescue []
                      locations = Location.where(world_id: @world.id, globe_hex_id: globe_hex_id).all rescue []
                    else
                      zones = []
                      locations = []
                    end

                    # Build a zone_id → location lookup so zones can link to their editors
                    zone_ids = zones.map(&:id)
                    zone_locations = if zone_ids.any?
                      Location.where(zone_id: zone_ids, world_id: @world.id).all.group_by(&:zone_id)
                    else
                      {}
                    end

                    {
                      success: true,
                      hex: globe_hex_id ? { globe_hex_id: globe_hex_id } : { x: hex_x, y: hex_y },
                      zones: zones.map { |z|
                        loc = zone_locations[z.id]&.first
                        {
                          id: z.id,
                          name: z.name,
                          zone_type: z.zone_type,
                          polygon_points: z.polygon_points,
                          polygon_scale: z.polygon_scale,
                          location_id: loc&.id,
                          has_city_grid: loc&.city_built_at ? true : false
                        }
                      },
                      locations: locations.map { |loc|
                        {
                          id: loc.id,
                          name: loc.name,
                          feet_x: loc.city_origin_x,
                          feet_y: loc.city_origin_y,
                          has_city_grid: !loc.city_built_at.nil?,
                          globe_hex_id: loc.globe_hex_id
                        }
                      }
                    }.to_json
                  rescue StandardError => e
                    warn "[WorldBuilder] hex_details failed: #{e.message}"
                    { success: false, error: e.message }.to_json
                  end
                end
              end

              # POST /admin/world_builder/:id/api/sub_hex_zone - Create zone within a hex at feet-level
              r.on 'sub_hex_zone' do
                r.post do
                  response['Content-Type'] = 'application/json'

                  begin
                    data = JSON.parse(request.body.read) rescue {}

                    name = data['name'] || "Zone #{SecureRandom.hex(3)}"
                    globe_hex_id = data['globe_hex_id']&.to_i
                    lat = data['lat']&.to_f
                    lng = data['lng']&.to_f
                    polygon_points = data['polygon_points'] || []
                    polygon_scale = data['polygon_scale'] || 'local'
                    zone_type = data['zone_type'] || 'area'
                    # Validate zone_type
                    zone_type = 'area' unless %w[political area location city].include?(zone_type)

                    zone = Zone.create(
                      world_id: @world.id,
                      name: name,
                      zone_type: zone_type,
                      danger_level: 1,
                      polygon_points: polygon_points,
                      polygon_scale: polygon_scale,
                      globe_hex_id: globe_hex_id.positive? ? globe_hex_id : nil
                    )

                    if zone.valid?
                      {
                        success: true,
                        zone: {
                          id: zone.id,
                          name: zone.name,
                          polygon_points: zone.polygon_points,
                          globe_hex_id: globe_hex_id,
                          lat: lat,
                          lng: lng
                        }
                      }.to_json
                    else
                      { success: false, errors: zone.errors.full_messages }.to_json
                    end
                  rescue StandardError => e
                    warn "[WorldBuilder] sub_hex_zone create failed: #{e.message}"
                    { success: false, error: e.message }.to_json
                  end
                end
              end

              # POST /admin/world_builder/:id/api/create_location - Create location within a hex
              r.on 'create_location' do
                r.post do
                  response['Content-Type'] = 'application/json'

                  begin
                    data = JSON.parse(request.body.read) rescue {}

                    name = data['name']
                    return { success: false, error: 'Name is required' }.to_json if name.nil? || name.strip.empty?

                    globe_hex_id = data['globe_hex_id']&.to_i
                    feet_x = data['feet_x']&.to_f
                    feet_y = data['feet_y']&.to_f

                    # Use existing zone if provided, otherwise create one
                    zone_id = data['zone_id']&.to_i
                    if zone_id && zone_id > 0
                      zone = Zone[zone_id]
                      return { success: false, error: 'Zone not found' }.to_json unless zone
                    else
                      zone = Zone.create(
                        world_id: @world.id,
                        name: name,
                        zone_type: 'location',
                        danger_level: 1
                      )

                      unless zone.valid?
                        return { success: false, errors: zone.errors.full_messages }.to_json
                      end
                    end

                    # Create the location
                    location = Location.create(
                      zone_id: zone.id,
                      world_id: @world.id,
                      name: name,
                      location_type: data['location_type'] || 'outdoor',
                      globe_hex_id: globe_hex_id,
                      city_origin_x: feet_x,
                      city_origin_y: feet_y
                    )

                    if location.valid?
                      {
                        success: true,
                        location: {
                          id: location.id,
                          name: location.name,
                          zone_id: zone.id,
                          globe_hex_id: globe_hex_id,
                          feet_x: feet_x,
                          feet_y: feet_y
                        },
                        location_id: location.id
                      }.to_json
                    else
                      zone.destroy # Clean up the orphaned zone
                      { success: false, errors: location.errors.full_messages }.to_json
                    end
                  rescue StandardError => e
                    warn "[WorldBuilder] create_location failed: #{e.message}"
                    { success: false, error: e.message }.to_json
                  end
                end
              end

              # POST /admin/world_builder/:id/api/link - Link two hex coordinates (legacy)
              r.on 'link' do
                r.post do
                  data = JSON.parse(request.body.read) rescue {}
                  from_city_id = data['from_city_id']
                  to_city_id = data['to_city_id']

                  # For now, just acknowledge the link request
                  # Full implementation would create WorldHex features along the path
                  response['Content-Type'] = 'application/json'
                  {
                    success: true,
                    message: "Link created between cities #{from_city_id} and #{to_city_id}"
                  }.to_json
                end
              end

              # POST /admin/world_builder/:id/api/link_cities - Link two cities via dropdown selection
              r.on 'link_cities' do
                r.post do
                  data = JSON.parse(request.body.read) rescue {}
                  from_city_id = data['from_city_id']
                  to_city_id = data['to_city_id']
                  feature_type = data['feature_type'] || 'road'

                  response['Content-Type'] = 'application/json'

                  # Validate feature type
                  valid_features = %w[trail road highway railway]
                  unless valid_features.include?(feature_type)
                    return { success: false, error: "Invalid feature type. Must be one of: #{valid_features.join(', ')}" }.to_json
                  end

                  # Find the cities (zones with zone_type == 'city')
                  from_city = Zone.where(id: from_city_id, world_id: @world.id, zone_type: 'city').first
                  to_city = Zone.where(id: to_city_id, world_id: @world.id, zone_type: 'city').first

                  unless from_city && to_city
                    return { success: false, error: 'One or both cities not found' }.to_json
                  end

                  if from_city_id == to_city_id
                    return { success: false, error: 'Cannot link a city to itself' }.to_json
                  end

                  # Get center points of both cities
                  from_center = from_city.center_point
                  to_center = to_city.center_point

                  unless from_center && to_center
                    return { success: false, error: 'Cities must have polygon boundaries to determine their centers' }.to_json
                  end

                  # For now, we'll create a simple direct link by updating hexes along the path
                  # Future implementation could use A* pathfinding for more realistic routes
                  hexes_updated = 0

                  # Calculate hexes along the path (simple linear interpolation)
                  from_x = from_center[:x].to_i
                  from_y = from_center[:y].to_i
                  to_x = to_center[:x].to_i
                  to_y = to_center[:y].to_i

                  # Use Bresenham's line algorithm for hex path
                  dx = (to_x - from_x).abs
                  dy = (to_y - from_y).abs
                  sx = from_x < to_x ? 1 : -1
                  sy = from_y < to_y ? 1 : -1
                  err = dx - dy

                  current_x = from_x
                  current_y = from_y

                  while true
                    # Ensure valid hex coordinates (y must be even, x parity depends on y)
                    hex_y = current_y.even? ? current_y : current_y + 1
                    hex_x = if hex_y % 4 == 0
                              current_x.even? ? current_x : current_x + 1
                            else
                              current_x.odd? ? current_x : current_x + 1
                            end

                    # Create or update hex with the feature
                    hex = WorldHex.find_or_create(
                      world_id: @world.id,
                      hex_x: hex_x,
                      hex_y: hex_y
                    ) do |h|
                      h.terrain_type = WorldHex::DEFAULT_TERRAIN
                    end

                    # Set directional features based on path direction
                    # For simplicity, we set the feature in multiple directions at junction points
                    if hex
                      # Determine direction from previous hex to this hex
                      prev_x = current_x - sx
                      prev_y = current_y - sy

                      # Set incoming direction feature
                      direction = determine_hex_direction.call(prev_x, prev_y, hex_x, hex_y)
                      if direction
                        hex.set_directional_feature(direction, feature_type)
                      end

                      # Set outgoing direction feature
                      next_x = current_x + sx
                      next_y = current_y + sy
                      out_direction = determine_hex_direction.call(hex_x, hex_y, next_x, next_y)
                      if out_direction
                        hex.set_directional_feature(out_direction, feature_type)
                      end

                      hexes_updated += 1
                    end

                    break if current_x == to_x && current_y == to_y

                    e2 = 2 * err
                    if e2 > -dy
                      err -= dy
                      current_x += sx
                    end
                    if e2 < dx
                      err += dx
                      current_y += sy
                    end
                  end

                  {
                    success: true,
                    from_city: from_city.name,
                    to_city: to_city.name,
                    feature_type: feature_type,
                    hexes_updated: hexes_updated
                  }.to_json
                rescue StandardError => e
                  warn "[WorldBuilder] Link cities failed: #{e.message}"
                  { success: false, error: 'Failed to create link' }.to_json
                end
              end

              # POST /admin/world_builder/:id/api/generate - Generate world terrain
              # Uses the 5-phase procedural pipeline: tectonics, elevation, climate, rivers, biomes
              # Also supports earth_import type for importing real Earth data
              r.on 'generate' do
                r.post do
                  response['Content-Type'] = 'application/json'

                  begin
                    data = JSON.parse(request.body.read) rescue {}
                    generation_type = data['type'] || 'procedural'
                    options = data['options'] || {}

                    # Handle earth_import type separately
                    if generation_type == 'earth_import'
                      job = WorldGenerationJob.create(
                        world_id: @world.id,
                        job_type: 'earth_import',
                        status: 'pending',
                        config: {
                          'subdivisions' => options['subdivisions'] || 6
                        }
                      )

                      # Start background earth import thread
                      job_id = job.id
                      Thread.new do
                        thread_job = WorldGenerationJob[job_id]
                        EarthImport::PipelineService.new(thread_job).run
                      rescue StandardError => e
                        warn "[EarthImport] Background thread error: #{e.message}"
                        fresh_job = WorldGenerationJob[job_id]
                        fresh_job&.fail!(e.message) unless fresh_job&.finished?
                      end
                    else
                      # Standard procedural generation (globe-based)
                      world_size = options['world_size'] || 0.5

                      job = WorldGenerationJob.create(
                        world_id: @world.id,
                        job_type: 'procedural',
                        status: 'pending',
                        config: {
                          'preset' => options['preset'] || 'earth_like',
                          'seed' => options['seed'],
                          'subdivisions' => options['subdivisions'],
                          'world_size' => world_size
                        }.compact
                      )

                      # Start background generation thread
                      job_id = job.id
                      Thread.new do
                        # Re-fetch job in new thread to ensure fresh database connection
                        thread_job = WorldGenerationJob[job_id]
                        WorldGeneration::PipelineService.new(thread_job).run
                      rescue StandardError => e
                        warn "[WorldGeneration] Background thread error: #{e.message}"
                        # Re-fetch to get fresh state before checking finished?
                        fresh_job = WorldGenerationJob[job_id]
                        fresh_job&.fail!(e.message) unless fresh_job&.finished?
                      end
                    end

                    {
                      success: true,
                      job: {
                        id: job.id,
                        status: job.status,
                        progress_percentage: 0
                      }
                    }.to_json
                  rescue StandardError => e
                    warn "[WorldBuilder] Generate failed: #{e.message}"
                    { success: false, error: e.message }.to_json
                  end
                end
              end

              # GET /admin/world_builder/:id/api/generation_status
              # Returns current job status with phase info and progress
              r.on 'generation_status' do
                r.get do
                  response['Content-Type'] = 'application/json'
                  begin
                    job = WorldGenerationJob.latest_for(@world)

                    if job
                      {
                        success: true,
                        job: {
                          id: job.id,
                          status: job.status,
                          progress_percentage: job.progress_percentage || 0,
                          phase: job.config&.dig('phase'),
                          subphase: job.config&.dig('subphase'),
                          phases_complete: job.config&.dig('phases_complete') || [],
                          completed_regions: job.completed_regions,
                          total_regions: job.total_regions,
                          error_message: job.error_message,
                          started_at: job.started_at&.iso8601,
                          completed_at: job.completed_at&.iso8601
                        }
                      }.to_json
                    else
                      { success: true, job: nil }.to_json
                    end
                  rescue StandardError => e
                    warn "[WorldBuilder] Generation status check failed: #{e.message}"
                    response.status = 500
                    { success: false, error: 'Status check temporarily unavailable' }.to_json
                  end
                end
              end

              # POST /admin/world_builder/:id/api/bulk_traversable - Bulk set traversable
              r.on 'bulk_traversable' do
                r.post do
                  data = JSON.parse(request.body.read) rescue {}
                  traversable = data['traversable'] == true

                  # Update all WorldHex records (the actual hex data used by pathfinding)
                  hex_count = WorldHex.set_all_traversable(@world, traversable: traversable)

                  # Also update WorldRegion aggregates for display consistency
                  WorldRegion.where(world_id: @world.id).update(
                    traversable_percentage: traversable ? 100 : 0
                  )

                  response['Content-Type'] = 'application/json'
                  { success: true, traversable: traversable, updated_hexes: hex_count }.to_json
                end
              end

              # POST /admin/world_builder/:id/api/landmass_traversable - Toggle traversable for connected landmass
              r.on 'landmass_traversable' do
                r.post do
                  data = JSON.parse(request.body.read) rescue {}
                  traversable = data['traversable'] == true

                  response['Content-Type'] = 'application/json'

                  # Find the seed hex
                  seed_hex = if data['globe_hex_id']
                              WorldHex.where(id: data['globe_hex_id'], world_id: @world.id).first
                            elsif data['lat'] && data['lng']
                              WorldHex.where(world_id: @world.id)
                                      .order(Sequel.lit('ABS(latitude - ?) + ABS(longitude - ?)', data['lat'].to_f, data['lng'].to_f))
                                      .first
                            end

                  unless seed_hex
                    next { success: false, error: 'Seed hex not found' }.to_json
                  end

                  # Don't flood fill from water hexes
                  water_terrains = %w[ocean lake]
                  if water_terrains.include?(seed_hex.terrain)
                    next { success: false, error: 'Cannot toggle landmass from a water hex' }.to_json
                  end

                  # BFS flood fill to find all connected land hexes
                  visited = Set.new
                  queue = [seed_hex]
                  visited.add(seed_hex.id)
                  land_hex_ids = []

                  while queue.any?
                    current = queue.shift
                    land_hex_ids << current.id

                    # Process in reasonable batches to avoid memory issues
                    if land_hex_ids.size > 100_000
                      break # Safety cap for very large landmasses
                    end

                    neighbors = WorldHex.neighbors_of(current)
                    neighbors.each do |neighbor|
                      next if visited.include?(neighbor.id)
                      next if water_terrains.include?(neighbor.terrain)
                      visited.add(neighbor.id)
                      queue << neighbor
                    end
                  end

                  # Bulk update in chunks of 1000
                  updated = 0
                  land_hex_ids.each_slice(1000) do |chunk|
                    updated += WorldHex.where(id: chunk).update(traversable: traversable)
                  end

                  { success: true, traversable: traversable, updated_hexes: updated }.to_json
                end
              end

              # ============================================
              # Globe View API Endpoints (3D icosahedral)
              # ============================================

              # GET /admin/world_builder/:id/api/terrain_texture.png - Pre-rendered terrain texture
              # Returns a 4096x2048 equirectangular PNG for efficient Globe.gl rendering
              r.get 'terrain_texture.png' do
                response['Content-Type'] = 'image/png'
                # Disable browser caching - textures change during world building
                response['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
                response['Pragma'] = 'no-cache'
                response['Expires'] = '0'

                cache_dir = File.join(Dir.pwd, 'tmp', 'textures')
                cache_path = File.join(cache_dir, "world_#{@world.id}.png")

                # Regenerate if missing or stale (world updated since texture generated)
                needs_regeneration = !File.exist?(cache_path) ||
                                     (@world.updated_at && File.mtime(cache_path) < @world.updated_at)

                if needs_regeneration
                  begin
                    png_data = TerrainTextureService.new(@world).generate
                    FileUtils.mkdir_p(cache_dir)
                    File.binwrite(cache_path, png_data)
                  rescue StandardError => e
                    warn "[TerrainTexture] Generation failed: #{e.message}"
                    # Return a minimal error image or ocean-only texture
                    response.status = 500
                    return ''
                  end
                end

                File.binread(cache_path)
              end

              # GET /admin/world_builder/:id/api/globe_hexes - All hex data for 3D globe view
              # Supports pagination: ?limit=1000&offset=0
              r.on 'globe_hexes' do
                r.get do
                  # Pagination with sensible limits
                  limit = [(request.params['limit'] || 1000).to_i, 10_000].min
                  limit = 1 if limit < 1
                  offset = (request.params['offset'] || 0).to_i
                  offset = 0 if offset < 0

                  total_count = WorldHex.where(world_id: @world.id).count
                  hexes = WorldHex.where(world_id: @world.id)
                                  .limit(limit)
                                  .offset(offset)
                                  .all
                                  .map do |hex|
                    {
                      id: hex.globe_hex_id || hex.id,
                      lat: hex.latitude || 0,
                      lng: hex.longitude || 0,
                      terrain: hex.terrain_type,
                      traversable: hex.traversable,
                      altitude: hex.altitude
                    }
                  end

                  response['Content-Type'] = 'application/json'
                  {
                    success: true,
                    hexes: hexes,
                    pagination: {
                      total: total_count,
                      limit: limit,
                      offset: offset,
                      has_more: offset + limit < total_count
                    }
                  }.to_json
                end
              end

              # GET /admin/world_builder/:id/api/nearest_hex - Find nearest hex to lat/lng
              # Used for click detection on the globe instead of loading all hexes client-side
              r.on 'nearest_hex' do
                r.get do
                  lat = request.params['lat']&.to_f
                  lng = request.params['lng']&.to_f

                  unless lat && lng
                    response['Content-Type'] = 'application/json'
                    response.status = 400
                    next { success: false, error: 'lat and lng parameters required' }.to_json
                  end

                  hex = WorldHex.find_nearest_by_latlon(@world.id, lat, lng)

                  response['Content-Type'] = 'application/json'
                  if hex
                    {
                      success: true,
                      hex: {
                        id: hex.globe_hex_id || hex.id,
                        lat: hex.latitude || 0,
                        lng: hex.longitude || 0,
                        terrain: hex.terrain_type,
                        traversable: hex.traversable,
                        altitude: hex.altitude
                      }
                    }.to_json
                  else
                    { success: true, hex: nil }.to_json
                  end
                end
              end

              # GET/POST /admin/world_builder/:id/api/globe_region - Get or save region data by icosahedral coordinates
              r.on 'globe_region' do
                r.is do
                  # GET - Get region data for 2D editor
                  r.get do
                    face = (request.params['face'] || 0).to_i
                    x = (request.params['x'] || 0).to_i
                    y = (request.params['y'] || 0).to_i
                    size = (request.params['size'] || 6).to_i

                    # Globe worlds use lat/lng for positioning
                    # Map x,y params to lat/lng bounds
                    # x ranges from 0 to 360 (longitude mapped to positive range)
                    # y ranges from 0 to 180 (latitude mapped to positive range)
                    # Each grid unit = 1 degree
                    min_lng = x - 180  # Convert to -180..180 range
                    max_lng = min_lng + size
                    min_lat = 90 - y - size  # Convert to -90..90 range (y=0 is north pole)
                    max_lat = 90 - y

                    # Use DISTINCT ON to push nearest-neighbor into SQL.
                    # For each 1-degree grid cell, Postgres picks the closest hex
                    # by Euclidean distance — returns ~400 rows instead of ~112K.
                    # FLOOR aligns cells with the grid: cell_x=0 covers [min_lng, min_lng+1).
                    min_lng_f = min_lng.to_f
                    max_lat_f = max_lat.to_f
                    hexes_raw = DB.fetch(
                      "SELECT DISTINCT ON (cell_x, cell_y) " \
                      "id, globe_hex_id, latitude, longitude, terrain_type, traversable, altitude, " \
                      "feature_n, feature_ne, feature_se, feature_s, feature_sw, feature_nw, " \
                      "FLOOR(longitude - ?::float8)::int AS cell_x, " \
                      "FLOOR(?::float8 - latitude)::int AS cell_y " \
                      "FROM world_hexes " \
                      "WHERE world_id = ? AND longitude >= ? AND longitude < ? AND latitude >= ? AND latitude < ? " \
                      "ORDER BY cell_x, cell_y, " \
                      "((longitude - ?) - FLOOR(longitude - ?) - 0.5)^2 + " \
                      "((? - latitude) - FLOOR(? - latitude) - 0.5)^2",
                      min_lng_f, max_lat_f,
                      @world.id, min_lng_f - 0.5, max_lng.to_f + 0.5, min_lat.to_f - 0.5, max_lat_f + 0.5,
                      min_lng_f, min_lng_f, max_lat_f, max_lat_f
                    ).all

                    # Index results by grid cell coordinates (cell_x, cell_y map directly to grid offsets)
                    hex_by_cell = {}
                    hexes_raw.each do |row|
                      hex_by_cell[[row[:cell_x], row[:cell_y]]] = row
                    end

                    # Fill in ALL grid cells with nearest hex data (interpolation)
                    hexes = []
                    size.times do |grid_y_offset|
                      size.times do |grid_x_offset|
                        cell_lng = min_lng + grid_x_offset + 0.5
                        cell_lat = max_lat - grid_y_offset - 0.5

                        # Look up directly by grid offset (matches FLOOR-based cell_x, cell_y)
                        nearest = hex_by_cell[[grid_x_offset, grid_y_offset]]

                        if nearest
                          features = {}
                          %w[n ne se s sw nw].each do |dir|
                            val = nearest[:"feature_#{dir}"]
                            features[dir] = val if val
                          end

                          hexes << {
                            id: nearest[:id],
                            globe_hex_id: nearest[:globe_hex_id],
                            x: grid_x_offset,
                            y: grid_y_offset,
                            lat: cell_lat,
                            lng: cell_lng,
                            terrain: nearest[:terrain_type],
                            traversable: nearest[:traversable],
                            altitude: nearest[:altitude],
                            features: features,
                            interpolated: true
                          }
                        else
                          hexes << {
                            x: grid_x_offset,
                            y: grid_y_offset,
                            lat: cell_lat,
                            lng: cell_lng,
                            terrain: 'ocean',
                            interpolated: true
                          }
                        end
                      end
                    end

                    response['Content-Type'] = 'application/json'
                    {
                      success: true,
                      origin: { face: face, x: x, y: y },
                      size: size,
                      hexes: hexes,
                      is_globe_world: true
                    }.to_json
                  end

                  # POST - Save region changes from 2D editor
                  r.post do
                    # Parse JSON with proper error handling
                    begin
                      data = JSON.parse(request.body.read)
                    rescue JSON::ParserError => e
                      warn "[GlobeRegionAPI] Invalid JSON: #{e.message}"
                      response['Content-Type'] = 'application/json'
                      response.status = 400
                      next { success: false, error: 'Invalid JSON in request body' }.to_json
                    end

                    # Validate required fields
                    unless data.is_a?(Hash)
                      response['Content-Type'] = 'application/json'
                      response.status = 400
                      next { success: false, error: 'Request body must be a JSON object' }.to_json
                    end

                    # Validate face is an integer 0-19 (icosahedral faces)
                    face = data['face']
                    unless face.is_a?(Integer) || (face.is_a?(String) && face.match?(/^\d+$/))
                      response['Content-Type'] = 'application/json'
                      response.status = 400
                      next { success: false, error: 'face must be an integer' }.to_json
                    end
                    face = face.to_i
                    unless face >= 0 && face <= 19
                      response['Content-Type'] = 'application/json'
                      response.status = 400
                      next { success: false, error: 'face must be between 0 and 19' }.to_json
                    end

                    # Validate hexes is an array
                    hexes_data = data['hexes']
                    unless hexes_data.is_a?(Array)
                      response['Content-Type'] = 'application/json'
                      response.status = 400
                      next { success: false, error: 'hexes must be an array' }.to_json
                    end

                    origin_x = (data['origin_x'] || 0).to_i
                    origin_y = (data['origin_y'] || 0).to_i

                    saved_count = 0
                    errors = []

                    hexes_data.each do |hex_data|
                      begin
                        unless hex_data.is_a?(Hash)
                          errors << 'Each hex entry must be an object'
                          next
                        end

                        globe_hex_id = hex_data['globe_hex_id'] || hex_data['id']
                        lat = hex_data['lat']
                        lng = hex_data['lng']

                        # Find existing hex by globe_hex_id or lat/lng
                        hex = if globe_hex_id
                                WorldHex.find_by_globe_hex(@world.id, globe_hex_id)
                              elsif lat && lng
                                WorldHex.find_nearest_by_latlon(@world.id, lat, lng)
                              end

                        if hex
                          # Update existing hex
                          update_attrs = {}
                          update_attrs[:terrain_type] = hex_data['terrain'] if hex_data.key?('terrain')
                          update_attrs[:traversable] = hex_data['traversable'] if hex_data.key?('traversable')
                          hex.update(update_attrs) unless update_attrs.empty?
                          saved_count += 1
                        else
                          # Hex not found - skip creating new hexes via this endpoint
                          # (they should be created via world generation)
                          errors << "Hex with globe_hex_id #{globe_hex_id} not found"
                        end
                      rescue StandardError => e
                        warn "[GlobeRegionAPI] Error updating hex: #{e.message}"
                        errors << e.message
                      end
                    end

                    response['Content-Type'] = 'application/json'
                    {
                      success: errors.empty?,
                      saved: saved_count,
                      errors: errors
                    }.to_json
                  end
                end
              end

              # GET /admin/world_builder/:id/api/world_overview - Low-res terrain for minimap
              r.get 'world_overview' do
                terrain = []

                # Globe world: use lat/lng for bounds and sampling
                min_x = 0
                max_x = 360
                min_y = 0
                max_y = 180

                # Globe worlds can have millions of hexes - sample aggressively
                # Use TABLESAMPLE for fast random sampling without full table scan
                step = 100
                begin
                  DB.transaction do
                    DB.run("SET LOCAL statement_timeout = '30s'")
                    DB.fetch(
                      'SELECT latitude, longitude, terrain_type FROM world_hexes TABLESAMPLE SYSTEM (0.5) WHERE world_id = ? AND latitude IS NOT NULL LIMIT 60000',
                      @world.id
                    ).each do |row|
                      grid_x = (row[:longitude] + 180).floor
                      grid_y = (90 - row[:latitude]).floor
                      terrain << {
                        x: grid_x,
                        y: grid_y,
                        t: (row[:terrain_type] || 'ocean')[0]
                      }
                    end
                  end
                rescue Sequel::DatabaseError => e
                  warn "[WorldBuilder] world_overview sampling failed: #{e.message}"
                end

                response['Content-Type'] = 'application/json'
                {
                  success: true,
                  is_globe_world: true,
                  bounds: {
                    minX: min_x,
                    maxX: max_x,
                    minY: min_y,
                    maxY: max_y
                  },
                  terrain: terrain,
                  step: step
                }.to_json
              end
            end

            # Weather Grid toggle and status endpoints
            r.on 'weather_grid' do
              r.is do
                r.post do
                  enabled = request.params['enabled'] == 'true'
                  @world.update(use_grid_weather: enabled)

                  # Initialize grid if enabling for the first time
                  if enabled
                    begin
                      unless defined?(WeatherGrid::GridService) && WeatherGrid::GridService.exists?(@world)
                        WeatherGrid::TerrainService.aggregate(@world) if defined?(WeatherGrid::TerrainService)
                        WeatherGrid::GridService.initialize_world(@world) if defined?(WeatherGrid::GridService)
                      end
                    rescue StandardError => e
                      warn "[WorldBuilder] Grid weather init error: #{e.message}"
                    end
                  end

                  flash['success'] = enabled ? 'Grid weather enabled' : 'Grid weather disabled'
                  r.redirect "/admin/world_builder/#{@world.id}"
                end
              end

              r.get 'status' do
                meta = @world.weather_grid_meta
                storms = @world.active_storms

                response['Content-Type'] = 'application/json'
                {
                  enabled: @world.grid_weather?,
                  grid_initialized: (defined?(WeatherGrid::GridService) && WeatherGrid::GridService.exists?(@world)) || false,
                  last_tick_at: meta&.dig('last_tick_at'),
                  tick_count: meta&.dig('tick_count') || 0,
                  storms: storms.map { |s|
                    { type: s['type'], phase: s['phase'], name: s['name'],
                      grid_x: s['grid_x']&.to_f&.round(1), grid_y: s['grid_y']&.to_f&.round(1),
                      intensity: s['intensity']&.to_f&.round(2) }
                  }
                }.to_json
              end

              r.post 'reset' do
                begin
                  WeatherGrid::GridService.clear(@world) if defined?(WeatherGrid::GridService)
                  WeatherGrid::TerrainService.clear(@world) if defined?(WeatherGrid::TerrainService)
                  @world.weather_world_state&.destroy
                rescue StandardError => e
                  warn "[WorldBuilder] Grid weather reset error: #{e.message}"
                end

                flash['success'] = 'Weather grid reset'
                r.redirect "/admin/world_builder/#{@world.id}"
              end
            end
          end
        end

        # City Builder (city block/building management)
        r.on 'city_builder' do
          # Index - list all cities
          r.is do
            r.get do
              @locations = Location.where(Sequel.~(city_built_at: nil))
                                   .eager(:world, :zone)
                                   .order(:city_name)
                                   .all
              view 'admin/city_builder/index'
            end
          end

          # Editor - edit a specific city
          r.get Integer do |location_id|
            @location = Location[location_id]
            unless @location&.city_built_at
              flash['error'] = 'City not found or not built yet'
              r.redirect '/admin/city_builder'
            end
            @world = @location.world
            @building_types = CityBuilderViewService.building_types_by_category
            view 'admin/city_builder/editor'
          end

          # API routes for a specific city
          r.on Integer, 'api' do |location_id|
            @location = Location[location_id]
            r.halt(404) unless @location

            # GET /api/city - Full city data
            r.is 'city' do
              r.get do
                response['Content-Type'] = 'application/json'
                CityBuilderViewService.city_data(@location).to_json
              end
            end

            # POST /api/building - Create building
            r.is 'building' do
              r.post do
                response['Content-Type'] = 'application/json'
                data = JSON.parse(request.body.read) rescue {}
                result = CityBuilderViewService.create_building(@location, data)
                result.to_json
              end
            end

            # DELETE /api/building/:id - Delete building
            r.on 'building', Integer do |building_id|
              r.delete do
                response['Content-Type'] = 'application/json'
                result = CityBuilderViewService.delete_building(building_id, location: @location)
                if !result[:success] && result[:error].to_s.downcase.include?('not found')
                  response.status = 404
                end
                result.to_json
              end
            end

            # GET /api/building_types - Get building types by category
            r.is 'building_types' do
              r.get do
                response['Content-Type'] = 'application/json'
                CityBuilderViewService.building_types_by_category.to_json
              end
            end
          end
        end

        # Room Builder (room management)
        r.on 'room_builder' do
          r.is do
            r.get do
              @rooms = Room.order(:name).limit(100).all rescue []
              @locations = Location.order(:name).all rescue []
              view 'admin/room_builder/index'
            end
          end

          r.on Integer do |id|
            @room = Room[id]
            unless @room
              flash['error'] = 'Room not found'
              r.redirect '/admin/room_builder'
            end

            r.is do
              r.get do
                view 'admin/room_builder/editor'
              end
            end

            # Room Builder API endpoints
            r.on 'api' do
              response['Content-Type'] = 'application/json'

              r.get 'room' do
                { success: true, room: RoomBuilderService.room_to_api_hash(@room) }.to_json
              end

              r.put 'room' do
                data = JSON.parse(request.body.read)
                result = RoomBuilderService.update_room(@room, data)
                result.to_json
              rescue JSON::ParserError
                { success: false, error: 'Invalid JSON' }.to_json
              rescue StandardError => e
                warn "[RoomBuilder] Failed to update room #{@room.id}: #{e.message}"
                { success: false, error: e.message }.to_json
              end

              r.on 'places' do
                r.is do
                  r.get do
                    places = @room.places.map { |p| RoomBuilderService.place_to_api_hash(p) }
                    { success: true, places: places }.to_json
                  end

                  r.post do
                    data = JSON.parse(request.body.read)
                    result = RoomBuilderService.create_place(@room, data)
                    result.to_json
                  rescue JSON::ParserError
                    { success: false, error: 'Invalid JSON' }.to_json
                  end
                end

                r.on Integer do |place_id|
                  place = Place.where(room_id: @room.id, id: place_id).first
                  unless place
                    response.status = 404
                    next { success: false, error: 'Place not found' }.to_json
                  end

                  r.put do
                    data = JSON.parse(request.body.read)
                    result = RoomBuilderService.update_place(place, data)
                    result.to_json
                  rescue JSON::ParserError
                    { success: false, error: 'Invalid JSON' }.to_json
                  end

                  r.delete do
                    place.destroy
                    { success: true }.to_json
                  end
                end
              end

              r.on 'decorations' do
                r.is do
                  r.get do
                    decorations = @room.decorations.map { |d| RoomBuilderService.decoration_to_api_hash(d) }
                    { success: true, decorations: decorations }.to_json
                  end

                  r.post do
                    data = JSON.parse(request.body.read)
                    result = RoomBuilderService.create_decoration(@room, data)
                    result.to_json
                  rescue JSON::ParserError
                    { success: false, error: 'Invalid JSON' }.to_json
                  rescue StandardError => e
                    warn "[RoomBuilder] Decoration create failed: #{e.message}"
                    { success: false, error: e.message }.to_json
                  end
                end

                r.on Integer do |dec_id|
                  decoration = Decoration.where(room_id: @room.id, id: dec_id).first
                  unless decoration
                    response.status = 404
                    next { success: false, error: 'Decoration not found' }.to_json
                  end

                  r.put do
                    data = JSON.parse(request.body.read)
                    result = RoomBuilderService.update_decoration(decoration, data)
                    result.to_json
                  rescue JSON::ParserError
                    { success: false, error: 'Invalid JSON' }.to_json
                  rescue StandardError => e
                    warn "[RoomBuilder] Decoration update failed: #{e.message}"
                    { success: false, error: e.message }.to_json
                  end

                  r.delete do
                    decoration.destroy
                    { success: true }.to_json
                  end
                end
              end

              r.on 'features' do
                r.is do
                  r.get do
                    features = RoomFeature.visible_from(@room).map { |f| RoomBuilderService.feature_to_api_hash(f) }
                    { success: true, features: features }.to_json
                  end

                  r.post do
                    data = JSON.parse(request.body.read)
                    result = RoomBuilderService.create_feature(@room, data)
                    result.to_json
                  rescue JSON::ParserError
                    { success: false, error: 'Invalid JSON' }.to_json
                  rescue StandardError => e
                    warn "[RoomBuilder] Feature create failed: #{e.message}"
                    { success: false, error: e.message }.to_json
                  end
                end

                r.on Integer do |feature_id|
                  feature = RoomFeature.where(id: feature_id).where(
                    Sequel.or(room_id: @room.id, connected_room_id: @room.id)
                  ).first
                  unless feature
                    response.status = 404
                    next { success: false, error: 'Feature not found' }.to_json
                  end

                  r.put do
                    data = JSON.parse(request.body.read)
                    result = RoomBuilderService.update_feature(feature, data)
                    result.to_json
                  rescue JSON::ParserError
                    { success: false, error: 'Invalid JSON' }.to_json
                  rescue StandardError => e
                    warn "[RoomBuilder] Feature update failed: #{e.message}"
                    { success: false, error: e.message }.to_json
                  end

                  r.delete do
                    affected_location_ids = [feature.room&.location_id]
                    if feature.connected_room_id
                      connected = Room[feature.connected_room_id]
                      affected_location_ids << connected&.location_id
                    end

                    feature.destroy

                    affected_location_ids.compact.uniq.each do |location_id|
                      RoomExitCacheService.invalidate_location!(location_id)
                    end

                    { success: true }.to_json
                  end
                end
              end

              r.on 'subrooms' do
                r.is do
                  r.get do
                    subrooms = @room.contained_rooms.map { |s| RoomBuilderService.subroom_to_api_hash(s) }
                    { success: true, subrooms: subrooms }.to_json
                  end

                  r.post do
                    data = JSON.parse(request.body.read)
                    result = RoomBuilderService.create_subroom(@room, data)
                    result.to_json
                  rescue JSON::ParserError
                    { success: false, error: 'Invalid JSON' }.to_json
                  end
                end

                r.on Integer do |subroom_id|
                  subroom = Room.where(inside_room_id: @room.id, id: subroom_id).first
                  unless subroom
                    response.status = 404
                    next { success: false, error: 'Subroom not found' }.to_json
                  end

                  r.delete do
                    subroom.destroy
                    { success: true }.to_json
                  end
                end
              end

              r.on 'exits' do
                r.is do
                  r.get do
                    exits = RoomAdjacencyService.adjacent_rooms(@room)
                    exit_data = exits.flat_map do |dir, rooms|
                      rooms.map { |rm| { direction: dir.to_s, to_room_id: rm.id, to_room_name: rm.name } }
                    end
                    { success: true, exits: exit_data }.to_json
                  end
                end
              end

              r.on 'generate' do
                r.post 'description' do
                  result = Generators::RoomGeneratorService.generate_description(room: @room)
                  if result[:success]
                    { success: true, description: result[:content] }.to_json
                  else
                    { success: false, error: result[:error] || 'Generation failed' }.to_json
                  end
                rescue StandardError => e
                  warn "[RoomBuilder] Generate description failed: #{e.message}"
                  { success: false, error: e.message }.to_json
                end

                r.post 'name' do
                  result = Generators::RoomGeneratorService.generate_name(
                    room_type: @room.room_type || 'standard',
                    parent_name: @room.location&.name
                  )
                  if result[:success]
                    { success: true, name: result[:name] }.to_json
                  else
                    { success: false, error: result[:error] || 'Generation failed' }.to_json
                  end
                rescue StandardError => e
                  warn "[RoomBuilder] Generate name failed: #{e.message}"
                  { success: false, error: e.message }.to_json
                end

                r.post 'seasonal' do
                  result = Generators::RoomGeneratorService.generate_seasonal_descriptions(room: @room)
                  if result[:success]
                    # Transform "dawn_spring" keys to nested { dawn: { spring: desc } }
                    nested = {}
                    result[:descriptions].each do |key, desc|
                      time, season = key.to_s.split('_', 2)
                      nested[time] ||= {}
                      nested[time][season] = desc
                    end
                    { success: true, seasonal_descriptions: nested }.to_json
                  else
                    { success: false, error: result[:error] || 'Generation failed' }.to_json
                  end
                rescue StandardError => e
                  warn "[RoomBuilder] Generate seasonal failed: #{e.message}"
                  { success: false, error: e.message }.to_json
                end
              end

              r.post 'upload_image' do
                file = request.params['image']
                unless file && file[:tempfile]
                  next { success: false, error: 'No file provided' }.to_json
                end

                ext = File.extname(file[:filename]).downcase
                unless %w[.jpg .jpeg .png .gif .webp].include?(ext)
                  next { success: false, error: 'Invalid file type' }.to_json
                end

                filename = "room_#{@room.id}_#{SecureRandom.hex(8)}#{ext}"
                dest = File.join('public', 'uploads', 'rooms', filename)
                FileUtils.mkdir_p(File.dirname(dest))
                FileUtils.cp(file[:tempfile].path, dest)
                url = "/uploads/rooms/#{filename}"
                @room.update(default_background_url: url)
                { success: true, url: url }.to_json
              rescue StandardError => e
                warn "[RoomBuilder] Upload failed: #{e.message}"
                { success: false, error: e.message }.to_json
              end
            end
          end

          # Catalog endpoint (outside room context)
          r.on 'api' do
            r.on 'catalog' do
              r.get 'furniture' do
                response['Content-Type'] = 'application/json'
                # Predefined furniture catalog with categories
                # default_sit_action: 'on' (chairs), 'in' (armchairs/sofas), 'at' (tables), 'by' (decorative)
                catalog = {
                  seating: [
                    { name: 'Wooden Chair', capacity: 1, width: 2, height: 2, description: 'A simple wooden chair', default_sit_action: 'sit on' },
                    { name: 'Armchair', capacity: 1, width: 3, height: 3, description: 'A comfortable padded armchair', default_sit_action: 'sit in' },
                    { name: 'Sofa', capacity: 3, width: 6, height: 3, description: 'A plush sofa', default_sit_action: 'sit on' },
                    { name: 'Loveseat', capacity: 2, width: 4, height: 3, description: 'A cozy two-person seat', default_sit_action: 'sit on' },
                    { name: 'Bench', capacity: 4, width: 8, height: 2, description: 'A long wooden bench', default_sit_action: 'sit on' },
                    { name: 'Stool', capacity: 1, width: 1, height: 1, description: 'A small stool', default_sit_action: 'sit on' },
                    { name: 'Bar Stool', capacity: 1, width: 1, height: 1, description: 'A tall bar stool', default_sit_action: 'sit on' },
                    { name: 'Throne', capacity: 1, width: 4, height: 4, description: 'An ornate throne', default_sit_action: 'sit on' }
                  ],
                  places: [
                    { name: 'Bar Counter', icon: "\u{1F37A}", capacity: 8, width: 10, height: 3, description: 'A long bar counter', default_sit_action: 'stand at' },
                    { name: 'Stage', icon: "\u{1F3AD}", capacity: 10, width: 12, height: 8, description: 'A raised performance stage', default_sit_action: 'stand on' },
                    { name: 'Fireplace', icon: "\u{1F525}", capacity: 4, width: 5, height: 2, description: 'A warm hearth to gather around', default_sit_action: 'sit near' },
                    { name: 'Fountain', icon: "\u26F2", capacity: 6, width: 5, height: 5, description: 'A decorative fountain', default_sit_action: 'stand near' },
                    { name: 'Altar', icon: "\u26EA", capacity: 2, width: 4, height: 3, description: 'A sacred altar', default_sit_action: 'kneel before' },
                    { name: 'Podium', icon: "\u{1F3A4}", capacity: 1, width: 2, height: 2, description: 'A speaker\'s podium', default_sit_action: 'stand at' },
                    { name: 'Throne Dais', icon: "\u{1F451}", capacity: 1, width: 5, height: 5, description: 'A raised throne platform', default_sit_action: 'sit on' },
                    { name: 'Well', icon: "\u{1FAA3}", capacity: 4, width: 4, height: 4, description: 'A stone well', default_sit_action: 'stand near' }
                  ],
                  tables: [
                    { name: 'Small Table', capacity: 0, width: 3, height: 3, description: 'A small side table', default_sit_action: 'sit at' },
                    { name: 'Dining Table', capacity: 0, width: 6, height: 4, description: 'A rectangular dining table', default_sit_action: 'sit at' },
                    { name: 'Round Table', capacity: 0, width: 4, height: 4, description: 'A round table', default_sit_action: 'sit at' },
                    { name: 'Desk', capacity: 0, width: 5, height: 3, description: 'A wooden desk', default_sit_action: 'sit at' },
                    { name: 'Counter', capacity: 0, width: 8, height: 2, description: 'A long counter', default_sit_action: 'stand at' },
                    { name: 'Bar', capacity: 0, width: 10, height: 3, description: 'A bar with stools', default_sit_action: 'sit at' },
                    { name: 'Workbench', capacity: 0, width: 6, height: 3, description: 'A sturdy workbench', default_sit_action: 'stand at' }
                  ],
                  beds: [
                    { name: 'Single Bed', capacity: 1, width: 3, height: 6, description: 'A single bed', default_sit_action: 'rest on' },
                    { name: 'Double Bed', capacity: 2, width: 5, height: 6, description: 'A double bed', default_sit_action: 'rest on' },
                    { name: 'King Bed', capacity: 2, width: 6, height: 7, description: 'A large king-size bed', default_sit_action: 'rest on' },
                    { name: 'Bunk Bed', capacity: 2, width: 3, height: 6, description: 'A bunk bed with two levels', default_sit_action: 'rest on' },
                    { name: 'Cot', capacity: 1, width: 2, height: 5, description: 'A simple cot', default_sit_action: 'rest on' },
                    { name: 'Hammock', capacity: 1, width: 2, height: 6, description: 'A hanging hammock', default_sit_action: 'rest in' }
                  ]
                }
                { success: true, catalog: catalog }.to_json
              end
            end
          end
        end

        # Pattern Designer (item patterns)
        r.on 'patterns' do
          r.is do
            r.get do
              @tab = r.params['tab'] || 'clothing'
              category_map = {
                'clothing'    => Pattern::CLOTHING_CATEGORIES,
                'jewelry'     => Pattern::JEWELRY_CATEGORIES,
                'weapons'     => Pattern::WEAPON_CATEGORIES,
                'consumables' => Pattern::CONSUMABLE_CATEGORIES,
                'other'       => Pattern::OTHER_CATEGORIES
              }
              categories = category_map[@tab] || Pattern::CLOTHING_CATEGORIES
              @patterns = Pattern
                .join(:unified_object_types, id: :unified_object_type_id)
                .where(Sequel[:unified_object_types][:category] => categories)
                .order(Sequel[:patterns][:id])
                .all rescue Pattern.order(:id).limit(100).all
              view 'admin/patterns/index'
            end
          end

          r.get 'new' do
            @pattern = Pattern.new
            @types = UnifiedObjectType.order(:name).all rescue []
            @body_positions = BodyPosition.ordered.all rescue []
            view 'admin/patterns/new'
          end

          r.post 'create' do
            result = PatternDesignerService.create(r.params)
            if result[:success]
              flash['success'] = 'Pattern created successfully'
              r.redirect "/admin/patterns/#{result[:pattern].id}"
            else
              flash['error'] = result[:error]
              @pattern = Pattern.new
              @types = UnifiedObjectType.order(:name).all rescue []
              @body_positions = BodyPosition.ordered.all rescue []
              view 'admin/patterns/new'
            end
          end

          r.on Integer do |id|
            @pattern = Pattern[id]
            unless @pattern
              flash['error'] = 'Pattern not found'
              r.redirect '/admin/patterns'
            end

            r.is do
              r.get do
                @types = UnifiedObjectType.order(:name).all rescue []
                @body_positions = BodyPosition.ordered.all rescue []
                view 'admin/patterns/edit'
              end

              r.post do
                result = PatternDesignerService.update(@pattern, r.params)
                if result[:success]
                  flash['success'] = 'Pattern saved'
                  r.redirect "/admin/patterns/#{@pattern.id}"
                else
                  flash['error'] = result[:error]
                  @types = UnifiedObjectType.order(:name).all rescue []
                  @body_positions = BodyPosition.ordered.all rescue []
                  view 'admin/patterns/edit'
                end
              end
            end

            r.post 'delete' do
              result = PatternDesignerService.delete(@pattern)
              if result[:success]
                flash['success'] = 'Pattern deleted'
                r.redirect '/admin/patterns'
              else
                flash['error'] = result[:error]
                r.redirect "/admin/patterns/#{@pattern.id}"
              end
            end
          end
        end

        # NPC Archetypes
        r.on 'npcs' do
          r.is do
            r.get do
              @archetypes = NpcArchetype.order(:name).all rescue []
              view 'admin/npcs/index'
            end
          end

          r.get 'new' do
            @archetype = NpcArchetype.new
            @tab = 'general'
            @npc_abilities = Ability.where(user_type: 'npc').order(:name).all
            view 'admin/npcs/edit'
          end

          r.post 'create' do
            params = parse_npc_params(r.params)
            @archetype = NpcArchetype.create(params)
            flash['success'] = "Archetype '#{@archetype.name}' created"
            r.redirect "/admin/npcs/#{@archetype.id}"
          rescue Sequel::ValidationFailed => e
            flash['error'] = "Validation error: #{e.message}"
            @archetype = NpcArchetype.new(params)
            @tab = 'general'
            view 'admin/npcs/edit'
          end

          r.get 'locations' do
            view 'admin/npcs/locations'
          end

          # Quick ability creation from NPC editor (JSON response)
          r.post 'abilities/create_quick' do
            response['Content-Type'] = 'application/json'
            begin
              ability = Ability.create(
                name: r.params['ability_name'],
                ability_type: r.params['ability_type'] || 'combat',
                action_type: r.params['action_type'] || 'main',
                user_type: 'npc',
                target_type: r.params['target_type'] || 'enemy',
                base_damage_dice: r.params['base_damage_dice'].to_s.strip.empty? ? nil : r.params['base_damage_dice'],
                damage_type: r.params['damage_type'] || 'physical',
                aoe_shape: r.params['aoe_shape'] || 'single',
                aoe_radius: r.params['aoe_radius'].to_i,
                aoe_length: r.params['aoe_length'].to_i,
                cooldown_seconds: r.params['cooldown_seconds'].to_i,
                activation_segment: r.params['activation_segment'].to_i.nonzero? || 50,
                description: r.params['description']
              )
              power_value = begin
                ability.power
              rescue StandardError => e
                warn "[Admin::Abilities] Failed to calculate ability power: #{e.message}"
                0
              end
              {
                success: true,
                ability: {
                  id: ability.id,
                  name: ability.name,
                  power: power_value
                }
              }.to_json
            rescue Sequel::ValidationFailed => e
              { success: false, error: e.message }.to_json
            rescue StandardError => e
              { success: false, error: e.message }.to_json
            end
          end

          r.on Integer do |id|
            @archetype = NpcArchetype[id]
            unless @archetype
              flash['error'] = 'Archetype not found'
              r.redirect '/admin/npcs'
            end

            load_npc_instances_context = lambda do |tab|
              @tab = tab
              @npcs = Character.where(npc_archetype_id: @archetype.id).order(:forename, :surname).all
              return unless @tab == 'instances'

              @saved_locations = NpcSpawnLocation.for_user(current_user).eager(:room).all
              @locations = Location.order(:name).all
            rescue StandardError => e
              warn "[Admin::NPCs] Failed to load instances context: #{e.message}"
              @saved_locations ||= []
              @locations ||= []
            end

            r.is do
              r.get do
                load_npc_instances_context.call(r.params['tab'] || 'general')
                # Load NPC abilities for combat tab
                @npc_abilities = Ability.where(user_type: 'npc').order(:name).all if @tab == 'combat'
                view 'admin/npcs/edit'
              end
            end

            r.post 'update' do
              params = parse_npc_params(r.params)
              @archetype.update(params)
              flash['success'] = 'Archetype updated'
              tab = r.params['_tab'] || 'general'
              r.redirect "/admin/npcs/#{@archetype.id}?tab=#{tab}"
            rescue Sequel::ValidationFailed => e
              flash['error'] = "Validation error: #{e.message}"
              load_npc_instances_context.call(r.params['_tab'] || 'general')
              view 'admin/npcs/edit'
            end

            r.post 'create_npc' do
              forename = r.params['forename'].to_s.strip
              if forename.empty?
                flash['error'] = 'First name is required'
                r.redirect "/admin/npcs/#{@archetype.id}?tab=instances"
              end

              npc = @archetype.create_unique_npc(
                forename,
                surname: r.params['surname'].to_s.strip.empty? ? nil : r.params['surname'].to_s.strip,
                short_desc: r.params['short_desc'].to_s.strip.empty? ? nil : r.params['short_desc'].to_s.strip,
                gender: r.params['gender'].to_s.strip.empty? ? nil : r.params['gender'].to_s.strip
              )

              flash['success'] = "Created NPC '#{npc.full_name}'"
              r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{npc.id}"
            rescue Sequel::ValidationFailed => e
              flash['error'] = "Failed to create NPC: #{e.message}"
              r.redirect "/admin/npcs/#{@archetype.id}?tab=instances"
            end

            r.on 'npc', Integer do |npc_id|
              @npc = Character.where(id: npc_id, npc_archetype_id: @archetype.id).first
              unless @npc
                flash['error'] = 'NPC not found for this archetype'
                r.redirect "/admin/npcs/#{@archetype.id}?tab=instances"
              end

              r.post 'delete' do
                NpcSpawnService.despawn_all(@npc) if defined?(NpcSpawnService)
                npc_name = @npc.full_name
                @npc.destroy
                flash['success'] = "Deleted NPC '#{npc_name}'"
                r.redirect "/admin/npcs/#{@archetype.id}?tab=instances"
              rescue StandardError => e
                flash['error'] = "Failed to delete NPC: #{e.message}"
                r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{@npc.id}"
              end

              r.post 'schedules' do
                room_id = r.params['room_id'].to_i
                room = Room[room_id]
                unless room
                  flash['error'] = 'Please select a valid room'
                  r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{@npc.id}"
                end

                start_hour = r.params['start_hour'].to_s.strip.empty? ? 0 : r.params['start_hour'].to_i
                end_hour = r.params['end_hour'].to_s.strip.empty? ? 24 : r.params['end_hour'].to_i
                probability = r.params['probability'].to_s.strip.empty? ? 100 : r.params['probability'].to_i
                max_npcs = r.params['max_npcs'].to_s.strip.empty? ? 1 : r.params['max_npcs'].to_i

                schedule = NpcSchedule.create(
                  character_id: @npc.id,
                  room_id: room.id,
                  activity: r.params['activity'].to_s.strip.empty? ? nil : r.params['activity'].to_s.strip,
                  start_hour: start_hour,
                  end_hour: end_hour,
                  weekdays: r.params['weekdays'].to_s.strip.empty? ? 'all' : r.params['weekdays'].to_s.strip,
                  probability: [[probability, 0].max, 100].min,
                  max_npcs: [max_npcs, 1].max,
                  is_active: r.params['is_active'] == '1'
                )

                if r.params['save_location'] == '1'
                  location_name = r.params['location_name'].to_s.strip
                  if !location_name.empty? && current_user
                    NpcSpawnLocation.create(
                      user_id: current_user.id,
                      room_id: room.id,
                      name: location_name
                    )
                  end
                end

                flash['success'] = "Added schedule ##{schedule.id} for #{@npc.full_name}"
                r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{@npc.id}"
              rescue Sequel::ValidationFailed => e
                flash['error'] = "Failed to add schedule: #{e.message}"
                r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{@npc.id}"
              rescue StandardError => e
                flash['error'] = "Failed to add schedule: #{e.message}"
                r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{@npc.id}"
              end

              r.on 'schedule', Integer do |schedule_id|
                @schedule = @npc.npc_schedules_dataset.first(id: schedule_id)
                unless @schedule
                  flash['error'] = 'Schedule not found'
                  r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{@npc.id}"
                end

                r.post 'update' do
                  room_id = r.params['room_id'].to_i
                  room = Room[room_id]
                  unless room
                    flash['error'] = 'Please select a valid room'
                    r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{@npc.id}"
                  end

                  start_hour = r.params['start_hour'].to_s.strip.empty? ? 0 : r.params['start_hour'].to_i
                  end_hour = r.params['end_hour'].to_s.strip.empty? ? 24 : r.params['end_hour'].to_i
                  probability = r.params['probability'].to_s.strip.empty? ? 100 : r.params['probability'].to_i
                  max_npcs = r.params['max_npcs'].to_s.strip.empty? ? 1 : r.params['max_npcs'].to_i

                  @schedule.update(
                    room_id: room.id,
                    activity: r.params['activity'].to_s.strip.empty? ? nil : r.params['activity'].to_s.strip,
                    start_hour: start_hour,
                    end_hour: end_hour,
                    weekdays: r.params['weekdays'].to_s.strip.empty? ? 'all' : r.params['weekdays'].to_s.strip,
                    probability: [[probability, 0].max, 100].min,
                    max_npcs: [max_npcs, 1].max,
                    is_active: r.params['is_active'] == '1'
                  )

                  flash['success'] = 'Schedule updated'
                  r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{@npc.id}"
                rescue Sequel::ValidationFailed => e
                  flash['error'] = "Failed to update schedule: #{e.message}"
                  r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{@npc.id}"
                rescue StandardError => e
                  flash['error'] = "Failed to update schedule: #{e.message}"
                  r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{@npc.id}"
                end

                r.post 'delete' do
                  @schedule.destroy
                  flash['success'] = 'Schedule deleted'
                  r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{@npc.id}"
                rescue StandardError => e
                  flash['error'] = "Failed to delete schedule: #{e.message}"
                  r.redirect "/admin/npcs/#{@archetype.id}?tab=instances&npc=#{@npc.id}"
                end
              end
            end

            r.post 'delete' do
              name = @archetype.name
              @archetype.destroy
              flash['success'] = "Archetype '#{name}' deleted"
              r.redirect '/admin/npcs'
            end

            r.post 'upload_profile_image' do
              file = r.params['profile_image']
              if file && file[:tempfile]
                # Save the uploaded image
                filename = "npc_#{@archetype.id}_#{Time.now.to_i}#{File.extname(file[:filename])}"
                path = File.join('public', 'images', 'npcs', filename)
                FileUtils.mkdir_p(File.dirname(path))
                FileUtils.cp(file[:tempfile].path, path)
                @archetype.update(profile_image_url: "/images/npcs/#{filename}")
                flash['success'] = 'Profile image uploaded'
              else
                flash['error'] = 'No file selected'
              end
              r.redirect "/admin/npcs/#{@archetype.id}?tab=appearance"
            end

            r.post 'remove_profile_image' do
              @archetype.update(profile_image_url: nil)
              flash['success'] = 'Profile image removed'
              r.redirect "/admin/npcs/#{@archetype.id}?tab=appearance"
            end
          end
        end

        # Abilities Admin
        r.on 'abilities' do
          r.is do
            r.get do
              @filter_type = r.params['type']
              @filter_user = r.params['user_type']
              @search = r.params['q']

              abilities = Ability.eager(:universe)
              abilities = abilities.where(ability_type: @filter_type) if @filter_type && !@filter_type.empty?
              abilities = abilities.where(user_type: @filter_user) if @filter_user && !@filter_user.empty?
              abilities = abilities.where(Sequel.ilike(:name, "%#{@search}%")) if @search && !@search.empty?

              @abilities = abilities.order(:name).all
              view 'admin/abilities/index'
            end
          end

          r.get 'new' do
            @ability = Ability.new
            @tab = 'general'
            @universes = Universe.order(:name).all rescue []
            @status_effects = StatusEffect.order(:name).all rescue []
            view 'admin/abilities/edit'
          end

          r.post 'create' do
            params = parse_ability_params(r.params)
            @ability = Ability.new(params)
            if @ability.valid?
              @ability.save
              flash['success'] = "Ability '#{@ability.name}' created"
              r.redirect "/admin/abilities/#{@ability.id}"
            else
              flash['error'] = @ability.errors.full_messages.join(', ')
              @tab = 'general'
              @universes = Universe.order(:name).all rescue []
              @status_effects = StatusEffect.order(:name).all rescue []
              view 'admin/abilities/edit'
            end
          rescue Sequel::ValidationFailed => e
            flash['error'] = "Validation error: #{e.message}"
            @tab = 'general'
            @universes = Universe.order(:name).all rescue []
            @status_effects = StatusEffect.order(:name).all rescue []
            view 'admin/abilities/edit'
          end

          # API endpoint for live power calculation
          r.post 'calculate_power' do
            response['Content-Type'] = 'application/json'
            begin
              params = parse_ability_params(r.params)
              temp_ability = Ability.new(params)
              calc = AbilityPowerCalculator.new(temp_ability)
              { total_power: calc.total_power, breakdown: calc.breakdown }.to_json
            rescue StandardError => e
              { error: e.message }.to_json
            end
          end

          r.on Integer do |id|
            @ability = Ability[id]
            unless @ability
              flash['error'] = 'Ability not found'
              r.redirect '/admin/abilities'
            end

            r.is do
              r.get do
                @tab = r.params['tab'] || 'general'
                @universes = Universe.order(:name).all rescue []
                @status_effects = StatusEffect.order(:name).all rescue []
                view 'admin/abilities/edit'
              end

              r.post do
                params = parse_ability_params(r.params)
                @ability.update(params)
                flash['success'] = 'Ability updated'
                tab = r.params['_tab'] || 'general'
                r.redirect "/admin/abilities/#{@ability.id}?tab=#{tab}"
              rescue Sequel::ValidationFailed => e
                flash['error'] = "Validation error: #{e.message}"
                @tab = r.params['_tab'] || 'general'
                @universes = Universe.order(:name).all rescue []
                @status_effects = StatusEffect.order(:name).all rescue []
                view 'admin/abilities/edit'
              end
            end

            r.post 'delete' do
              name = @ability.name
              @ability.destroy
              flash['success'] = "Ability '#{name}' deleted"
              r.redirect '/admin/abilities'
            end

            r.post 'duplicate' do
              new_values = @ability.values.reject { |k, _| %i[id created_at updated_at].include?(k) }
              new_ability = Ability.new(new_values)
              new_ability.name = "#{@ability.name} (copy)"
              new_ability.save
              flash['success'] = "Duplicated as '#{new_ability.name}'"
              r.redirect "/admin/abilities/#{new_ability.id}"
            rescue Sequel::ValidationFailed => e
              flash['error'] = "Could not duplicate: #{e.message}"
              r.redirect "/admin/abilities/#{@ability.id}"
            end
          end
        end

        # Vehicle Types
        r.on 'vehicle_types' do
          r.is do
            r.get do
              @category = r.params['category']
              @vehicle_types = if @category
                                 VehicleType.where(category: @category).order(:name).all
                               else
                                 VehicleType.order(:name).all
                               end
              view 'admin/vehicle_types/index'
            end
          end

          r.get 'new' do
            @vehicle_type = nil
            view 'admin/vehicle_types/new'
          end

          r.post 'create' do
            result = VehicleTypeDesignerService.create(r.params)
            if result[:success]
              flash['success'] = "Vehicle type '#{result[:vehicle_type].name}' created."
              r.redirect "/admin/vehicle_types/#{result[:vehicle_type].id}"
            else
              flash['error'] = result[:error]
              r.redirect '/admin/vehicle_types/new'
            end
          end

          r.on Integer do |id|
            @vehicle_type = VehicleType[id]
            unless @vehicle_type
              flash['error'] = 'Vehicle type not found'
              r.redirect '/admin/vehicle_types'
            end

            r.is do
              r.get do
                view 'admin/vehicle_types/edit'
              end
            end

            r.post 'update' do
              result = VehicleTypeDesignerService.update(@vehicle_type, r.params)
              if result[:success]
                flash['success'] = "Vehicle type '#{@vehicle_type.name}' updated."
              else
                flash['error'] = result[:error]
              end
              r.redirect "/admin/vehicle_types/#{id}"
            end

            r.post 'delete' do
              result = VehicleTypeDesignerService.delete(@vehicle_type)
              if result[:success]
                flash['success'] = 'Vehicle type deleted.'
                r.redirect '/admin/vehicle_types'
              else
                flash['error'] = result[:error]
                r.redirect "/admin/vehicle_types/#{id}"
              end
            end
          end
        end

        # Battle Map Templates
        r.on 'battle_map_templates' do
          r.is do
            r.get do
              @templates = BattleMapTemplate.order(:category, :shape_key, :variant).all
              view 'admin/battle_map_templates/index'
            end
          end

          r.on Integer do |id|
            @template = BattleMapTemplate[id]
            unless @template
              flash['error'] = 'Template not found'
              r.redirect '/admin/battle_map_templates'
            end

            r.on 'edit' do
              r.get do
                hex_data = @template.hex_data
                @hex_data = hex_data.respond_to?(:to_a) ? hex_data.to_a : (hex_data.is_a?(Array) ? hex_data : [])

                # Compute valid hex coordinates from template dimensions
                valid_coords = HexGrid.hex_coords_for_room(0, 0, @template.width_feet, @template.height_feet)
                hex_xs = valid_coords.map(&:first)
                hex_ys = valid_coords.map(&:last)

                @hex_min_x = hex_xs.min || 0
                @hex_max_x = hex_xs.max || 0
                @hex_min_y = hex_ys.min || 0
                @hex_max_y = hex_ys.max || 0
                @valid_coords_json = valid_coords.to_json

                # Convert hex_data to format editor expects
                @hex_data_json = @hex_data.map { |h|
                  {
                    hex_x: h['hex_x'], hex_y: h['hex_y'],
                    hex_type: h['hex_type'] || 'normal',
                    traversable: h.fetch('traversable', true),
                    danger_level: h['danger_level'] || 0,
                    elevation_level: h['elevation_level'] || 0,
                    has_cover: h['has_cover'] || false,
                    cover_object: h['cover_object'],
                    surface_type: h['surface_type'],
                    difficult_terrain: h['difficult_terrain'] || false,
                    hazard_type: h['hazard_type'],
                    water_type: h['water_type'],
                    wall_feature: h['wall_feature']
                  }
                }.to_json

                lights = @template.light_sources
                @light_count = lights.respond_to?(:length) ? lights.length : 0

                @hex_types = (RoomHex::HEX_TYPES + %w[door archway off_map]).uniq
                @surface_types = RoomHex::SURFACE_TYPES
                @cover_types = CoverObjectType.order(:name).all rescue []
                @cover_names_fallback = @cover_types.empty? ? RoomHex::COVER_OBJECTS : []
                @water_types = RoomHex::WATER_TYPES
                @hazard_types = RoomHex::HAZARD_TYPES

                # Unified editor variables
                @entity = @template
                @editor_mode = :template

                view 'admin/battle_map_templates/editor'
              end
            end

            # API endpoints for template hex editor
            r.on 'api' do
              r.on 'hexes' do
                r.post do
                  hex_x = r.params['hex_x'].to_i
                  hex_y = r.params['hex_y'].to_i

                  # Deep copy via JSON roundtrip to break all references to
                  # the JSONBArray's internal objects — prevents stale serialization
                  hexes = JSON.parse(@template.hex_data.to_json)

                  # Find or create hex entry
                  hex = hexes.find { |h| h['hex_x'] == hex_x && h['hex_y'] == hex_y }
                  unless hex
                    hex = { 'hex_x' => hex_x, 'hex_y' => hex_y, 'hex_type' => 'normal', 'traversable' => true }
                    hexes << hex
                  end

                  nullable = ->(v) { (v.nil? || v.to_s.strip.empty?) ? nil : v }

                  hex['hex_type'] = r.params['hex_type'] if r.params['hex_type'] && !r.params['hex_type'].empty?
                  hex['surface_type'] = nullable.call(r.params['surface_type']) if r.params.key?('surface_type')
                  hex['cover_object'] = nullable.call(r.params['cover_object']) if r.params.key?('cover_object')
                  hex['has_cover'] = r.params['has_cover'] == 'true' if r.params.key?('has_cover')
                  hex['elevation_level'] = r.params['elevation_level'].to_i if r.params['elevation_level'] && !r.params['elevation_level'].empty?
                  hex['danger_level'] = r.params['danger_level'].to_i if r.params['danger_level'] && !r.params['danger_level'].empty?
                  hex['water_type'] = nullable.call(r.params['water_type']) if r.params.key?('water_type')
                  hex['hazard_type'] = nullable.call(r.params['hazard_type']) if r.params.key?('hazard_type')
                  hex['traversable'] = r.params['traversable'] == 'true' if r.params.key?('traversable')
                  hex['difficult_terrain'] = r.params['difficult_terrain'] == 'true' if r.params.key?('difficult_terrain')
                  hex['has_cover'] = r.params['has_cover'] == 'true' if r.params.key?('has_cover')
                  hex['cover_height'] = r.params['cover_height'].to_i if r.params['cover_height'] && !r.params['cover_height'].empty?
                  hex['blocks_line_of_sight'] = r.params['blocks_los'] == 'true' if r.params.key?('blocks_los')
                  hex['destroyable'] = r.params['destroyable'] == 'true' if r.params.key?('destroyable')
                  hex['hit_points'] = r.params['hit_points'].to_i if r.params['hit_points'] && !r.params['hit_points'].empty?
                  hex['is_ramp'] = r.params['is_ramp'] == 'true' if r.params.key?('is_ramp')
                  hex['is_stairs'] = r.params['is_stairs'] == 'true' if r.params.key?('is_stairs')
                  hex['is_ladder'] = r.params['is_ladder'] == 'true' if r.params.key?('is_ladder')
                  hex['water_depth'] = r.params['water_depth'].to_i if r.params['water_depth'] && !r.params['water_depth'].empty?
                  hex['requires_swimming'] = r.params['requires_swimming'] == 'true' if r.params.key?('requires_swimming')
                  hex['hazard_damage_per_round'] = r.params['hazard_damage_per_round'].to_i if r.params['hazard_damage_per_round'] && !r.params['hazard_damage_per_round'].empty?
                  hex['hazard_save_difficulty'] = r.params['hazard_save_difficulty'].to_i if r.params['hazard_save_difficulty'] && !r.params['hazard_save_difficulty'].empty?
                  hex['is_potential_hazard'] = r.params['is_potential_hazard'] == 'true' if r.params.key?('is_potential_hazard')
                  hex['potential_trigger'] = nullable.call(r.params['potential_trigger']) if r.params.key?('potential_trigger')
                  hex['is_explosive'] = r.params['is_explosive'] == 'true' if r.params.key?('is_explosive')
                  hex['explosion_radius'] = r.params['explosion_radius'].to_i if r.params['explosion_radius'] && !r.params['explosion_radius'].empty?
                  hex['explosion_damage'] = r.params['explosion_damage'].to_i if r.params['explosion_damage'] && !r.params['explosion_damage'].empty?
                  hex['explosion_trigger'] = nullable.call(r.params['explosion_trigger']) if r.params.key?('explosion_trigger')
                  hex['slippery'] = r.params['slippery'] == 'true' if r.params.key?('slippery')
                  hex['movement_modifier'] = r.params['movement_modifier'].to_f if r.params['movement_modifier'] && !r.params['movement_modifier'].empty?
                  hex['description_override'] = nullable.call(r.params['description_override']) if r.params.key?('description_override')
                  hex['wall_feature'] = nullable.call(r.params['wall_feature']) if r.params.key?('wall_feature')

                  BattleMapTemplate.where(id: @template.id)
                                   .update(hex_data: Sequel.pg_jsonb_wrap(hexes))

                  response['Content-Type'] = 'application/json'
                  { success: true }.to_json
                end
              end

              # Generate SAM masks for template
              r.on 'generate_masks' do
                r.post do
                  response['Content-Type'] = 'application/json'

                  unless @template.image_url && !@template.image_url.to_s.strip.empty?
                    return { success: false, error: 'No background image' }.to_json
                  end

                  unless defined?(ReplicateSamService) && ReplicateSamService.available?
                    return { success: false, error: 'SAM service not available (no Replicate API key)' }.to_json
                  end

                  image_url = @template.image_url
                  local_path = image_url.start_with?('/') ? File.join('public', image_url) : image_url

                  unless File.exist?(local_path)
                    return { success: false, error: "Image not found on disk: #{local_path}" }.to_json
                  end

                  results = {}
                  mask_updates = {}

                  if r.params['sam_water']
                    result = ReplicateSamService.segment(local_path, 'water', suffix: '_sam_water')
                    if result[:success] && result[:mask_path] && !result[:no_detections]
                      url = result[:mask_path].sub(%r{^public/?}, '')
                      url = "/#{url}" unless url.start_with?('/')
                      mask_updates[:water_mask_url] = url
                      results['water'] = { success: true }
                    else
                      results['water'] = { success: false, error: result[:no_detections] ? 'No water detected' : (result[:error] || 'failed') }
                    end
                  end

                  if r.params['sam_foliage']
                    tree_result = ReplicateSamService.segment(local_path, 'tree', suffix: '_sam_foliage_tree')
                    bush_result = ReplicateSamService.segment(local_path, 'bush', suffix: '_sam_foliage_bush')

                    begin
                      require 'vips'
                      masks = []
                      masks << Vips::Image.new_from_file(tree_result[:mask_path]) if tree_result[:success] && tree_result[:mask_path] && !tree_result[:no_detections] && File.exist?(tree_result[:mask_path])
                      masks << Vips::Image.new_from_file(bush_result[:mask_path]) if bush_result[:success] && bush_result[:mask_path] && !bush_result[:no_detections] && File.exist?(bush_result[:mask_path])

                      if masks.any?
                        combined = masks.first
                        masks[1..].each do |m|
                          m = m.resize(combined.width.to_f / m.width) if m.width != combined.width
                          combined = (combined | m)
                        end
                        combined = combined.extract_band(0) if combined.bands > 1
                        output_path = local_path.sub(/(\.\w+)$/, '_sam_foliage.png')
                        combined.write_to_file(output_path)
                        url = output_path.sub(%r{^public/?}, '')
                        url = "/#{url}" unless url.start_with?('/')
                        mask_updates[:foliage_mask_url] = url
                        results['foliage'] = { success: true }
                      else
                        results['foliage'] = { success: false, error: 'No foliage detected' }
                      end
                    rescue StandardError => e
                      results['foliage'] = { success: false, error: e.message }
                    end
                  end

                  sam_light_queries = AIBattleMapGeneratorService::SAM_LIGHT_QUERIES
                  light_colors = AIBattleMapGeneratorService::LIGHT_COLORS
                  light_intensities = AIBattleMapGeneratorService::LIGHT_INTENSITIES

                  all_light_sources = []
                  fire_mask_path = nil

                  sam_light_queries.each do |stype, query|
                    next unless r.params["sam_light_#{stype}"]

                    suffix = "_sam_light_#{stype}"
                    result = ReplicateSamService.segment(local_path, query, suffix: suffix)

                    if result[:success] && result[:mask_path] && !result[:no_detections] && File.exist?(result[:mask_path])
                      positions = AIBattleMapGeneratorService.extract_positions_from_mask(result[:mask_path])

                      if positions.any?
                        positions.each do |pos|
                          all_light_sources << {
                            'type' => stype,
                            'center_x' => pos[:cx],
                            'center_y' => pos[:cy],
                            'radius_px' => [pos[:radius] * 3, 60].max,
                            'intensity' => light_intensities[stype] || AIBattleMapGeneratorService::LIGHT_INTENSITY_DEFAULT,
                            'color' => light_colors[stype] || AIBattleMapGeneratorService::LIGHT_COLOR_DEFAULT
                          }
                        end
                        results["light_#{stype}"] = { success: true, count: positions.length }
                      else
                        results["light_#{stype}"] = { success: false, error: 'No positions detected' }
                      end

                      fire_mask_path = result[:mask_path] if stype == 'fire'
                    else
                      results["light_#{stype}"] = { success: false, error: result[:no_detections] ? 'Nothing detected' : (result[:error] || 'failed') }
                    end
                  end

                  if r.params['sam_fire'] || fire_mask_path
                    if r.params['sam_fire'] && !fire_mask_path
                      fire_result = ReplicateSamService.segment(local_path, 'hearth fire', suffix: '_sam_light_fire')
                      fire_mask_path = fire_result[:mask_path] if fire_result[:success] && !fire_result[:no_detections]
                    end

                    if fire_mask_path && File.exist?(fire_mask_path)
                      begin
                        require 'vips'
                        mask = Vips::Image.new_from_file(fire_mask_path)
                        mask = mask.extract_band(0) if mask.bands > 1
                        if mask.avg > 20
                          binary = (mask > 200).ifthenelse(255, 0).cast(:uchar)
                          binary.pngsave(fire_mask_path)
                        end
                        url = fire_mask_path.sub(%r{^public/?}, '')
                        url = "/#{url}" unless url.start_with?('/')
                        mask_updates[:fire_mask_url] = url
                        results['fire'] = { success: true } unless results['fire']
                      rescue StandardError => e
                        results['fire'] = { success: false, error: e.message }
                      end
                    else
                      results['fire'] = { success: false, error: 'No fire detected' } unless results['fire']
                    end
                  end

                  @template.update(mask_updates) if mask_updates.any?
                  if all_light_sources.any?
                    @template.update(light_sources: Sequel.pg_jsonb_wrap(all_light_sources))
                  end

                  { success: true, results: results }.to_json
                rescue StandardError => e
                  warn "[BattleMapTemplates] Mask generation failed: #{e.message}"
                  response['Content-Type'] = 'application/json'
                  response.status = 500
                  { success: false, error: e.message }.to_json
                end
              end

              # Clear all masks for template
              r.on 'clear_masks' do
                r.post do
                  @template.update(
                    water_mask_url: nil,
                    foliage_mask_url: nil,
                    fire_mask_url: nil,
                    light_sources: Sequel.pg_jsonb_wrap([])
                  )
                  response['Content-Type'] = 'application/json'
                  { success: true }.to_json
                rescue StandardError => e
                  warn "[BattleMapTemplates] Clear masks failed: #{e.message}"
                  response['Content-Type'] = 'application/json'
                  response.status = 500
                  { success: false, error: e.message }.to_json
                end
              end

              # Paint wall/door/window mask rectangle for template
              r.on 'wall_mask_rect' do
                r.post do
                  response['Content-Type'] = 'application/json'
                  x1 = r.params['x1'].to_f.clamp(0.0, 1.0)
                  y1 = r.params['y1'].to_f.clamp(0.0, 1.0)
                  x2 = r.params['x2'].to_f.clamp(0.0, 1.0)
                  y2 = r.params['y2'].to_f.clamp(0.0, 1.0)
                  mask_type = r.params['mask_type'].to_s.strip

                  result = WallMaskPainterService.new(@template).paint_rect(x1, y1, x2, y2, mask_type)
                  response.status = 422 unless result[:success]
                  result.to_json
                rescue StandardError => e
                  warn "[BattleMapTemplates] wall_mask_rect failed: #{e.message}"
                  response.status = 422
                  { success: false, error: e.message }.to_json
                end
              end

              # Clear wall mask for template
              r.on 'clear_wall_mask' do
                r.post do
                  response['Content-Type'] = 'application/json'
                  result = WallMaskPainterService.new(@template).clear!
                  result.to_json
                rescue StandardError => e
                  warn "[BattleMapTemplates] clear_wall_mask failed: #{e.message}"
                  response.status = 500
                  { success: false, error: e.message }.to_json
                end
              end

              # Regenerate wall/door feature icons from wall mask for template
              r.on 'regenerate_wall_features' do
                r.post do
                  response['Content-Type'] = 'application/json'
                  result = WallMaskPainterService.new(@template).regenerate_wall_features!
                  response.status = 422 unless result[:success]
                  result.to_json
                rescue StandardError => e
                  warn "[BattleMapTemplates] regenerate_wall_features failed: #{e.message}"
                  response.status = 500
                  { success: false, error: e.message }.to_json
                end
              end
            end

            r.on 'delete' do
              r.post do
                @template.delete
                flash['success'] = 'Template deleted'
                r.redirect '/admin/battle_map_templates'
              end
            end
          end
        end

        # Battle Maps
        r.on 'battle_maps' do
          r.is do
            r.get do
              @rooms = Room.where(has_battle_map: true).order(:name).all rescue []
              @cover_types = CoverObjectType.order(:name).all rescue []
              view 'admin/battle_maps/index'
            end
          end

          # Test gallery for AI image generation QA
          r.on 'test_gallery' do
            r.is do
              r.get do
                service = BattleMapTestGalleryService.new
                @configs = BattleMapTestGalleryService::TEST_CONFIGS
                @results = service.load_results
                @rooms = @configs.each_index.map { |i| service.load_room(i) }
                view 'admin/battle_maps/test_gallery'
              end
            end

            r.on 'generate' do
              r.post do
                index = r.params['index'].to_i
                service = BattleMapTestGalleryService.new
                result = service.generate_image(index)
                if result[:success]
                  flash['success'] = "Generated image for test ##{index + 1}: #{BattleMapTestGalleryService::TEST_CONFIGS[index][:label]}"
                else
                  flash['error'] = "Failed to generate test ##{index + 1}: #{result[:error]}"
                end
                r.redirect '/admin/battle_maps/test_gallery'
              end
            end

            r.on 'generate_all' do
              r.post do
                max_concurrent = BattleMapTestGalleryService::MAX_CONCURRENT_MAPS
                successes = 0
                failures = 0
                mutex = Mutex.new
                semaphore = Mutex.new
                active = 0

                threads = BattleMapTestGalleryService::TEST_CONFIGS.each_index.map do |i|
                  Thread.new do
                    loop do
                      slot = false
                      semaphore.synchronize { slot = true; active += 1 if active < max_concurrent }
                      break if slot
                      sleep 1
                    end
                    begin
                      svc = BattleMapTestGalleryService.new
                      result = svc.generate_image(i)
                      mutex.synchronize { result[:success] ? successes += 1 : failures += 1 }
                    ensure
                      semaphore.synchronize { active -= 1 }
                    end
                  end
                end
                threads.each { |t| t.join(600) }

                if failures.zero?
                  flash['success'] = "Generated all #{successes} test images successfully"
                else
                  flash['warning'] = "Generated #{successes} images, #{failures} failed"
                end
                r.redirect '/admin/battle_maps/test_gallery'
              end
            end

            r.on 'classify' do
              r.post do
                index = r.params['index'].to_i
                service = BattleMapTestGalleryService.new
                result = service.classify_hexes(index)
                if result[:success]
                  flash['success'] = "Classified #{result[:count]} hexes for test ##{index + 1} (#{result[:model]}, legacy)"
                else
                  flash['error'] = "Classification failed for ##{index + 1}: #{result[:error]}"
                end
                r.redirect '/admin/battle_maps/test_gallery'
              end
            end

            r.on 'classify_simple' do
              r.post do
                index = r.params['index'].to_i
                service = BattleMapTestGalleryService.new
                result = service.classify_hexes_simple(index)
                if result[:success]
                  flash['success'] = "Simple classified #{result[:count]} hexes for test ##{index + 1} (#{result[:model]}, #{result[:other_count] || 0} 'other')"
                else
                  flash['error'] = "Simple classification failed for ##{index + 1}: #{result[:error]}"
                end
                r.redirect '/admin/battle_maps/test_gallery'
              end
            end

            r.on 'classify_overview' do
              r.post do
                index = r.params['index'].to_i
                service = BattleMapTestGalleryService.new
                result = service.classify_hexes_overview(index)
                if result[:success]
                  flash['success'] = "Overview classified #{result[:count]} hexes for test ##{index + 1} (#{result[:model]}, #{result[:types_found] || 0} types)"
                else
                  flash['error'] = "Overview classification failed for ##{index + 1}: #{result[:error]}"
                end
                r.redirect '/admin/battle_maps/test_gallery'
              end
            end

            r.on 'classify_all' do
              r.post do
                max_concurrent = BattleMapTestGalleryService::MAX_CONCURRENT_MAPS
                successes = 0
                failures = 0
                mutex = Mutex.new
                semaphore = Mutex.new
                active = 0

                # Pre-filter eligible indices
                svc_check = BattleMapTestGalleryService.new
                all_results = svc_check.load_results
                eligible = BattleMapTestGalleryService::TEST_CONFIGS.each_index.select do |i|
                  data = all_results[i.to_s]
                  data && data['success'] && data['labeled_url']
                end

                threads = eligible.map do |i|
                  Thread.new do
                    loop do
                      slot = false
                      semaphore.synchronize { slot = true; active += 1 if active < max_concurrent }
                      break if slot
                      sleep 1
                    end
                    begin
                      svc = BattleMapTestGalleryService.new
                      result = svc.classify_hexes(i)
                      mutex.synchronize { result[:success] ? successes += 1 : failures += 1 }
                    ensure
                      semaphore.synchronize { active -= 1 }
                    end
                  end
                end
                threads.each { |t| t.join(600) }

                if failures.zero?
                  flash['success'] = "Classified #{successes} battle maps successfully"
                else
                  flash['warning'] = "Classified #{successes} maps, #{failures} failed"
                end
                r.redirect '/admin/battle_maps/test_gallery'
              end
            end

            r.on 'cleanup' do
              r.post do
                service = BattleMapTestGalleryService.new
                service.cleanup_all
                flash['success'] = 'All test rooms and images cleaned up'
                r.redirect '/admin/battle_maps/test_gallery'
              end
            end

            # Generate and serve a blueprint SVG for a room on-the-fly
            r.on 'blueprint' do
              r.on Integer do |room_id|
                r.get do
                  room = Room[room_id]
                  unless room
                    response.status = 404
                    next 'Room not found'
                  end
                  svg = MapSvgRenderService.render_blueprint(room)
                  response['Content-Type'] = 'image/svg+xml'
                  svg
                end
              end
            end
          end

          # Battle map inspection page — must come before Integer matcher
          r.on 'inspect' do
            r.on Integer do |room_id|
              @room = Room[room_id]
              unless @room
                flash['error'] = 'Room not found'
                r.redirect '/admin/battle_maps'
              end

              inspect_dir = File.join('public', 'uploads', 'battle_map_debug', "room_#{room_id}")
              metadata_path = File.join(inspect_dir, 'inspection.json')

              unless File.exist?(metadata_path)
                flash['warning'] = 'No inspection data found. Generate a battle map first.'
                r.redirect "/admin/battle_maps/#{room_id}/edit"
              end

              @inspect_data = JSON.parse(File.read(metadata_path)) rescue {}
              @inspect_dir = inspect_dir
              @inspect_url_base = "/uploads/battle_map_debug/room_#{room_id}"

              # Collect all artifact images in the directory
              @artifacts = Dir.glob(File.join(inspect_dir, '*.{png,jpg,webp}')).map do |path|
                { filename: File.basename(path), url: "#{@inspect_url_base}/#{File.basename(path)}" }
              end.sort_by { |a| a[:filename] }

              @breadcrumbs = [
                { label: 'Admin', path: '/admin' },
                { label: 'Battle Maps', path: '/admin/battle_maps' },
                { label: @room.name, path: "/admin/battle_maps/#{room_id}/edit" },
                { label: 'Inspect' }
              ]

              view 'admin/battle_maps/inspect'
            end
          end

          r.on Integer do |id|
            @room = Room[id]
            unless @room
              flash['error'] = 'Room not found'
              r.redirect '/admin/battle_maps'
            end

            # Match both /admin/battle_maps/:id and /admin/battle_maps/:id/edit
            r.on 'edit' do
              r.get do
                @hexes = RoomHex.where(room_id: @room.id).all rescue []
                @hex_types = (RoomHex::HEX_TYPES + %w[door archway off_map]).uniq
                @surface_types = RoomHex::SURFACE_TYPES
                @cover_types = CoverObjectType.order(:name).all rescue []
                @cover_names_fallback = @cover_types.empty? ? RoomHex::COVER_OBJECTS : []
                @water_types = RoomHex::WATER_TYPES
                @hazard_types = RoomHex::HAZARD_TYPES
                @entity = @room
                @editor_mode = :room
                view 'admin/battle_maps/editor'
              end
            end

            r.is do
              r.get do
                @hexes = RoomHex.where(room_id: @room.id).all rescue []
                @hex_types = (RoomHex::HEX_TYPES + %w[door archway off_map]).uniq
                @surface_types = RoomHex::SURFACE_TYPES
                @cover_types = CoverObjectType.order(:name).all rescue []
                @cover_names_fallback = @cover_types.empty? ? RoomHex::COVER_OBJECTS : []
                @water_types = RoomHex::WATER_TYPES
                @hazard_types = RoomHex::HAZARD_TYPES
                @entity = @room
                @editor_mode = :room
                view 'admin/battle_maps/editor'
              end
            end

            # API endpoints for hex editor
            r.on 'api' do
              r.on 'hexes' do
                r.get do
                  hexes = RoomHex.where(room_id: @room.id).all rescue []
                  hex_data = hexes.map do |h|
                    {
                      id: h.id, hex_x: h.hex_x, hex_y: h.hex_y,
                      hex_type: h.hex_type, surface_type: h.surface_type,
                      cover_object: h.cover_object, has_cover: h.has_cover,
                      cover_height: h.cover_height, blocks_line_of_sight: h.blocks_line_of_sight,
                      destroyable: h.destroyable, hit_points: h.hit_points,
                      elevation_level: h.elevation_level,
                      is_ramp: h.is_ramp, is_stairs: h.is_stairs, is_ladder: h.is_ladder,
                      water_type: h.water_type, water_depth: h.water_depth,
                      requires_swimming: h.requires_swimming,
                      hazard_type: h.hazard_type, danger_level: h.danger_level,
                      hazard_damage_per_round: h.hazard_damage_per_round,
                      hazard_save_difficulty: h.hazard_save_difficulty,
                      is_potential_hazard: h.is_potential_hazard,
                      potential_trigger: h.potential_trigger,
                      traversable: h.traversable, difficult_terrain: h.difficult_terrain,
                      slippery: h.slippery, movement_modifier: h.movement_modifier&.to_f,
                      is_explosive: h.is_explosive,
                      explosion_radius: h.explosion_radius, explosion_damage: h.explosion_damage,
                      explosion_trigger: h.explosion_trigger,
                      description_override: h.description_override,
                      wall_feature: h.wall_feature
                    }
                  end
                  response['Content-Type'] = 'application/json'
                  { hexes: hex_data }.to_json
                end

                r.post do
                  hex_x = r.params['hex_x'].to_i
                  hex_y = r.params['hex_y'].to_i

                  hex = RoomHex.where(room_id: @room.id, hex_x: hex_x, hex_y: hex_y).first
                  unless hex
                    hex = RoomHex.new(
                      room_id: @room.id, hex_x: hex_x, hex_y: hex_y,
                      hex_type: 'normal', danger_level: 0, traversable: true,
                      has_cover: false, elevation_level: 0
                    )
                  end

                  # Helper to convert empty strings to nil for optional fields
                  nullable = ->(v) { (v.nil? || v.to_s.strip.empty?) ? nil : v }

                  hex.hex_type = r.params['hex_type'] if r.params['hex_type'] && !r.params['hex_type'].empty?
                  hex.surface_type = nullable.call(r.params['surface_type']) if r.params.key?('surface_type')

                  # Cover properties
                  hex.cover_object = nullable.call(r.params['cover_object']) if r.params.key?('cover_object')
                  hex.has_cover = r.params['has_cover'] == 'true' if r.params.key?('has_cover')
                  hex.cover_height = r.params['cover_height'].to_i if r.params['cover_height'] && !r.params['cover_height'].empty?
                  hex.blocks_line_of_sight = r.params['blocks_los'] == 'true' if r.params.key?('blocks_los')
                  hex.destroyable = r.params['destroyable'] == 'true' if r.params.key?('destroyable')
                  hex.hit_points = r.params['hit_points'].to_i if r.params['hit_points'] && !r.params['hit_points'].empty?

                  # Elevation properties
                  hex.elevation_level = r.params['elevation_level'].to_i if r.params['elevation_level'] && !r.params['elevation_level'].empty?
                  hex.is_ramp = r.params['is_ramp'] == 'true' if r.params.key?('is_ramp')
                  hex.is_stairs = r.params['is_stairs'] == 'true' if r.params.key?('is_stairs')
                  hex.is_ladder = r.params['is_ladder'] == 'true' if r.params.key?('is_ladder')

                  # Water properties
                  hex.water_type = nullable.call(r.params['water_type']) if r.params.key?('water_type')
                  hex.water_depth = r.params['water_depth'].to_i if r.params['water_depth'] && !r.params['water_depth'].empty?
                  hex.requires_swimming = r.params['requires_swimming'] == 'true' if r.params.key?('requires_swimming')

                  # Hazard properties
                  hex.hazard_type = nullable.call(r.params['hazard_type']) if r.params.key?('hazard_type')
                  hex.danger_level = r.params['danger_level'].to_i if r.params['danger_level'] && !r.params['danger_level'].empty?
                  hex.hazard_damage_per_round = r.params['hazard_damage_per_round'].to_i if r.params['hazard_damage_per_round'] && !r.params['hazard_damage_per_round'].empty?
                  hex.hazard_save_difficulty = r.params['hazard_save_difficulty'].to_i if r.params['hazard_save_difficulty'] && !r.params['hazard_save_difficulty'].empty?
                  hex.is_potential_hazard = r.params['is_potential_hazard'] == 'true' if r.params.key?('is_potential_hazard')
                  hex.potential_trigger = nullable.call(r.params['potential_trigger']) if r.params.key?('potential_trigger')

                  # Explosive properties
                  hex.is_explosive = r.params['is_explosive'] == 'true' if r.params.key?('is_explosive')
                  hex.explosion_radius = r.params['explosion_radius'].to_i if r.params['explosion_radius'] && !r.params['explosion_radius'].empty?
                  hex.explosion_damage = r.params['explosion_damage'].to_i if r.params['explosion_damage'] && !r.params['explosion_damage'].empty?
                  hex.explosion_trigger = nullable.call(r.params['explosion_trigger']) if r.params.key?('explosion_trigger')

                  # Movement properties
                  hex.traversable = r.params['traversable'] != 'false' if r.params.key?('traversable')
                  hex.difficult_terrain = r.params['difficult_terrain'] == 'true' if r.params.key?('difficult_terrain')
                  hex.slippery = r.params['slippery'] == 'true' if r.params.key?('slippery')
                  hex.movement_modifier = r.params['movement_modifier'].to_f if r.params['movement_modifier'] && !r.params['movement_modifier'].empty?

                  # Description
                  hex.description_override = nullable.call(r.params['description_override']) if r.params.key?('description_override')

                  hex.save
                  response['Content-Type'] = 'application/json'
                  { success: true, hex_id: hex.id }.to_json
                rescue StandardError => e
                  warn "[BattleMaps] Hex update failed: #{e.message}"
                  response['Content-Type'] = 'application/json'
                  response.status = 422
                  { success: false, error: e.message }.to_json
                end
              end

              # Generate SAM masks for lighting/effects
              r.on 'generate_masks' do
                r.post do
                  response['Content-Type'] = 'application/json'

                  unless @room.battle_map_image_url && !@room.battle_map_image_url.to_s.strip.empty?
                    return { success: false, error: 'No background image uploaded' }.to_json
                  end

                  unless defined?(ReplicateSamService) && ReplicateSamService.available?
                    return { success: false, error: 'SAM service not available (no Replicate API key)' }.to_json
                  end

                  # Resolve image path on disk
                  image_url = @room.battle_map_image_url
                  local_path = if image_url.start_with?('/')
                                 File.join('public', image_url)
                               else
                                 image_url
                               end

                  unless File.exist?(local_path)
                    return { success: false, error: "Image not found on disk: #{local_path}" }.to_json
                  end

                  results = {}
                  mask_updates = {}

                  # Effect masks: water
                  if r.params['sam_water']
                    result = ReplicateSamService.segment(local_path, 'water', suffix: '_sam_water')
                    if result[:success] && result[:mask_path] && !result[:no_detections]
                      url = result[:mask_path].sub(%r{^public/?}, '')
                      url = "/#{url}" unless url.start_with?('/')
                      mask_updates[:battle_map_water_mask_url] = url
                      results['water'] = { success: true }
                    else
                      results['water'] = { success: false, error: result[:no_detections] ? 'No water detected' : (result[:error] || 'failed') }
                    end
                  end

                  # Effect masks: foliage (tree + bush combined)
                  if r.params['sam_foliage']
                    tree_result = ReplicateSamService.segment(local_path, 'tree', suffix: '_sam_foliage_tree')
                    bush_result = ReplicateSamService.segment(local_path, 'bush', suffix: '_sam_foliage_bush')

                    # Combine masks via Vips OR
                    begin
                      require 'vips'
                      masks = []
                      masks << Vips::Image.new_from_file(tree_result[:mask_path]) if tree_result[:success] && tree_result[:mask_path] && !tree_result[:no_detections] && File.exist?(tree_result[:mask_path])
                      masks << Vips::Image.new_from_file(bush_result[:mask_path]) if bush_result[:success] && bush_result[:mask_path] && !bush_result[:no_detections] && File.exist?(bush_result[:mask_path])

                      if masks.any?
                        combined = masks.first
                        masks[1..].each do |m|
                          m = m.resize(combined.width.to_f / m.width) if m.width != combined.width
                          combined = (combined | m)
                        end
                        combined = combined.extract_band(0) if combined.bands > 1
                        output_path = local_path.sub(/(\.\w+)$/, '_sam_foliage.png')
                        combined.write_to_file(output_path)
                        url = output_path.sub(%r{^public/?}, '')
                        url = "/#{url}" unless url.start_with?('/')
                        mask_updates[:battle_map_foliage_mask_url] = url
                        results['foliage'] = { success: true }
                      else
                        results['foliage'] = { success: false, error: 'No foliage detected' }
                      end
                    rescue StandardError => e
                      results['foliage'] = { success: false, error: e.message }
                    end
                  end

                  # Light sources and fire mask — constants from AIBattleMapGeneratorService
                  sam_light_queries = AIBattleMapGeneratorService::SAM_LIGHT_QUERIES
                  light_colors = AIBattleMapGeneratorService::LIGHT_COLORS
                  light_intensities = AIBattleMapGeneratorService::LIGHT_INTENSITIES

                  all_light_sources = []
                  fire_mask_path = nil

                  sam_light_queries.each do |stype, query|
                    next unless r.params["sam_light_#{stype}"]

                    suffix = "_sam_light_#{stype}"
                    result = ReplicateSamService.segment(local_path, query, suffix: suffix)

                    if result[:success] && result[:mask_path] && !result[:no_detections] && File.exist?(result[:mask_path])
                      # Extract light source positions via OpenCV
                      positions = AIBattleMapGeneratorService.extract_positions_from_mask(result[:mask_path])

                      if positions.any?
                        positions.each do |pos|
                          all_light_sources << {
                            'type' => stype,
                            'center_x' => pos[:cx],
                            'center_y' => pos[:cy],
                            'radius_px' => [pos[:radius] * 3, 60].max,
                            'intensity' => light_intensities[stype] || AIBattleMapGeneratorService::LIGHT_INTENSITY_DEFAULT,
                            'color' => light_colors[stype] || AIBattleMapGeneratorService::LIGHT_COLOR_DEFAULT
                          }
                        end
                        results["light_#{stype}"] = { success: true, count: positions.length }
                      else
                        results["light_#{stype}"] = { success: false, error: 'No positions detected' }
                      end

                      # Use fire-type mask as the fire effect mask
                      fire_mask_path = result[:mask_path] if stype == 'fire'
                    else
                      results["light_#{stype}"] = { success: false, error: result[:no_detections] ? 'Nothing detected' : (result[:error] || 'failed') }
                    end
                  end

                  # Process fire effect mask (threshold + store)
                  if r.params['sam_fire'] || fire_mask_path
                    # If fire mask checkbox checked but no fire light source was run, run SAM for fire
                    if r.params['sam_fire'] && !fire_mask_path
                      fire_result = ReplicateSamService.segment(local_path, 'hearth fire', suffix: '_sam_light_fire')
                      fire_mask_path = fire_result[:mask_path] if fire_result[:success] && !fire_result[:no_detections]
                    end

                    if fire_mask_path && File.exist?(fire_mask_path)
                      begin
                        require 'vips'
                        mask = Vips::Image.new_from_file(fire_mask_path)
                        mask = mask.extract_band(0) if mask.bands > 1
                        if mask.avg > 20
                          binary = (mask > 200).ifthenelse(255, 0).cast(:uchar)
                          binary.pngsave(fire_mask_path)
                        end
                        url = fire_mask_path.sub(%r{^public/?}, '')
                        url = "/#{url}" unless url.start_with?('/')
                        mask_updates[:battle_map_fire_mask_url] = url
                        results['fire'] = { success: true } unless results['fire']
                      rescue StandardError => e
                        results['fire'] = { success: false, error: e.message }
                      end
                    else
                      results['fire'] = { success: false, error: 'No fire detected' } unless results['fire']
                    end
                  end

                  # Persist mask URLs and light sources
                  @room.update(mask_updates) if mask_updates.any?
                  if all_light_sources.any?
                    @room.update(detected_light_sources: Sequel.pg_jsonb_wrap(all_light_sources))
                  end

                  { success: true, results: results }.to_json
                rescue StandardError => e
                  warn "[BattleMaps] Mask generation failed: #{e.message}"
                  response['Content-Type'] = 'application/json'
                  response.status = 500
                  { success: false, error: e.message }.to_json
                end
              end

              # Clear all masks
              r.on 'clear_masks' do
                r.post do
                  @room.update(
                    battle_map_water_mask_url: nil,
                    battle_map_foliage_mask_url: nil,
                    battle_map_fire_mask_url: nil,
                    detected_light_sources: Sequel.pg_jsonb_wrap([])
                  )
                  response['Content-Type'] = 'application/json'
                  { success: true }.to_json
                rescue StandardError => e
                  warn "[BattleMaps] Clear masks failed: #{e.message}"
                  response['Content-Type'] = 'application/json'
                  response.status = 500
                  { success: false, error: e.message }.to_json
                end
              end

              r.on 'wall_mask_rect' do
                r.post do
                  response['Content-Type'] = 'application/json'
                  x1 = r.params['x1'].to_f.clamp(0.0, 1.0)
                  y1 = r.params['y1'].to_f.clamp(0.0, 1.0)
                  x2 = r.params['x2'].to_f.clamp(0.0, 1.0)
                  y2 = r.params['y2'].to_f.clamp(0.0, 1.0)
                  mask_type = r.params['mask_type'].to_s.strip

                  result = WallMaskPainterService.new(@room).paint_rect(x1, y1, x2, y2, mask_type)
                  response.status = 422 unless result[:success]
                  result.to_json
                rescue StandardError => e
                  warn "[BattleMaps] wall_mask_rect failed: #{e.message}"
                  response.status = 422
                  { success: false, error: e.message }.to_json
                end
              end

              r.on 'clear_wall_mask' do
                r.post do
                  response['Content-Type'] = 'application/json'
                  result = WallMaskPainterService.new(@room).clear!
                  result.to_json
                rescue StandardError => e
                  warn "[BattleMaps] clear_wall_mask failed: #{e.message}"
                  response.status = 500
                  { success: false, error: e.message }.to_json
                end
              end

              r.on 'regenerate_wall_features' do
                r.post do
                  response['Content-Type'] = 'application/json'
                  result = WallMaskPainterService.new(@room).regenerate_wall_features!
                  response.status = 422 unless result[:success]
                  result.to_json
                rescue StandardError => e
                  warn "[BattleMaps] regenerate_wall_features failed: #{e.message}"
                  response.status = 500
                  { success: false, error: e.message }.to_json
                end
              end
            end

            # Procedural generation
            r.on 'generate' do
              r.post do
                service = BattleMapGeneratorService.new(@room)
                if service.generate!
                  flash['success'] = 'Battle map generated successfully'
                else
                  flash['error'] = 'Failed to generate battle map'
                end
                r.redirect "/admin/battle_maps/#{@room.id}"
              end
            end

            # AI generation
            r.on 'generate_ai' do
              r.post do
                if defined?(AIBattleMapGeneratorService)
                  service = AIBattleMapGeneratorService.new(@room)
                  result = service.generate
                  if result[:success]
                    if result[:fallback]
                      flash['success'] = "Battle map generated (procedural fallback: #{result[:error]})"
                    else
                      flash['success'] = "AI battle map generated successfully (#{result[:hex_count]} hexes)"
                    end
                  else
                    flash['error'] = "Failed to generate AI battle map: #{result[:error]}"
                  end
                else
                  flash['error'] = 'AI battle map generation not available'
                end
                r.redirect "/admin/battle_maps/#{@room.id}"
              end
            end

            # Regenerate AI
            r.on 'regenerate_ai' do
              r.post do
                if defined?(AIBattleMapGeneratorService)
                  # Clear existing hexes first
                  RoomHex.where(room_id: @room.id).delete
                  service = AIBattleMapGeneratorService.new(@room)
                  result = service.generate
                  if result[:success]
                    if result[:fallback]
                      flash['success'] = "Battle map regenerated (procedural fallback: #{result[:error]})"
                    else
                      flash['success'] = "AI battle map regenerated successfully (#{result[:hex_count]} hexes)"
                    end
                  else
                    flash['error'] = "Failed to regenerate AI battle map: #{result[:error]}"
                  end
                else
                  flash['error'] = 'AI battle map generation not available'
                end
                r.redirect "/admin/battle_maps/#{@room.id}"
              end
            end

            # Clear all hexes
            r.on 'clear' do
              r.post do
                RoomHex.where(room_id: @room.id).delete
                @room.update(has_battle_map: false, battle_map_image_url: nil) rescue nil
                flash['success'] = 'Battle map cleared'
                r.redirect "/admin/battle_maps/#{@room.id}"
              end
            end

            # Upload background image
            r.on 'upload_image' do
              r.post do
                if r.params['battle_map_image'] && r.params['battle_map_image'][:tempfile]
                  file = r.params['battle_map_image']
                  ext = File.extname(file[:filename]).downcase
                  filename = "battle_map_#{@room.id}#{ext}"
                  dest = File.join('public', 'uploads', 'battle_maps', filename)
                  FileUtils.mkdir_p(File.dirname(dest))
                  FileUtils.cp(file[:tempfile].path, dest)
                  @room.update(battle_map_image_url: "/uploads/battle_maps/#{filename}")
                  flash['success'] = 'Background image uploaded'
                else
                  flash['error'] = 'No image file provided'
                end
                r.redirect "/admin/battle_maps/#{@room.id}"
              end
            end
          end
        end

        # Content Restrictions
        r.on 'content_restrictions' do
          r.is do
            r.get do
              @restrictions = ContentRestriction.order(:name).all rescue []
              view 'admin/content_restrictions/index'
            end
          end

          r.on Integer do |id|
            @restriction = ContentRestriction[id]
            unless @restriction
              flash['error'] = 'Restriction not found'
              r.redirect '/admin/content_restrictions'
            end

            r.get do
              view 'admin/content_restrictions/edit'
            end
          end
        end

        # World Generator (LLM-powered content generation)
        r.on 'world_generator' do
          # Index page with generation forms
          r.is do
            r.get do
              @ai_available = WorldBuilderOrchestratorService.available? rescue false
              @active_jobs = ProgressTrackerService.active_jobs_for(current_character) rescue []
              @sample_tables = {
                character: SeedTermService.sample(:character_descriptors, count: 3),
                locations: SeedTermService.sample(:locations, count: 3),
                city: SeedTermService.sample(:city_descriptors, count: 3),
                adventure_tone: SeedTermService.sample(:adventure_tone, count: 3)
              } rescue {}
              view 'admin/world_generator/index'
            end
          end

          # Generate description
          r.post 'description' do
            target_type = r.params['target_type']
            target_id = r.params['target_id'].to_i
            setting = (r.params['setting'] || 'fantasy').to_sym

            target = case target_type
                     when 'room' then Room[target_id]
                     when 'item' then Pattern[target_id]
                     when 'npc' then Character[target_id]
                     end

            unless target
              flash['error'] = "#{target_type.capitalize} ##{target_id} not found"
              r.redirect '/admin/world_generator'
            end

            job = WorldBuilderOrchestratorService.generate_description(
              target: target,
              setting: setting,
              created_by: current_character
            )

            flash['success'] = "Description generation started. Job ##{job.id}"
            r.redirect "/admin/world_generator/jobs/#{job.id}"
          end

          # Generate item
          r.post 'item' do
            category = (r.params['category'] || 'misc').to_sym
            subcategory = r.params['subcategory']
            subcategory = nil if subcategory&.empty?
            generate_image = r.params['generate_image'] == 'on'
            setting = (r.params['setting'] || 'fantasy').to_sym

            job = WorldBuilderOrchestratorService.generate_item(
              category: category,
              subcategory: subcategory,
              setting: setting,
              generate_image: generate_image,
              created_by: current_character
            )

            flash['success'] = "Item generation started. Job ##{job.id}"
            r.redirect "/admin/world_generator/jobs/#{job.id}"
          end

          # Generate NPC
          r.post 'npc' do
            location_id = r.params['location_id'].to_i
            location = Location[location_id]

            unless location
              flash['error'] = "Location ##{location_id} not found"
              r.redirect '/admin/world_generator'
            end

            role = r.params['role']
            role = nil if role&.empty?
            gender = (r.params['gender'] || 'any').to_sym
            culture = (r.params['culture'] || 'western').to_sym
            setting = (r.params['setting'] || 'fantasy').to_sym
            generate_portrait = r.params['generate_portrait'] == 'on'
            generate_schedule = r.params['generate_schedule'] == 'on'

            job = WorldBuilderOrchestratorService.generate_npc(
              location: location,
              role: role,
              gender: gender,
              culture: culture,
              setting: setting,
              generate_portrait: generate_portrait,
              generate_schedule: generate_schedule,
              created_by: current_character
            )

            flash['success'] = "NPC generation started. Job ##{job.id}"
            r.redirect "/admin/world_generator/jobs/#{job.id}"
          end

          # Generate place
          r.post 'place' do
            longitude = r.params['longitude']&.to_f
            latitude = r.params['latitude']&.to_f

            unless longitude && latitude
              flash['error'] = 'Coordinates (longitude, latitude) are required'
              r.redirect '/admin/world_generator'
            end

            place_type = (r.params['place_type'] || 'tavern').to_sym
            setting = (r.params['setting'] || 'fantasy').to_sym
            generate_rooms = r.params['generate_rooms'] == 'on'
            generate_npcs = r.params['generate_npcs'] == 'on'

            job = WorldBuilderOrchestratorService.generate_place(
              longitude: longitude,
              latitude: latitude,
              place_type: place_type,
              setting: setting,
              generate_rooms: generate_rooms,
              generate_npcs: generate_npcs,
              created_by: current_character
            )

            flash['success'] = "Place generation started. Job ##{job.id}"
            r.redirect "/admin/world_generator/jobs/#{job.id}"
          end

          # Generate city
          r.post 'city' do
            longitude = r.params['longitude']&.to_f
            latitude = r.params['latitude']&.to_f

            unless longitude && latitude
              flash['error'] = 'Coordinates (longitude, latitude) are required'
              r.redirect '/admin/world_generator'
            end

            size = (r.params['size'] || 'medium').to_sym
            setting = (r.params['setting'] || 'fantasy').to_sym
            generate_places = r.params['generate_places'] == 'on'
            generate_place_rooms = r.params['generate_place_rooms'] == 'on'
            generate_npcs = r.params['generate_npcs'] == 'on'
            generate_inventory = r.params['generate_inventory'] == 'on'
            green_space_ratio = r.params['green_space_ratio'] ? r.params['green_space_ratio'].to_f / 100.0 : nil

            job = WorldBuilderOrchestratorService.generate_city(
              longitude: longitude,
              latitude: latitude,
              setting: setting,
              size: size,
              generate_places: generate_places,
              generate_place_rooms: generate_place_rooms,
              generate_npcs: generate_npcs,
              created_by: current_character,
              options: { green_space_ratio: green_space_ratio, generate_inventory: generate_inventory }.compact
            )

            flash['success'] = "City generation started. This may take several minutes. Job ##{job.id}"
            r.redirect "/admin/world_generator/jobs/#{job.id}"
          end

          # Generate image
          r.post 'image' do
            target_type = r.params['target_type']
            target_id = r.params['target_id'].to_i
            setting = (r.params['setting'] || 'fantasy').to_sym

            target = case target_type
                     when 'room' then Room[target_id]
                     when 'item' then Pattern[target_id]
                     when 'npc' then Character[target_id]
                     end

            unless target
              flash['error'] = "#{target_type.capitalize} ##{target_id} not found"
              r.redirect '/admin/world_generator'
            end

            job = WorldBuilderOrchestratorService.generate_image(
              target: target,
              setting: setting,
              created_by: current_character
            )

            flash['success'] = "Image generation started. Job ##{job.id}"
            r.redirect "/admin/world_generator/jobs/#{job.id}"
          end

          # Jobs list
          r.on 'jobs' do
            r.is do
              r.get do
                @jobs = GenerationJob.order(Sequel.desc(:created_at)).limit(100).all.map do |job|
                  ProgressTrackerService.get_progress(job: job)
                end
                view 'admin/world_generator/jobs'
              end
            end

            # Single job view
            r.on Integer do |job_id|
              @job = GenerationJob[job_id]
              unless @job
                flash['error'] = "Job ##{job_id} not found"
                r.redirect '/admin/world_generator'
              end

              r.is do
                r.get do
                  @job_info = ProgressTrackerService.get_progress(job: @job)
                  view 'admin/world_generator/job'
                end
              end

              # Cancel job
              r.post 'cancel' do
                if %w[pending running].include?(@job.status)
                  ProgressTrackerService.cancel(job: @job)
                  flash['success'] = "Job ##{job_id} cancelled"
                else
                  flash['error'] = "Job ##{job_id} cannot be cancelled (status: #{@job.status})"
                end
                r.redirect '/admin/world_generator/jobs'
              end
            end
          end
        end

        # Mission Generator (LLM-driven mission creation)
        r.on 'mission_generator' do
          # New mission form
          r.is do
            r.get do
              @models_available = Generators::MissionGeneratorService.models_available? rescue { available: false }
              @active_jobs = GenerationJob.where(job_type: 'mission', created_by_id: current_character&.id)
                                          .where(status: %w[pending running])
                                          .order(Sequel.desc(:created_at))
                                          .limit(5).all rescue []
              @recent_jobs = GenerationJob.where(job_type: 'mission')
                                          .order(Sequel.desc(:created_at))
                                          .limit(10).all rescue []
              @settings = Generators::MissionGeneratorService::SETTINGS
              @difficulties = Generators::MissionGeneratorService::DIFFICULTY_TIERS
              @location_modes = Generators::MissionGeneratorService::LOCATION_MODES
              @rooms = Room.order(:name).limit(200).all rescue []
              @universes = Universe.order(:name).all rescue []
              view 'admin/mission_generator/new'
            end

            # Submit generation request
            r.post do
              description = r.params['description']
              location_mode = (r.params['location_mode'] || 'mission_specific').to_sym
              setting = (r.params['setting'] || 'fantasy').to_sym
              difficulty = (r.params['difficulty'] || 'normal').to_sym
              generate_images = r.params['generate_images'] == 'on'
              universe_id = r.params['universe_id']&.to_i
              stat_block_id = r.params['stat_block_id']&.to_i
              activity_type = r.params['activity_type'] || 'mission'

              # Handle existing room option
              base_location = nil
              if location_mode == :existing && r.params['base_room_id']
                base_location = Room[r.params['base_room_id'].to_i]
              end

              if description.nil? || description.to_s.strip.length < 10
                flash['error'] = 'Mission description must be at least 10 characters'
                r.redirect '/admin/mission_generator'
              end

              job = Generators::MissionGeneratorService.generate_async(
                description: description,
                location_mode: location_mode,
                setting: setting,
                difficulty: difficulty,
                options: {
                  generate_images: generate_images,
                  base_location: base_location,
                  universe_id: universe_id.nil? || universe_id == 0 ? nil : universe_id,
                  stat_block_id: stat_block_id.nil? || stat_block_id == 0 ? nil : stat_block_id,
                  activity_type: activity_type
                },
                created_by: current_character
              )

              flash['success'] = "Mission generation started. Job ##{job.id}"
              r.redirect "/admin/mission_generator/#{job.id}"
            end
          end

          # API endpoint for stat blocks (used by universe dropdown JS)
          r.get 'api/stat_blocks' do
            response['Content-Type'] = 'application/json'
            universe_id = r.params['universe_id']&.to_i
            if universe_id && universe_id > 0
              blocks = StatBlock.where(universe_id: universe_id).order(:name).all
              {
                success: true,
                stat_blocks: blocks.map { |sb| { id: sb.id, name: sb.name, block_type: sb.block_type, is_default: sb.is_default } }
              }.to_json
            else
              { success: true, stat_blocks: [] }.to_json
            end
          end

          # Single job view
          r.on Integer do |job_id|
            @job = GenerationJob[job_id]
            unless @job && @job.job_type == 'mission'
              flash['error'] = "Mission job ##{job_id} not found"
              r.redirect '/admin/mission_generator'
            end

            r.is do
              r.get do
                @activity = @job.result_value(:activity_id) ? Activity[@job.result_value(:activity_id)] : nil
                view 'admin/mission_generator/show'
              end
            end

            # Cancel job
            r.post 'cancel' do
              if Generators::MissionGeneratorService.cancel(@job)
                flash['success'] = "Job ##{job_id} cancelled"
              else
                flash['error'] = "Job ##{job_id} cannot be cancelled (status: #{@job.status})"
              end
              r.redirect '/admin/mission_generator'
            end
          end
        end

        # Activity Builder (Missions, Competitions, Tasks)
        r.on 'activity_builder' do
          # Activity list/index page
          r.is do
            r.get do
              @activities = Activity.order(Sequel.desc(:id)).limit(100).all
              @activity_types = Activity::ACTIVITY_TYPES
              view 'admin/activity_builder/index'
            end

            r.post do
              data = r.params
              activity = Activity.create(
                name: data['name'],
                description: data['description'],
                activity_type: data['type'] || 'mission',
                share_type: data['share_type'] || 'private',
                launch_mode: data['launch_mode'] || 'creator',
                location: data['location_id'],
                is_public: data['is_public'] == 'on',
                repeatable: data['repeatable'] == 'on',
                created_by: current_character&.id
              )
              flash['success'] = "Activity '#{activity.aname}' created"
              r.redirect "/admin/activity_builder/#{activity.id}"
            end
          end

          # New activity form
          r.get 'new' do
            @activity = nil
            @activity_types = Activity::ACTIVITY_TYPES
            @round_types = ActivityRound::ROUND_TYPES
            @rooms = Room.order(:name).limit(500).all
            @npc_archetypes = NpcArchetype.order(:name).all
            @patterns = Pattern.order(:description).limit(200).all
            @universes = Universe.order(:name).all
            view 'admin/activity_builder/editor'
          end

          # Top-level API endpoints (used by the new-activity form where there's no activity ID yet)
          r.on 'api' do
            response['Content-Type'] = 'application/json'

            r.get 'worlds' do
              worlds = World.order(:name).all
              { success: true, worlds: worlds.map { |w| { id: w.id, name: w.name } } }.to_json
            end

            r.get 'locations' do
              world_id = r.params['world_id']&.to_i
              locations = world_id ? Location.where(world_id: world_id).order(:name).all : []
              { success: true, locations: locations.map { |l| { id: l.id, name: l.name } } }.to_json
            end

            r.get 'rooms' do
              location_id = r.params['location_id']&.to_i
              rooms = location_id ? Room.where(location_id: location_id).order(:name).all : Room.order(:name).limit(500).all
              { success: true, rooms: rooms.map { |rm| { id: rm.id, name: rm.name } } }.to_json
            end
          end

          r.on Integer do |activity_id|
            @activity = Activity[activity_id]
            unless @activity
              flash['error'] = 'Activity not found'
              r.redirect '/admin/activity_builder'
            end

            # Main editor page
            r.is do
              r.get do
                @activity_types = Activity::ACTIVITY_TYPES
                @round_types = ActivityRound::ROUND_TYPES
                @rooms = Room.order(:name).limit(500).all
                @npc_archetypes = NpcArchetype.order(:name).all
                @patterns = Pattern.order(:description).limit(200).all
                @universes = Universe.order(:name).all
                view 'admin/activity_builder/editor'
              end

              r.put do
                data = JSON.parse(request.body.read)
                @activity.update(
                  name: data['name'],
                  description: data['description'],
                  activity_type: data['type'],
                  share_type: data['share_type'],
                  launch_mode: data['launch_mode'],
                  location: data['location_id'],
                  locale: data['locale_id'],
                  anchor_item_id: data['anchor_item_id'],
                  anchor_item_pattern_id: data['anchor_item_pattern_id'],
                  task_trigger_room_id: data['task_trigger_room_id'],
                  task_auto_start: data['task_auto_start'],
                  is_public: data['is_public'],
                  repeatable: data['repeatable'],
                  universe_id: data['universe_id'],
                  stat_block_id: data['stat_block_id']
                )
                response['Content-Type'] = 'application/json'
                { success: true, activity: @activity.to_builder_json }.to_json
              end

              r.delete do
                @activity.destroy
                response['Content-Type'] = 'application/json'
                { success: true }.to_json
              end
            end

            # API endpoints for the builder
            r.on 'api' do
              response['Content-Type'] = 'application/json'

              r.get 'activity' do
                {
                  success: true,
                  activity: @activity.to_builder_json,
                  rounds: @activity.rounds.map(&:to_builder_json)
                }.to_json
              end

              r.on 'rounds' do
                r.is do
                  r.get do
                    { success: true, rounds: @activity.rounds.map(&:to_builder_json) }.to_json
                  end

                  r.post do
                    data = JSON.parse(request.body.read)
                    round = ActivityRound.create(
                      activity_id: @activity.id,
                      round_number: data['round_number'] || (@activity.total_rounds + 1),
                      branch: data['branch'] || 0,
                      rtype: data['round_type'] || 'standard',
                      emit: data['emit'],
                      succ_text: data['success_text'],
                      fail_text: data['failure_text'],
                      canvas_x: data['canvas_x'] || 0,
                      canvas_y: data['canvas_y'] || 0
                    )
                    { success: true, round: round.to_builder_json }.to_json
                  end
                end

                r.post 'reorder' do
                  data = JSON.parse(request.body.read)
                  data['order'].each_with_index do |round_data, idx|
                    round = ActivityRound[round_data['id']]
                    round&.update(round_number: idx + 1) if round&.activity_id == @activity.id
                  end
                  { success: true }.to_json
                end

                r.on Integer do |round_id|
                  @round = ActivityRound[round_id]
                  unless @round && @round.activity_id == @activity.id
                    next { success: false, error: 'Round not found' }.to_json
                  end

                  r.is do
                    r.get do
                      { success: true, round: @round.to_builder_json }.to_json
                    end

                    r.put do
                      data = JSON.parse(request.body.read)
                      npc_ids = data['combat_npc_ids']
                      npc_ids = Sequel.pg_array(npc_ids.map(&:to_i), :integer) if npc_ids.is_a?(Array)

                      update_hash = {}
                      update_hash[:name] = data['name'] if data.key?('name')
                      update_hash[:rtype] = data['round_type'] if data.key?('round_type')
                      update_hash[:emit] = data['emit'] if data.key?('emit')
                      update_hash[:succ_text] = data['success_text'] if data.key?('success_text')
                      update_hash[:fail_text] = data['failure_text'] if data.key?('failure_text')
                      update_hash[:fail_con] = data['failure_consequence'] if data.key?('failure_consequence')
                      update_hash[:fail_repeat] = data['fail_repeat'] if data.key?('fail_repeat')
                      update_hash[:knockout] = data['knockout'] if data.key?('knockout')
                      update_hash[:single_solution] = data['single_solution'] if data.key?('single_solution')
                      update_hash[:group_actions] = data['group_actions'] if data.key?('group_actions')
                      update_hash[:round_room_id] = data['round_room_id'] if data.key?('round_room_id')
                      update_hash[:use_activity_room] = data['use_activity_room'] if data.key?('use_activity_room')
                      update_hash[:media_url] = data['media_url'] if data.key?('media_url')
                      update_hash[:media_type] = data['media_type'] if data.key?('media_type')
                      update_hash[:media_display_mode] = data['media_display_mode'] if data.key?('media_display_mode')
                      update_hash[:media_duration_mode] = data['media_duration_mode'] if data.key?('media_duration_mode')
                      update_hash[:canvas_x] = data['canvas_x'] if data.key?('canvas_x')
                      update_hash[:canvas_y] = data['canvas_y'] if data.key?('canvas_y')
                      update_hash[:battle_map_room_id] = data['battle_map_room_id'] if data.key?('battle_map_room_id')
                      update_hash[:combat_difficulty] = data['combat_difficulty'] if data.key?('combat_difficulty')
                      update_hash[:combat_is_finale] = data['combat_is_finale'] if data.key?('combat_is_finale')
                      update_hash[:combat_npc_ids] = npc_ids if data.key?('combat_npc_ids')
                      update_hash[:branch_to] = data['branch_to'] if data.key?('branch_to')
                      update_hash[:branch_choice_one] = data['branch_choice_one'] if data.key?('branch_choice_one')
                      update_hash[:branch_choice_two] = data['branch_choice_two'] if data.key?('branch_choice_two')
                      update_hash[:fail_branch_to] = data['fail_branch_to'] if data.key?('fail_branch_to')
                      update_hash[:reflex_stat_id] = data['reflex_stat_id'] if data.key?('reflex_stat_id')
                      update_hash[:persuade_stat_id] = data['persuade_stat_id'] if data.key?('persuade_stat_id')
                      if data.key?('persuade_stat_ids') && data['persuade_stat_ids'].is_a?(Array)
                        ids = data['persuade_stat_ids'].map(&:to_i)
                        update_hash[:stat_set_a] = Sequel.pg_array(ids, :integer)
                        update_hash[:persuade_stat_id] = ids.first
                      end
                      update_hash[:persuade_base_dc] = data['persuade_base_dc'] if data.key?('persuade_base_dc')
                      update_hash[:timeout_seconds] = data['timeout_seconds'] if data.key?('timeout_seconds')
                      update_hash[:persuade_npc_name] = data['persuade_npc_name'] if data.key?('persuade_npc_name')
                      update_hash[:persuade_npc_personality] = data['persuade_npc_personality'] if data.key?('persuade_npc_personality')
                      update_hash[:persuade_goal] = data['persuade_goal'] if data.key?('persuade_goal')
                      update_hash[:free_roll_context] = data['free_roll_context'] if data.key?('free_roll_context')

                      if data.key?('stat_set_a') && data['stat_set_a'].is_a?(Array)
                        update_hash[:stat_set_a] = Sequel.pg_array(data['stat_set_a'].map(&:to_i), :integer)
                      end
                      if data.key?('stat_set_b') && data['stat_set_b'].is_a?(Array)
                        update_hash[:stat_set_b] = Sequel.pg_array(data['stat_set_b'].map(&:to_i), :integer)
                      end

                      if data.key?('branch_choices') && data['branch_choices'].is_a?(Array)
                        update_hash[:branch_choices] = Sequel.pg_jsonb_wrap(data['branch_choices'])
                      end

                      @round.update(update_hash)
                      { success: true, round: @round.to_builder_json }.to_json
                    end

                    r.delete do
                      @round.destroy
                      { success: true }.to_json
                    end
                  end

                  # Task CRUD for this round
                  r.on 'tasks' do
                    r.is do
                      r.get do
                        tasks = ActivityTask.where(activity_round_id: @round.id).order(:task_number).all
                        { success: true, tasks: tasks.map(&:to_builder_json) }.to_json
                      end

                      r.post do
                        begin
                          data = JSON.parse(request.body.read)
                          stat_a = data['stat_set_a']
                          stat_a = Sequel.pg_array(stat_a.map(&:to_i), :integer) if stat_a.is_a?(Array)
                          stat_b = data['stat_set_b']
                          stat_b = if stat_b.is_a?(Array) && stat_b.any?
                                     Sequel.pg_array(stat_b.map(&:to_i), :integer)
                                   end

                          # Determine task_number: use requested or find next available
                          existing_numbers = ActivityTask.where(activity_round_id: @round.id).select_map(:task_number)
                          requested_number = data['task_number']&.to_i || 1
                          task_number = if existing_numbers.include?(requested_number)
                                         ([1, 2] - existing_numbers).first || requested_number
                                       else
                                         requested_number
                                       end

                          next { success: false, error: 'Maximum 2 tasks per round' }.to_json if existing_numbers.length >= 2

                          task = ActivityTask.create(
                            activity_round_id: @round.id,
                            task_number: task_number,
                            description: data['description'] || '',
                            stat_set_a: stat_a,
                            stat_set_b: stat_b,
                            dc_reduction: data['dc_reduction'] || 3,
                            min_participants: data['min_participants'] || 1
                          )
                          { success: true, task: task.to_builder_json }.to_json
                        rescue StandardError => e
                          warn "[ActivityBuilder] Task creation failed: #{e.message}"
                          response.status = 422
                          { success: false, error: e.message }.to_json
                        end
                      end
                    end

                    r.on Integer do |tid|
                      task = ActivityTask[tid]
                      next { success: false, error: 'Task not found' }.to_json unless task && task.activity_round_id == @round.id

                      r.is do
                        r.put do
                          data = JSON.parse(request.body.read)
                          update_data = {}
                          update_data[:task_number] = data['task_number'] if data.key?('task_number')
                          update_data[:description] = data['description'] if data.key?('description')
                          update_data[:dc_reduction] = data['dc_reduction'] if data.key?('dc_reduction')
                          update_data[:min_participants] = data['min_participants'] if data.key?('min_participants')

                          if data.key?('stat_set_a')
                            sa = data['stat_set_a']
                            update_data[:stat_set_a] = sa.is_a?(Array) ? Sequel.pg_array(sa.map(&:to_i), :integer) : nil
                          end
                          if data.key?('stat_set_b')
                            sb = data['stat_set_b']
                            update_data[:stat_set_b] = sb.is_a?(Array) && sb.any? ? Sequel.pg_array(sb.map(&:to_i), :integer) : nil
                          end

                          task.update(update_data)
                          { success: true, task: task.to_builder_json }.to_json
                        end

                        r.delete do
                          task.destroy
                          { success: true }.to_json
                        end
                      end
                    end
                  end

                  # Action CRUD for this round
                  r.on 'actions' do
                    r.is do
                      r.get do
                        # Get actions scoped to this round:
                        # 1. Actions linked via round's actions array (non-task)
                        # 2. Actions linked via tasks belonging to this round
                        round_action_ids = @round.actions.to_a rescue []
                        task_ids = @round.tasks.map(&:id)
                        actions = if round_action_ids.any? && task_ids.any?
                                    ActivityAction.where(
                                      Sequel.|({ id: round_action_ids }, { task_id: task_ids })
                                    ).all
                                  elsif round_action_ids.any?
                                    ActivityAction.where(id: round_action_ids).all
                                  elsif task_ids.any?
                                    ActivityAction.where(task_id: task_ids).all
                                  else
                                    []
                                  end
                        {
                          success: true,
                          actions: actions.map do |a|
                            {
                              id: a.id, choice_string: a.choice_string,
                              output_string: a.output_string, fail_string: a.fail_string,
                              allowed_roles: a.allowed_roles,
                              skill_one: a.skill_one, skill_two: a.skill_two,
                              skill_three: a.skill_three,
                              task_id: (a[:task_id] rescue nil),
                              stat_set_label: (a[:stat_set_label] rescue nil),
                              risk_sides: (a[:risk_sides] rescue nil)
                            }
                          end
                        }.to_json
                      end

                      r.post do
                        data = JSON.parse(request.body.read)
                        attrs = {
                          activity_parent: @activity.id,
                          choice_string: data['choice_string'] || 'New Action',
                          output_string: data['output_string'] || '',
                          fail_string: data['fail_string'] || '',
                          allowed_roles: data['allowed_roles']
                        }
                        attrs[:task_id] = data['task_id'].to_i if data['task_id'] && !data['task_id'].to_s.empty?
                        attrs[:stat_set_label] = data['stat_set_label'] if data['stat_set_label']
                        attrs[:risk_sides] = data['risk_sides'].to_i if data['risk_sides'] && !data['risk_sides'].to_s.empty?

                        action = ActivityAction.create(attrs)
                        # Link action to round's actions array (for non-task rounds)
                        unless attrs[:task_id]
                          existing = @round.actions.to_a rescue []
                          @round.update(actions: Sequel.pg_array((existing + [action.id]).uniq, :integer))
                        end
                        {
                          success: true,
                          action: {
                            id: action.id, choice_string: action.choice_string,
                            output_string: action.output_string, fail_string: action.fail_string,
                            allowed_roles: action.allowed_roles,
                            task_id: (action[:task_id] rescue nil),
                            stat_set_label: (action[:stat_set_label] rescue nil),
                            risk_sides: (action[:risk_sides] rescue nil)
                          }
                        }.to_json
                      end
                    end

                    r.on Integer do |action_id|
                      action = ActivityAction[action_id]
                      next { success: false, error: 'Action not found' }.to_json unless action && action.activity_parent == @activity.id

                      r.is do
                        r.put do
                          data = JSON.parse(request.body.read)
                          update_data = {}
                          update_data[:choice_string] = data['choice_string'] if data.key?('choice_string')
                          update_data[:output_string] = data['output_string'] if data.key?('output_string')
                          update_data[:fail_string] = data['fail_string'] if data.key?('fail_string')
                          update_data[:allowed_roles] = data['allowed_roles'] if data.key?('allowed_roles')
                          update_data[:task_id] = data['task_id'] if data.key?('task_id')
                          update_data[:stat_set_label] = data['stat_set_label'] if data.key?('stat_set_label')
                          update_data[:risk_sides] = data['risk_sides'] if data.key?('risk_sides')
                          action.update(update_data)
                          {
                            success: true,
                            action: {
                              id: action.id, choice_string: action.choice_string,
                              output_string: action.output_string, fail_string: action.fail_string,
                              allowed_roles: action.allowed_roles,
                              task_id: (action[:task_id] rescue nil),
                              stat_set_label: (action[:stat_set_label] rescue nil),
                              risk_sides: (action[:risk_sides] rescue nil)
                            }
                          }.to_json
                        end

                        r.delete do
                          # Remove from round's actions array
                          existing = @round.actions.to_a rescue []
                          @round.update(actions: Sequel.pg_array((existing - [action.id]), :integer))
                          action.destroy
                          { success: true }.to_json
                        end
                      end
                    end
                  end
                end
              end

              r.get 'npcs' do
                npcs = NpcArchetype.order(:name).all
                {
                  success: true,
                  npcs: npcs.map do |n|
                    { id: n.id, name: n.name, race: n.race, character_class: n.character_class }
                  end
                }.to_json
              end

              r.get 'saved_locations' do
                character = current_character
                if character
                  saved = SavedLocation.for_character(character).all
                  {
                    success: true,
                    saved_locations: saved.map do |sl|
                      { id: sl.room_id, name: sl.name, room_name: sl.room&.name }
                    end
                  }.to_json
                else
                  { success: true, saved_locations: [] }.to_json
                end
              end

              r.get 'universes' do
                universes = Universe.order(:name).all
                {
                  success: true,
                  universes: universes.map { |u| { id: u.id, name: u.name, theme: u.theme } }
                }.to_json
              end

              r.get 'worlds' do
                worlds = World.order(:name).all
                {
                  success: true,
                  worlds: worlds.map { |w| { id: w.id, name: w.name } }
                }.to_json
              end

              r.get 'locations' do
                world_id = r.params['world_id']&.to_i
                locations = world_id ? Location.where(world_id: world_id).order(:name).all : []
                {
                  success: true,
                  locations: locations.map { |l| { id: l.id, name: l.name } }
                }.to_json
              end

              r.get 'rooms' do
                location_id = r.params['location_id']&.to_i
                if location_id
                  rooms = Room.where(location_id: location_id).order(:name).all
                else
                  rooms = Room.order(:name).limit(500).all
                end
                {
                  success: true,
                  rooms: rooms.map do |rm|
                    { id: rm.id, name: rm.name, room_type: rm.room_type, location_name: rm.location&.name }
                  end
                }.to_json
              end

              r.get 'patterns' do
                patterns = Pattern.tattoos.order(:description).limit(200).all
                {
                  success: true,
                  patterns: patterns.map do |p|
                    { id: p.id, description: p.description, price: p.price }
                  end
                }.to_json
              end

              r.get 'room_exits' do
                room_id = r.params['room_id']&.to_i
                exits = []
                if room_id
                  room = Room[room_id]
                  if room && defined?(RoomAdjacencyService)
                    adjacent = RoomAdjacencyService.adjacent_rooms(room) rescue {}
                    adjacent.each do |direction, rooms|
                      rooms.each do |adj_room|
                        exits << {
                          room_id: adj_room.id,
                          room_name: adj_room.rname || "Room #{adj_room.id}",
                          direction: direction.to_s.capitalize
                        }
                      end
                    end
                  end
                end
                { success: true, exits: exits }.to_json
              end

              r.get 'stat_blocks' do
                universe_id = r.params['universe_id']&.to_i
                if universe_id && universe_id > 0
                  blocks = StatBlock.where(universe_id: universe_id).order(:name).all
                  {
                    success: true,
                    stat_blocks: blocks.map { |sb| { id: sb.id, name: sb.name, block_type: sb.block_type, is_default: sb.is_default } }
                  }.to_json
                else
                  { success: true, stat_blocks: [] }.to_json
                end
              end

              r.get 'stats' do
                stat_block_id = r.params['stat_block_id']&.to_i
                universe_id = r.params['universe_id']&.to_i

                stat_block = if stat_block_id && stat_block_id > 0
                              StatBlock[stat_block_id]
                            elsif universe_id && universe_id > 0
                              StatBlock.first(universe_id: universe_id, is_default: true) ||
                                StatBlock.first(universe_id: universe_id)
                            end

                stats = stat_block ? stat_block.stats : []
                {
                  success: true,
                  stats: stats.map { |s| { id: s.id, name: s.name, abbreviation: s.abbreviation } }
                }.to_json
              end

              r.put 'clear_stat_selections' do
                round_ids = @activity.rounds.map(&:id)
                unless round_ids.empty?
                  ActivityRound.where(id: round_ids).update(
                    stat_set_a: nil,
                    stat_set_b: nil
                  )
                  ActivityTask.where(activity_round_id: round_ids).update(
                    stat_set_a: nil,
                    stat_set_b: nil
                  )
                end
                { success: true }.to_json
              end
            end
          end
        end

        # ====== HELP SYSTEM ADMIN ======
        r.on 'help' do
          # Help overview - list helpfiles and systems
          r.is do
            r.get do
              @helpfiles = Helpfile.order(:category, :command_name).all
              @help_systems = defined?(HelpSystem) ? HelpSystem.ordered : []
              @categories = @helpfiles.map(&:category).compact.uniq.sort
              view 'admin/help/index'
            end
          end

          # Trigger manual sync
          r.post 'sync' do
            count = Firefly::HelpManager.sync_commands!
            system_count = defined?(HelpSystem) ? HelpSystem.seed_defaults! : 0
            flash['success'] = "Synced #{count} commands and #{system_count} systems"
            r.redirect '/admin/help'
          end

          # Command helpfiles
          r.on 'commands' do
            r.on Integer do |id|
              @helpfile = Helpfile[id]
              unless @helpfile
                flash['error'] = 'Helpfile not found'
                r.redirect '/admin/help'
              end

              r.is do
                r.get do
                  view 'admin/help/edit_command'
                end

                r.post do
                  updates = {
                    summary: r.params['summary'],
                    description: r.params['description'],
                    staff_notes: r.params['staff_notes'],
                    is_lore: r.params['is_lore'] == 'true'
                  }

                  # Handle code references as JSON array
                  if r.params['code_references'] && !r.params['code_references'].empty?
                    begin
                      refs = JSON.parse(r.params['code_references'])
                      updates[:code_references] = Sequel.pg_jsonb(refs)
                    rescue JSON::ParserError
                      flash['error'] = 'Invalid JSON in code references'
                      r.redirect "/admin/help/commands/#{id}"
                    end
                  end

                  @helpfile.update(updates)
                  flash['success'] = 'Helpfile updated'
                  r.redirect '/admin/help'
                end
              end
            end
          end

          # Help systems
          r.on 'systems' do
            r.is do
              r.get do
                @help_systems = defined?(HelpSystem) ? HelpSystem.ordered : []
                view 'admin/help/systems'
              end

              r.post do
                unless defined?(HelpSystem)
                  flash['error'] = 'HelpSystem not available'
                  r.redirect '/admin/help/systems'
                end

                system = HelpSystem.create(
                  name: r.params['name'],
                  display_name: r.params['display_name'],
                  summary: r.params['summary'],
                  display_order: r.params['display_order']&.to_i || 100
                )
                flash['success'] = "System '#{system.name}' created"
                r.redirect "/admin/help/systems/#{system.id}"
              end
            end

            r.on Integer do |id|
              unless defined?(HelpSystem)
                flash['error'] = 'HelpSystem not available'
                r.redirect '/admin/help'
              end

              @help_system = HelpSystem[id]
              unless @help_system
                flash['error'] = 'Help system not found'
                r.redirect '/admin/help/systems'
              end

              r.is do
                r.get do
                  @all_commands = Helpfile.order(:command_name).select(:command_name).map(&:command_name)
                  view 'admin/help/edit_system'
                end

                r.post do
                  updates = {
                    name: r.params['name'],
                    display_name: r.params['display_name'],
                    summary: r.params['summary'],
                    description: r.params['description'],
                    staff_notes: r.params['staff_notes'],
                    display_order: r.params['display_order']&.to_i || 100,
                    # New documentation fields
                    player_guide: r.params['player_guide'],
                    staff_guide: r.params['staff_guide'],
                    quick_reference: r.params['quick_reference']
                  }

                  # Handle command names array
                  if r.params['command_names']
                    cmd_names = r.params['command_names'].split(',').map(&:strip).reject(&:empty?)
                    updates[:command_names] = cmd_names
                  end

                  # Handle related systems array
                  if r.params['related_systems']
                    related = r.params['related_systems'].split(',').map(&:strip).reject(&:empty?)
                    updates[:related_systems] = related
                  end

                  # Handle key files array
                  if r.params['key_files']
                    files = r.params['key_files'].split("\n").map(&:strip).reject(&:empty?)
                    updates[:key_files] = files
                  end

                  # Handle constants JSON
                  if r.params['constants_json'] && !r.params['constants_json'].strip.empty?
                    begin
                      constants = JSON.parse(r.params['constants_json'])
                      updates[:constants_json] = Sequel.pg_jsonb(constants)
                    rescue JSON::ParserError
                      flash['error'] = 'Invalid JSON in constants field'
                      r.redirect "/admin/help/systems/#{id}"
                    end
                  elsif r.params['constants_json']&.strip&.empty?
                    updates[:constants_json] = nil
                  end

                  @help_system.update(updates)
                  flash['success'] = 'Help system updated'
                  r.redirect '/admin/help/systems'
                end

                r.delete do
                  name = @help_system.name
                  @help_system.destroy
                  flash['success'] = "System '#{name}' deleted"
                  response['Content-Type'] = 'application/json'
                  { success: true, redirect: '/admin/help/systems' }.to_json
                end
              end
            end
          end
        end

        # ====== TRIGGERS ADMIN ======
        r.on 'triggers' do
          r.is do
            r.get do
              @triggers = Trigger.order(Sequel.desc(:created_at)).all
              view 'admin/triggers/index'
            end
          end

          r.get 'new' do
            @trigger = Trigger.new
            @activities = Activity.order(:name).all
            @npcs = Character.where(is_npc: true).order(:forename).all
            @archetypes = NpcArchetype.order(:name).all
            view 'admin/triggers/form'
          end

          r.post 'create' do
            @trigger = Trigger.new(trigger_params(r.params))
            @trigger.created_by_user_id = current_user.id

            if @trigger.valid?
              @trigger.save
              flash['success'] = 'Trigger created successfully'
              r.redirect '/admin/triggers'
            else
              flash['error'] = @trigger.errors.full_messages.join(', ')
              @activities = Activity.order(:name).all
              @npcs = Character.where(is_npc: true).order(:forename).all
              @archetypes = NpcArchetype.order(:name).all
              view 'admin/triggers/form'
            end
          end

          r.on Integer do |id|
            @trigger = Trigger[id]
            unless @trigger
              flash['error'] = 'Trigger not found'
              r.redirect '/admin/triggers'
            end

            r.is do
              r.get do
                @activities = Activity.order(:name).all
                @npcs = Character.where(is_npc: true).order(:forename).all
                @archetypes = NpcArchetype.order(:name).all
                view 'admin/triggers/form'
              end

              r.post do
                @trigger.set(trigger_params(r.params))
                if @trigger.valid?
                  @trigger.save
                  flash['success'] = 'Trigger updated successfully'
                  r.redirect '/admin/triggers'
                else
                  flash['error'] = @trigger.errors.full_messages.join(', ')
                  @activities = Activity.order(:name).all
                  @npcs = Character.where(is_npc: true).order(:forename).all
                  @archetypes = NpcArchetype.order(:name).all
                  view 'admin/triggers/form'
                end
              end
            end

            r.get 'activations' do
              @activations = @trigger.trigger_activations_dataset
                .order(Sequel.desc(:activated_at))
                .limit(100)
                .all
              view 'admin/triggers/activations'
            end

            r.post 'toggle' do
              @trigger.update(is_active: !@trigger.is_active)
              flash['success'] = "Trigger #{@trigger.is_active ? 'enabled' : 'disabled'}"
              r.redirect '/admin/triggers'
            end

            r.post 'delete' do
              @trigger.destroy
              flash['success'] = 'Trigger deleted'
              r.redirect '/admin/triggers'
            end
          end
        end

        # Global trigger activation log
        r.get 'trigger-activations' do
          @activations = TriggerActivation
            .order(Sequel.desc(:activated_at))
            .limit(200)
            .eager(:trigger, :source_character)
            .all
          view 'admin/triggers/all_activations'
        end

        # ====== TICKETS ADMIN ======
        r.on 'tickets' do
          r.is do
            r.get do
              status_filter = r.params['status'] || 'open'
              category_filter = r.params['category']

              @status_filter = status_filter
              @category_filter = category_filter

              tickets = Ticket.order(Sequel.desc(:created_at))
              tickets = tickets.where(status: status_filter) unless status_filter == 'all'
              tickets = tickets.where(category: category_filter) if category_filter && !category_filter.empty?
              @tickets = tickets.limit(100).all

              # Count by status for badges
              @open_count = Ticket.status_open.count
              @resolved_count = Ticket.resolved.count
              @closed_count = Ticket.closed.count

              view 'admin/tickets/index'
            end
          end

          r.on Integer do |id|
            @ticket = Ticket[id]
            unless @ticket
              flash['error'] = 'Ticket not found'
              r.redirect '/admin/tickets'
            end

            r.is do
              r.get do
                view 'admin/tickets/show'
              end
            end

            r.post 'resolve' do
              notes = r.params['notes']&.strip
              if notes.nil? || notes.empty?
                flash['error'] = 'Resolution notes are required'
                r.redirect "/admin/tickets/#{id}"
              end

              @ticket.resolve!(by_user: current_user, notes: notes)
              flash['success'] = "Ticket ##{id} resolved"
              r.redirect '/admin/tickets'
            end

            r.post 'close' do
              notes = r.params['notes']&.strip
              @ticket.close!(by_user: current_user, notes: notes)
              flash['success'] = "Ticket ##{id} closed"
              r.redirect '/admin/tickets'
            end

            r.post 'reopen' do
              @ticket.reopen!
              flash['success'] = "Ticket ##{id} reopened"
              r.redirect '/admin/tickets'
            end
          end
        end

        # ====== AUTOHELPER REQUESTS ADMIN ======
        r.on 'autohelper' do
          r.is do
            r.get do
              @tab = r.params['tab'] || 'recent'
              @requests = AutohelperRequest.recent(100)
              @top_queries = AutohelperRequest.top_queries(limit: 20)
              @unmatched = AutohelperRequest.unmatched_queries(limit: 20)
              @total_count = AutohelperRequest.count
              @success_count = AutohelperRequest.successful.count
              @ticket_count = AutohelperRequest.with_tickets.count
              view 'admin/autohelper/index'
            end
          end
        end

        # ====== NEWS ADMIN ======
        r.on 'news' do
          r.is do
            r.get do
              @news_type = r.params['type']
              @articles = StaffBulletin.order(Sequel.desc(:published_at))
              @articles = @articles.by_type(@news_type) if @news_type && !@news_type.empty?
              @articles = @articles.limit(50).all
              view 'admin/news/index'
            end
          end

          r.is 'new' do
            r.get do
              @article = StaffBulletin.new
              view 'admin/news/edit'
            end
            r.post do
              @article = StaffBulletin.create(
                news_type: r.params['news_type'],
                title: r.params['title'],
                content: r.params['content'],
                is_published: r.params['is_published'] == '1',
                published_at: Time.now,
                created_by_user_id: current_user.id
              )
              flash['success'] = 'News article created.'
              r.redirect '/admin/news'
            end
          end

          r.on Integer do |id|
            @article = StaffBulletin[id]
            unless @article
              flash['error'] = 'Article not found.'
              r.redirect '/admin/news'
            end

            r.is do
              r.get { view 'admin/news/edit' }
              r.post do
                @article.update(
                  news_type: r.params['news_type'],
                  title: r.params['title'],
                  content: r.params['content'],
                  is_published: r.params['is_published'] == '1'
                )
                flash['success'] = 'News article updated.'
                r.redirect '/admin/news'
              end
            end

            r.post 'delete' do
              @article.destroy
              flash['success'] = 'News article deleted.'
              r.redirect '/admin/news'
            end
          end
        end

        # ====== BROADCASTS ADMIN ======
        r.on 'broadcasts' do
          r.is do
            r.get do
              @broadcasts = StaffBroadcast.order(Sequel.desc(:created_at)).limit(50).all
              view 'admin/broadcasts/index'
            end
          end

          r.is 'new' do
            r.get { view 'admin/broadcasts/new' }
            r.post do
              broadcast = StaffBroadcast.create(
                created_by_user_id: current_user.id,
                content: r.params['content']
              )
              delivered_count = broadcast.deliver!
              flash['success'] = "Broadcast sent to #{delivered_count} online player#{'s' unless delivered_count == 1}."
              r.redirect '/admin/broadcasts'
            end
          end
        end

        # ====== CLUES ADMIN ======
        r.on 'clues' do
          r.is do
            r.get do
              @clues = Clue.order(:name).all
              view 'admin/clues/index'
            end
          end

          r.get 'new' do
            @clue = Clue.new
            @npcs = Character.where(is_npc: true).order(:forename).all
            view 'admin/clues/form'
          end

          r.post 'create' do
            @clue = Clue.new(clue_params(r.params))
            @clue.created_by_user_id = current_user.id

            if @clue.valid?
              @clue.save
              @clue.store_embedding!
              # Create NPC associations
              update_clue_npc_associations(@clue, r.params['npc_ids'] || [])
              flash['success'] = 'Clue created successfully'
              r.redirect '/admin/clues'
            else
              flash['error'] = @clue.errors.full_messages.join(', ')
              @npcs = Character.where(is_npc: true).order(:forename).all
              view 'admin/clues/form'
            end
          end

          r.on Integer do |id|
            @clue = Clue[id]
            unless @clue
              flash['error'] = 'Clue not found'
              r.redirect '/admin/clues'
            end

            r.is do
              r.get do
                @npcs = Character.where(is_npc: true).order(:forename).all
                view 'admin/clues/form'
              end

              r.post do
                @clue.set(clue_params(r.params))
                if @clue.valid?
                  @clue.save
                  @clue.store_embedding!
                  update_clue_npc_associations(@clue, r.params['npc_ids'] || [])
                  flash['success'] = 'Clue updated successfully'
                  r.redirect '/admin/clues'
                else
                  flash['error'] = @clue.errors.full_messages.join(', ')
                  @npcs = Character.where(is_npc: true).order(:forename).all
                  view 'admin/clues/form'
                end
              end
            end

            r.get 'shares' do
              @shares = @clue.clue_shares_dataset
                .order(Sequel.desc(:shared_at))
                .limit(100)
                .all
              view 'admin/clues/shares'
            end

            r.post 'delete' do
              @clue.destroy
              flash['success'] = 'Clue deleted'
              r.redirect '/admin/clues'
            end
          end
        end

        # ====== ARRANGED SCENES ADMIN ======
        r.on 'arranged_scenes' do
          r.is do
            r.get do
              filter = r.params['filter'] || 'all'
              @filter = filter
              @scenes = case filter
                        when 'pending'
                          ArrangedScene.where(status: 'pending').order(Sequel.desc(:created_at)).all
                        when 'active'
                          ArrangedScene.where(status: 'active').order(Sequel.desc(:started_at)).all
                        when 'completed'
                          ArrangedScene.where(status: 'completed').order(Sequel.desc(:ended_at)).limit(50).all
                        else
                          ArrangedScene.order(Sequel.desc(:created_at)).limit(100).all
                        end
              view 'admin/arranged_scenes/index'
            end
          end

          r.get 'new' do
            @scene = ArrangedScene.new
            @npcs = Character.where(is_npc: true).order(:forename).all
            @pcs = Character.where(is_npc: false).order(:forename).all
            @rooms = Room.order(:name).all
            view 'admin/arranged_scenes/form'
          end

          r.post 'create' do
            @scene = ArrangedScene.new(arranged_scene_params(r.params))
            @scene.created_by_id = current_user.default_character&.id || Character.first&.id

            if @scene.valid?
              @scene.save
              # Send invitation to PC
              ArrangedSceneService.send_invitation(@scene)
              flash['success'] = 'Arranged scene created successfully'
              r.redirect '/admin/arranged_scenes'
            else
              flash['error'] = @scene.errors.full_messages.join(', ')
              @npcs = Character.where(is_npc: true).order(:forename).all
              @pcs = Character.where(is_npc: false).order(:forename).all
              @rooms = Room.order(:name).all
              view 'admin/arranged_scenes/form'
            end
          end

          r.on Integer do |id|
            @scene = ArrangedScene[id]
            unless @scene
              flash['error'] = 'Arranged scene not found'
              r.redirect '/admin/arranged_scenes'
            end

            r.is do
              r.get do
                @npcs = Character.where(is_npc: true).order(:forename).all
                @pcs = Character.where(is_npc: false).order(:forename).all
                @rooms = Room.order(:name).all
                view 'admin/arranged_scenes/form'
              end

              r.post do
                @scene.set(arranged_scene_params(r.params))
                if @scene.valid?
                  @scene.save
                  flash['success'] = 'Arranged scene updated successfully'
                  r.redirect '/admin/arranged_scenes'
                else
                  flash['error'] = @scene.errors.full_messages.join(', ')
                  @npcs = Character.where(is_npc: true).order(:forename).all
                  @pcs = Character.where(is_npc: false).order(:forename).all
                  @rooms = Room.order(:name).all
                  view 'admin/arranged_scenes/form'
                end
              end
            end

            r.get 'show' do
              view 'admin/arranged_scenes/show'
            end

            r.post 'cancel' do
              if @scene.pending?
                result = ArrangedSceneService.cancel_scene(@scene)
                if result[:success]
                  flash['success'] = 'Scene cancelled'
                else
                  flash['error'] = result[:message]
                end
              else
                flash['error'] = 'Only pending scenes can be cancelled'
              end
              r.redirect '/admin/arranged_scenes'
            end

            r.post 'resend_invitation' do
              if @scene.pending?
                ArrangedSceneService.send_invitation(@scene)
                flash['success'] = 'Invitation resent'
              else
                flash['error'] = 'Can only resend invitations for pending scenes'
              end
              r.redirect "/admin/arranged_scenes/#{@scene.id}/show"
            end

            r.post 'delete' do
              @scene.destroy
              flash['success'] = 'Arranged scene deleted'
              r.redirect '/admin/arranged_scenes'
            end
          end
        end

        # ====== MONSTER TEMPLATES ADMIN ======
        r.on 'monsters' do
          r.is do
            r.get do
              @monster_templates = MonsterTemplate.order(:name).all
              view 'admin/monsters/index'
            end
          end

          r.get 'new' do
            @monster = MonsterTemplate.new
            @archetypes = NpcArchetype.order(:name).all
            view 'admin/monsters/form'
          end

          r.post 'create' do
            @monster = MonsterTemplate.new(monster_template_params(r.params))

            if @monster.valid?
              @monster.save
              flash['success'] = 'Monster template created successfully'
              r.redirect "/admin/monsters/#{@monster.id}"
            else
              flash['error'] = @monster.errors.full_messages.join(', ')
              @archetypes = NpcArchetype.order(:name).all
              view 'admin/monsters/form'
            end
          end

          r.on Integer do |id|
            @monster = MonsterTemplate[id]
            unless @monster
              flash['error'] = 'Monster template not found'
              r.redirect '/admin/monsters'
            end

            r.is do
              r.get do
                @archetypes = NpcArchetype.order(:name).all
                @segments = @monster.monster_segment_templates_dataset.order(:id).all
                view 'admin/monsters/form'
              end

              r.post do
                @monster.set(monster_template_params(r.params))
                if @monster.valid?
                  @monster.save
                  flash['success'] = 'Monster template updated successfully'
                  r.redirect "/admin/monsters/#{@monster.id}"
                else
                  flash['error'] = @monster.errors.full_messages.join(', ')
                  @archetypes = NpcArchetype.order(:name).all
                  @segments = @monster.monster_segment_templates_dataset.order(:id).all
                  view 'admin/monsters/form'
                end
              end
            end

            # Segment management
            r.on 'segments' do
              r.post 'create' do
                segment = MonsterSegmentTemplate.new(
                  monster_template_id: @monster.id,
                  name: r.params['name'],
                  segment_type: r.params['segment_type'],
                  hp_percent: (r.params['hp_percent'] || 20).to_i,
                  attacks_per_round: (r.params['attacks_per_round'] || 1).to_i,
                  damage_dice: r.params['damage_dice'] || '2d6',
                  attack_speed: (r.params['attack_speed'] || 5).to_i,
                  reach: (r.params['reach'] || 2).to_i,
                  is_weak_point: r.params['is_weak_point'] == 'on',
                  required_for_mobility: r.params['required_for_mobility'] == 'on',
                  hex_offset_x: (r.params['hex_offset_x'] || 0).to_i,
                  hex_offset_y: (r.params['hex_offset_y'] || 0).to_i
                )

                if segment.valid?
                  segment.save
                  flash['success'] = "Segment '#{segment.name}' created"
                else
                  flash['error'] = segment.errors.full_messages.join(', ')
                end
                r.redirect "/admin/monsters/#{@monster.id}"
              end

              r.on Integer do |segment_id|
                @segment = MonsterSegmentTemplate[segment_id]
                unless @segment && @segment.monster_template_id == @monster.id
                  flash['error'] = 'Segment not found'
                  r.redirect "/admin/monsters/#{@monster.id}"
                end

                r.post do
                  @segment.set(
                    name: r.params['name'],
                    segment_type: r.params['segment_type'],
                    hp_percent: (r.params['hp_percent'] || 20).to_i,
                    attacks_per_round: (r.params['attacks_per_round'] || 1).to_i,
                    damage_dice: r.params['damage_dice'] || '2d6',
                    attack_speed: (r.params['attack_speed'] || 5).to_i,
                    reach: (r.params['reach'] || 2).to_i,
                    is_weak_point: r.params['is_weak_point'] == 'on',
                    required_for_mobility: r.params['required_for_mobility'] == 'on',
                    hex_offset_x: (r.params['hex_offset_x'] || 0).to_i,
                    hex_offset_y: (r.params['hex_offset_y'] || 0).to_i
                  )

                  if @segment.valid?
                    @segment.save
                    flash['success'] = "Segment '#{@segment.name}' updated"
                  else
                    flash['error'] = @segment.errors.full_messages.join(', ')
                  end
                  r.redirect "/admin/monsters/#{@monster.id}"
                end

                r.post 'delete' do
                  name = @segment.name
                  @segment.destroy
                  flash['success'] = "Segment '#{name}' deleted"
                  r.redirect "/admin/monsters/#{@monster.id}"
                end
              end
            end

            r.post 'delete' do
              name = @monster.name
              @monster.destroy
              flash['success'] = "Monster template '#{name}' deleted"
              r.redirect '/admin/monsters'
            end
          end
        end

        # ====== MODERATION ======
        r.on 'moderation' do
          # Require moderation permission
          unless current_user&.can_moderate?
            flash['error'] = 'Moderation access required'
            r.redirect '/admin'
          end

          # IP Bans management
          r.on 'ip-bans' do
            r.is do
              r.get do
                @ip_bans = IpBan.order(Sequel.desc(:created_at)).limit(100).all
                view 'admin/moderation/ip_bans'
              end

              r.post do
                ip_pattern = r.params['ip_pattern']&.strip
                reason = r.params['reason']&.strip
                duration = r.params['duration']

                if ip_pattern.nil? || ip_pattern.empty?
                  flash['error'] = 'IP pattern is required'
                  r.redirect '/admin/moderation/ip-bans'
                end

                # Calculate expiration
                expires_at = case duration
                when 'permanent' then nil
                when '1h' then Time.now + 3600
                when '24h' then Time.now + 86400
                when '7d' then Time.now + (7 * 86400)
                when '30d' then Time.now + (30 * 86400)
                else nil
                end

                begin
                  IpBan.ban_ip!(ip_pattern, reason: reason, expires_at: expires_at, created_by: current_user)
                  flash['success'] = "IP ban created for #{ip_pattern}"
                rescue Sequel::UniqueConstraintViolation
                  flash['error'] = "An IP ban for #{ip_pattern} already exists"
                rescue => e
                  flash['error'] = "Failed to create ban: #{e.message}"
                end
                r.redirect '/admin/moderation/ip-bans'
              end
            end

            r.on Integer do |id|
              @ip_ban = IpBan[id]
              unless @ip_ban
                flash['error'] = 'IP ban not found'
                r.redirect '/admin/moderation/ip-bans'
              end

              r.post 'deactivate' do
                @ip_ban.deactivate!
                flash['success'] = "IP ban for #{@ip_ban.ip_pattern} deactivated"
                r.redirect '/admin/moderation/ip-bans'
              end

              r.post 'delete' do
                pattern = @ip_ban.ip_pattern
                @ip_ban.destroy
                flash['success'] = "IP ban for #{pattern} deleted"
                r.redirect '/admin/moderation/ip-bans'
              end
            end
          end

          # Connection logs
          r.on 'connections' do
            r.is do
              r.get do
                @logs = ConnectionLog.order(Sequel.desc(:created_at)).limit(200).all
                view 'admin/moderation/connections'
              end
            end

            r.on 'user' do
              r.on Integer do |user_id|
                @target_user = User[user_id]
                unless @target_user
                  flash['error'] = 'User not found'
                  r.redirect '/admin/moderation/connections'
                end

                r.get do
                  @logs = ConnectionLog.recent_for_user(user_id, limit: 100)
                  @known_ips = @target_user.known_ips
                  view 'admin/moderation/user_connections'
                end
              end
            end

            r.on 'ip' do
              r.on String do |ip|
                @ip_address = CGI.unescape(ip)

                r.get do
                  @logs = ConnectionLog.recent_for_ip(@ip_address, limit: 100)
                  @users = ConnectionLog.users_from_ip(@ip_address)
                  @is_banned = IpBan.banned?(@ip_address)
                  view 'admin/moderation/ip_connections'
                end
              end
            end
          end

          # Suspensions - user management
          r.on 'suspensions' do
            r.is do
              r.get do
                @suspended_users = User.exclude(suspended_at: nil).all
                view 'admin/moderation/suspensions'
              end
            end
          end

          # User suspend/unsuspend actions
          r.on 'users' do
            r.on Integer do |user_id|
              @target_user = User[user_id]
              unless @target_user
                flash['error'] = 'User not found'
                r.redirect '/admin/moderation/suspensions'
              end

              r.post 'suspend' do
                reason = r.params['reason']&.strip
                duration = r.params['duration']

                until_time = case duration
                when 'permanent' then nil
                when '1h' then Time.now + 3600
                when '24h' then Time.now + 86400
                when '7d' then Time.now + (7 * 86400)
                when '30d' then Time.now + (30 * 86400)
                else nil
                end

                @target_user.suspend!(reason: reason, until_time: until_time, by_user: current_user)
                flash['success'] = "#{@target_user.username} has been suspended"
                r.redirect request.referer || '/admin/moderation/suspensions'
              end

              r.post 'unsuspend' do
                @target_user.unsuspend!
                flash['success'] = "#{@target_user.username} has been unsuspended"
                r.redirect request.referer || '/admin/moderation/suspensions'
              end
            end
          end

          # Abuse Monitoring
          r.on 'abuse-monitoring' do
            r.is do
              r.get do
                @enabled = AbuseMonitoringService.enabled?
                @delay_mode = AbuseMonitoringService.delay_mode?
                @override_active = AbuseMonitoringService.override_active?
                @override = AbuseMonitoringOverride.current_active
                @pending_checks = AbuseCheck.pending.order(Sequel.desc(:created_at)).limit(20).all
                @recent_checks = AbuseCheck.order(Sequel.desc(:created_at)).limit(50).all
                @flagged_count = AbuseCheck.where(status: 'flagged').count
                @escalated_count = AbuseCheck.where(status: 'escalated').count
                @confirmed_count = AbuseCheck.where(status: 'confirmed').count
                view 'admin/moderation/abuse_monitoring'
              end
            end

            r.post 'toggle' do
              current = GameSetting.get('abuse_monitoring_enabled', 'false')
              new_value = current == 'true' ? 'false' : 'true'
              GameSetting.set('abuse_monitoring_enabled', new_value)
              flash['success'] = "Abuse monitoring #{new_value == 'true' ? 'enabled' : 'disabled'}"
              r.redirect '/admin/moderation/abuse-monitoring'
            end

            r.post 'toggle-delay' do
              current = GameSetting.get('abuse_monitoring_delay_mode', 'false')
              new_value = current == 'true' ? 'false' : 'true'
              GameSetting.set('abuse_monitoring_delay_mode', new_value)
              flash['success'] = "Delay mode #{new_value == 'true' ? 'enabled' : 'disabled'}"
              r.redirect '/admin/moderation/abuse-monitoring'
            end

            r.post 'override' do
              reason = r.params['reason']&.strip || 'Staff override'
              duration_hours = (r.params['duration'] || 1).to_i

              AbuseMonitoringService.activate_override!(
                staff_user: current_user,
                reason: reason,
                duration_hours: duration_hours
              )
              flash['success'] = "Abuse monitoring override activated for #{duration_hours} hour(s)"
              r.redirect '/admin/moderation/abuse-monitoring'
            end

            r.post 'cancel-override' do
              override = AbuseMonitoringOverride.current_active
              if override
                override.deactivate!
                flash['success'] = 'Override cancelled'
              else
                flash['error'] = 'No active override found'
              end
              r.redirect '/admin/moderation/abuse-monitoring'
            end
          end

          # Abuse Checks Review
          r.on 'abuse-checks' do
            r.is do
              r.get do
                status_filter = r.params['status']
                @checks = if status_filter && !status_filter.empty?
                  AbuseCheck.where(status: status_filter).order(Sequel.desc(:created_at)).limit(100).all
                else
                  AbuseCheck.order(Sequel.desc(:created_at)).limit(100).all
                end
                @status_filter = status_filter
                view 'admin/moderation/abuse_checks'
              end
            end

            r.on Integer do |check_id|
              @check = AbuseCheck[check_id]
              unless @check
                flash['error'] = 'Abuse check not found'
                r.redirect '/admin/moderation/abuse-checks'
              end

              r.get do
                @related_checks = AbuseCheck.where(user_id: @check.user_id)
                                            .exclude(id: @check.id)
                                            .order(Sequel.desc(:created_at))
                                            .limit(10).all
                view 'admin/moderation/abuse_check_detail'
              end

              r.post 'clear' do
                @check.update(status: 'cleared', reviewed_by_user_id: current_user.id, reviewed_at: Time.now)
                flash['success'] = 'Check marked as cleared'
                r.redirect '/admin/moderation/abuse-checks'
              end

              r.post 'confirm' do
                @check.update(status: 'confirmed', claude_confirmed: true, reviewed_by_user_id: current_user.id, reviewed_at: Time.now)
                # Execute moderation actions
                AutoModerationService.execute_moderation(@check)
                flash['success'] = 'Abuse confirmed and moderation actions executed'
                r.redirect '/admin/moderation/abuse-checks'
              end
            end
          end

          # Moderation Actions Log
          r.on 'moderation-actions' do
            r.is do
              r.get do
                @actions = ModerationAction.order(Sequel.desc(:created_at)).limit(100).all
                view 'admin/moderation/moderation_actions'
              end
            end

            r.on Integer do |action_id|
              @action = ModerationAction[action_id]
              unless @action
                flash['error'] = 'Moderation action not found'
                r.redirect '/admin/moderation/moderation-actions'
              end

              r.post 'reverse' do
                @action.reverse!(reversed_by: current_user, reason: r.params['reason'])
                flash['success'] = 'Moderation action reversed'
                r.redirect '/admin/moderation/moderation-actions'
              end
            end
          end

          # Moderation dashboard
          r.is do
            r.get do
              @recent_connections = ConnectionLog.order(Sequel.desc(:created_at)).limit(20).all
              @active_bans = IpBan.active_bans
              @suspended_users = User.exclude(suspended_at: nil).all
              @abuse_monitoring_enabled = AbuseMonitoringService.enabled?
              @pending_abuse_checks = AbuseCheck.pending.count
              @flagged_abuse_checks = AbuseCheck.where(status: 'flagged').count
              view 'admin/moderation/index'
            end
          end
        end

        # ====== PC REPUTATIONS ADMIN ======
        r.on 'reputations' do
          # List all PCs with reputation status
          r.is do
            r.get do
              @characters = Character.where(is_npc: false)
                                     .order(Sequel.desc(:reputation_updated_at))
                                     .limit(100)
                                     .all
              view 'admin/reputations/index'
            end
          end

          # Regenerate all reputations (background job)
          r.post 'regenerate_all' do
            Thread.new do
              ReputationService.regenerate_all!
            rescue StandardError => e
              warn "[Admin] Reputation regeneration failed: #{e.message}"
            end
            flash['info'] = 'Reputation regeneration started in background'
            r.redirect '/admin/reputations'
          end

          # Individual character reputation
          r.on Integer do |id|
            @character = Character[id]
            unless @character
              flash['error'] = 'Character not found'
              r.redirect '/admin/reputations'
            end

            r.is do
              r.get do
                # Get related world memories for context
                @memories = if defined?(WorldMemory)
                              WorldMemory.for_character(@character, limit: 20).all
                            else
                              []
                            end
                view 'admin/reputations/edit'
              end

              r.post do
                @character.update(
                  tier_1_reputation: r.params['tier_1_reputation'],
                  tier_2_reputation: r.params['tier_2_reputation'],
                  tier_3_reputation: r.params['tier_3_reputation'],
                  reputation_updated_at: Time.now
                )
                flash['success'] = 'Reputation updated'
                r.redirect "/admin/reputations/#{id}"
              end
            end

            # Regenerate single character reputation
            r.post 'regenerate' do
              result = ReputationService.regenerate_for_character!(@character)
              if result
                flash['success'] = 'Reputation regenerated from world memories'
              else
                flash['warning'] = 'No world memories found or generation failed'
              end
              r.redirect "/admin/reputations/#{id}"
            end
          end
        end

        # ====== NARRATIVE INTELLIGENCE ADMIN ======
        r.on 'narrative' do
          # Main narrative dashboard
          r.is do
            r.get do
              @filter = r.params['filter'] || 'all'
              @threads = NarrativeThread.dataset

              # Apply filter if specified
              @threads = case @filter
                         when 'active' then @threads.where(status: 'active')
                         when 'emerging' then @threads.where(status: 'emerging')
                         when 'climax' then @threads.where(status: 'climax')
                         when 'dormant' then @threads.where(status: 'dormant')
                         when 'resolved' then @threads.where(status: 'resolved')
                         else @threads
                         end

              @threads = @threads.order(Sequel.desc(:last_activity_at)).all
              
              # Calculate stats
              @stats = {
                active_threads: NarrativeThread.where(status: 'active').count,
                total_threads: NarrativeThread.count,
                total_entities: NarrativeEntity.count,
                unprocessed_memories: WorldMemory.exclude(id: NarrativeExtractionLog.where(success: true).select(:world_memory_id)).count,
                entity_types: NarrativeEntity.select_group(:entity_type)
                                             .select_append(Sequel.function(:count, Sequel.lit('*')).as(:count))
                                             .order(Sequel.desc(:count))
                                             .all
                                             .map { |e| { type: e.entity_type, count: e.count } }
              }
              
              view 'admin/narrative/index'
            end
          end
          
          # Narrative threads list/detail
          r.on 'threads' do
            r.is do
              r.get do
                @threads = NarrativeThread.order(Sequel.desc(:last_activity_at)).all
                view 'admin/narrative/threads'
              end
            end
            
            r.on Integer do |thread_id|
              @thread = NarrativeThread[thread_id]
              unless @thread
                flash['error'] = 'Thread not found'
                r.redirect '/admin/narrative'
              end
              
              r.is do
                r.get do
                  @entities = @thread.narrative_thread_entities
                  @memories = @thread.narrative_thread_memories
                  view 'admin/narrative/thread'
                end
              end
            end
          end
          
          # Narrative entities list
          r.on 'entities' do
            r.is do
              r.get do
                @entity_type = r.params['type']
                @entities = NarrativeEntityMemory.all
                
                if @entity_type && !@entity_type.empty?
                  @entities = @entities.where(entity_type: @entity_type)
                end
                
                @entities = @entities.order(Sequel.desc(:created_at)).all
                @entity_types = NarrativeEntityMemory.distinct(:entity_type)
                                                      .order(:entity_type)
                                                      .select(:entity_type)
                                                      .all
                                                      .map(&:entity_type)
                
                view 'admin/narrative/entities'
              end
            end
          end
        end
      end
    end
  end

  # ====== ROUTE HANDLER METHODS ======
  # These keep the route block clean while maintaining functionality

  def handle_message_ack(r)
    data = JSON.parse(request.body.read)
    char_instance = current_character_instance
    unless char_instance
      response.status = 401
      return { success: false, error: 'No character selected' }.to_json
    end

    REDIS_POOL.with do |redis|
      (data['acks'] || []).each do |msg_id|
        redis.sadd("msg_acks:#{char_instance.id}", msg_id)
        redis.srem("msg_pending:#{char_instance.id}", msg_id)
      end
      redis.set("msg_seq:#{char_instance.id}", data['last_sequence']) if data['last_sequence']
      redis.expire("msg_acks:#{char_instance.id}", 86400)
      redis.expire("msg_seq:#{char_instance.id}", 86400)
    end
    { success: true, acknowledged: (data['acks'] || []).length }.to_json
  rescue JSON::ParserError
    response.status = 400
    { success: false, error: 'Invalid JSON' }.to_json
  rescue => e
    warn "[MessageAck] Unexpected error: #{e.message}"
    response.status = 500
    { success: false, error: e.message }.to_json
  end

  def handle_message_resync(r)
    char_instance = current_character_instance
    unless char_instance
      response.status = 401
      return { success: false, error: 'No character selected' }.to_json
    end

    from_seq = r.params['from']&.to_i || 0
    to_seq = r.params['to']&.to_i || 0
    messages = []
    char_created_at = char_instance.created_at

    REDIS_POOL.with do |redis|
      redis.smembers("msg_pending:#{char_instance.id}").each do |msg_id|
        msg_data = redis.get("msg_data:#{msg_id}")
        if msg_data
          msg = JSON.parse(msg_data)
          # Skip messages from before this character existed
          next if msg['timestamp'] && Time.parse(msg['timestamp']) < char_created_at
          seq = msg['sequence_number'].to_i
          messages << msg if seq >= from_seq && seq <= to_seq
        end
      end
    end

    sorted = messages.sort_by { |m| m['sequence_number'] }
    personalize_character_refs(sorted, char_instance)
    personalize_message_content(sorted, char_instance)
    sorted.to_json
  rescue => e
    warn "[MessageResync] Unexpected error: #{e.message}"
    response.status = 500
    { success: false, error: e.message }.to_json
  end

  def handle_message_reconnect(r)
    data = JSON.parse(request.body.read)
    char_instance = current_character_instance
    unless char_instance
      response.status = 401
      return { success: false, error: 'No character selected' }.to_json
    end

    last_sequence = data['last_sequence']&.to_i || 0
    missed_messages = []
    char_created_at = char_instance.created_at

    REDIS_POOL.with do |redis|
      redis.smembers("msg_pending:#{char_instance.id}").each do |msg_id|
        msg_data = redis.get("msg_data:#{msg_id}")
        if msg_data
          msg = JSON.parse(msg_data)
          # Skip messages from before this character existed
          next if msg['timestamp'] && Time.parse(msg['timestamp']) < char_created_at
          missed_messages << msg if msg['sequence_number'].to_i > last_sequence
        end
      end
      redis.setex("connected:#{char_instance.id}", 300, Time.now.iso8601)
    end

    sorted_missed = missed_messages.sort_by { |m| m['sequence_number'] }
    personalize_character_refs(sorted_missed, char_instance)
    personalize_message_content(sorted_missed, char_instance)
    { success: true, missed_messages: sorted_missed, current_sequence: get_current_sequence_number }.to_json
  rescue JSON::ParserError
    response.status = 400
    { success: false, error: 'Invalid JSON' }.to_json
  rescue => e
    warn "[MessageReconnect] Unexpected error: #{e.class}: #{e.message}"
    response.status = 500
    { success: false, error: e.message }.to_json
  end

  def handle_message_seen(r)
    data = JSON.parse(request.body.read)
    char_instance = current_character_instance
    if char_instance
      REDIS_POOL.with do |redis|
        redis.sadd("seen_messages:#{char_instance.id}", data['message_id'])
        redis.hset("message_seen_at:#{data['message_id']}", char_instance.id, data['timestamp'])
        redis.expire("seen_messages:#{char_instance.id}", 86400)
        redis.expire("message_seen_at:#{data['message_id']}", 86400)
      end
      { success: true }.to_json
    else
      { success: false, error: 'No character selected' }.to_json
    end
  rescue JSON::ParserError
    response.status = 400
    { success: false, error: 'Invalid JSON' }.to_json
  rescue => e
    warn "[MessageReconnect] Unexpected error: #{e.message}"
    response.status = 500
    { success: false, error: 'Internal server error' }.to_json
  end

  def handle_address_cycle(r)
    char_instance = current_character_instance
    unless char_instance
      response.status = 401
      return { success: false, error: 'No character selected' }.to_json
    end

    data = JSON.parse(request.body.read) rescue {}
    direction = data['direction'].to_s

    unless %w[up down].include?(direction)
      return { success: false, error: 'Invalid direction' }.to_json
    end

    new_cursor = ChannelHistoryService.cycle(char_instance, direction)

    unless new_cursor
      return { success: true, status_bar: nil, cursor: char_instance.channel_history_cursor || 0 }.to_json
    end

    char_instance.refresh
    status_data = StatusBarService.new(char_instance).build_status_data

    {
      success: true,
      status_bar: status_data,
      cursor: new_cursor
    }.to_json
  rescue => e
    warn "[AddressHistory] Cycle failed: #{e.message}"
    response.status = 500
    { success: false, error: 'Internal server error' }.to_json
  end

  # Map RpLog log_type to webclient message_type for panel routing
  RPLOG_TYPE_MAP = {
    'say' => 'say',
    'emote' => 'emote',
    'think' => 'emote',
    'attempt' => 'emote',
    'whisper' => 'whisper',
    'private_message' => 'whisper',
    'movement' => 'action',
    'arrival' => 'action',
    'departure' => 'action',
    'room_desc' => 'room',
    'combat' => 'combat',
    'system' => 'system'
  }.freeze

  def handle_get_messages(r)
    char_instance = current_character_instance
    return [].to_json unless char_instance

    # Use per-recipient RpLog instead of the global Message table.
    # This ensures characters only see messages they actually witnessed.
    logs = RpLog.where(character_instance_id: char_instance.id)
               .order(Sequel.desc(:logged_at))
               .limit(50)
               .all
               .reverse # Chronological order

    # Fetch room characters for name personalization context
    room_characters = CharacterInstance.where(
      current_room_id: char_instance.current_room_id,
      online: true
    ).eager(:character).all

    logs.map do |log|
      api_hash = log.to_api_hash(char_instance, room_characters: room_characters)
      {
        id: log.id,
        content: api_hash[:html_content] || api_hash[:content],
        message_type: RPLOG_TYPE_MAP[log.log_type] || 'emote',
        created_at: log.display_timestamp&.iso8601,
        sequence_number: log.id
      }
    end.to_json
  end

  def handle_post_message(r)
    request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    data = JSON.parse(request.body.read)
    char_instance = current_character_instance
    unless char_instance
      return { success: false, error: 'No character selected' }.to_json
    end

    content = data['content'].to_s.strip
    message_type = data['type'].to_s.strip

    # Empty input (just hitting enter) re-shows any pending quickmenu
    if content.empty?
      pending = OutputHelper.get_pending_interactions(char_instance.id)
      quickmenu = pending.select { |i| i[:type] == 'quickmenu' }.max_by { |q| q[:created_at] || '' }
      if quickmenu
        return {
          success: true,
          message: { id: SecureRandom.uuid, character_id: char_instance.id,
                     content: nil, message_type: 'system',
                     created_at: Time.now.iso8601, sequence_number: get_next_sequence_number },
          type: :quickmenu,
          display_type: :quickmenu,
          output_category: :info,
          data: {
            interaction_id: quickmenu[:interaction_id],
            prompt: quickmenu[:prompt],
            options: quickmenu[:options]
          }
        }.to_json
      end
      return {
        success: true,
        message: { id: SecureRandom.uuid, character_id: char_instance.id,
                   content: '', message_type: 'system',
                   created_at: Time.now.iso8601, sequence_number: get_next_sequence_number }
      }.to_json
    end

    # Handle channel switching (user typed only a channel name on left panel)
    if message_type == 'switch_channel'
      # Extract channel name from "channel <name> " format
      channel_name = content.gsub(/\Achannel\s+/i, '').strip
      channel = ChannelBroadcastService.find_channel(channel_name)

      if channel
        # Update the character's current channel
        char_instance.update(
          current_channel_id: channel.id,
          last_channel_name: channel.name
        )
        ChannelHistoryService.push(char_instance)

        return {
          success: true,
          message: nil,
          status_bar: StatusBarService.new(char_instance).build_status_data
        }.to_json
      else
        return { success: false, error: "Channel not found: #{channel_name}" }.to_json
      end
    end

    # Auto-route OOC messages from left panel to OOC channel
    # Skip if content already starts with ooc/+ or looks like a slash command
    if message_type == 'ooc' && !content.match?(/\A(ooc|channel|reply|respond|msg|\+|\/|undo)\s*/i)
      content = "ooc #{content}"
    end

    # Pass source panel to commands (for undo to know which panel to target)
    request.env['firefly.source_panel'] = message_type == 'ooc' ? 'left' : 'right'

    # Try input interception first (quickmenu shortcuts, activity shortcuts)
    result = InputInterceptorService.intercept(char_instance, content)

    # If not intercepted, rewrite for context and use normal command processing
    unless result
      rewritten_content = InputInterceptorService.rewrite_for_context(char_instance, content)
      result = Commands::Base::Registry.execute_command(char_instance, rewritten_content, request_env: request.env)
    end

    if result[:success]
      created_at = result[:message_created_at] || Time.now
      message_id = result[:message_id] || SecureRandom.uuid
      sequence_number = get_next_sequence_number

      response_data = {
        success: true,
        message: {
          id: message_id,
          character_id: char_instance.id,
          character_name: result[:character_name] || char_instance.character.full_name,
          content: result[:message],
          message_type: result[:message_type] || 'system',
          created_at: created_at.iso8601,
          sequence_number: sequence_number
        },
        moved_to: result[:moved_to],
        moved_from: result[:moved_from],
        direction: result[:direction],
        menu: result[:menu],
        popup: result[:popup],
        delve_status: get_delve_status(char_instance)
      }

      # Include movement data for minimap animation
      if result[:moving]
        response_data[:moving] = true
        response_data[:duration] = result[:duration]
        response_data[:target_world_x] = result[:target_world_x]
        response_data[:target_world_y] = result[:target_world_y]
      end

      # Include structured data for rich rendering (observation panels)
      response_data[:type] = result[:type] if result[:type]
      response_data[:data] = result[:data] if result[:data]
      response_data[:structured] = result[:structured] if result[:structured]
      response_data[:display_type] = result[:display_type] if result[:display_type]
      response_data[:status_bar] = result[:status_bar] if result[:status_bar]
      response_data[:output_category] = result[:output_category] if result[:output_category]
      if result[:animation_data]
        response_data[:animation_data] = result[:animation_data]
        response_data[:roll_modifier] = result[:roll_modifier]
        response_data[:roll_total] = result[:roll_total]
      end

      # Include target_panel for routing - infer from display_type if not explicitly set
      if result[:target_panel]
        response_data[:target_panel] = result[:target_panel]
      elsif result[:structured]&.dig(:display_type)
        response_data[:target_panel] = Firefly::Panels.infer(display_type: result[:structured][:display_type])
      end

      # Detect quickmenus embedded in result[:data] (fight/spar commands)
      if result[:data].is_a?(Hash) && result[:data][:quickmenu].is_a?(Hash)
        qm = result[:data][:quickmenu]
        qm_id = SecureRandom.uuid
        qm_stored = {
          interaction_id: qm_id,
          type: 'quickmenu',
          prompt: qm[:prompt],
          options: qm[:options],
          context: qm[:context] || {},
          created_at: Time.now.iso8601
        }
        OutputHelper.store_agent_interaction(char_instance, qm_id, qm_stored)
        response_data[:quickmenu] = {
          interaction_id: qm_id,
          prompt: qm[:prompt],
          options: qm[:options]
        }
      end

      personalize_character_refs(response_data, char_instance)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - request_start) * 1000).round
      response_data[:server_time_ms] = elapsed_ms
      warn "[PostMessage] #{content.split.first} completed in #{elapsed_ms}ms" if elapsed_ms > 50
      response_data.to_json
    else
      error_response = { success: false, error: result[:error] || "Command failed", delve_status: get_delve_status(char_instance) }
      error_response[:target_panel] = result[:target_panel] if result[:target_panel]
      error_response[:output_category] = result[:output_category] if result[:output_category]
      error_response[:restore_input] = result[:restore_input] if result[:restore_input]
      error_response.to_json
    end
  rescue => e
    warn "[PostMessage] Unexpected error: #{e.message}"
    response.status = 500
    { success: false, error: "Failed to create message: #{e.message}" }.to_json
  end

  def handle_client_info(r)
    data = JSON.parse(request.body.read)
    char_instance = current_character_instance
    client_info = {
      timezone: data['timezone'], timezone_offset: data['timezone_offset'], locale: data['locale'],
      screen_width: data['screen_width'], screen_height: data['screen_height'],
      viewport_width: data['viewport_width'], viewport_height: data['viewport_height'],
      user_agent: data['user_agent'], platform: data['platform'], online: data['online'],
      connection_type: data['connection_type'], referrer: data['referrer'],
      ip_address: request.ip, last_seen: Time.now.iso8601
    }

    REDIS_POOL.with do |redis|
      key = char_instance ? "client_info:#{char_instance.id}" : "client_info:user:#{current_user.id}"
      redis.setex(key, 86400, JSON.generate(client_info))
      if char_instance
        redis.setex("connected:#{char_instance.id}", 300, Time.now.iso8601)
        redis.sadd("room_players:#{char_instance.current_room_id}", char_instance.id)
        redis.expire("room_players:#{char_instance.current_room_id}", 600)
      end
    end
    { success: true }.to_json
  rescue JSON::ParserError
    response.status = 400
    { success: false, error: 'Invalid JSON' }.to_json
  rescue => e
    warn "[ClientInfo] Unexpected error: #{e.class}: #{e.message}"
    response.status = 500
    { success: false, error: e.message }.to_json
  end

  def handle_typing_post(r)
    data = JSON.parse(request.body.read)
    char_instance = current_character_instance
    unless char_instance
      response.status = 401
      return { success: false, error: 'No character selected' }.to_json
    end

    typing_data = data['typing'] || data
    if typing_data.is_a?(Hash) && typing_data['status']
      status = typing_data['status']
      command_type = typing_data['command_type'] || 'other'
      duration_ms = typing_data['duration_ms'] || 0
    else
      status = data['status'] == 'start' ? 'typing' : 'idle'
      command_type = data['side'] == 'right' ? 'emote' : 'ooc'
      duration_ms = 0
    end

    room_id = char_instance.current_room_id
    room_typing = []

    REDIS_POOL.with do |redis|
      if status == 'idle'
        redis.del("typing:#{room_id}:#{char_instance.id}")
        redis.srem("room_typing:#{room_id}", char_instance.id)
      else
        typing_info = { character_id: char_instance.id, character_name: char_instance.character.full_name, status: status, command_type: command_type, duration_ms: duration_ms, started_at: Time.now.iso8601 }
        ttl = status == 'paused' ? 180 : 15
        redis.setex("typing:#{room_id}:#{char_instance.id}", ttl, JSON.generate(typing_info))
        redis.sadd("room_typing:#{room_id}", char_instance.id)
        redis.expire("room_typing:#{room_id}", 600)
      end

      redis.smembers("room_typing:#{room_id}").each do |cid|
        next if cid.to_i == char_instance.id
        info = redis.get("typing:#{room_id}:#{cid}")
        room_typing << JSON.parse(info) if info
      end
    end
    personalize_character_refs(room_typing, char_instance)

    { success: true, room_typing: room_typing }.to_json
  rescue JSON::ParserError
    response.status = 400
    { success: false, error: 'Invalid JSON' }.to_json
  rescue => e
    response.status = 500
    { success: false, error: e.message }.to_json
  end

  def handle_typing_get(r)
    char_instance = current_character_instance
    unless char_instance
      response.status = 401
      return { success: false, error: 'No character selected' }.to_json
    end

    room_typing = []
    REDIS_POOL.with do |redis|
      redis.smembers("room_typing:#{char_instance.current_room_id}").each do |cid|
        next if cid.to_i == char_instance.id
        info = redis.get("typing:#{char_instance.current_room_id}:#{cid}")
        room_typing << JSON.parse(info) if info
      end
    end
    personalize_character_refs(room_typing, char_instance)
    { success: true, room_typing: room_typing }.to_json
  end

  def handle_popup_response(r)
    data = JSON.parse(request.body.read)
    popup_response = data['popup_response']
    unless popup_response
      response.status = 400
      return { success: false, error: 'Missing popup_response' }.to_json
    end

    char_instance = current_character_instance
    unless char_instance
      response.status = 401
      return { success: false, error: 'No character selected' }.to_json
    end

    handler_result = nil
    REDIS_POOL.with do |redis|
      handler_key = "popup:#{char_instance.id}:#{popup_response['popup_id']}"
      handler_data = redis.get(handler_key)
      if handler_data
        handler_info = JSON.parse(handler_data)
        redis.del(handler_key)
        case handler_info['handler_type']
        when 'command'
          args = (popup_response['values'] || {}).map { |k, v| "#{k}=#{v}" }.join(' ')
          handler_result = Commands::Base::Registry.execute_command(char_instance, "#{handler_info['command']} #{args}".strip, request_env: request.env)
        when 'callback'
          redis.setex("popup_result:#{popup_response['popup_id']}", 300, JSON.generate({ values: popup_response['values'], character_id: char_instance.id, submitted_at: Time.now.iso8601 }))
          handler_result = { success: true, message: 'Form submitted successfully' }
        else
          handler_result = { success: true, message: 'Form received' }
        end
      else
        handler_result = { success: true, message: 'Form processed' }
      end
    end

    result = handler_result || { success: true }
    if result[:success] && result[:message]
      { success: true, message: { content: result[:message], message_type: result[:message_type] || 'system', created_at: Time.now.iso8601 } }.to_json
    else
      { success: result[:success] != false, error: result[:error] }.to_json
    end
  rescue JSON::ParserError
    response.status = 400
    { success: false, error: 'Invalid JSON' }.to_json
  rescue => e
    response.status = 500
    { success: false, error: e.message }.to_json
  end

  def handle_settings_post(r)
    data = JSON.parse(request.body.read)
    allowed = %w[llheight rlheight lfont rfont simpleui single_screen noback pichide notify_message notify_emote notification_sound emoteremind show_full autoscan ispeech noambi volume emailmissed emailscene]
    sanitized = allowed.each_with_object({}) { |k, h| h[k] = data[k] if data.key?(k) }

    if current_user
      current_user.update(settings: Sequel.pg_json(sanitized)) if User.columns.include?(:settings)
      REDIS_POOL.with { |redis| redis.set("settings:user:#{current_user.id}", JSON.generate(sanitized)) }
      { success: true, message: 'Settings saved' }.to_json
    else
      response.status = 401
      { success: false, error: 'Not authenticated' }.to_json
    end
  rescue JSON::ParserError
    response.status = 400
    { success: false, error: 'Invalid JSON' }.to_json
  rescue => e
    response.status = 500
    { success: false, error: e.message }.to_json
  end

  def handle_settings_get(r)
    if current_user
      settings = {}
      REDIS_POOL.with do |redis|
        cached = redis.get("settings:user:#{current_user.id}")
        settings = cached ? JSON.parse(cached) : (User.columns.include?(:settings) && current_user.settings ? current_user.settings.to_h : {})
      end
      { success: true, settings: settings }.to_json
    else
      response.status = 401
      { success: false, error: 'Not authenticated' }.to_json
    end
  end

  def handle_room_status(r)
    char_instance = current_character_instance
    unless char_instance
      response.status = 401
      return { success: false, error: 'No character selected' }.to_json
    end

    room_status = { typing: [], players: [] }
    REDIS_POOL.with do |redis|
      redis.smembers("room_typing:#{char_instance.current_room_id}").each do |cid|
        next if cid.to_i == char_instance.id
        info = redis.get("typing:#{char_instance.current_room_id}:#{cid}")
        room_status[:typing] << JSON.parse(info) if info
      end

      redis.smembers("room_players:#{char_instance.current_room_id}").each do |cid|
        if redis.get("connected:#{cid}")
          ci = CharacterInstance[cid.to_i]
          room_status[:players] << { id: ci.id, character_id: ci.id, name: ci.character.full_name, online: true } if ci && ci.id != char_instance.id
        end
      end
    end
    personalize_character_refs(room_status, char_instance)
    { success: true, room: room_status }.to_json
  end

  def handle_character_status(r)
    if current_character
      { id: current_character.id, name: current_character.name, room: current_character.room&.name, health: current_character.health || 100, energy: current_character.energy || 100 }.to_json
    else
      { error: 'No character selected' }.to_json
    end
  end

  def handle_profile_update(r)
    begin
      current_user.update(email: r.params['email'])
      flash['success'] = 'Profile updated successfully'
    rescue Sequel::ValidationFailed => e
      flash['error'] = e.message
    rescue Sequel::UniqueConstraintViolation
      flash['error'] = 'Email is already in use'
    end
    r.redirect '/settings'
  end

  def handle_password_update(r)
    unless current_user.authenticate(r.params['current_password'])
      flash['error'] = 'Current password is incorrect'
      r.redirect '/settings'
    end

    if r.params['new_password'] != r.params['confirm_password']
      flash['error'] = 'New passwords do not match'
      r.redirect '/settings'
    end

    if r.params['new_password'].length < 6
      flash['error'] = 'New password must be at least 6 characters'
      r.redirect '/settings'
    end

    begin
      current_user.set_password(r.params['new_password'])
      current_user.save
      flash['success'] = 'Password changed successfully'
    rescue => e
      flash['error'] = "Failed to change password: #{e.message}"
    end
    r.redirect '/settings'
  end

  def handle_webclient_settings(r)
    settings = {
      'llheight' => r.params['llheight'], 'rlheight' => r.params['rlheight'],
      'lfont' => r.params['lfont'], 'rfont' => r.params['rfont'],
      'simpleui' => r.params['simpleui'] == '1', 'single_screen' => r.params['single_screen'] == '1',
      'noback' => r.params['noback'] == '1', 'pichide' => r.params['pichide'] == '1',
      'notify_message' => r.params['notify_message'] == '1', 'notify_emote' => r.params['notify_emote'] == '1',
      'noambi' => r.params['noambi'] == '1', 'volume' => r.params['volume'].to_i,
      'emailmissed' => r.params['emailmissed'] == '1', 'emailscene' => r.params['emailscene'] == '1'
    }
    REDIS_POOL.with { |redis| redis.set("settings:user:#{current_user.id}", JSON.generate(settings)) }
    flash['success'] = 'Webclient settings saved'
    r.redirect '/settings'
  end

  def handle_account_delete(r)
    begin
      current_user.destroy
      session.clear
      flash['success'] = 'Your account has been deleted'
      r.redirect '/'
    rescue => e
      flash['error'] = "Failed to delete account: #{e.message}"
      r.redirect '/settings'
    end
  end

  def handle_character_create(r)
    birthdate = r.params['birthdate']
    age = nil
    if birthdate && !birthdate.empty?
      birth_date = Date.parse(birthdate)
      age = Date.today.year - birth_date.year
      age -= 1 if Date.today < Date.new(Date.today.year, birth_date.month, birth_date.day)
      if age < 18
        flash['error'] = 'Character must be at least 18 years old'
        r.redirect '/characters/new'
      end
    end

    picture_url = r.params['picture_url']
    if r.params['character_picture']&.dig(:tempfile)
      uploaded = r.params['character_picture']
      filename = "#{SecureRandom.hex(16)}_#{uploaded[:filename]}"
      upload_dir = File.join(__dir__, 'public', 'uploads', 'characters')
      FileUtils.mkdir_p(upload_dir)
      File.open(File.join(upload_dir, filename), 'wb') { |f| f.write(uploaded[:tempfile].read) }
      picture_url = "/uploads/characters/#{filename}"
    end

    attrs = {
      forename: r.params['forename'], surname: r.params['surname'], nickname: r.params['nickname'],
      short_desc: r.params['short_desc'], gender: r.params['gender'], age: age, birthdate: birthdate,
      user_id: current_user.id, active: true, is_npc: false, session_id: SecureRandom.hex(16),
      point_of_view: r.params['point_of_view'], recruited_by: r.params['recruited_by'],
      distinctive_color: r.params['distinctive_color'], picture_url: picture_url,
      height_ft: r.params['height_ft']&.to_i, height_in: r.params['height_in']&.to_i&.clamp(0, 11),
      height_cm: r.params['height_cm']&.to_i, ethnicity: r.params['ethnicity'],
      custom_ethnicity: r.params['custom_ethnicity'], body_type: r.params['body_type'],
      eye_color: r.params['eye_color'], custom_eye_color: r.params['custom_eye_color'],
      hair_color: r.params['hair_color'], custom_hair_color: r.params['custom_hair_color'],
      hair_style: r.params['hair_style'], custom_hair_style: r.params['custom_hair_style'],
      beard_color: r.params['beard_color'], custom_beard_color: r.params['custom_beard_color'],
      beard_style: r.params['beard_style'], custom_beard_style: r.params['custom_beard_style'],
      personality: r.params['personality'], backstory: r.params['backstory'], goals: r.params['goals']
    }

    # Parse stat allocations from the form
    parsed_allocations = StatAllocationService.parse_form_allocations(r.params)
    attrs[:stat_allocations] = Sequel.pg_jsonb_wrap(parsed_allocations) if parsed_allocations.any?

    begin
      character = Character.create(attrs)

      # Transfer descriptions from draft character (created via AJAX during form editing)
      draft = Character.where(user_id: current_user.id, is_draft: true).first
      if draft
        CharacterDefaultDescription.where(character_id: draft.id).update(character_id: character.id)
        draft.destroy
      end

      flash['success'] = "Character '#{character.full_name}' created successfully!"
      r.redirect "/characters/#{character.id}"
    rescue => e
      flash['error'] = "Failed to create character: #{e.message}"
      r.redirect '/characters/new'
    end
  end

  def handle_character_update(r, character_id)
    @character.update(name: r.params['name'], active: r.params['active'] == 'true')
    if r.params['attributes']
      @character.custom_attributes = r.params['attributes'].to_json
      @character.save
    end
    flash['success'] = 'Character updated successfully!'
    r.redirect "/characters/#{character_id}"
  end

  def handle_character_delete(r, character_id)
    character = Character.where(id: character_id, user_id: current_user.id).first
    unless character
      flash['error'] = 'Character not found'
      r.redirect '/dashboard'
    end

    # Soft delete - set deleted_at timestamp and mark as inactive
    character.update(deleted_at: Time.now, active: false)

    # Log the character out of all instances
    character.character_instances_dataset.update(online: false)

    flash['success'] = "#{character.full_name} has been deleted. You have 30 days to recover this character."
    r.redirect '/dashboard'
  end

  def handle_character_recover(r, character_id)
    character = Character.where(id: character_id, user_id: current_user.id).first
    unless character
      flash['error'] = 'Character not found'
      r.redirect '/dashboard'
    end

    unless character.deleted_at
      flash['warning'] = 'This character is not deleted'
      r.redirect "/characters/#{character_id}"
    end

    # Recover - clear deleted_at and mark as active
    character.update(deleted_at: nil, active: true)

    flash['success'] = "#{character.full_name} has been recovered!"
    r.redirect "/characters/#{character_id}"
  end

  def handle_character_export(r, character)
    # Export character content to ZIP
    export_data = ContentExportService.export_character(character)

    # Create ZIP package
    zip_result = ContentPackageService.create_package(
      export_data[:json],
      export_data[:images],
      "character_#{character.id}_export"
    )

    if zip_result[:error]
      flash['error'] = "Export failed: #{zip_result[:error]}"
      return r.redirect "/characters/#{character.id}"
    end

    # Serve the ZIP file
    response['Content-Type'] = 'application/zip'
    response['Content-Disposition'] = "attachment; filename=\"#{character.forename || 'character'}_export.zip\""

    if zip_result[:zip_data]
      zip_result[:zip_data]
    elsif zip_result[:path] && File.file?(zip_result[:path])
      File.binread(zip_result[:path])
    elsif zip_result[:path] && Dir.exist?(zip_result[:path])
      zip_directory_to_data(zip_result[:path])
    else
      flash['error'] = 'Export failed: invalid package output'
      r.redirect "/characters/#{character.id}"
    end
  end

  def handle_character_import(r, character)
    response['Content-Type'] = 'application/json'
    temp_dir = nil

    begin
      content_package = r.params['content_package']
      unless content_package && content_package[:tempfile]
        response.status = 400
        return { success: false, error: 'No content package provided' }.to_json
      end

      # Extract the ZIP package
      result = ContentPackageService.extract_package(content_package)
      if result[:error]
        response.status = 400
        return { success: false, error: result[:error] }.to_json
      end

      json_data = result[:json_data]
      image_files = result[:image_files]
      temp_dir = result[:temp_dir]

      # Validate export type
      unless json_data['export_type'] == 'character'
        response.status = 400
        return { success: false, error: 'Invalid package: expected character export' }.to_json
      end

      # Upload images and get URL mapping
      url_mapping = ContentPackageService.upload_images_from_package(
        temp_dir, image_files, 'character', character.id
      )

      # Import full character content (descriptions, items, outfits, base metadata)
      import_result = ContentImportService.import_character(
        character, json_data, url_mapping
      )

      if import_result[:success]
        imported = import_result[:imported] || {}
        {
          success: true,
          message: "Imported #{imported[:descriptions] || 0} descriptions, #{imported[:items] || 0} items, and #{imported[:outfits] || 0} outfits successfully."
        }.to_json
      else
        {
          success: false,
          error: "Import completed with errors: #{import_result[:errors].join(', ')}"
        }.to_json
      end
    rescue StandardError => e
      warn "[CharacterImport] Import failed for character #{character.id}: #{e.message}"
      response.status = 500
      { success: false, error: 'Import failed due to an internal server error' }.to_json
    ensure
      FileUtils.rm_rf(temp_dir) if temp_dir && Dir.exist?(temp_dir)
    end
  end

  def handle_property_export(r, room)
    export_data = ContentExportService.export_property(room)

    zip_result = ContentPackageService.create_package(
      export_data[:json],
      export_data[:images],
      "property_#{room.id}_export"
    )

    if zip_result[:error]
      flash['error'] = "Property export failed: #{zip_result[:error]}"
      return r.redirect "/properties/#{room.id}"
    end

    response['Content-Type'] = 'application/zip'
    response['Content-Disposition'] = "attachment; filename=\"#{room.name.to_s.gsub(/[^a-zA-Z0-9_-]/, '_')}_blueprint.zip\""

    if zip_result[:zip_data]
      zip_result[:zip_data]
    elsif zip_result[:path] && File.file?(zip_result[:path])
      File.binread(zip_result[:path])
    elsif zip_result[:path] && Dir.exist?(zip_result[:path])
      zip_directory_to_data(zip_result[:path])
    else
      flash['error'] = 'Property export failed: invalid package output'
      r.redirect "/properties/#{room.id}"
    end
  end

  def handle_property_import(r, room)
    temp_dir = nil

    begin
      content_package = r.params['content_package']
      unless content_package && content_package[:tempfile]
        flash['error'] = 'No content package provided'
        return r.redirect("/properties/#{room.id}/import")
      end

      result = ContentPackageService.extract_package(content_package)
      if result[:error]
        flash['error'] = result[:error]
        return r.redirect("/properties/#{room.id}/import")
      end

      json_data = result[:json_data]
      image_files = result[:image_files]
      temp_dir = result[:temp_dir]

      unless json_data['export_type'] == 'property'
        flash['error'] = 'Invalid package: expected property export'
        return r.redirect("/properties/#{room.id}/import")
      end

      url_mapping = ContentPackageService.upload_images_from_package(
        temp_dir, image_files, 'property', room.id
      )

      options = {
        replace_existing: r.params['replace_existing'] != '0',
        scale_places: r.params['scale_places'] == '1',
        import_battle_map: r.params['import_battle_map'] == '1',
        preserve_exits: r.params['preserve_exits'] == '1'
      }

      import_result = ContentImportService.import_property(room, json_data, url_mapping, options)
      if import_result[:success]
        imported = import_result[:imported] || {}
        flash['success'] = "Imported blueprint: #{imported[:places] || 0} places, #{imported[:decorations] || 0} decorations, #{imported[:features] || 0} features, #{imported[:hexes] || 0} hexes."
        r.redirect "/properties/#{room.id}"
      else
        flash['error'] = "Import failed: #{(import_result[:errors] || ['unknown error']).join(', ')}"
        r.redirect "/properties/#{room.id}/import"
      end
    rescue StandardError => e
      warn "[PropertyImport] Import failed for room #{room.id}: #{e.message}"
      flash['error'] = 'Import failed due to an internal server error'
      r.redirect "/properties/#{room.id}/import"
    ensure
      FileUtils.rm_rf(temp_dir) if temp_dir && Dir.exist?(temp_dir)
    end
  end

  def can_manage_property_room?(room)
    return false unless current_user && room
    return true if current_user.admin?

    owner = room.owner
    owner && owner.user_id == current_user.id
  end

  def zip_directory_to_data(dir)
    base = Pathname.new(dir)
    buffer = Zip::OutputStream.write_buffer do |zip|
      Dir.glob(File.join(dir, '**', '*')).sort.each do |path|
        next if File.directory?(path)

        relative = Pathname.new(path).relative_path_from(base).to_s
        zip.put_next_entry(relative)
        zip.write(File.binread(path))
      end
    end
    buffer.rewind
    buffer.read
  end

  # ====== DRAFT CHARACTER HELPER METHODS ======

  def handle_draft_character_create(r)
    # Clean up any existing drafts for this user (limit to 1 draft per user)
    Character.where(user_id: current_user.id, is_draft: true).delete

    # Create a new draft character with minimal required fields
    draft = Character.create(
      user_id: current_user.id,
      is_draft: true,
      active: false,
      is_npc: false,
      forename: 'Draft',
      surname: 'Character',
      session_id: SecureRandom.hex(16)
    )

    { success: true, draft_id: draft.id }.to_json
  rescue StandardError => e
    warn "[DraftCharacter] Failed to create draft: #{e.message}"
    response.status = 500
    { success: false, error: 'Failed to create draft character' }.to_json
  end

  def handle_draft_character_update(r, draft)
    begin
      data = JSON.parse(request.body.read)
    rescue JSON::ParserError
      response.status = 400
      return { success: false, error: 'Invalid JSON' }.to_json
    end

    # List of allowed fields that can be updated
    allowed_fields = %w[
      forename surname nickname short_desc gender birthdate
      point_of_view recruited_by discord_name discord_number
      distinctive_color height_ft height_in height_cm
      ethnicity custom_ethnicity body_type
      eye_color custom_eye_color
      hair_color custom_hair_color hair_style custom_hair_style
      beard_color custom_beard_color beard_style custom_beard_style
      personality backstory goals
      voice_type voice_speed voice_pitch
    ]

    updates = {}
    data.each do |key, value|
      next unless allowed_fields.include?(key)

      # Handle type conversions
      case key
      when 'height_ft', 'height_cm'
        updates[key.to_sym] = value.to_s.empty? ? nil : value.to_i
      when 'height_in'
        # Cap inches at 11 (0-11 valid range)
        inches = value.to_s.empty? ? nil : value.to_i
        updates[:height_in] = inches.nil? ? nil : inches.clamp(0, 11)
      when 'voice_speed', 'voice_pitch'
        updates[key.to_sym] = value.to_s.empty? ? nil : value.to_f
      else
        updates[key.to_sym] = value.to_s.empty? ? nil : value
      end
    end

    # Calculate age if birthdate provided
    if updates[:birthdate] && !updates[:birthdate].to_s.empty?
      begin
        birth_date = Date.parse(updates[:birthdate].to_s)
        age = Date.today.year - birth_date.year
        age -= 1 if Date.today < Date.new(Date.today.year, birth_date.month, birth_date.day)
        updates[:age] = age
      rescue Date::Error
        # Invalid date, ignore
      end
    end

    # Auto-calculate height_cm from feet/inches if not directly provided
    height_ft = updates[:height_ft] || draft.height_ft
    height_in = updates[:height_in] || draft.height_in
    if (height_ft || height_in) && !updates[:height_cm]
      total_inches = ((height_ft || 0) * 12) + (height_in || 0)
      updates[:height_cm] = (total_inches * 2.54).round if total_inches > 0
    end

    draft.update(updates) unless updates.empty?

    { success: true, updated_fields: updates.keys }.to_json
  rescue StandardError => e
    warn "[DraftCharacter] Failed to update draft: #{e.message}"
    response.status = 500
    { success: false, error: 'Failed to update draft character' }.to_json
  end

  def handle_draft_character_preview(draft)
    service = DraftCharacterPreviewService.new(draft)
    preview = service.build_display
    html = service.render_html

    {
      success: true,
      preview: preview,
      html: html
    }.to_json
  rescue StandardError => e
    warn "[DraftCharacter] Failed to generate preview: #{e.message}"
    response.status = 500
    { success: false, error: 'Failed to generate preview' }.to_json
  end

  def handle_draft_character_finalize(r, draft)
    begin
      data = JSON.parse(request.body.read)
    rescue JSON::ParserError
      data = {}
    end

    # Validate required fields before finalizing
    errors = []
    errors << 'First name is required' if draft.forename.nil? || draft.forename.strip.empty? || draft.forename == 'Draft'
    errors << 'Last name is required' if draft.surname.nil? || draft.surname.strip.empty? || draft.surname == 'Character'
    errors << 'Gender is required' if draft.gender.nil? || draft.gender.strip.empty?
    errors << 'Birthdate is required' if draft.birthdate.nil?

    # Validate age
    if draft.birthdate
      begin
        birth_date = Date.parse(draft.birthdate.to_s)
        age = Date.today.year - birth_date.year
        age -= 1 if Date.today < Date.new(Date.today.year, birth_date.month, birth_date.day)
        errors << 'Character must be at least 18 years old' if age < 18
      rescue Date::Error
        errors << 'Invalid birthdate'
      end
    end

    unless errors.empty?
      response.status = 400
      return { success: false, errors: errors }.to_json
    end

    # Convert draft to real character
    draft.update(is_draft: false, active: true)

    { success: true, character_id: draft.id, redirect_url: "/characters/#{draft.id}" }.to_json
  rescue StandardError => e
    warn "[DraftCharacter] Failed to finalize draft: #{e.message}"
    response.status = 500
    { success: false, error: 'Failed to finalize character' }.to_json
  end

  def handle_draft_character_import(r, draft)
    temp_dir = nil
    content_package = r.params['content_package']

    unless content_package && content_package[:tempfile]
      response.status = 400
      return { success: false, error: 'No content package provided' }.to_json
    end

    # Extract the ZIP package
    result = ContentPackageService.extract_package(content_package)
    if result[:error]
      response.status = 400
      return { success: false, error: result[:error] }.to_json
    end

    json_data = result[:json_data]
    image_files = result[:image_files]
    temp_dir = result[:temp_dir]

    # Validate export type
    unless json_data['export_type'] == 'character'
      response.status = 400
      return { success: false, error: 'Invalid package: expected character export' }.to_json
    end

    # Upload images and get URL mapping
    url_mapping = ContentPackageService.upload_images_from_package(
      temp_dir, image_files, 'character', draft.id
    )

    # Import descriptions using the service (draft has no instance for items/outfits)
    import_result = ContentImportService.import_descriptions_to_character(
      draft, json_data['descriptions'], url_mapping
    )
    descriptions_count = import_result[:count]
    errors = import_result[:errors]

    # Note: Items and outfits require a character instance (created after character creation)
    # They will need to be imported separately after the character is finalized
    items_count = json_data['items']&.length || 0
    outfits_count = json_data['outfits']&.length || 0
    skipped_note = if items_count > 0 || outfits_count > 0
                     " (#{items_count} items and #{outfits_count} outfits will be available after character creation)"
                   else
                     ''
                   end

    {
      success: true,
      descriptions_count: descriptions_count,
      items_count: 0, # Not imported during draft
      outfits_count: 0,
      errors: errors,
      message: "Imported #{descriptions_count} descriptions#{skipped_note}"
    }.to_json
  rescue StandardError => e
    warn "[DraftCharacter] Failed to import content: #{e.message}"
    response.status = 500
    { success: false, error: "Import failed: #{e.message}" }.to_json
  ensure
    FileUtils.rm_rf(temp_dir) if temp_dir && Dir.exist?(temp_dir)
  end

  # ====== TRIGGER/CLUE HELPER METHODS ======

  def trigger_params(params)
    result = {
      name: params['name'],
      description: params['description'],
      trigger_type: params['trigger_type'],
      is_active: params['is_active'] == '1' || params['is_active'] == 'true',
      condition_type: params['condition_type'],
      condition_value: params['condition_value'],
      llm_match_prompt: params['llm_match_prompt'],
      llm_match_threshold: params['llm_match_threshold']&.to_f,
      mission_event_type: params['mission_event_type'],
      activity_id: params['activity_id'].to_s.empty? ? nil : params['activity_id'].to_i,
      specific_round: params['specific_round'].to_s.empty? ? nil : params['specific_round'].to_i,
      specific_branch: params['specific_branch'].to_s.empty? ? nil : params['specific_branch'].to_i,
      npc_character_id: params['npc_character_id'].to_s.empty? ? nil : params['npc_character_id'].to_i,
      memory_publicity_filter: params['memory_publicity_filter'],
      min_importance: params['min_importance'].to_s.empty? ? nil : params['min_importance'].to_i,
      action_type: params['action_type'],
      code_block: params['code_block'],
      send_discord: params['send_discord'] == '1' || params['send_discord'] == 'true',
      send_email: params['send_email'] == '1' || params['send_email'] == 'true',
      email_recipients: params['email_recipients'],
      alert_message_template: params['alert_message_template']
    }

    # Handle archetype IDs array
    if params['npc_archetype_ids']
      ids = params['npc_archetype_ids'].is_a?(Array) ? params['npc_archetype_ids'] : [params['npc_archetype_ids']]
      result[:npc_archetype_ids] = Sequel.pg_jsonb(ids.map(&:to_i).reject(&:zero?))
    end

    # Handle character filters
    if params['required_character_ids']
      ids = params['required_character_ids'].is_a?(Array) ? params['required_character_ids'] : params['required_character_ids'].split(',')
      result[:character_filters] = Sequel.pg_jsonb({ 'required_character_ids' => ids.map(&:to_i).reject(&:zero?) })
    end

    result
  end

  def clue_params(params)
    {
      name: params['name'],
      content: params['content'],
      share_likelihood: params['share_likelihood']&.to_f || 0.5,
      share_context: params['share_context'],
      is_active: params['is_active'] == '1' || params['is_active'] == 'true',
      is_secret: params['is_secret'] == '1' || params['is_secret'] == 'true',
      min_trust_required: params['min_trust_required']&.to_f || 0.0,
      topic_keywords: Sequel.pg_jsonb((params['topic_keywords'] || '').split(',').map(&:strip).reject(&:empty?))
    }
  end

  def monster_template_params(params)
    {
      name: params['name'],
      monster_type: params['monster_type'] || 'colossus',
      npc_archetype_id: params['npc_archetype_id'].to_s.empty? ? nil : params['npc_archetype_id'].to_i,
      total_hp: (params['total_hp'] || 500).to_i,
      defeat_threshold_percent: (params['defeat_threshold_percent'] || 50).to_i,
      hex_width: (params['hex_width'] || 3).to_i,
      hex_height: (params['hex_height'] || 3).to_i,
      climb_distance: (params['climb_distance'] || 3).to_i,
      description: params['description'],
      image_url: params['image_url']
    }
  end

  def update_clue_npc_associations(clue, npc_ids)
    npc_ids = npc_ids.is_a?(Array) ? npc_ids : [npc_ids]
    npc_ids = npc_ids.map(&:to_i).reject(&:zero?)

    # Remove existing associations not in the new list
    existing_ids = clue.npc_ids
    (existing_ids - npc_ids).each do |id|
      npc = Character[id]
      clue.remove_npc!(npc) if npc
    end

    # Add new associations
    (npc_ids - existing_ids).each do |id|
      npc = Character[id]
      clue.add_npc!(npc) if npc
    end
  end

  def arranged_scene_params(params)
    result = {
      npc_character_id: params['npc_character_id']&.to_i,
      pc_character_id: params['pc_character_id']&.to_i,
      meeting_room_id: params['meeting_room_id']&.to_i,
      rp_room_id: params['rp_room_id']&.to_i,
      scene_name: params['scene_name'],
      npc_instructions: params['npc_instructions'],
      invitation_message: params['invitation_message']
    }

    # Handle optional datetime fields
    if params['available_from'] && !params['available_from'].empty?
      result[:available_from] = Time.parse(params['available_from'])
    end

    if params['expires_at'] && !params['expires_at'].empty?
      result[:expires_at] = Time.parse(params['expires_at'])
    end

    result
  end
end

# Start the server
if __FILE__ == $0
  require 'rack/handler/puma'
  Rack::Handler::Puma.run(FireflyApp, :Port => 3000, :Host => '0.0.0.0')
end
