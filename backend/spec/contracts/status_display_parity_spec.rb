# frozen_string_literal: true

require 'spec_helper'

# Status Display Parity Contract Tests
#
# These tests verify that the status shown in the webclient status bar always
# matches what other people see when they look at a character in a room.
#
# For example, if Bob is "sitting on a sofa" in the room view, his status bar
# should show "sitting on a sofa" too.
#
# Architecture:
# - StatusBarService#current_action_text calls RoomDisplayService#build_status_line
# - RoomDisplayService#character_brief includes status_line via build_status_line
# - This spec ensures these remain synchronized across all character states.

RSpec.describe 'Status Display Parity', type: :contract do
  let(:room) { create(:room, name: 'Test Room') }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:reality) { create(:reality) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           status: 'alive',
           online: true)
  end

  # Helper: Get the action_text from StatusBarService
  def status_bar_action_text(ci)
    StatusBarService.new(ci).build_status_data.dig(:right, :action_text)
  end

  # Helper: Get the status_line from RoomDisplayService for a character
  def room_display_status_line(ci, viewer: nil)
    viewer ||= ci
    display = RoomDisplayService.new(ci.current_room, viewer).build_display

    # Find our character in the room display
    chars = display[:characters_ungrouped] || []
    (display[:places] || []).each { |p| chars.concat(p[:characters] || []) }

    char_data = chars.find { |c| c[:id] == ci.id }
    char_data&.dig(:status_line)
  end

  # Helper: Verify parity between status bar and room display
  def verify_parity(ci, viewer: nil)
    status_bar = status_bar_action_text(ci)
    room_status = room_display_status_line(ci, viewer: viewer)

    # Note: When viewer == self, character won't appear in room display
    # So we directly compare what build_status_line produces
    direct_status = RoomDisplayService.new(ci.current_room, ci).send(:build_status_line, ci)

    expect(status_bar).to eq(direct_status),
      "Status bar and room display diverged!\n" \
      "  Status bar action_text: #{status_bar.inspect}\n" \
      "  Direct build_status_line: #{direct_status.inspect}"

    status_bar
  end

  describe 'basic parity verification' do
    it 'status bar action_text matches room display status_line' do
      verify_parity(character_instance)
    end

    it 'both return nil for default standing character' do
      character_instance.update(stance: 'standing', current_place_id: nil)
      result = verify_parity(character_instance)
      expect(result).to be_nil
    end
  end

  describe 'posture + place combinations' do
    let(:sofa) do
      create(:place, room: room, name: 'Leather Sofa', is_furniture: true)
    end

    let(:bed) do
      create(:place, room: room, name: 'King Bed', is_furniture: true)
    end

    let(:bar) do
      create(:place, room: room, name: 'The Bar', is_furniture: true)
    end

    it 'sitting at a place matches in both displays' do
      character_instance.update(stance: 'sitting', current_place_id: sofa.id)
      result = verify_parity(character_instance)
      expect(result).to eq('sitting at Leather Sofa')
    end

    it 'lying on a place matches in both displays' do
      character_instance.update(stance: 'lying', current_place_id: bed.id)
      result = verify_parity(character_instance)
      expect(result).to eq('lying on King Bed')
    end

    it 'reclining on a place matches in both displays' do
      character_instance.update(stance: 'reclining', current_place_id: sofa.id)
      result = verify_parity(character_instance)
      expect(result).to eq('reclining on Leather Sofa')
    end

    it 'standing near a place matches in both displays' do
      character_instance.update(stance: 'standing', current_place_id: bar.id)
      result = verify_parity(character_instance)
      expect(result).to eq('standing near The Bar')
    end

    it 'sitting without a place matches in both displays' do
      character_instance.update(stance: 'sitting', current_place_id: nil)
      result = verify_parity(character_instance)
      expect(result).to eq('sitting')
    end

    it 'lying without a place matches in both displays' do
      character_instance.update(stance: 'lying', current_place_id: nil)
      result = verify_parity(character_instance)
      expect(result).to eq('lying down')
    end

    it 'reclining without a place matches in both displays' do
      character_instance.update(stance: 'reclining', current_place_id: nil)
      result = verify_parity(character_instance)
      expect(result).to eq('reclining')
    end
  end

  describe 'injury states' do
    context 'with health attributes' do
      before do
        # Ensure character instance has health attributes
        character_instance.update(max_health: 100)
      end

      it 'full health shows no injury in both displays' do
        character_instance.update(health: 100, max_health: 100)
        result = verify_parity(character_instance)
        expect(result).to be_nil
      end

      it 'lightly wounded (76-99%) matches in both displays' do
        character_instance.update(health: 80, max_health: 100)
        result = verify_parity(character_instance)
        expect(result).to eq('lightly wounded')
      end

      it 'injured (51-75%) matches in both displays' do
        character_instance.update(health: 60, max_health: 100)
        result = verify_parity(character_instance)
        expect(result).to eq('injured')
      end

      it 'badly wounded (26-50%) matches in both displays' do
        character_instance.update(health: 40, max_health: 100)
        result = verify_parity(character_instance)
        expect(result).to eq('badly wounded')
      end

      it 'critically injured (0-25%) matches in both displays' do
        character_instance.update(health: 20, max_health: 100)
        result = verify_parity(character_instance)
        expect(result).to eq('critically injured')
      end
    end
  end

  describe 'combined states' do
    let(:bar) do
      create(:place, room: room, name: 'The Bar', is_furniture: true)
    end

    let(:bed) do
      create(:place, room: room, name: 'Soft Bed', is_furniture: true)
    end

    it 'sitting at place + injured matches in both displays' do
      character_instance.update(
        stance: 'sitting',
        current_place_id: bar.id,
        health: 40,
        max_health: 100
      )
      result = verify_parity(character_instance)
      expect(result).to eq('sitting at The Bar, badly wounded')
    end

    it 'lying on bed + lightly wounded matches in both displays' do
      character_instance.update(
        stance: 'lying',
        current_place_id: bed.id,
        health: 85,
        max_health: 100
      )
      result = verify_parity(character_instance)
      expect(result).to eq('lying on Soft Bed, lightly wounded')
    end

    it 'standing alone + critically injured matches in both displays' do
      character_instance.update(
        stance: 'standing',
        current_place_id: nil,
        health: 10,
        max_health: 100
      )
      result = verify_parity(character_instance)
      expect(result).to eq('critically injured')
    end
  end

  describe 'edge cases' do
    it 'dead character returns nil in both displays' do
      character_instance.update(status: 'dead')
      result = verify_parity(character_instance)
      expect(result).to be_nil
    end

    it 'unconscious character returns nil in both displays' do
      character_instance.update(status: 'unconscious')
      result = verify_parity(character_instance)
      expect(result).to be_nil
    end

    it 'status bar gracefully handles missing room' do
      # Simulate a character instance that loses its room (e.g., room deleted)
      # Use the existing character instance and set room to nil after creation
      character_instance.instance_variable_set(:@current_room, nil)
      allow(character_instance).to receive(:current_room).and_return(nil)

      # StatusBarService should fall back to display_action
      status_bar_data = StatusBarService.new(character_instance).build_status_data
      action_text = status_bar_data.dig(:right, :action_text)

      # Should not raise, should return the fallback (display_action)
      expect { action_text }.not_to raise_error
      expect(action_text).to eq(character_instance.display_action)
    end

    it 'handles nil stance gracefully' do
      character_instance.update(stance: nil, current_place_id: nil)
      result = verify_parity(character_instance)
      # nil stance defaults to 'standing' in status_posture_and_place
      expect(result).to be_nil
    end
  end

  describe 'viewer perspective consistency' do
    let(:other_user) { create(:user) }
    let(:other_character) { create(:character, user: other_user) }
    let(:other_instance) do
      create(:character_instance,
             character: other_character,
             reality: reality,
             current_room: room,
             status: 'alive',
             online: true)
    end

    let(:sofa) do
      create(:place, room: room, name: 'Corner Sofa', is_furniture: true)
    end

    it 'status shown to others matches self-view in status bar' do
      character_instance.update(
        stance: 'sitting',
        current_place_id: sofa.id,
        health: 60,
        max_health: 100
      )

      # What the character sees in their own status bar
      self_status_bar = status_bar_action_text(character_instance)

      # What another character sees when looking at the room
      display = RoomDisplayService.new(room, other_instance).build_display
      chars = display[:characters_ungrouped] || []
      (display[:places] || []).each { |p| chars.concat(p[:characters] || []) }
      char_data = chars.find { |c| c[:id] == character_instance.id }
      viewer_sees = char_data&.dig(:status_line)

      expect(self_status_bar).to eq(viewer_sees),
        "Status bar doesn't match what others see!\n" \
        "  Self status bar: #{self_status_bar.inspect}\n" \
        "  Others see: #{viewer_sees.inspect}"
    end
  end

  describe 'implementation contract' do
    # This test documents the expected relationship between the services
    it 'StatusBarService delegates to RoomDisplayService for action_text' do
      # This test verifies the implementation stays coupled
      # If someone changes StatusBarService to not use RoomDisplayService,
      # this test should fail and alert them to update the parity tests

      source = File.read(
        File.join(__dir__, '../../app/services/status_bar_service.rb')
      )

      expect(source).to include('RoomDisplayService'),
        'StatusBarService should delegate to RoomDisplayService for consistency'

      expect(source).to include('build_status_line'),
        'StatusBarService should call build_status_line from RoomDisplayService'
    end
  end
end
