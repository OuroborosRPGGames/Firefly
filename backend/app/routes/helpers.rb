# frozen_string_literal: true

# Shared route helpers for authentication, messaging, and game state
# Included in FireflyApp and available to all route modules
module RouteHelpers
  include CharacterLookupHelper
  # ====== VIEW HELPERS ======

  # Truncate a string to a maximum length, appending '...' if truncated.
  # Replaces Rails' String#truncate which doesn't exist in plain Ruby.
  # @param text [String, nil] Text to truncate
  # @param length [Integer] Maximum length (default 100)
  # @return [String]
  def truncate_text(text, length = 100)
    return '' if text.nil?
    text = text.to_s
    text.length > length ? text[0, length - 3] + '...' : text
  end

  # Render the opening wrapper for admin pages (sidebar + grid layout).
  # Use with admin_content_end to avoid duplicating the sidebar boilerplate.
  # @return [String] Opening HTML for admin layout
  def admin_content_start
    <<~HTML
      <div class="container mx-auto px-4 py-4">
        <div class="grid grid-cols-1 md:grid-cols-12 gap-4">
          <!-- Sidebar -->
          <div class="md:col-span-3 mb-4">
            <div class="card bg-base-200 shadow-lg">
              <div class="card-body p-0">
                <div class="flex items-center gap-2 px-4 py-3 border-b border-base-content/10">
                  <i class="bi bi-shield-lock text-primary"></i>
                  <h5 class="font-semibold text-base-content">Admin Console</h5>
                </div>
                #{partial 'admin/sidebar'}
              </div>
            </div>
          </div>

          <!-- Main Content -->
          <div class="md:col-span-9">
    HTML
  end

  # Render the closing wrapper for admin pages.
  # @return [String] Closing HTML for admin layout
  def admin_content_end
    <<~HTML
          </div>
        </div>
      </div>
    HTML
  end

  # Render a partial (ERB template without layout)
  # @param template [String] Template path (e.g., 'admin/sidebar')
  # @param locals [Hash] Local variables to pass to the partial
  # @return [String] Rendered HTML
  def partial(template, locals: {})
    # Convert 'admin/sidebar' to 'admin/_sidebar'
    dir = File.dirname(template)
    base = File.basename(template)
    partial_path = dir == '.' ? "_#{base}" : "#{dir}/_#{base}"
    render(partial_path, locals: locals)
  end

  # Activity Builder helper: get icon for activity type
  # @param atype [String] Activity type
  # @return [String] Bootstrap icon name
  def activity_icon(atype)
    case atype
    when 'mission', 'adventure' then 'compass'
    when 'competition' then 'trophy'
    when 'tcompetition' then 'people'
    when 'task' then 'check2-square'
    when 'elimination' then 'crosshair'
    when 'collaboration' then 'hand-thumbs-up'
    when 'encounter' then 'exclamation-triangle'
    when 'survival' then 'heart-pulse'
    when 'intersym', 'interasym' then 'chat-heart'
    else 'journal-text'
    end
  end

  # Activity Builder helper: get badge color for activity type
  # @param atype [String] Activity type
  # @return [String] Bootstrap color class
  def activity_badge_color(atype)
    case atype
    when 'mission', 'adventure' then 'primary'
    when 'competition', 'tcompetition' then 'warning'
    when 'task' then 'info'
    when 'elimination' then 'danger'
    when 'collaboration' then 'success'
    when 'encounter' then 'warning'
    when 'survival' then 'danger'
    when 'intersym', 'interasym' then 'pink'
    else 'secondary'
    end
  end

  # Activity Builder helper: get icon for round type
  # @param rt [String] Round type
  # @return [String] Bootstrap icon name
  def round_type_icon(rt)
    case rt
    when 'standard' then 'play-circle'
    when 'combat' then 'sword'
    when 'branch' then 'signpost-split'
    when 'reflex' then 'lightning'
    when 'group_check' then 'people'
    when 'free_roll' then 'dice-6'
    when 'persuade' then 'chat-heart'
    when 'rest' then 'cup-hot'
    when 'break' then 'pause-circle'
    else 'circle'
    end
  end

  # Activity Builder helper: get color for round type
  # @param rt [String] Round type
  # @return [String] Bootstrap color class
  def round_type_color(rt)
    case rt
    when 'standard' then 'primary'
    when 'combat' then 'danger'
    when 'branch' then 'purple'
    when 'reflex' then 'warning'
    when 'group_check' then 'success'
    when 'free_roll' then 'info'
    when 'persuade' then 'pink'
    when 'rest' then 'success'
    when 'break' then 'secondary'
    else 'light'
    end
  end

  # Format a byte count as a human-readable string (e.g. "1.4 GB")
  # @param bytes [Integer] Number of bytes
  # @return [String] Human-readable size
  def format_bytes(bytes)
    return '0 B' if bytes == 0

    units = %w[B KB MB GB TB]
    exp = (Math.log(bytes) / Math.log(1024)).to_i
    exp = units.length - 1 if exp >= units.length
    format('%.1f %s', bytes.to_f / (1024**exp), units[exp])
  end

  # ====== MESSAGE SYNC HELPERS ======

  # Get the next sequence number for message ordering
  def get_next_sequence_number
    REDIS_POOL.with do |redis|
      redis.incr("global_msg_sequence")
    end
  end

  # Get the current (last used) sequence number
  def get_current_sequence_number
    REDIS_POOL.with do |redis|
      redis.get("global_msg_sequence")&.to_i || 0
    end
  end

  # Store a message for the sync system (for redelivery on reconnect)
  def store_message_for_sync(char_instance, message)
    room_id = char_instance.current_room_id
    message_id = message[:id] || message['id']

    REDIS_POOL.with do |redis|
      # Store the message data
      redis.setex("msg_data:#{message_id}", 3600, JSON.generate(message)) # 1 hour TTL

      # Get all character instances in the room
      room_players = redis.smembers("room_players:#{room_id}")

      # Add to pending list for each player (except sender)
      room_players.each do |player_id|
        next if player_id.to_i == char_instance.id
        redis.sadd("msg_pending:#{player_id}", message_id)
        redis.expire("msg_pending:#{player_id}", 3600)
      end
    end
  end

  # Low-level Redis facade: enqueue a message to all connected players in a room.
  # Named to distinguish from Command#broadcast_to_room (high-level, personalized).
  def broadcast_to_room_redis(room_id, message, exclude_character_id = nil)
    sequence_number = get_next_sequence_number
    message[:sequence_number] = sequence_number
    message_id = message[:id] || SecureRandom.uuid
    message[:id] = message_id

    REDIS_POOL.with do |redis|
      # Store the message
      redis.setex("msg_data:#{message_id}", 3600, JSON.generate(message))

      # Get all connected players in the room
      room_players = redis.smembers("room_players:#{room_id}")

      room_players.each do |player_id|
        next if exclude_character_id && player_id.to_i == exclude_character_id
        # Add to their pending queue
        redis.sadd("msg_pending:#{player_id}", message_id)
        redis.expire("msg_pending:#{player_id}", 3600)
      end
    end

    message
  end

  # Register a popup handler for a character
  def register_popup_handler(char_instance, popup_id, handler_type, options = {})
    REDIS_POOL.with do |redis|
      handler_data = {
        handler_type: handler_type,
        command: options[:command],
        callback_id: options[:callback_id],
        created_at: Time.now.iso8601
      }
      redis.setex("popup:#{char_instance.id}:#{popup_id}", 600, JSON.generate(handler_data))
    end
    popup_id
  end

  # ====== AUTHENTICATION HELPERS ======

  def current_user
    return @current_user if defined?(@current_user)
    @current_user = if session['user_id']
      User[session['user_id']]
    end
  end

  def logged_in?
    !!current_user
  end

  def require_login!
    unless logged_in?
      flash['error'] = 'You must be logged in to access that page'
      request.redirect '/login'
    end
  end

  def current_character
    character_id = session['character_id']
    return unless character_id
    Character[character_id]
  end

  def current_character_instance
    return @current_character_instance if defined?(@current_character_instance)

    # Prefer explicit character_instance_id from request params (supports multi-tab)
    requested_id = request.params['character_instance_id']
    if requested_id && current_user
      ci = CharacterInstance[requested_id.to_i]
      if ci && ci.character&.user_id == current_user.id
        @current_character_instance = ci
        return @current_character_instance
      end
    end

    # Fall back to session-based lookup
    if session['character_instance_id']
      @current_character_instance = CharacterInstance[session['character_instance_id']]
      session.delete('character_instance_id') unless @current_character_instance
    end

    if !@current_character_instance && current_character
      ensured_instance = ensure_character_instance_for(current_character)
      if ensured_instance
        session['character_instance_id'] = ensured_instance.id
        @current_character_instance = ensured_instance
      end
    end

    @current_character_instance
  end

  # Get character instance from Bearer token (for API/MCP access)
  # Uses Redis caching to avoid N+1 queries on every request
  # Also enforces IP bans and account suspensions
  def character_instance_from_token
    return @token_character_instance if defined?(@token_character_instance)

    auth_header = request.env['HTTP_AUTHORIZATION']
    return nil unless auth_header.is_a?(String) && auth_header.start_with?('Bearer ')

    # Parse and validate token format (strip whitespace for robustness)
    token = auth_header.sub('Bearer ', '').strip
    return nil if token.empty?
    return nil unless token.match?(/\A[a-f0-9]{64}\z/)

    # Check IP ban before processing token
    if defined?(AccessControlService) && AccessControlService.ip_banned?(request.ip)
      ConnectionLog.log_connection(
        user_id: nil,
        ip_address: request.ip,
        connection_type: 'api_auth',
        outcome: 'banned_ip',
        user_agent: request.user_agent,
        failure_reason: 'IP banned'
      ) if defined?(ConnectionLog)
      @token_character_instance = nil
      return nil
    end

    # Try Redis cache first (keyed by token hash to avoid storing tokens)
    cache_key = "api_auth:#{Digest::SHA256.hexdigest(token)[0..15]}"
    cached = begin
      REDIS_POOL.with { |r| r.get(cache_key) }
    rescue StandardError => e
      warn "[RouteHelpers] Redis cache read failed: #{e.message}"
      nil
    end

    if cached
      data = JSON.parse(cached)
      # Verify user is still not suspended (cached data might be stale)
      user = User[data['user_id']]
      if user&.suspended?
        # Invalidate cache and reject
        begin
          REDIS_POOL.with { |r| r.del(cache_key) }
        rescue StandardError => e
          warn "[RouteHelpers] Redis cache delete failed: #{e.message}"
        end
        ConnectionLog.log_connection(
          user_id: user.id,
          ip_address: request.ip,
          connection_type: 'api_auth',
          outcome: 'suspended',
          user_agent: request.user_agent,
          failure_reason: user.suspension_reason
        ) if defined?(ConnectionLog)
        @token_character_instance = nil
        return nil
      end
      @token_character_instance = CharacterInstance[data['character_instance_id']]
      return @token_character_instance if @token_character_instance
    end

    # Cache miss - do full lookup
    user = User.find_by_api_token(token)
    return nil unless user

    # Block disabled test accounts
    if user.is_test_account && !GameSetting.boolean('test_account_enabled')
      @token_character_instance = nil
      return nil
    end

    # Check access control (suspension check)
    if defined?(AccessControlService)
      access = AccessControlService.check_access(
        user: user,
        ip_address: request.ip,
        connection_type: 'api_auth',
        user_agent: request.user_agent
      )
      unless access[:allowed]
        @token_character_instance = nil
        return nil
      end
    end

    # Get the user's active character
    character = user.player_characters.first
    return nil unless character

    # Get or create character instance
    @token_character_instance = ensure_character_instance_for(character)
    return nil unless @token_character_instance

    # Cache result for 1 hour (token hash -> character instance id)
    begin
      REDIS_POOL.with do |r|
        r.setex(cache_key, 3600, JSON.generate({
          user_id: user.id,
          character_id: character.id,
          character_instance_id: @token_character_instance.id
        }))
      end
    rescue StandardError => e
      warn "[RouteHelpers] Redis cache write failed: #{e.message}"
    end

    @token_character_instance
  end

  # Authenticate WebSocket connection
  # Supports query param (for initial connection) and session-based auth
  # @return [CharacterInstance, nil] The authenticated character instance
  def authenticate_websocket(r)
    # Try query param first (for WebSocket URL: /cable?character_instance=123)
    if r.params['character_instance']
      char_instance = CharacterInstance[r.params['character_instance'].to_i]
      # Verify character belongs to current user (if logged in via session)
      if char_instance && current_user && char_instance.character.user_id == current_user.id
        return char_instance
      end
      # For agent connections, require a Bearer token and verify it owns this instance
      token_instance = character_instance_from_token
      return char_instance if token_instance && token_instance.id == char_instance&.id
    end

    # Fall back to session-based auth
    if session && session['character_instance_id']
      return CharacterInstance[session['character_instance_id']]
    end

    nil
  end

  # ====== CHARACTER INSTANCE HELPERS ======

  def ensure_character_instance_for(character)
    return unless character

    # Prefer existing instances in primary reality
    default_reality = Reality.first(reality_type: 'primary') || Reality.first
    return unless default_reality

    existing = CharacterInstance.where(character_id: character.id, reality_id: default_reality.id).first ||
               CharacterInstance.where(character_id: character.id).first
    return existing if existing

    starting_room = find_starting_room
    return unless starting_room

    CharacterInstance.create(
      character_id: character.id,
      reality_id: default_reality.id,
      current_room_id: starting_room.id
    )
  end

  def find_starting_room
    Room.tutorial_spawn_room
  end

  # ====== WEBCLIENT CHARACTER SELECTION ======

  # Handle character selection from URL parameters for webclient/play
  def handle_character_selection_from_params(r)
    if r.params['character_instance']
      # Direct character instance selection
      character_instance = CharacterInstance.where(id: r.params['character_instance']).first
      if character_instance && character_instance.character.user_id == current_user.id
        session['character_id'] = character_instance.character_id
        session['character_instance_id'] = character_instance.id
        clear_cached_character_state
      end
    elsif r.params['character']
      # Character selection (use default instance)
      character = Character.where(id: r.params['character'], user_id: current_user.id).first
      if character
        session['character_id'] = character.id
        if character.default_instance
          session['character_instance_id'] = character.default_instance.id
        end
        clear_cached_character_state
      end
    end
  end

  def clear_cached_character_state
    remove_instance_variable(:@current_character) if defined?(@current_character)
    remove_instance_variable(:@current_character_instance) if defined?(@current_character_instance)
  end

  def ensure_character_for_play(r)
    unless current_character
      flash['error'] = 'Please select a character first'
      r.redirect '/dashboard'
    end

    @character = current_character
    @character_instance = current_character_instance

    # Ensure we have an instance; create/load default if needed
    if @character && !@character_instance
      new_instance = ensure_character_instance_for(@character)
      if new_instance
        session['character_instance_id'] = new_instance.id
        @current_character_instance = new_instance
        @character_instance = new_instance
      end
    end

    unless @character_instance
      flash['error'] = 'Unable to load your character instance'
      r.redirect '/dashboard'
    end

    # Bring character online and trigger login logging
    bring_character_online(@character_instance)

    @room = @character_instance&.current_room || Room.first
  end

  # Bring a character online and handle login logging
  #
  # @param character_instance [CharacterInstance] The character to bring online
  # @return [Array<Hash>] Backfill logs for the client
  def bring_character_online(character_instance)
    return [] unless character_instance

    was_offline = !character_instance.online

    # Update online status, activity, and start session tracking
    character_instance.update(
      online: true,
      last_activity: Time.now,
      session_start_at: was_offline ? Time.now : character_instance.session_start_at
    )

    # Ensure character is in at least the default channel (Newbie)
    Channel.ensure_default_membership(character_instance.character)

    # Only do login logging if character was previously offline
    if was_offline
      # Sync default descriptions to instance on login
      DescriptionCopyService.sync_on_login(
        character_instance.character,
        character_instance
      )

      # Create Wake breakpoint and get backfill logs
      @login_backfill = RpLoggingService.on_login(character_instance)

      # Check for unread news
      if defined?(StaffBulletin)
        @unread_news = StaffBulletin.unread_counts_for(character_instance.character.user)
      end

      # Deliver missed broadcasts
      if defined?(StaffBroadcast)
        missed_broadcasts = StaffBroadcast.undelivered_for(character_instance)
        missed_broadcasts.each do |broadcast|
          BroadcastService.to_character(character_instance, broadcast.formatted_message, type: :broadcast)
          StaffBroadcastDelivery.create(
            staff_broadcast_id: broadcast.id,
            character_instance_id: character_instance.id,
            login_delivered_at: Time.now
          )
        end
      end
      # Check if character is stranded in a defunct temporary room
      StrandedCharacterService.check_and_rescue!(character_instance)
    else
      @login_backfill = []
    end

    @login_backfill
  end

  # ====== ADMIN HELPERS ======

  # Check if current user is an admin
  def admin?
    current_user&.admin?
  end

  # Check if current user can access admin console
  # Grants access to full admins and users with the can_access_admin_console permission.
  def can_access_admin?
    current_user&.can_access_admin_console?
  end

  # Require admin console access
  def require_admin_access!
    require_login!
    unless can_access_admin?
      flash['error'] = 'You do not have permission to access the admin console'
      request.redirect '/dashboard'
    end
  end

  # Require full admin status (for dangerous operations)
  def require_admin!
    require_login!
    unless admin?
      flash['error'] = 'This action requires administrator privileges'
      request.redirect '/dashboard'
    end
  end

  # Check if user has specific permission
  def has_permission?(permission)
    current_user&.has_permission?(permission)
  end

  # Get game setting value (with caching)
  def game_setting(key)
    GameSetting.get(key)
  end

  # Get game name (with fallback)
  def game_name
    name = game_setting('game_name')
    (name && !name.empty?) ? name : 'Firefly'
  end

  # ====== TEST API HELPERS ======

  # Render a path for testing purposes
  # Returns { html: "..." } on success or { error: true, ... } on failure
  def render_path_for_test(path)
    # Map paths to templates and setup requirements
    case path
    # Admin pages
    when '/admin', '/admin/'
      setup_admin_dashboard_vars
      { html: view('admin/index') }
    when '/admin/settings'
      setup_admin_settings_vars
      { html: view('admin/settings/index') }
    when '/admin/users'
      setup_admin_users_vars
      { html: view('admin/users/index') }
    when %r{^/admin/users/(\d+)$}
      user_id = $1.to_i
      @target_user = User[user_id]
      return { error: true, error_type: 'NotFound', error_message: "User #{user_id} not found" } unless @target_user
      @permissions = begin
        Permission::PERMISSIONS
      rescue StandardError => e
        warn "[RouteHelpers] Failed to load permissions: #{e.message}"
        {}
      end
      @user_characters = @target_user.characters_dataset.order(:forename).all
      { html: view('admin/users/show') }

    # Admin stat blocks
    when '/admin/stat_blocks'
      @stat_blocks = StatBlock.eager(:stats, :universe).order(:name).all
      { html: view('admin/stat_blocks/index') }
    when '/admin/stat_blocks/new'
      @stat_block = StatBlock.new
      @universes = Universe.order(:name).all
      { html: view('admin/stat_blocks/edit') }
    when %r{^/admin/stat_blocks/(\d+)$}
      stat_block_id = $1.to_i
      @stat_block = StatBlock[stat_block_id]
      return { error: true, error_type: 'NotFound', error_message: "StatBlock #{stat_block_id} not found" } unless @stat_block
      @universes = Universe.order(:name).all
      { html: view('admin/stat_blocks/edit') }

    # Admin patterns
    when '/admin/patterns'
      @tab = 'clothing'
      @patterns = Pattern.clothing
                         .eager(:unified_object_type)
                         .order(:id)
                         .limit(100)
                         .all
      { html: view('admin/patterns/index') }
    when '/admin/patterns/new'
      @types = UnifiedObjectType.order(:category, :subcategory, :name).all
      @pattern = Pattern.new
      { html: view('admin/patterns/new') }
    when %r{^/admin/patterns/(\d+)$}
      pattern_id = $1.to_i
      @pattern = Pattern[pattern_id]
      return { error: true, error_type: 'NotFound', error_message: "Pattern #{pattern_id} not found" } unless @pattern
      @types = UnifiedObjectType.order(:category, :subcategory, :name).all
      { html: view('admin/patterns/edit') }

    # Admin vehicle types
    when '/admin/vehicle_types'
      @category = nil
      @vehicle_types = VehicleType.order(:category, :name).all
      @universes = Universe.order(:name).all rescue []
      { html: view('admin/vehicle_types/index') }
    when '/admin/vehicle_types/new'
      @vehicle_type = VehicleType.new
      @universes = Universe.order(:name).all rescue []
      { html: view('admin/vehicle_types/new') }
    when %r{^/admin/vehicle_types/(\d+)$}
      vehicle_type_id = $1.to_i
      @vehicle_type = VehicleType[vehicle_type_id]
      return { error: true, error_type: 'NotFound', error_message: "VehicleType #{vehicle_type_id} not found" } unless @vehicle_type
      @universes = Universe.order(:name).all rescue []
      { html: view('admin/vehicle_types/edit') }

    # Admin NPC archetypes
    when '/admin/npcs'
      @archetypes = if admin?
                      NpcArchetype.order(:name).all
                    else
                      NpcArchetype.where(created_by_id: current_user&.id).order(:name).all
                    end
      { html: view('admin/npcs/index') }
    when '/admin/npcs/new'
      @archetype = NpcArchetype.new
      @tab = 'general'
      { html: view('admin/npcs/edit') }
    when '/admin/npcs/locations'
      @locations = NpcSpawnLocation.for_user(current_user).eager(:room).all
      { html: view('admin/npcs/locations') }
    when %r{^/admin/npcs/(\d+)$}
      archetype_id = $1.to_i
      @archetype = NpcArchetype[archetype_id]
      return { error: true, error_type: 'NotFound', error_message: "NpcArchetype #{archetype_id} not found" } unless @archetype
      @tab = 'general'
      { html: view('admin/npcs/edit') }

    # Admin world builder
    when '/admin/world_builder'
      @worlds = World.eager(:universe).order(:name).all rescue []
      { html: view('admin/world_builder/index') }
    when %r{^/admin/world_builder/(\d+)$}
      world_id = $1.to_i
      @world = World[world_id]
      return { error: true, error_type: 'NotFound', error_message: "World #{world_id} not found" } unless @world
      { html: view('admin/world_builder/editor') }

    # Admin room builder
    when '/admin/room_builder'
      @rooms = Room.order(:name).limit(50).all rescue []
      @locations = Location.order(:name).all rescue []
      { html: view('admin/room_builder/index') }
    when %r{^/admin/room_builder/(\d+)$}
      room_id = $1.to_i
      @room = Room[room_id]
      return { error: true, error_type: 'NotFound', error_message: "Room #{room_id} not found" } unless @room
      { html: view('admin/room_builder/editor') }

    # Admin battle maps
    when '/admin/battle_maps'
      @rooms = Room.where(has_battle_map: true)
                   .or(room_type: %w[combat arena dojo gym])
                   .eager(:location)
                   .order(:name)
                   .all
      @cover_types = CoverObjectType.order(:category, :name).all
      { html: view('admin/battle_maps/index') }
    when %r{^/admin/battle_maps/(\d+)/edit$}
      room_id = $1.to_i
      @room = Room[room_id]
      return { error: true, error_type: 'NotFound', error_message: "Room #{room_id} not found" } unless @room
      @hexes = @room.room_hexes_dataset.order(:hex_y, :hex_x).all
      @cover_types = CoverObjectType.order(:category, :name).all
      @hex_types = RoomHex::HEX_TYPES
      @water_types = RoomHex::WATER_TYPES
      @surface_types = RoomHex::SURFACE_TYPES
      @hazard_types = RoomHex::HAZARD_TYPES rescue %w[fire acid electric poison]
      { html: view('admin/battle_maps/editor') }

    # Public pages (no auth required in real app, but we render with user context)
    when '/', '/home'
      { html: view('home/index') }
    when '/login'
      { html: view('auth/login') }
    when '/register'
      { html: view('auth/register') }

    # Info pages
    when '/info'
      { html: view('info/index') }
    when '/info/rules'
      { html: view('info/rules') }
    when '/info/getting_started', '/info/getting-started'
      { html: view('info/getting_started') }
    when '/info/terms'
      { html: view('info/terms') }
    when '/info/privacy'
      { html: view('info/privacy') }
    when '/info/contact'
      { html: view('info/contact') }

    # World pages
    when '/world'
      { html: view('world/index') }
    when '/world/lore'
      { html: view('world/lore') }
    when '/world/locations'
      { html: view('world/locations') }
    when '/world/factions'
      { html: view('world/factions') }

    # User pages (require login)
    when '/dashboard'
      @characters = current_user.characters_dataset.order(:forename).all
      { html: view('dashboard/index') }
    when '/settings'
      { html: view('settings/index') }
    when '/news'
      { html: view('news/index') }
    when '/characters/new'
      { html: view('characters/new') }

    # Game pages (require character)
    when '/play', '/webclient'
      setup_play_vars
      { html: view('webclient/index') }

    else
      { error: true, error_type: 'NotFound', error_message: "Unknown path: #{path}" }
    end
  rescue StandardError => e
    {
      error: true,
      error_type: e.class.name,
      error_message: e.message,
      error_file: e.backtrace&.first&.split(':')&.first,
      error_line: e.backtrace&.first&.split(':')&.[](1)&.to_i,
      backtrace: e.backtrace&.first(10)
    }
  end

  # Setup variables for admin dashboard
  def setup_admin_dashboard_vars
    @user_count = User.count
    @character_count = Character.count
    @room_count = Room.count
    @online_count = find_all_online_characters.count
    @ai_status = begin
      AIProviderService.status_summary
    rescue StandardError => e
      warn "[RouteHelpers] Failed to get AI provider status: #{e.message}"
      { any_available: false, providers: [] }
    end
  end

  # Setup variables for admin settings
  def setup_admin_settings_vars
    @settings = {
      general: {
        game_name: GameSetting.get('game_name'),
        world_type: GameSetting.get('world_type'),
        time_period: GameSetting.get('time_period'),
        spawn_location_id: GameSetting.integer('spawn_location_id'),
        spawn_room_id: GameSetting.integer('spawn_room_id'),
        test_account_enabled: GameSetting.boolean('test_account_enabled')
      },
      time: {
        clock_mode: GameSetting.get('clock_mode'),
        earth_timezone: GameSetting.get('earth_timezone'),
        fictional_time_ratio: GameSetting.get('fictional_time_ratio'),
        fictional_current_date: GameSetting.get('fictional_current_date')
      },
      weather: {
        weather_source: GameSetting.get('weather_source'),
        weather_api_key: GameSetting.get('weather_api_key').nil? ? nil : '••••••••'
      },
      ai: {
        anthropic_configured: !GameSetting.get('anthropic_api_key').to_s.empty?,
        openai_configured: !GameSetting.get('openai_api_key').to_s.empty?,
        google_gemini_configured: !GameSetting.get('google_gemini_api_key').to_s.empty?,
        openrouter_configured: !GameSetting.get('openrouter_api_key').to_s.empty?,
        voyage_configured: !GameSetting.get('voyage_api_key').to_s.empty?,
        replicate_configured: !GameSetting.get('replicate_api_key').to_s.empty?,
        ai_provider_order: GameSetting.get('ai_provider_order'),
        default_embedding_model: GameSetting.get('default_embedding_model') || 'voyage-3-large',
        # LLM Feature Toggles
        combat_llm_enhancement_enabled: GameSetting.boolean('combat_llm_enhancement_enabled'),
        activity_free_roll_enabled: GameSetting.boolean('activity_free_roll_enabled'),
        activity_persuade_enabled: GameSetting.boolean('activity_persuade_enabled'),
        ai_battle_maps_enabled: GameSetting.boolean('ai_battle_maps_enabled'),
        ai_weather_prose_enabled: GameSetting.boolean('ai_weather_prose_enabled'),
        abuse_monitoring_enabled: GameSetting.boolean('abuse_monitoring_enabled'),
        auto_gm_enabled: GameSetting.boolean('auto_gm_enabled'),
        autohelper_enabled: GameSetting.boolean('autohelper_enabled'),
        autohelper_ticket_threshold: GameSetting.get('autohelper_ticket_threshold') || 'notable'
      },
      delve: {
        barricade_stat: GameSetting.get('delve_barricade_stat') || 'STR',
        lockpick_stat: GameSetting.get('delve_lockpick_stat') || 'DEX',
        jump_stat: GameSetting.get('delve_jump_stat') || 'AGI',
        balance_stat: GameSetting.get('delve_balance_stat') || 'AGI',
        base_skill_dc: GameSetting.integer('delve_base_skill_dc') || 10,
        dc_per_level: GameSetting.integer('delve_dc_per_level') || 2,
        time_move: GameSetting.integer('delve_time_move') || 60,
        time_combat_round: GameSetting.integer('delve_time_combat_round') || 10,
        time_skill_check: GameSetting.integer('delve_time_skill_check') || 15,
        time_trap_listen: GameSetting.integer('delve_time_trap_listen') || 10,
        time_puzzle_attempt: GameSetting.integer('delve_time_puzzle_attempt') || 15,
        time_puzzle_help: GameSetting.integer('delve_time_puzzle_help') || GameSetting.integer('delve_time_puzzle_hint') || 30,
        time_easier: GameSetting.integer('delve_time_easier') || 30,
        time_recover: GameSetting.integer('delve_time_recover') || 300,
        time_focus: GameSetting.integer('delve_time_focus') || 60,
        time_study: GameSetting.integer('delve_time_study') || 60,
        base_treasure_min: GameSetting.integer('delve_base_treasure_min') || 5,
        base_treasure_max: GameSetting.integer('delve_base_treasure_max') || 10,
        monster_move_threshold: GameSetting.integer('delve_monster_move_threshold') || 10
      },
      email: {
        require_verification: GameSetting.boolean('email_require_verification'),
        sendgrid_configured: !GameSetting.get('sendgrid_api_key').to_s.empty?,
        from_address: GameSetting.get('email_from_address'),
        from_name: GameSetting.get('email_from_name') || game_name,
        verification_subject: GameSetting.get('email_verification_subject') || 'Verify your email address'
      },
      storage: {
        r2_enabled: GameSetting.boolean('storage_r2_enabled'),
        endpoint: GameSetting.get('storage_r2_endpoint'),
        bucket: GameSetting.get('storage_r2_bucket'),
        public_url: GameSetting.get('storage_r2_public_url'),
        has_access_key: !GameSetting.get('storage_r2_access_key').to_s.empty?,
        has_secret_key: !GameSetting.get('storage_r2_secret_key').to_s.empty?
      }
    }
    @ai_status = begin
      AIProviderService.status_summary
    rescue StandardError => e
      warn "[RouteHelpers] Failed to get AI provider status: #{e.message}"
      { any_available: false, providers: [] }
    end
    @available_stats = begin
      Stat.order(:name).all.map { |s| [s.abbreviation, s.name] }
    rescue StandardError => e
      warn "[RouteHelpers] Failed to load available stats: #{e.message}"
      []
    end
    @spawn_locations = begin
      Location.order(:name).all.map { |l| { id: l.id, name: l.display_name, is_city: l.is_city? } }
    rescue StandardError => e
      warn "[RouteHelpers] Failed to load spawn locations: #{e.message}"
      []
    end
    @spawn_rooms = begin
      loc_id = @settings[:general][:spawn_location_id]
      if loc_id
        Room.where(location_id: loc_id)
            .where(Sequel.lit("publicity IS NULL OR publicity = 'public'"))
            .order(:name).all
            .map { |r| { id: r.id, name: r.name, room_type: r.room_type } }
      else
        []
      end
    rescue StandardError => e
      warn "[RouteHelpers] Failed to load spawn rooms: #{e.message}"
      []
    end
  end

  # Setup variables for admin users list
  def setup_admin_users_vars
    @users = User.order(:username).all
  end

  # Setup variables for play/webclient
  def setup_play_vars
    @character = current_user.characters.first
    return unless @character

    @character_instance = @character.default_instance || CharacterInstance.where(character_id: @character.id).first
    @room = @character_instance&.current_room || Room.first
    @messages = []

    # Build initial room data for background image and room display on page load
    if @character_instance && @room
      begin
        service = RoomDisplayService.for(@room, @character_instance)
        @initial_room_data = service.build_display
      rescue StandardError => e
        warn "[setup_play_vars] Failed to build initial room data: #{e.message}"
        @initial_room_data = nil
      end
    end

    # Check if character is in an active delve (for HUD auto-activation)
    @in_delve = @character_instance &&
      DelveParticipant.where(character_instance_id: @character_instance.id, status: 'active').count > 0
  end

  # Extract title from HTML
  def extract_title(html)
    return nil unless html
    match = html.match(/<title[^>]*>([^<]+)<\/title>/i)
    match ? match[1].strip : nil
  end

  # ====== DELVE STATUS HELPERS ======

  # Get delve status for a character instance (for webclient display)
  # @param char_instance [CharacterInstance] The character to check
  # @return [Hash, nil] Delve status or nil if not in a delve
  def get_delve_status(char_instance)
    return nil unless char_instance

    participant = DelveParticipant
      .where(character_instance_id: char_instance.id, status: 'active')
      .first

    return nil unless participant

    {
      active: true,
      time_remaining: participant.time_remaining_seconds,
      delve_name: participant.delve&.name,
      current_level: participant.current_level,
      loot_collected: participant.loot_collected
    }
  rescue StandardError => e
    warn "[RoutesHelper] Failed to get delve status: #{e.message}"
    nil
  end

  # ====== ADMIN VIEW HELPERS ======

  # Render a stats table for the admin stat blocks edit page
  def render_stats_table(stats, stat_block)
    if stats.empty?
      return '<div class="card-body"><p class="text-muted mb-0">No stats in this category yet.</p></div>'
    end

    html = '<div class="table-responsive"><table class="table table-dark table-striped mb-0"><thead><tr>'
    html += '<th>Order</th><th>Name</th><th>Abbreviation</th><th>Description</th><th>Actions</th>'
    html += '</tr></thead><tbody>'

    stats.each do |stat|
      html += '<tr>'
      html += "<td>#{stat.display_order}</td>"
      html += "<td><strong>#{h(stat.name)}</strong></td>"
      html += "<td><code>#{h(stat.abbreviation)}</code></td>"
      desc_text = stat.description ? stat.description[0..39] + (stat.description.length > 40 ? '...' : '') : nil
      html += "<td>#{desc_text ? h(desc_text) : '<span class=\"text-muted\">-</span>'}</td>"
      html += '<td>'
      html += "<form action=\"/admin/stat_blocks/#{stat_block.id}/stats/#{stat.id}/delete\" method=\"post\" class=\"inline\" "
      html += "onsubmit=\"return confirm('Delete stat #{h(stat.name).gsub("'", '&#39;')}?');\">"
      html += csrf_tag
      html += "<button type=\"submit\" class=\"btn btn-sm btn-outline btn-error\" title=\"Delete #{h(stat.name)}\" aria-label=\"Delete #{h(stat.name)}\">"
      html += '<i class="bi bi-trash" aria-hidden="true"></i>'
      html += '</button></form>'
      html += '</td>'
      html += '</tr>'
    end

    html += '</tbody></table></div>'
    html
  end

  # NPC behavior pattern badge colors
  def behavior_badge_color(pattern)
    case pattern&.to_s&.downcase
    when 'friendly', 'ally'
      'success'
    when 'neutral'
      'secondary'
    when 'hostile', 'aggressive'
      'danger'
    when 'defensive'
      'warning'
    when 'cowardly', 'fearful'
      'info'
    when 'merchant', 'trader'
      'primary'
    else
      'secondary'
    end
  end

  # Parse NPC archetype parameters from form data
  # Handles the special npc_attacks array format
  # @param params [Hash] Form parameters
  # @return [Hash] Cleaned parameters for NpcArchetype
  def parse_npc_params(params)
    result = {
      name: params['name'],
      behavior_pattern: params['behavior_pattern'],
      race: params['race'],
      character_class: params['character_class'],
      dialogue_style: params['dialogue_style'],
      is_humanoid: params['is_humanoid'] == '1',

      # Appearance
      default_hair_desc: params['default_hair_desc'],
      default_eyes_desc: params['default_eyes_desc'],
      default_skin_tone: params['default_skin_tone'],
      default_body_desc: params['default_body_desc'],
      default_clothes_desc: params['default_clothes_desc'],
      default_creature_desc: params['default_creature_desc'],
      profile_image_url: params['profile_image_url'],

      # Spawning
      name_pattern: params['name_pattern'],
      spawn_health_range: params['spawn_health_range'],
      spawn_level_range: params['spawn_level_range'],

      # Combat stats
      combat_max_hp: params['combat_max_hp']&.to_i,
      combat_damage_bonus: params['combat_damage_bonus']&.to_i,
      combat_defense_bonus: params['combat_defense_bonus']&.to_i,
      combat_speed_modifier: params['combat_speed_modifier']&.to_i,
      combat_ai_profile: params['combat_ai_profile'],
      combat_ability_chance: params['combat_ability_chance']&.to_i,
      flee_health_percent: params['flee_health_percent']&.to_i,
      defensive_health_percent: params['defensive_health_percent']&.to_i,
      damage_dice_count: params['damage_dice_count']&.to_i,
      damage_dice_sides: params['damage_dice_sides']&.to_i
    }

    # Parse npc_attacks array from form params
    # Form params come in format: npc_attacks[0][name], npc_attacks[0][attack_type], etc.
    if params['npc_attacks'].is_a?(Hash)
      attacks = []
      params['npc_attacks'].each_value do |attack_data|
        next if StringHelper.blank?(attack_data['name'])

        attacks << {
          'name' => attack_data['name'].to_s.strip,
          'attack_type' => attack_data['attack_type'] || 'melee',
          'damage_dice' => attack_data['damage_dice'] || '2d6',
          'damage_type' => attack_data['damage_type'] || 'physical',
          'attack_speed' => (attack_data['attack_speed'] || 5).to_i,
          'range_hexes' => (attack_data['range_hexes'] || 1).to_i,
          'weapon_template' => attack_data['weapon_template'].to_s.strip.empty? ? nil : attack_data['weapon_template'],
          'hit_message' => attack_data['hit_message'].to_s.strip.empty? ? nil : attack_data['hit_message'],
          'miss_message' => attack_data['miss_message'].to_s.strip.empty? ? nil : attack_data['miss_message'],
          'critical_message' => attack_data['critical_message'].to_s.strip.empty? ? nil : attack_data['critical_message']
        }.compact
      end
      result[:npc_attacks] = attacks
    elsif !params.key?('npc_attacks')
      # Don't overwrite existing attacks if not in params (e.g., from other tabs)
      result.delete(:npc_attacks)
    else
      # Empty attacks array (all attacks removed)
      result[:npc_attacks] = []
    end

    # Parse combat_ability_ids array (Postgres integer array)
    if params['combat_ability_ids'].is_a?(Array)
      ability_ids = params['combat_ability_ids'].map(&:to_i).reject(&:zero?)
      result[:combat_ability_ids] = ability_ids.empty? ? nil : Sequel.pg_array(ability_ids)
    elsif !params.key?('combat_ability_ids')
      # Don't overwrite existing abilities if not in params (from other tabs)
      result.delete(:combat_ability_ids)
    else
      # Empty abilities (all removed)
      result[:combat_ability_ids] = nil
    end

    # Parse combat_ability_chances hash (JSONB)
    if params['combat_ability_chances'].is_a?(Hash)
      chances = {}
      params['combat_ability_chances'].each do |ability_id, chance|
        next if chance.to_s.strip.empty?

        chances[ability_id.to_s] = chance.to_i
      end
      result[:combat_ability_chances] = chances.empty? ? nil : chances
    elsif !params.key?('combat_ability_chances')
      # Don't overwrite existing chances if not in params
      result.delete(:combat_ability_chances)
    end

    # Leadership settings (optional - only update when fields are submitted)
    result[:is_leadable] = params['is_leadable'] == '1' if params.key?('is_leadable')
    result[:is_summonable] = params['is_summonable'] == '1' if params.key?('is_summonable')
    if params.key?('summon_range') && !params['summon_range'].to_s.strip.empty?
      result[:summon_range] = params['summon_range'].to_s.strip
    end

    # Animation settings (optional - only update when fields are submitted)
    if params.key?('animation_level') && !params['animation_level'].to_s.strip.empty?
      result[:animation_level] = params['animation_level'].to_s.strip
    end
    if params.key?('animation_primary_model') && !params['animation_primary_model'].to_s.strip.empty?
      result[:animation_primary_model] = params['animation_primary_model'].to_s.strip
    end
    if params.key?('animation_first_emote_model') && !params['animation_first_emote_model'].to_s.strip.empty?
      result[:animation_first_emote_model] = params['animation_first_emote_model'].to_s.strip
    end
    if params.key?('animation_memory_model') && !params['animation_memory_model'].to_s.strip.empty?
      result[:animation_memory_model] = params['animation_memory_model'].to_s.strip
    end
    if params.key?('animation_personality_prompt')
      result[:animation_personality_prompt] = params['animation_personality_prompt'].to_s.strip
    end
    if params.key?('animation_cooldown_seconds') && !params['animation_cooldown_seconds'].to_s.strip.empty?
      result[:animation_cooldown_seconds] = params['animation_cooldown_seconds'].to_i
    end
    result[:generate_outfit_on_spawn] = params['generate_outfit_on_spawn'] == '1' if params.key?('generate_outfit_on_spawn')
    result[:generate_status_on_spawn] = params['generate_status_on_spawn'] == '1' if params.key?('generate_status_on_spawn')
    if params.key?('animation_fallback_models')
      fallback_models = params['animation_fallback_models']
                           .to_s
                           .split(',')
                           .map(&:strip)
                           .reject(&:empty?)
      result[:animation_fallback_models] = fallback_models
    end

    # Voice/style anchors for NPC animation prompting
    if params.key?('example_dialogue')
      result[:example_dialogue] = params['example_dialogue'].to_s.strip
    end
    if params.key?('speech_quirks')
      result[:speech_quirks] = params['speech_quirks'].to_s.strip
    end
    if params.key?('vocabulary_notes')
      result[:vocabulary_notes] = params['vocabulary_notes'].to_s.strip
    end
    if params.key?('character_flaws')
      result[:character_flaws] = params['character_flaws'].to_s.strip
    end

    # Remove nil values
    result.compact
  end

  # Parse Ability parameters from form data
  # Handles JSONB fields for costs, status effects, etc.
  # @param params [Hash] Form parameters
  # @return [Hash] Cleaned parameters for Ability
  def parse_ability_params(params)
    result = {
      name: params['name'],
      ability_type: params['ability_type'],
      action_type: params['action_type'],
      description: params['description'],
      user_type: params['user_type'],
      universe_id: params['universe_id'].to_s.empty? ? nil : params['universe_id'].to_i,
      icon_name: params['icon_name'].to_s.strip.empty? ? nil : params['icon_name'],
      is_active: params.key?('is_active') ? params['is_active'] != '0' : nil,

      # Targeting
      target_type: params['target_type'],
      aoe_shape: params['aoe_shape'],
      aoe_radius: params['aoe_radius'].to_s.empty? ? nil : params['aoe_radius'].to_i,
      aoe_length: params['aoe_length'].to_s.empty? ? nil : params['aoe_length'].to_i,
      aoe_angle: params['aoe_angle'].to_s.empty? ? nil : params['aoe_angle'].to_i,
      aoe_hits_allies: params.key?('aoe_hits_allies') ? params['aoe_hits_allies'] == '1' : nil,

      # Timing
      activation_segment: params['activation_segment'].to_s.empty? ? nil : params['activation_segment'].to_i,
      segment_variance: params['segment_variance'].to_s.empty? ? nil : params['segment_variance'].to_i,
      cooldown_seconds: params['cooldown_seconds'].to_s.empty? ? nil : params['cooldown_seconds'].to_i,

      # Damage
      base_damage_dice: params['base_damage_dice'].to_s.strip.empty? ? nil : params['base_damage_dice'],
      damage_stat: params['damage_stat'].to_s.strip.empty? ? nil : params['damage_stat'],
      damage_type: params['damage_type'],
      damage_modifier: params['damage_modifier'].to_s.empty? ? nil : params['damage_modifier'].to_i,
      damage_multiplier: params['damage_multiplier'].to_s.empty? ? nil : params['damage_multiplier'].to_f,
      damage_modifier_dice: params['damage_modifier_dice'].to_s.strip.empty? ? nil : params['damage_modifier_dice'],
      is_healing: params.key?('is_healing') ? params['is_healing'] == '1' : nil,
      bypasses_resistances: params.key?('bypasses_resistances') ? params['bypasses_resistances'] == '1' : nil,

      # Advanced
      execute_threshold: params['execute_threshold'].to_s.empty? ? nil : params['execute_threshold'].to_i,
      lifesteal_max: params['lifesteal_max'].to_s.empty? ? nil : params['lifesteal_max'].to_i,
      applies_prone: params.key?('applies_prone') ? params['applies_prone'] == '1' : nil
    }

    # Costs JSONB
    result[:costs] = build_ability_costs_jsonb(params)

    # Status effects JSONB array
    result[:applied_status_effects] = build_ability_status_effects_jsonb(params)

    # Split damage types JSONB array
    result[:damage_types] = build_ability_damage_types_jsonb(params)

    # Conditional damage JSONB array
    result[:conditional_damage] = build_ability_conditional_damage_jsonb(params)

    # Chain config JSONB
    result[:chain_config] = build_ability_chain_config_jsonb(params)

    # Forced movement JSONB
    result[:forced_movement] = build_ability_forced_movement_jsonb(params)

    # Execute effect JSONB
    result[:execute_effect] = build_ability_execute_effect_jsonb(params)

    # Combo condition JSONB
    result[:combo_condition] = build_ability_combo_condition_jsonb(params)

    # Narrative - parse textarea to arrays
    result[:cast_verbs] = parse_textarea_to_jsonb_array(params['cast_verbs'])
    result[:hit_verbs] = parse_textarea_to_jsonb_array(params['hit_verbs'])
    result[:aoe_descriptions] = parse_textarea_to_jsonb_array(params['aoe_descriptions'])

    result.compact
  end

  def parse_textarea_to_jsonb_array(text)
    return nil if StringHelper.blank?(text)

    text.split("\n").map(&:strip).reject(&:empty?)
  end

  def build_ability_costs_jsonb(params)
    cost_fields_present = %w[
      ability_penalty_amount
      ability_penalty_decay
      all_roll_penalty_amount
      all_roll_penalty_decay
      specific_cooldown_rounds
      global_cooldown_rounds
    ].any? { |field| params.key?(field) }
    return nil unless cost_fields_present

    costs = {}

    # Ability penalty
    penalty_amount = params['ability_penalty_amount'].to_i
    if penalty_amount != 0
      costs['ability_penalty'] = {
        'amount' => penalty_amount,
        'decay_per_round' => params['ability_penalty_decay'].to_i
      }
    end

    # All-roll penalty
    all_roll_amount = params['all_roll_penalty_amount'].to_i
    if all_roll_amount != 0
      costs['all_roll_penalty'] = {
        'amount' => all_roll_amount,
        'decay_per_round' => params['all_roll_penalty_decay'].to_i
      }
    end

    # Specific cooldown
    specific_cd = params['specific_cooldown_rounds'].to_i
    costs['specific_cooldown'] = { 'rounds' => specific_cd } if specific_cd > 0

    # Global cooldown
    global_cd = params['global_cooldown_rounds'].to_i
    costs['global_cooldown'] = { 'rounds' => global_cd } if global_cd > 0

    costs.empty? ? {} : costs
  end

  def build_ability_status_effects_jsonb(params)
    return nil unless params['status_effects'].is_a?(Hash)

    effects = []
    params['status_effects'].each_value do |effect_data|
      effect_name = effect_data['effect'].to_s.strip
      effect_name = effect_data['effect_name'].to_s.strip if effect_name.empty?
      effect_name = resolve_status_effect_name(effect_data['effect_id']) if effect_name.empty?
      next if effect_name.to_s.strip.empty?

      duration = effect_data['duration_rounds']
      duration = effect_data['duration'] if duration.nil?

      threshold = effect_data['effect_threshold']
      threshold = effect_data['threshold'] if threshold.nil?

      effect = {
        'effect' => effect_name.to_s.downcase,
        'duration_rounds' => (duration || 1).to_i,
        'chance' => normalize_probability(effect_data['chance'])
      }
      effect['effect_threshold'] = threshold.to_i if threshold.to_i > 0
      effect['value'] = effect_data['value'].to_i if effect_data['value'].to_i != 0
      effect['damage_reduction'] = effect_data['damage_reduction'].to_i if effect_data['damage_reduction'].to_i > 0
      effect['shield_hp'] = effect_data['shield_hp'].to_i if effect_data['shield_hp'].to_i > 0

      effects << effect.compact
    end

    effects.empty? ? nil : effects
  end

  def build_ability_damage_types_jsonb(params)
    return nil unless params['damage_types_split'].is_a?(Hash)

    types = []
    params['damage_types_split'].each_value do |type_data|
      next if type_data['type'].to_s.strip.empty?

      types << {
        'type' => type_data['type'],
        'value' => type_data['value']
      }
    end

    types.empty? ? nil : types
  end

  def build_ability_conditional_damage_jsonb(params)
    return nil unless params['conditional_damage'].is_a?(Hash)

    conditions = []
    params['conditional_damage'].each_value do |cond_data|
      next if cond_data['condition'].to_s.strip.empty?

      conditions << {
        'condition' => cond_data['condition'],
        'status' => cond_data['status'],
        'bonus_dice' => cond_data['bonus_dice']
      }.compact
    end

    conditions.empty? ? nil : conditions
  end

  def build_ability_chain_config_jsonb(params)
    return nil unless params['chain_enabled'] == '1'

    {
      'max_targets' => (params['chain_max_targets'] || 3).to_i,
      'range_per_jump' => (params['chain_range_per_jump'] || 2).to_i,
      'damage_falloff' => (params['chain_damage_falloff'] || 0.5).to_f,
      'friendly_fire' => params['chain_friendly_fire'] == '1'
    }
  end

  def build_ability_forced_movement_jsonb(params)
    direction = params['forced_movement_direction'].to_s.strip
    direction = params['movement_direction'].to_s.strip if direction.empty?
    return nil if direction.empty?

    distance = params['forced_movement_distance']
    distance = params['movement_distance'] if distance.to_s.strip.empty?
    distance = 1 if distance.to_s.strip.empty?

    {
      'direction' => direction,
      'distance' => [distance.to_i, 1].max
    }
  end

  def normalize_probability(value)
    raw = value.to_s.strip
    return 1.0 if raw.empty?

    chance = raw.to_f
    chance /= 100.0 if chance > 1.0
    chance.clamp(0.0, 1.0)
  end

  def resolve_status_effect_name(effect_id)
    return nil if effect_id.to_s.strip.empty?

    status = StatusEffect[effect_id.to_i]
    status&.name&.downcase
  rescue StandardError => e
    warn "[Helpers] Failed to resolve status effect ID #{effect_id}: #{e.message}"
    nil
  end

  def build_ability_execute_effect_jsonb(params)
    return nil if params['execute_threshold'].to_s.empty?

    if params['execute_instant_kill'] == '1'
      { 'instant_kill' => true }
    else
      multiplier = params['execute_damage_multiplier'].to_s.empty? ? 2.0 : params['execute_damage_multiplier'].to_f
      { 'damage_multiplier' => multiplier }
    end
  end

  def build_ability_combo_condition_jsonb(params)
    status = params['combo_requires_status'].to_s.strip
    return nil if status.empty?

    {
      'requires_status' => status,
      'bonus_dice' => params['combo_bonus_dice'],
      'consumes_status' => params['combo_consumes_status'] == '1'
    }.compact
  end

  # Ability type badge colors for admin
  def ability_type_color(atype)
    case atype
    when 'combat' then 'danger'
    when 'utility' then 'info'
    when 'passive' then 'secondary'
    when 'social' then 'success'
    when 'crafting' then 'warning'
    else 'secondary'
    end
  end

  # Power rating badge colors
  def power_color(power)
    case power.to_i
    when 0..50 then 'success'
    when 51..100 then 'info'
    when 101..150 then 'warning'
    else 'danger'
    end
  end

  # Format power breakdown for tooltip display
  def format_power_breakdown(breakdown)
    return '' unless breakdown

    breakdown.map do |key, value|
      next if value.to_f == 0

      sign = value >= 0 ? '+' : ''
      "#{key}: #{sign}#{value.round}"
    end.compact.join("\n")
  end

  # Battle map room type badge colors
  def room_type_badge_color(room_type)
    RoomTypeConfig.badge_color(room_type)
  end

  # Battle map cover object category colors
  def category_color(category)
    case category
    when 'furniture' then 'primary'
    when 'vehicle' then 'warning'
    when 'nature' then 'success'
    when 'structure' then 'info'
    else 'secondary'
    end
  end

  # Character creation: render a stat allocation row
  # @param stat [Stat] The stat to render
  # @param block [StatBlock] The stat block containing the stat
  # @return [String] HTML for the stat row
  def render_stat_allocation_row(stat, block)
    html = '<div class="stat-row flex items-center justify-between mb-2 p-2 rounded bg-base-200" '
    html += "data-stat-id=\"#{stat.id}\" data-category=\"#{stat.stat_category}\">"

    # Stat name and info
    html += '<div class="stat-info flex-grow">'
    html += "<strong>#{h(stat.name)}</strong> "
    html += "<span class=\"badge badge-neutral badge-sm ml-1\">#{h(stat.abbreviation)}</span>"
    if stat.description
      html += "<br><small class=\"text-base-content/60\">#{h(stat.description)}</small>"
    end
    html += '</div>'

    # Controls
    html += '<div class="stat-controls flex items-center gap-2">'

    # Decrease button
    html += "<button type=\"button\" class=\"btn btn-square btn-sm btn-outline stat-decrease\" "
    html += "data-block-id=\"#{block.id}\" data-stat-id=\"#{stat.id}\" disabled>"
    html += '<span class="text-lg font-bold">−</span></button>'

    # Value display
    html += "<span class=\"stat-value badge badge-primary badge-lg font-mono\" style=\"min-width: 2.5rem;\" "
    html += "data-block-id=\"#{block.id}\" data-stat-id=\"#{stat.id}\">#{block.min_stat_value}</span>"

    # Hidden input for form submission
    html += "<input type=\"hidden\" name=\"stat_allocations[#{block.id}][#{stat.id}]\" "
    html += "value=\"#{block.min_stat_value}\" class=\"stat-input\" "
    html += "data-block-id=\"#{block.id}\" data-stat-id=\"#{stat.id}\">"

    # Increase button
    html += "<button type=\"button\" class=\"btn btn-square btn-sm btn-primary stat-increase\" "
    html += "data-block-id=\"#{block.id}\" data-stat-id=\"#{stat.id}\">"
    html += '<span class="text-lg font-bold">+</span></button>'

    # Cost display
    html += "<small class=\"text-base-content/60 stat-cost ml-1\" data-block-id=\"#{block.id}\" data-stat-id=\"#{stat.id}\">"
    html += "(#{block.point_cost_for_level(block.min_stat_value + 1)})</small>"

    html += '</div></div>'
    html
  end

  # ====== CHARACTER NAME PERSONALIZATION ======

  # Walk a data structure and resolve character names per-viewer.
  # Any Hash containing 'character_id'/'character_name' (or symbol equivalents)
  # gets its name fields overwritten with display_name_for(viewer).
  # This is the single enforcement point for name personalization in API responses.
  #
  # @param data [Hash, Array] The response data to process (mutated in place)
  # @param viewer_instance [CharacterInstance] The viewer to personalize for
  # @return [Hash, Array] The same data object, with names resolved
  def personalize_character_refs(data, viewer_instance)
    return data unless viewer_instance

    cache = {} # character_id => display_name, avoids N+1
    room_chars = CharacterInstance.where(
      current_room_id: viewer_instance.current_room_id, online: true
    ).eager(:character).all

    process = ->(obj) {
      case obj
      when Array
        obj.each { |item| process.call(item) }
      when Hash
        # If hash has character_id, resolve character_name for the viewer
        cid = obj['character_id'] || obj[:character_id]
        if cid
          display = cache[cid] ||= begin
            ci = CharacterInstance[cid]
            ci ? ci.character.display_name_for(viewer_instance, room_characters: room_chars) : 'someone'
          end
          # Overwrite character_name with personalized version
          obj['character_name'] = display if obj.key?('character_name')
          obj[:character_name] = display if obj.key?(:character_name)
          # Also handle :name key (room player lists)
          obj['name'] = display if obj.key?('name') && obj.key?('character_id')
          obj[:name] = display if obj.key?(:name) && obj.key?(:character_id)
        end
        obj.each_value { |v| process.call(v) if v.is_a?(Hash) || v.is_a?(Array) }
      end
    }

    process.call(data)
    data
  end

  # Personalize the 'message' content field of sync/reconnect messages
  # Uses MessagePersonalizationService to substitute character names in message text
  def personalize_message_content(messages, viewer_instance)
    return unless viewer_instance

    # Get room characters for name lookup context
    room_characters = CharacterInstance.where(
      current_room_id: viewer_instance.current_room_id,
      online: true
    ).eager(:character).all

    messages.each do |msg|
      next unless msg.is_a?(Hash)

      # Personalize string message field
      text_key = msg.key?('message') ? 'message' : (msg.key?(:message) ? :message : nil)
      next unless text_key

      text = msg[text_key]
      next unless text.is_a?(String) && !text.empty?

      msg[text_key] = MessagePersonalizationService.personalize(
        message: text,
        viewer: viewer_instance,
        room_characters: room_characters
      )
    end
  end

  # ====== WARDROBE HELPERS ======

  def wardrobe_result_json(result)
    strip_html = ->(s) { s.to_s.gsub(/<[^>]+>/, '') }
    payload = if result[:success]
                { success: true, message: strip_html.call(result[:message]) }
              else
                { success: false, error: strip_html.call(result[:message]) }
              end

    data = sanitize_wardrobe_result_data(result[:data], strip_html)
    if data
      payload[:data] = data
      if data.is_a?(Hash)
        data.each do |key, value|
          payload[key] = value unless payload.key?(key)
        end
      end
    end

    payload.to_json
  end

  def sanitize_wardrobe_result_data(data, strip_html)
    case data
    when nil
      nil
    when Item
      wardrobe_item_json(data)
    when String
      strip_html.call(data)
    when Array
      data.map { |value| sanitize_wardrobe_result_data(value, strip_html) }
    when Hash
      data.each_with_object({}) do |(key, value), hash|
        hash[key] = sanitize_wardrobe_result_data(value, strip_html)
      end
    else
      data
    end
  end

  def normalize_subcategory(uot_category)
    WardrobeService::SUBCATEGORY_REVERSE_MAP[uot_category]
  end

  def clean_description(text)
    return nil if text.nil?

    plain = text.to_s.gsub(/<[^>]+>/, '')
    # Filter out URL-like descriptions
    return nil if plain.match?(%r{\Ahttps?://}) || plain.match?(/\.(png|jpg|jpeg|gif|webp|svg)\z/i)

    plain
  end

  def wardrobe_item_json(item)
    plain_name = item.name.to_s.gsub(/<[^>]+>/, '')
    uot_category = item.pattern&.category
    {
      id: item.id,
      card_type: 'item',
      name: plain_name,
      description: clean_description(item.description),
      long_description: item.respond_to?(:long_description) ? item.long_description : nil,
      image_url: item.respond_to?(:image_url) ? item.image_url : nil,
      thumbnail_url: item.respond_to?(:thumbnail_url) ? item.thumbnail_url : nil,
      uot_category: uot_category,
      subcategory: normalize_subcategory(uot_category),
      pattern_id: item.pattern_id,
      worn: item.respond_to?(:worn) ? item.worn : false,
      condition: item.condition,
      stored_room_id: item.stored_room_id,
      stored_room_name: item.stored_room&.name
    }
  end

  def wardrobe_pattern_json(pattern, ci)
    base_price = pattern.price || 0
    half_price = (base_price * WardrobeService::PATTERN_CREATE_COST_MULTIPLIER).round
    owned_count = ci.objects_dataset.where(pattern_id: pattern.id).count
    desc = pattern.description.to_s
    plain_desc = desc.gsub(/<[^>]+>/, '')
    uot_category = pattern.category

    # Use pattern image if available, otherwise fall back to an owned item's image
    img = pattern.respond_to?(:image_url) ? pattern.image_url : nil
    thumb = pattern.respond_to?(:thumbnail_url) ? pattern.thumbnail_url : nil
    unless img || thumb
      sample = ci.objects_dataset.where(pattern_id: pattern.id).first
      if sample
        img = sample.respond_to?(:image_url) ? sample.image_url : nil
        thumb = sample.respond_to?(:thumbnail_url) ? sample.thumbnail_url : nil
      end
    end

    {
      id: pattern.id,
      card_type: 'pattern',
      name: plain_desc,
      description: plain_desc,
      image_url: img,
      thumbnail_url: thumb,
      uot_category: uot_category,
      subcategory: normalize_subcategory(uot_category),
      price: base_price,
      half_price: half_price,
      owned_count: owned_count
    }
  end

  # ====== COMBAT LOG HELPERS ======

  COMBAT_LOG_DIR = File.join(__dir__, '..', '..', 'log')

  # List available combat log dates (most recent first)
  def combat_log_dates
    Dir.glob(File.join(COMBAT_LOG_DIR, 'combat_rounds_*.log'))
       .map { |f| File.basename(f).match(/combat_rounds_(\d{4}-\d{2}-\d{2})\.log/)&.[](1) }
       .compact
       .sort
       .reverse
  end

  # Parse a day's combat log into a list of fights with metadata
  def parse_combat_log_index(date)
    path = File.join(COMBAT_LOG_DIR, "combat_rounds_#{date}.log")
    return [] unless File.exist?(path)

    fights = {}
    current_fight_id = nil

    File.foreach(path) do |line|
      if (m = line.match(/Fight #(\d+) Round (\d+)/))
        current_fight_id = m[1].to_i
        fights[current_fight_id] ||= { fight_id: current_fight_id, rounds: [], participants: Set.new, room: nil, battle_map: false, first_time: nil }
        fights[current_fight_id][:rounds] << m[2].to_i
      end

      if current_fight_id && (tm = line.match(/^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\]/))
        fights[current_fight_id][:first_time] ||= tm[1].split('T').last
      end

      if current_fight_id && (rm = line.match(/Room: (.+?) \|/))
        fights[current_fight_id][:room] ||= rm[1]
      end

      if current_fight_id && line.include?('Battle Map: true')
        fights[current_fight_id][:battle_map] = true
      end

      if current_fight_id && (pm = line.match(/^\s{2}(\S.+?) \(ID:\d+\)/))
        fights[current_fight_id][:participants] << pm[1]
      end
    end

    fights.values.each { |f| f[:participants] = f[:participants].to_a }
    fights.values.sort_by { |f| f[:first_time] || '' }.reverse
  end

  # Parse a specific fight's log entries into rounds with sections
  def parse_combat_log_fight(date, fight_id)
    path = File.join(COMBAT_LOG_DIR, "combat_rounds_#{date}.log")
    return [] unless File.exist?(path)

    rounds = []
    current_round = nil
    current_section = nil
    in_fight = false

    File.foreach(path) do |line|
      line = line.rstrip

      # Detect fight/round header
      if (m = line.match(/^\[(\S+)\] Fight #(\d+) Round (\d+)/))
        if m[2].to_i == fight_id
          in_fight = true
          current_round = { timestamp: m[1], round_number: m[3].to_i, sections: [] }
          current_section = nil
          rounds << current_round
          next
        else
          in_fight = false
          next
        end
      end

      next unless in_fight
      next if line.match?(/^={10,}/) # Skip separator lines

      # Detect section headers
      if (sm = line.match(/^--- (.+?) ---$/))
        section_name = sm[1].split('|').first.strip
        current_section = { name: section_name, lines: [] }
        current_round[:sections] << current_section if current_round
        next
      end

      # Add line to current section (or create implicit section)
      if current_round
        unless current_section
          current_section = { name: 'LOG', lines: [] }
          current_round[:sections] << current_section
        end
        current_section[:lines] << line unless line.strip.empty?
      end
    end

    rounds
  end

  # Colorize log lines with CSS classes for the combat log viewer
  def color_log_line(line)
    case line
    when /\[ATTACK\]/
      "<span class=\"text-warning\">#{line}</span>"
    when /\[ATTACK MISS\]/
      "<span class=\"text-base-content/40\">#{line}</span>"
    when /\[ATTACK BLOCKED\]/
      "<span class=\"text-base-content/40\">#{line}</span>"
    when /\[DAMAGE\]/
      "<span class=\"text-error\">#{line}</span>"
    when /\[KNOCKOUT\]/
      "<span class=\"text-error font-bold\">#{line}</span>"
    when /\[MOVE\] /
      "<span class=\"text-info\">#{line}</span>"
    when /\[MOVE SKIP\]|MOVE FALLBACK|PATHFIND FAIL|DYNAMIC STEP FAIL/
      "<span class=\"text-warning\">#{line}</span>"
    when /\[PATHFIND\]/
      "<span class=\"text-info/70\">#{line}</span>"
    when /\[ABILITY\]/
      "<span class=\"text-accent\">#{line}</span>"
    when /\[FLEE\]/
      "<span class=\"text-warning\">#{line}</span>"
    when /\[HAZARD\]/
      "<span class=\"text-error/70\">#{line}</span>"
    when /\[AI\]/
      "<span class=\"text-secondary\">#{line}</span>"
    when /\[STATUS\]/
      "<span class=\"text-secondary/70\">#{line}</span>"
    when /\[WEAPON SWITCH\]/
      "<span class=\"text-info/70\">#{line}</span>"
    when /\[REDIRECT\]/
      "<span class=\"text-warning/70\">#{line}</span>"
    when /\[SPAR TOUCH\]/
      "<span class=\"text-accent\">#{line}</span>"
    when /ERRORS:/
      "<span class=\"text-error font-bold\">#{line}</span>"
    else
      line
    end
  end
end
