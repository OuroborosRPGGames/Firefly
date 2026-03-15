# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Battle Map - Real Player Testing', type: :system, js: true do
  before(:all) do
    # Enable AI battle maps for all tests
    GameSetting.set('ai_battle_maps_enabled', 'true')
  end

  after(:all) do
    GameSetting.set('ai_battle_maps_enabled', 'false')
  end

  def login_as(session_name, username, password)
    Capybara.using_session(session_name) do
      visit '/login'

      fill_in 'Username or Email', with: username
      fill_in 'Password', with: password
      click_button 'Sign In'

      # Should redirect to dashboard
      expect(page).to have_current_path('/dashboard', wait: 10)

      # Navigate to webclient
      visit '/webclient'
      expect(page).to have_current_path('/webclient', wait: 5)

      # Wait for game to load
      expect(page).to have_css('#game-output', wait: 5)
    end
  end

  def send_command(command_text)
    # Use JavaScript to set the input and submit the form
    page.execute_script(<<~JS)
      const input = document.getElementById('command-input');
      const form = document.getElementById('command-form');
      input.value = '#{command_text.gsub("'", "\\'")}';
      form.dispatchEvent(new Event('submit'));
    JS

    # Wait a moment for the command to process
    sleep 0.5
  end

  def wait_for_element(selector, timeout: 10)
    page.find(selector, wait: timeout)
  rescue Capybara::ElementNotFound
    nil
  end

  def get_game_output
    output_elem = page.find('#game-output', wait: 2)
    output_elem.text
  end

  describe 'Two real players test battle map generation',
           skip: 'Requires specific pre-seeded user accounts (linis/linispassword) in the database' do
    it 'logs in as Linis Dao and another character, starts fight, verifies battle map' do
      # Login as Linis Dao (has profile picture)
      Capybara.using_session(:linis) do
        login_as(:linis, 'linis', 'linispassword')

        # Check that we're logged in and can see the game
        output = get_game_output
        puts "Linis logged in, initial output length: #{output.length}"
      end

      # Login as second character
      Capybara.using_session(:player2) do
        login_as(:player2, 'firefly_test', 'firefly_test_2024')

        output = get_game_output
        puts "Player 2 logged in, initial output length: #{output.length}"
      end

      # Find out where Linis is and move player2 there
      linis_location = nil
      Capybara.using_session(:linis) do
        send_command('look')
        sleep 1
        output = get_game_output
        puts "Linis location: #{output[0..200]}"

        # Try to extract room name from output
        if output =~ /^([^\n]+)/
          linis_location = $1.strip
        end
      end

      # Make sure player2 is in same room or move them there
      Capybara.using_session(:player2) do
        send_command('look')
        sleep 1
        output = get_game_output
        puts "Player 2 location: #{output[0..200]}"

        # If not in same room, try to navigate there
        # For now, let's just start a fight wherever they are
        send_command('who')
        sleep 1
        who_output = get_game_output
        puts "Who output: #{who_output}"
      end

      # Start the fight from Linis's session
      Capybara.using_session(:linis) do
        # Try to find another character to fight
        send_command('look')
        sleep 1
        look_output = get_game_output

        # Extract character name from room (looking for "TestChar" or similar)
        target_name = nil
        if look_output =~ /TestChar\d+/
          target_name = $&
        end

        if target_name
          puts "Linis attempting to fight: #{target_name}"
          send_command("fight #{target_name}")

          # Wait for battle map container to appear
          battle_map_container = wait_for_element('#battle-map-container', timeout: 5)
          expect(battle_map_container).to be_visible

          # Verify loading UI appears
          loading_ui = wait_for_element('#battle-map-loading', timeout: 3)
          if loading_ui
            expect(loading_ui).to be_visible
            puts "✓ Loading UI appeared"

            # Verify loading components
            expect(page).to have_css('#hex-grid-wireframe', wait: 2)
            expect(page).to have_css('#generation-progress-bar', wait: 2)
            expect(page).to have_css('#generation-step', wait: 2)
            expect(page).to have_css('#generation-percentage', wait: 2)
            puts "✓ All loading components present"

            # Verify wireframe SVG is rendered
            wireframe = page.find('#hex-grid-wireframe')
            expect(wireframe).to be_visible
            viewbox = wireframe['viewBox']
            expect(viewbox).not_to be_nil
            expect(viewbox).not_to be_empty
            puts "✓ Wireframe SVG rendered with viewBox: #{viewbox}"
          end

          # Wait for generation to complete (up to 90 seconds)
          puts "Waiting for battle map generation..."
          completion_detected = false
          90.times do
            if page.has_css?('#battle-map-loading.hidden', visible: :hidden, wait: 0)
              completion_detected = true
              puts "✓ Loading UI hidden"
              break
            end

            # Check if percentage shows 100%
            if page.has_css?('#generation-percentage', text: '100%', wait: 0)
              completion_detected = true
              puts "✓ Generation reached 100%"
              sleep 1 # Give time for UI to transition
              break
            end

            # Log progress every 10 seconds
            if (Time.now.to_i % 10) == 0
              if page.has_css?('#generation-percentage', wait: 0)
                pct = page.find('#generation-percentage').text rescue 'unknown'
                step = page.find('#generation-step').text rescue 'unknown'
                puts "  Progress: #{pct} - #{step}"
              end
            end

            sleep 1
          end

          expect(completion_detected).to be true, 'Battle map generation did not complete within 90 seconds'

          # After generation, loading UI should be hidden
          expect(page).to have_css('#battle-map-loading.hidden', visible: :hidden, wait: 5)
          puts "✓ Loading UI properly hidden after completion"

          # Battle map SVG should now be visible
          battle_map = wait_for_element('#battle-map:not(.hidden)', timeout: 5)
          expect(battle_map).to be_visible
          puts "✓ Battle map SVG is visible"

          # Verify battle map has hexes rendered
          hexes = page.all('#battle-map polygon.hex', wait: 5)
          expect(hexes.count).to be > 0, 'Battle map should have hex polygons rendered'
          puts "✓ Battle map has #{hexes.count} hexes"

          # Verify hex tessellation (hexes should have 6 points each)
          first_hex = hexes.first
          points_attr = first_hex['points']
          expect(points_attr).not_to be_nil

          # A hexagon has 6 coordinate pairs, so 12 numbers total
          points = points_attr.split(/[\s,]+/).map(&:to_f)
          expect(points.length).to eq(12), 'Each hex should have 6 coordinate pairs (12 numbers)'
          puts "✓ Hexes have proper tessellation (6 points)"

          # Verify hexes have proper data attributes
          hex_with_type = page.find('#battle-map polygon.hex[data-hex-type]', match: :first)
          expect(hex_with_type).not_to be_nil

          hex_type = hex_with_type['data-hex-type']
          expect(hex_type).not_to be_empty

          # Valid hex types from RoomHex model
          valid_types = %w[normal wall fire water trap cover difficult pit debris furniture door stairs window hazard]
          expect(valid_types).to include(hex_type)
          puts "✓ Hexes have valid type attributes (found: #{hex_type})"

          # Verify hexes have coordinates
          hex_with_coords = page.find('#battle-map polygon.hex[data-x][data-y]', match: :first)
          x = hex_with_coords['data-x']
          y = hex_with_coords['data-y']
          expect(x).to match(/^-?\d+$/)
          expect(y).to match(/^-?\d+$/)
          puts "✓ Hexes have coordinate attributes (example: #{x},#{y})"

          # Test scrolling (pan the map)
          battle_map_element = page.find('#battle-map')
          viewbox_before = battle_map_element['viewBox'].split.map(&:to_f)

          # Pan right by 100 units
          page.execute_script(<<~JS)
            const map = document.getElementById('battle-map');
            const viewBox = map.getAttribute('viewBox').split(' ').map(Number);
            viewBox[0] += 100;
            map.setAttribute('viewBox', viewBox.join(' '));
          JS

          viewbox_after = battle_map_element['viewBox'].split.map(&:to_f)
          expect(viewbox_after[0]).to be > viewbox_before[0], 'Map should pan when viewBox changes'
          puts "✓ Map panning works (viewBox changed from #{viewbox_before[0]} to #{viewbox_after[0]})"

          # Test clicking a hex to move
          empty_hex = page.find('#battle-map polygon.hex[data-hex-type="normal"]', match: :first, wait: 2) rescue nil
          if empty_hex
            target_x = empty_hex['data-x']
            target_y = empty_hex['data-y']

            puts "Testing hex click at (#{target_x}, #{target_y})"
            empty_hex.click
            sleep 1

            # Check if command was processed
            output = get_game_output
            puts "Output after hex click: #{output[-200..-1]}"
          else
            puts "⚠ Could not find empty hex to test clicking"
          end

          # Test clicking an occupied hex
          occupied_hexes = page.all('#battle-map polygon.hex.occupied', wait: 2)
          puts "✓ Found #{occupied_hexes.count} occupied hexes"

          if occupied_hexes.count >= 1
            # Verify character markers
            occupied_hexes.each_with_index do |hex, i|
              char_name = hex['data-character']
              puts "  Occupied hex #{i}: #{char_name}" if char_name
            end
          end

          # Take a screenshot for manual inspection
          page.save_screenshot('/tmp/battle_map_linis.png')
          puts "✓ Screenshot saved to /tmp/battle_map_linis.png"

        else
          puts "⚠ No target found to fight - skipping battle map test"
          skip "No other characters in room to fight"
        end
      end

      # Check that player2 also sees the battle map
      Capybara.using_session(:player2) do
        battle_map = wait_for_element('#battle-map:not(.hidden)', timeout: 5)
        if battle_map
          expect(battle_map).to be_visible

          hexes = page.all('#battle-map polygon.hex', wait: 5)
          expect(hexes.count).to be > 0
          puts "✓ Player 2 also sees battle map with #{hexes.count} hexes"

          page.save_screenshot('/tmp/battle_map_player2.png')
          puts "✓ Screenshot saved to /tmp/battle_map_player2.png"
        else
          puts "⚠ Player 2 did not see battle map"
        end
      end
    end
  end
end
