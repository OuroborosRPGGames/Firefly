# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Async Battle Map Loading - Two Player Integration', type: :system, js: true do
  let(:zone) { create(:zone, name: 'Test Zone') }
  let(:location) { create(:location, name: 'Test City', zone: zone) }
  let(:room) do
    create(:room,
           name: 'Arena',
           location: location,
           min_x: 0, max_x: 40, min_y: 0, max_y: 40,
           has_battle_map: false)
  end

  let!(:user1) { create(:user, email: 'player1@test.com', username: 'Player1', password: 'password123') }
  let!(:user2) { create(:user, email: 'player2@test.com', username: 'Player2', password: 'password123') }
  let!(:char1) { create(:character, user: user1, forename: 'Alpha') }
  let!(:char2) { create(:character, user: user2, forename: 'Beta') }
  let!(:instance1) { create(:character_instance, character: char1, current_room: room) }
  let!(:instance2) { create(:character_instance, character: char2, current_room: room) }

  before do
    # Ensure AI battle maps are enabled
    GameSetting.set('ai_battle_maps_enabled', 'true')
    sleep 0.1
  end

  after do
    # Clean up
    GameSetting.set('ai_battle_maps_enabled', 'false')
  end

  def login_character(session_name, email, password)
    Capybara.using_session(session_name) do
      visit '/login'
      fill_in 'Username or Email', with: email
      fill_in 'Password', with: password
      click_button 'Sign In'

      # Check where we ended up
      sleep 1
      current_url = page.current_url
      puts "DEBUG #{session_name}: After login, at #{current_url}"

      # If still at login, check for error
      if page.current_path == '/login'
        error_elem = page.all('.alert, .flash').first
        puts "DEBUG #{session_name}: Login failed - #{error_elem&.text || 'no error shown'}"
        page.save_screenshot("/tmp/login_fail_#{session_name}.png") rescue nil
      end

      # Login redirects to /dashboard, then navigate to webclient
      expect(page).to have_current_path('/dashboard', wait: 5)
      visit '/webclient'
      expect(page).to have_current_path('/webclient', wait: 5)
    end
  end

  def wait_for_element(selector, timeout: 10)
    page.find(selector, wait: timeout)
  rescue Capybara::ElementNotFound
    nil
  end

  describe 'Two players initiate combat in room without battle map',
           skip: 'Requires fully configured game server with AI APIs and active character sessions' do
    before do
      # Log in both players
      login_character(:player1, 'player1@test.com', 'password123')
      login_character(:player2, 'player2@test.com', 'password123')
    end

    it 'shows loading UI to both players, then renders battle map with correct hexes' do
      # Player 1 initiates combat
      Capybara.using_session(:player1) do
        # Send fight command
        page.execute_script("document.getElementById('command-input').value = 'fight Beta';")
        page.execute_script("document.getElementById('command-form').dispatchEvent(new Event('submit'));")

        # Wait for battle map container to appear
        battle_map_container = wait_for_element('#battle-map-container', timeout: 5)
        expect(battle_map_container).to be_visible

        # Verify loading UI appears
        loading_ui = wait_for_element('#battle-map-loading', timeout: 3)
        expect(loading_ui).to be_visible

        # Verify loading components are present
        expect(page).to have_css('#hex-grid-wireframe', wait: 2)
        expect(page).to have_css('#generation-progress-bar', wait: 2)
        expect(page).to have_css('#generation-step', wait: 2)
        expect(page).to have_css('#generation-percentage', wait: 2)

        # Verify progress bar exists and has ARIA attributes
        progress_bar = page.find('.progress-bar[role="progressbar"]')
        expect(progress_bar['aria-valuenow']).to eq('0')
        expect(progress_bar['aria-valuemin']).to eq('0')
        expect(progress_bar['aria-valuemax']).to eq('100')

        # Verify initial state shows 0%
        percentage_text = page.find('#generation-percentage').text
        expect(percentage_text).to eq('0%')

        # Verify wireframe SVG is rendered
        wireframe = page.find('#hex-grid-wireframe')
        expect(wireframe).to be_visible

        # Check SVG has viewBox attribute (indicates it's properly initialized)
        viewbox = wireframe['viewBox']
        expect(viewbox).not_to be_nil
        expect(viewbox).not_to be_empty

        # Attempt to use combat command during generation (should be blocked)
        page.execute_script("document.getElementById('command-input').value = 'strike Beta';")
        page.execute_script("document.getElementById('command-form').dispatchEvent(new Event('submit'));")

        # Should see error message about generation in progress
        error_msg = wait_for_element('.error-message, .alert-danger', timeout: 3)
        expect(error_msg.text).to match(/generating|in progress|wait/i) if error_msg

        # Wait for generation to complete (progress reaches 100%)
        # This could take 30-60 seconds with real AI generation
        using_wait_time(90) do
          # Poll for completion - either progress reaches 100% or loading UI disappears
          completion_detected = false
          90.times do
            if page.has_css?('#battle-map-loading.hidden', visible: :hidden)
              completion_detected = true
              break
            end

            # Check if percentage shows 100%
            if page.has_css?('#generation-percentage', text: '100%', wait: 0)
              completion_detected = true
              sleep 1 # Give time for UI to transition
              break
            end

            sleep 1
          end

          expect(completion_detected).to be true, 'Battle map generation did not complete within 90 seconds'
        end

        # After generation, loading UI should be hidden
        expect(page).to have_css('#battle-map-loading.hidden', visible: :hidden, wait: 5)

        # Battle map SVG should now be visible
        battle_map = wait_for_element('#battle-map:not(.hidden)', timeout: 5)
        expect(battle_map).to be_visible

        # Verify battle map has hexes rendered
        hexes = page.all('#battle-map polygon.hex', wait: 5)
        expect(hexes.count).to be > 0, 'Battle map should have hex polygons rendered'

        # Verify hex tessellation (hexes should have 6 points each)
        first_hex = hexes.first
        points_attr = first_hex['points']
        expect(points_attr).not_to be_nil

        # A hexagon has 6 coordinate pairs, so 12 numbers total
        points = points_attr.split(/[\s,]+/).map(&:to_f)
        expect(points.length).to eq(12), 'Each hex should have 6 coordinate pairs (12 numbers)'

        # Verify hexes have proper classes (hex_type attributes)
        hex_with_type = page.find('#battle-map polygon.hex[data-hex-type]', match: :first)
        expect(hex_with_type).not_to be_nil

        hex_type = hex_with_type['data-hex-type']
        expect(hex_type).not_to be_empty

        # Valid hex types from RoomHex model
        valid_types = %w[normal wall fire water trap cover difficult pit debris furniture door stairs window hazard]
        expect(valid_types).to include(hex_type)

        # Verify hexes have coordinates
        hex_with_coords = page.find('#battle-map polygon.hex[data-x][data-y]', match: :first)
        expect(hex_with_coords['data-x']).to match(/^-?\d+$/)
        expect(hex_with_coords['data-y']).to match(/^-?\d+$/)

        # Test scrolling (pan the map)
        battle_map_element = page.find('#battle-map')
        viewbox_before = battle_map_element['viewBox'].split.map(&:to_f)

        # Simulate pan (this depends on how panning is implemented in battle-map-renderer.js)
        # Typically done via mouse drag or wheel events
        page.execute_script(<<~JS)
          const map = document.getElementById('battle-map');
          const viewBox = map.getAttribute('viewBox').split(' ').map(Number);
          // Pan right by 100 units
          viewBox[0] += 100;
          map.setAttribute('viewBox', viewBox.join(' '));
        JS

        viewbox_after = battle_map_element['viewBox'].split.map(&:to_f)
        expect(viewbox_after[0]).to be > viewbox_before[0], 'Map should pan when viewBox changes'

        # Test clicking a hex to move
        # Find an empty (normal/open) hex that's not occupied
        empty_hex = page.find('#battle-map polygon.hex[data-hex-type="normal"]', match: :first)
        target_x = empty_hex['data-x']
        target_y = empty_hex['data-y']

        # Click the hex
        empty_hex.click

        # Should trigger movement or show movement UI
        # Wait for command to be processed
        sleep 1

        # Verify character moved (check game output or character position update)
        # This depends on the game's response format
        output_area = page.find('#game-output', wait: 2)
        expect(output_area.text).to match(/move|moved|position/i).or match(/#{target_x}|#{target_y}/)

        # Test clicking an occupied hex to attack
        # Find hex where Beta (opponent) is located
        opponent_hex = page.find("#battle-map polygon.hex.occupied[data-character*='Beta']", match: :first, wait: 2)

        if opponent_hex
          opponent_hex.click
          sleep 1

          # Should initiate attack or show attack options
          output_area = page.find('#game-output', wait: 2)
          expect(output_area.text).to match(/attack|strike|Beta/i)
        else
          # If opponent hex not found, at least verify occupied hexes exist
          occupied_hexes = page.all('#battle-map polygon.hex.occupied', wait: 2)
          expect(occupied_hexes.count).to be >= 1, 'Should have at least one occupied hex (player position)'
        end
      end

      # Player 2 should also see the battle map
      Capybara.using_session(:player2) do
        # Wait for battle map to appear
        battle_map = wait_for_element('#battle-map:not(.hidden)', timeout: 5)
        expect(battle_map).to be_visible

        # Verify hexes are rendered for player 2 as well
        hexes = page.all('#battle-map polygon.hex', wait: 5)
        expect(hexes.count).to be > 0

        # Player 2 should see their character and Alpha's character on the map
        occupied_hexes = page.all('#battle-map polygon.hex.occupied', wait: 2)
        expect(occupied_hexes.count).to be >= 2, 'Should show both player positions'
      end
    end

    context 'when one player has a character picture and one does not' do
      before do
        # Add picture URL to character1
        character1.update(picture_url: 'https://example.com/alpha.jpg')

        # Ensure character2 has no picture
        character2.update(picture_url: nil)
      end

      it 'renders battle map correctly regardless of picture presence' do
        # Initiate combat
        Capybara.using_session(:player1) do
          page.execute_script("document.getElementById('command-input').value = 'fight Beta';")
          page.execute_script("document.getElementById('command-form').dispatchEvent(new Event('submit'));")

          # Wait for generation to complete
          using_wait_time(90) do
            90.times do
              break if page.has_css?('#battle-map:not(.hidden)', visible: :visible, wait: 0)
              sleep 1
            end
          end

          # Verify battle map loaded
          expect(page).to have_css('#battle-map:not(.hidden)', visible: :visible, wait: 5)

          # Verify both characters are on the map
          occupied_hexes = page.all('#battle-map polygon.hex.occupied')
          expect(occupied_hexes.count).to be >= 2

          # Check that character markers are rendered (could be avatars or colored hexes)
          # This depends on implementation details of battle-map-renderer.js
          alpha_marker = page.find("#battle-map [data-character*='Alpha']", match: :first, wait: 2)
          beta_marker = page.find("#battle-map [data-character*='Beta']", match: :first, wait: 2)

          expect(alpha_marker).not_to be_nil
          expect(beta_marker).not_to be_nil
        end
      end
    end

    context 'when generation fails and falls back to procedural' do
      before do
        # Stub AIBattleMapGeneratorService to fail
        allow_any_instance_of(AIBattleMapGeneratorService).to receive(:generate_battlemap_image).and_raise(StandardError, 'AI generation failed')
      end

      it 'still generates a procedural battle map and allows gameplay' do
        Capybara.using_session(:player1) do
          page.execute_script("document.getElementById('command-input').value = 'fight Beta';")
          page.execute_script("document.getElementById('command-form').dispatchEvent(new Event('submit'));")

          # Wait for loading UI
          expect(page).to have_css('#battle-map-loading', visible: :visible, wait: 5)

          # Generation should complete (falling back to procedural)
          using_wait_time(60) do
            60.times do
              break if page.has_css?('#battle-map:not(.hidden)', visible: :visible, wait: 0)
              sleep 1
            end
          end

          # Verify battle map appears despite AI failure
          expect(page).to have_css('#battle-map:not(.hidden)', visible: :visible, wait: 5)

          # Verify hexes were generated procedurally
          hexes = page.all('#battle-map polygon.hex')
          expect(hexes.count).to be > 0

          # Verify gameplay works (can issue commands)
          page.execute_script("document.getElementById('command-input').value = 'look';")
          page.execute_script("document.getElementById('command-form').dispatchEvent(new Event('submit'));")

          sleep 1
          output = page.find('#game-output').text
          expect(output).to match(/Arena|battle/i)
        end
      end
    end
  end

  describe 'Hex feature validation',
           skip: 'Requires fully configured game server with AI APIs and active character sessions' do
    before do
      # Manually create a room with battle map for faster testing
      room.update(has_battle_map: true)

      # Create some hex features
      create(:room_hex, room: room, hex_x: 0, hex_y: 0, hex_type: 'normal')
      create(:room_hex, room: room, hex_x: 2, hex_y: 0, hex_type: 'wall')
      create(:room_hex, room: room, hex_x: 4, hex_y: 0, hex_type: 'cover', cover_object: 'barrel', cover_value: 2)
      create(:room_hex, room: room, hex_x: 6, hex_y: 0, hex_type: 'water', water_type: 'deep', traversable: false)
      create(:room_hex, room: room, hex_x: 8, hex_y: 0, hex_type: 'difficult', difficult_terrain: true)

      login_character(:player1, 'player1@test.com', 'password123')
      login_character(:player2, 'player2@test.com', 'password123')
    end

    it 'renders hex features with correct visual attributes' do
      # Start fight to show battle map
      Capybara.using_session(:player1) do
        page.execute_script("document.getElementById('command-input').value = 'fight Beta';")
        page.execute_script("document.getElementById('command-form').dispatchEvent(new Event('submit'));")

        # Wait for battle map
        expect(page).to have_css('#battle-map:not(.hidden)', visible: :visible, wait: 10)

        # Find wall hex
        wall_hex = page.find('#battle-map polygon.hex[data-hex-type="wall"][data-x="2"][data-y="0"]')
        expect(wall_hex).not_to be_nil
        expect(wall_hex[:class]).to include('wall')

        # Find cover hex
        cover_hex = page.find('#battle-map polygon.hex[data-hex-type="cover"][data-x="4"][data-y="0"]')
        expect(cover_hex).not_to be_nil
        expect(cover_hex['data-cover-value']).to eq('2')
        expect(cover_hex['data-cover-object']).to eq('barrel')

        # Find water hex
        water_hex = page.find('#battle-map polygon.hex[data-hex-type="water"][data-x="6"][data-y="0"]')
        expect(water_hex).not_to be_nil
        expect(water_hex['data-water-type']).to eq('deep')
        expect(water_hex['data-traversable']).to eq('false')

        # Find difficult terrain hex
        difficult_hex = page.find('#battle-map polygon.hex[data-hex-type="difficult"][data-x="8"][data-y="0"]')
        expect(difficult_hex).not_to be_nil
        expect(difficult_hex['data-difficult-terrain']).to eq('true')

        # Verify hex colors/styles differ (this depends on CSS)
        # Check computed styles
        wall_fill = page.evaluate_script("getComputedStyle(document.querySelector('#battle-map polygon.hex.wall')).fill")
        normal_fill = page.evaluate_script("getComputedStyle(document.querySelector('#battle-map polygon.hex[data-hex-type=\"normal\"]')).fill")

        # Wall and normal should have different fills
        expect(wall_fill).not_to eq(normal_fill)
      end
    end
  end
end
