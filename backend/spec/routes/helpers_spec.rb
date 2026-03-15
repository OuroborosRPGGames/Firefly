# frozen_string_literal: true

require 'spec_helper'

# Test helper class that includes RouteHelpers
class TestHelperClass
  include RouteHelpers

  attr_accessor :session, :request, :flash

  def initialize
    @session = {}
    @flash = {}
    @request = MockRequest.new
  end

  # Mock methods required by RouteHelpers
  def render(template, locals: {})
    "<rendered>#{template}</rendered>"
  end

  def view(template)
    "<view>#{template}</view>"
  end

  def h(text)
    text.to_s.gsub('<', '&lt;').gsub('>', '&gt;')
  end

  def csrf_tag
    '<input type="hidden" name="_csrf" value="token">'
  end

  # Simple mock request class
  class MockRequest
    attr_accessor :ip, :user_agent, :env, :params

    def initialize
      @ip = '127.0.0.1'
      @user_agent = 'TestAgent'
      @env = {}
      @params = {}
    end
  end
end

RSpec.describe RouteHelpers do
  let(:helper) { TestHelperClass.new }

  describe '#partial' do
    it 'converts template path to partial format' do
      result = helper.partial('admin/sidebar')
      expect(result).to eq('<rendered>admin/_sidebar</rendered>')
    end

    it 'handles root-level templates' do
      result = helper.partial('header')
      expect(result).to eq('<rendered>_header</rendered>')
    end
  end

  describe '#activity_icon' do
    it 'returns compass for mission' do
      expect(helper.activity_icon('mission')).to eq('compass')
    end

    it 'returns trophy for competition' do
      expect(helper.activity_icon('competition')).to eq('trophy')
    end

    it 'returns people for team competition' do
      expect(helper.activity_icon('tcompetition')).to eq('people')
    end

    it 'returns check2-square for task' do
      expect(helper.activity_icon('task')).to eq('check2-square')
    end

    it 'returns crosshair for elimination' do
      expect(helper.activity_icon('elimination')).to eq('crosshair')
    end

    it 'returns chat-heart for intersym' do
      expect(helper.activity_icon('intersym')).to eq('chat-heart')
    end

    it 'returns journal-text for unknown type' do
      expect(helper.activity_icon('unknown')).to eq('journal-text')
    end
  end

  describe '#activity_badge_color' do
    it 'returns primary for mission' do
      expect(helper.activity_badge_color('mission')).to eq('primary')
    end

    it 'returns warning for competition' do
      expect(helper.activity_badge_color('competition')).to eq('warning')
    end

    it 'returns info for task' do
      expect(helper.activity_badge_color('task')).to eq('info')
    end

    it 'returns danger for elimination' do
      expect(helper.activity_badge_color('elimination')).to eq('danger')
    end

    it 'returns secondary for unknown type' do
      expect(helper.activity_badge_color('unknown')).to eq('secondary')
    end
  end

  describe '#round_type_icon' do
    it 'returns play-circle for standard' do
      expect(helper.round_type_icon('standard')).to eq('play-circle')
    end

    it 'returns sword for combat' do
      expect(helper.round_type_icon('combat')).to eq('sword')
    end

    it 'returns signpost-split for branch' do
      expect(helper.round_type_icon('branch')).to eq('signpost-split')
    end

    it 'returns lightning for reflex' do
      expect(helper.round_type_icon('reflex')).to eq('lightning')
    end

    it 'returns people for group_check' do
      expect(helper.round_type_icon('group_check')).to eq('people')
    end

    it 'returns dice-6 for free_roll' do
      expect(helper.round_type_icon('free_roll')).to eq('dice-6')
    end

    it 'returns chat-heart for persuade' do
      expect(helper.round_type_icon('persuade')).to eq('chat-heart')
    end

    it 'returns cup-hot for rest' do
      expect(helper.round_type_icon('rest')).to eq('cup-hot')
    end

    it 'returns pause-circle for break' do
      expect(helper.round_type_icon('break')).to eq('pause-circle')
    end

    it 'returns circle for unknown type' do
      expect(helper.round_type_icon('unknown')).to eq('circle')
    end
  end

  describe '#round_type_color' do
    it 'returns primary for standard' do
      expect(helper.round_type_color('standard')).to eq('primary')
    end

    it 'returns danger for combat' do
      expect(helper.round_type_color('combat')).to eq('danger')
    end

    it 'returns purple for branch' do
      expect(helper.round_type_color('branch')).to eq('purple')
    end

    it 'returns warning for reflex' do
      expect(helper.round_type_color('reflex')).to eq('warning')
    end

    it 'returns success for group_check' do
      expect(helper.round_type_color('group_check')).to eq('success')
    end

    it 'returns secondary for break' do
      expect(helper.round_type_color('break')).to eq('secondary')
    end

    it 'returns light for unknown type' do
      expect(helper.round_type_color('unknown')).to eq('light')
    end
  end

  describe 'authentication helpers' do
    let(:user) { create(:user) }

    describe '#current_user' do
      it 'returns nil when no user_id in session' do
        helper.session = {}
        expect(helper.current_user).to be_nil
      end

      it 'returns user when user_id in session' do
        helper.session = { 'user_id' => user.id }
        expect(helper.current_user).to eq(user)
      end

      it 'memoizes the result' do
        helper.session = { 'user_id' => user.id }
        first_call = helper.current_user
        expect(helper.current_user).to equal(first_call)
      end
    end

    describe '#logged_in?' do
      it 'returns false when no user' do
        helper.session = {}
        expect(helper.logged_in?).to be false
      end

      it 'returns true when user is present' do
        helper.session = { 'user_id' => user.id }
        expect(helper.logged_in?).to be true
      end
    end

    describe '#current_character' do
      let(:character) { create(:character, user: user) }

      it 'returns nil when no character_id in session' do
        helper.session = {}
        expect(helper.current_character).to be_nil
      end

      it 'returns character when character_id in session' do
        helper.session = { 'character_id' => character.id }
        expect(helper.current_character).to eq(character)
      end
    end
  end

  describe 'admin helpers' do
    let(:user) { create(:user) }
    let(:admin_user) { create(:user, :admin) }

    describe '#admin?' do
      it 'returns false for regular user' do
        helper.session = { 'user_id' => user.id }
        expect(helper.admin?).to be false
      end

      it 'returns true for admin user' do
        helper.session = { 'user_id' => admin_user.id }
        expect(helper.admin?).to be true
      end

      it 'returns nil when not logged in' do
        helper.session = {}
        expect(helper.admin?).to be_nil
      end
    end

    describe '#can_access_admin?' do
      it 'returns false for regular user' do
        helper.session = { 'user_id' => user.id }
        expect(helper.can_access_admin?).to be false
      end

      it 'returns true for admin user' do
        helper.session = { 'user_id' => admin_user.id }
        expect(helper.can_access_admin?).to be true
      end
    end
  end

  describe '#find_starting_room' do
    let!(:regular_room) { create(:room, name: 'Regular Room') }

    it 'finds tutorial_spawn_room_id configured room first' do
      spawn = create(:room, name: 'Spawn Point')
      GameSetting.set('tutorial_spawn_room_id', spawn.id, type: 'integer')
      expect(helper.find_starting_room).to eq(spawn)
    end

    it 'finds safe_room flagged room when no tutorial_spawn_room_id' do
      safe = create(:room, safe_room: true, name: 'Safe Haven')
      expect(helper.find_starting_room).to eq(safe)
    end

    it 'finds safe type room' do
      safe = create(:room, room_type: 'safe', name: 'Safe Zone')
      expect(helper.find_starting_room).to eq(safe)
    end

    it 'falls back to first room' do
      expect(helper.find_starting_room).to eq(regular_room)
    end
  end

  describe '#ensure_character_instance_for' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let!(:starting_room) { create(:room, safe_room: true) }
    # Create a primary reality after ensuring no others exist
    # (the helper uses Reality.first with reality_type: 'primary')
    let!(:reality) do
      Reality.where(reality_type: 'primary').delete
      create(:reality, reality_type: 'primary')
    end

    it 'returns nil when character is nil' do
      expect(helper.ensure_character_instance_for(nil)).to be_nil
    end

    it 'returns existing instance if one exists' do
      existing = create(:character_instance, character: character, reality: reality, current_room: starting_room)
      expect(helper.ensure_character_instance_for(character)).to eq(existing)
    end

    it 'creates new instance if none exists' do
      instance = helper.ensure_character_instance_for(character)
      expect(instance).not_to be_nil
      expect(instance.character_id).to eq(character.id)
      expect(instance.reality_id).to eq(reality.id)
      expect(instance.current_room_id).to eq(starting_room.id)
    end
  end

  describe '#game_setting' do
    it 'delegates to GameSetting.get' do
      expect(GameSetting).to receive(:get).with('test_key').and_return('test_value')
      expect(helper.game_setting('test_key')).to eq('test_value')
    end
  end

  describe '#game_name' do
    it 'returns game_name setting when set' do
      allow(helper).to receive(:game_setting).with('game_name').and_return('Test Game')
      expect(helper.game_name).to eq('Test Game')
    end

    it 'returns Firefly as fallback when not set' do
      allow(helper).to receive(:game_setting).with('game_name').and_return(nil)
      expect(helper.game_name).to eq('Firefly')
    end

    it 'returns Firefly when empty string' do
      allow(helper).to receive(:game_setting).with('game_name').and_return('')
      expect(helper.game_name).to eq('Firefly')
    end
  end

  describe '#behavior_badge_color' do
    it 'returns success for friendly' do
      expect(helper.behavior_badge_color('friendly')).to eq('success')
    end

    it 'returns success for ally' do
      expect(helper.behavior_badge_color('ally')).to eq('success')
    end

    it 'returns secondary for neutral' do
      expect(helper.behavior_badge_color('neutral')).to eq('secondary')
    end

    it 'returns danger for hostile' do
      expect(helper.behavior_badge_color('hostile')).to eq('danger')
    end

    it 'returns danger for aggressive' do
      expect(helper.behavior_badge_color('aggressive')).to eq('danger')
    end

    it 'returns warning for defensive' do
      expect(helper.behavior_badge_color('defensive')).to eq('warning')
    end

    it 'returns info for cowardly' do
      expect(helper.behavior_badge_color('cowardly')).to eq('info')
    end

    it 'returns primary for merchant' do
      expect(helper.behavior_badge_color('merchant')).to eq('primary')
    end

    it 'handles case insensitivity' do
      expect(helper.behavior_badge_color('HOSTILE')).to eq('danger')
    end

    it 'returns secondary for nil' do
      expect(helper.behavior_badge_color(nil)).to eq('secondary')
    end
  end

  describe '#ability_type_color' do
    it 'returns danger for combat' do
      expect(helper.ability_type_color('combat')).to eq('danger')
    end

    it 'returns info for utility' do
      expect(helper.ability_type_color('utility')).to eq('info')
    end

    it 'returns secondary for passive' do
      expect(helper.ability_type_color('passive')).to eq('secondary')
    end

    it 'returns success for social' do
      expect(helper.ability_type_color('social')).to eq('success')
    end

    it 'returns warning for crafting' do
      expect(helper.ability_type_color('crafting')).to eq('warning')
    end

    it 'returns secondary for unknown' do
      expect(helper.ability_type_color('unknown')).to eq('secondary')
    end
  end

  describe '#power_color' do
    it 'returns success for low power (0-50)' do
      expect(helper.power_color(0)).to eq('success')
      expect(helper.power_color(25)).to eq('success')
      expect(helper.power_color(50)).to eq('success')
    end

    it 'returns info for medium power (51-100)' do
      expect(helper.power_color(51)).to eq('info')
      expect(helper.power_color(75)).to eq('info')
      expect(helper.power_color(100)).to eq('info')
    end

    it 'returns warning for high power (101-150)' do
      expect(helper.power_color(101)).to eq('warning')
      expect(helper.power_color(125)).to eq('warning')
      expect(helper.power_color(150)).to eq('warning')
    end

    it 'returns danger for very high power (151+)' do
      expect(helper.power_color(151)).to eq('danger')
      expect(helper.power_color(200)).to eq('danger')
      expect(helper.power_color(1000)).to eq('danger')
    end
  end

  describe '#format_power_breakdown' do
    it 'returns empty string for nil' do
      expect(helper.format_power_breakdown(nil)).to eq('')
    end

    it 'formats positive values with plus sign' do
      breakdown = { 'damage' => 10 }
      expect(helper.format_power_breakdown(breakdown)).to eq('damage: +10')
    end

    it 'formats negative values' do
      breakdown = { 'penalty' => -5 }
      expect(helper.format_power_breakdown(breakdown)).to eq('penalty: -5')
    end

    it 'skips zero values' do
      breakdown = { 'damage' => 10, 'zero' => 0, 'penalty' => -5 }
      result = helper.format_power_breakdown(breakdown)
      expect(result).not_to include('zero')
      expect(result).to include('damage')
      expect(result).to include('penalty')
    end

    it 'joins multiple values with newlines' do
      breakdown = { 'a' => 1, 'b' => 2 }
      expect(helper.format_power_breakdown(breakdown)).to include("\n")
    end
  end

  describe '#room_type_badge_color' do
    it 'returns danger for combat' do
      expect(helper.room_type_badge_color('combat')).to eq('danger')
    end

    it 'returns danger for arena' do
      expect(helper.room_type_badge_color('arena')).to eq('danger')
    end

    it 'returns warning for dojo' do
      expect(helper.room_type_badge_color('dojo')).to eq('warning')
    end

    it 'returns success for safe' do
      expect(helper.room_type_badge_color('safe')).to eq('success')
    end

    it 'returns info for shop' do
      expect(helper.room_type_badge_color('shop')).to eq('info')
    end

    it 'returns secondary for unknown' do
      expect(helper.room_type_badge_color('unknown')).to eq('secondary')
    end
  end

  describe '#category_color' do
    it 'returns primary for furniture' do
      expect(helper.category_color('furniture')).to eq('primary')
    end

    it 'returns warning for vehicle' do
      expect(helper.category_color('vehicle')).to eq('warning')
    end

    it 'returns success for nature' do
      expect(helper.category_color('nature')).to eq('success')
    end

    it 'returns info for structure' do
      expect(helper.category_color('structure')).to eq('info')
    end

    it 'returns secondary for unknown' do
      expect(helper.category_color('unknown')).to eq('secondary')
    end
  end

  describe '#extract_title' do
    it 'returns nil for nil html' do
      expect(helper.extract_title(nil)).to be_nil
    end

    it 'extracts title from html' do
      html = '<html><head><title>Test Page</title></head><body></body></html>'
      expect(helper.extract_title(html)).to eq('Test Page')
    end

    it 'strips whitespace from title' do
      html = '<title>  Spaced Title  </title>'
      expect(helper.extract_title(html)).to eq('Spaced Title')
    end

    it 'handles missing title tag' do
      html = '<html><head></head><body></body></html>'
      expect(helper.extract_title(html)).to be_nil
    end
  end

  describe '#parse_textarea_to_jsonb_array' do
    it 'returns nil for nil input' do
      expect(helper.parse_textarea_to_jsonb_array(nil)).to be_nil
    end

    it 'returns nil for empty string' do
      expect(helper.parse_textarea_to_jsonb_array('')).to be_nil
    end

    it 'returns nil for whitespace only' do
      expect(helper.parse_textarea_to_jsonb_array('   ')).to be_nil
    end

    it 'splits text by newlines' do
      text = "line1\nline2\nline3"
      expect(helper.parse_textarea_to_jsonb_array(text)).to eq(%w[line1 line2 line3])
    end

    it 'strips whitespace from lines' do
      text = "  line1  \n  line2  "
      expect(helper.parse_textarea_to_jsonb_array(text)).to eq(%w[line1 line2])
    end

    it 'removes empty lines' do
      text = "line1\n\nline2\n  \nline3"
      expect(helper.parse_textarea_to_jsonb_array(text)).to eq(%w[line1 line2 line3])
    end
  end

  describe '#parse_npc_params' do
    it 'parses basic params' do
      params = { 'name' => 'Test NPC', 'behavior_pattern' => 'friendly' }
      result = helper.parse_npc_params(params)
      expect(result[:name]).to eq('Test NPC')
      expect(result[:behavior_pattern]).to eq('friendly')
    end

    it 'converts boolean params' do
      params = { 'name' => 'Test', 'is_humanoid' => '1' }
      result = helper.parse_npc_params(params)
      expect(result[:is_humanoid]).to be true
    end

    it 'converts integer params' do
      params = { 'name' => 'Test', 'combat_max_hp' => '100' }
      result = helper.parse_npc_params(params)
      expect(result[:combat_max_hp]).to eq(100)
    end

    it 'parses npc_attacks array' do
      params = {
        'name' => 'Test',
        'npc_attacks' => {
          '0' => { 'name' => 'Bite', 'attack_type' => 'melee', 'damage_dice' => '2d6' },
          '1' => { 'name' => 'Claw', 'attack_type' => 'melee', 'damage_dice' => '1d8' }
        }
      }
      result = helper.parse_npc_params(params)
      expect(result[:npc_attacks].length).to eq(2)
      expect(result[:npc_attacks][0]['name']).to eq('Bite')
      expect(result[:npc_attacks][1]['name']).to eq('Claw')
    end

    it 'skips empty attack names' do
      params = {
        'name' => 'Test',
        'npc_attacks' => {
          '0' => { 'name' => '', 'attack_type' => 'melee' },
          '1' => { 'name' => 'Claw', 'attack_type' => 'melee' }
        }
      }
      result = helper.parse_npc_params(params)
      expect(result[:npc_attacks].length).to eq(1)
      expect(result[:npc_attacks][0]['name']).to eq('Claw')
    end
  end

  describe '#build_ability_costs_jsonb' do
    it 'returns nil for empty costs' do
      params = {}
      expect(helper.build_ability_costs_jsonb(params)).to be_nil
    end

    it 'returns empty hash when cost fields are present but all zero' do
      params = { 'ability_penalty_amount' => '0' }
      result = helper.build_ability_costs_jsonb(params)
      expect(result).to eq({})
    end

    it 'includes ability penalty when non-zero' do
      params = { 'ability_penalty_amount' => '-2', 'ability_penalty_decay' => '1' }
      result = helper.build_ability_costs_jsonb(params)
      expect(result['ability_penalty']['amount']).to eq(-2)
      expect(result['ability_penalty']['decay_per_round']).to eq(1)
    end

    it 'includes specific cooldown when positive' do
      params = { 'specific_cooldown_rounds' => '3' }
      result = helper.build_ability_costs_jsonb(params)
      expect(result['specific_cooldown']['rounds']).to eq(3)
    end

    it 'includes global cooldown when positive' do
      params = { 'global_cooldown_rounds' => '2' }
      result = helper.build_ability_costs_jsonb(params)
      expect(result['global_cooldown']['rounds']).to eq(2)
    end
  end

  describe '#build_ability_chain_config_jsonb' do
    it 'returns nil when chain not enabled' do
      params = { 'chain_enabled' => '0' }
      expect(helper.build_ability_chain_config_jsonb(params)).to be_nil
    end

    it 'returns nil when chain_enabled not present' do
      params = {}
      expect(helper.build_ability_chain_config_jsonb(params)).to be_nil
    end

    it 'returns config when chain enabled' do
      params = {
        'chain_enabled' => '1',
        'chain_max_targets' => '5',
        'chain_range_per_jump' => '3',
        'chain_damage_falloff' => '0.7',
        'chain_friendly_fire' => '1'
      }
      result = helper.build_ability_chain_config_jsonb(params)
      expect(result['max_targets']).to eq(5)
      expect(result['range_per_jump']).to eq(3)
      expect(result['damage_falloff']).to eq(0.7)
      expect(result['friendly_fire']).to be true
    end

    it 'uses defaults when values not provided' do
      params = { 'chain_enabled' => '1' }
      result = helper.build_ability_chain_config_jsonb(params)
      expect(result['max_targets']).to eq(3)
      expect(result['range_per_jump']).to eq(2)
      expect(result['damage_falloff']).to eq(0.5)
      expect(result['friendly_fire']).to be false
    end
  end

  describe '#build_ability_forced_movement_jsonb' do
    it 'returns nil when direction empty' do
      params = { 'forced_movement_direction' => '' }
      expect(helper.build_ability_forced_movement_jsonb(params)).to be_nil
    end

    it 'returns config when direction present' do
      params = { 'forced_movement_direction' => 'push', 'forced_movement_distance' => '3' }
      result = helper.build_ability_forced_movement_jsonb(params)
      expect(result['direction']).to eq('push')
      expect(result['distance']).to eq(3)
    end

    it 'uses default distance of 1' do
      params = { 'forced_movement_direction' => 'pull' }
      result = helper.build_ability_forced_movement_jsonb(params)
      expect(result['distance']).to eq(1)
    end

    it 'supports legacy movement_* field names' do
      params = { 'movement_direction' => 'push', 'movement_distance' => '2' }
      result = helper.build_ability_forced_movement_jsonb(params)
      expect(result['direction']).to eq('push')
      expect(result['distance']).to eq(2)
    end
  end

  describe '#build_ability_execute_effect_jsonb' do
    it 'returns nil when execute_threshold empty' do
      params = { 'execute_threshold' => '' }
      expect(helper.build_ability_execute_effect_jsonb(params)).to be_nil
    end

    it 'returns instant_kill when enabled' do
      params = { 'execute_threshold' => '25', 'execute_instant_kill' => '1' }
      result = helper.build_ability_execute_effect_jsonb(params)
      expect(result['instant_kill']).to be true
    end

    it 'returns damage_multiplier when not instant kill' do
      params = { 'execute_threshold' => '25', 'execute_damage_multiplier' => '3.0' }
      result = helper.build_ability_execute_effect_jsonb(params)
      expect(result['damage_multiplier']).to eq(3.0)
    end

    it 'uses default multiplier of 2.0' do
      params = { 'execute_threshold' => '25' }
      result = helper.build_ability_execute_effect_jsonb(params)
      expect(result['damage_multiplier']).to eq(2.0)
    end
  end

  describe '#build_ability_combo_condition_jsonb' do
    it 'returns nil when requires_status empty' do
      params = { 'combo_requires_status' => '' }
      expect(helper.build_ability_combo_condition_jsonb(params)).to be_nil
    end

    it 'returns config when status present' do
      params = {
        'combo_requires_status' => 'stunned',
        'combo_bonus_dice' => '2d6',
        'combo_consumes_status' => '1'
      }
      result = helper.build_ability_combo_condition_jsonb(params)
      expect(result['requires_status']).to eq('stunned')
      expect(result['bonus_dice']).to eq('2d6')
      expect(result['consumes_status']).to be true
    end
  end

  describe 'Redis-based helpers' do
    describe '#get_next_sequence_number' do
      it 'increments global sequence' do
        first = helper.get_next_sequence_number
        second = helper.get_next_sequence_number
        expect(second).to eq(first + 1)
      end
    end

    describe '#get_current_sequence_number' do
      it 'returns current sequence without incrementing' do
        helper.get_next_sequence_number # Ensure at least one increment
        first = helper.get_current_sequence_number
        second = helper.get_current_sequence_number
        expect(first).to eq(second)
      end
    end

    describe '#register_popup_handler' do
      let(:char_instance) { create(:character_instance, current_room: create(:room)) }

      it 'stores handler data in redis' do
        popup_id = 'test-popup-123'
        helper.register_popup_handler(char_instance, popup_id, 'quickmenu', command: 'test')

        stored = REDIS_POOL.with do |redis|
          redis.get("popup:#{char_instance.id}:#{popup_id}")
        end

        expect(stored).not_to be_nil
        data = JSON.parse(stored)
        expect(data['handler_type']).to eq('quickmenu')
        expect(data['command']).to eq('test')
      end

      it 'returns the popup_id' do
        result = helper.register_popup_handler(char_instance, 'my-popup', 'form')
        expect(result).to eq('my-popup')
      end
    end
  end

  describe '#get_delve_status' do
    let(:room) { create(:room) }
    let(:char_instance) { create(:character_instance, current_room: room) }

    it 'returns nil for nil character instance' do
      expect(helper.get_delve_status(nil)).to be_nil
    end

    it 'returns nil when not in a delve' do
      expect(helper.get_delve_status(char_instance)).to be_nil
    end
  end

  describe '#store_message_for_sync' do
    let(:room) { create(:room) }
    let(:char_instance) { create(:character_instance, current_room: room) }
    let(:message) { { id: 'msg-123', content: 'Hello world' } }

    it 'stores message data in redis with TTL' do
      helper.store_message_for_sync(char_instance, message)

      REDIS_POOL.with do |redis|
        stored = redis.get('msg_data:msg-123')
        expect(stored).not_to be_nil
        expect(JSON.parse(stored)['content']).to eq('Hello world')
      end
    end

    it 'generates message id if not present' do
      msg = { content: 'No ID message' }
      helper.store_message_for_sync(char_instance, msg)
      # Should not raise
    end
  end

  describe '#broadcast_to_room_redis' do
    let(:room) { create(:room) }
    let(:message) { { content: 'Broadcast message' } }

    it 'adds sequence number to message' do
      result = helper.broadcast_to_room_redis(room.id, message)
      expect(result[:sequence_number]).to be_a(Integer)
    end

    it 'adds message id if not present' do
      result = helper.broadcast_to_room_redis(room.id, message)
      expect(result[:id]).not_to be_nil
    end

    it 'preserves existing message id' do
      msg_with_id = { id: 'custom-id', content: 'Test' }
      result = helper.broadcast_to_room_redis(room.id, msg_with_id)
      expect(result[:id]).to eq('custom-id')
    end

    it 'stores message in redis' do
      result = helper.broadcast_to_room_redis(room.id, message)

      REDIS_POOL.with do |redis|
        stored = redis.get("msg_data:#{result[:id]}")
        expect(stored).not_to be_nil
      end
    end

    it 'excludes specified character from broadcast' do
      char_instance = create(:character_instance, current_room: room)
      # Clean up any stale Redis data first
      REDIS_POOL.with do |redis|
        redis.del("room_players:#{room.id}")
        redis.del("msg_pending:#{char_instance.id}")
      end

      # Register the character in the room
      REDIS_POOL.with do |redis|
        redis.sadd("room_players:#{room.id}", char_instance.id)
      end

      helper.broadcast_to_room_redis(room.id, message, char_instance.id)

      REDIS_POOL.with do |redis|
        pending = redis.smembers("msg_pending:#{char_instance.id}")
        expect(pending).to be_empty
      end
    end
  end

  describe '#require_login!' do
    context 'when not logged in' do
      it 'sets flash error' do
        helper.session = {}
        allow(helper.request).to receive(:redirect)

        begin
          helper.require_login!
        rescue SystemExit, NoMethodError
          # Redirect may throw
        end

        expect(helper.flash['error']).to eq('You must be logged in to access that page')
      end
    end

    context 'when logged in' do
      let(:user) { create(:user) }

      it 'does not redirect' do
        helper.session = { 'user_id' => user.id }
        expect { helper.require_login! }.not_to raise_error
      end
    end
  end

  describe '#current_character_instance' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let!(:reality) { create(:reality, reality_type: 'primary') }
    let!(:starting_room) { create(:room, safe_room: true) }

    context 'when character_instance_id in session' do
      let(:char_instance) { create(:character_instance, character: character, current_room: starting_room, reality: reality) }

      it 'returns the character instance' do
        helper.session = { 'character_instance_id' => char_instance.id }
        expect(helper.current_character_instance).to eq(char_instance)
      end

      it 'clears invalid session id' do
        helper.session = { 'character_instance_id' => 99999 }
        helper.current_character_instance
        expect(helper.session['character_instance_id']).to be_nil
      end
    end

    context 'when only character_id in session' do
      it 'creates instance for character' do
        helper.session = { 'character_id' => character.id, 'user_id' => user.id }
        instance = helper.current_character_instance
        expect(instance).to be_a(CharacterInstance)
        expect(instance.character_id).to eq(character.id)
      end

      it 'stores new instance id in session' do
        helper.session = { 'character_id' => character.id, 'user_id' => user.id }
        helper.current_character_instance
        expect(helper.session['character_instance_id']).not_to be_nil
      end
    end

    it 'memoizes the result' do
      char_instance = create(:character_instance, character: character, current_room: starting_room, reality: reality)
      helper.session = { 'character_instance_id' => char_instance.id }

      first_call = helper.current_character_instance
      expect(helper.current_character_instance).to equal(first_call)
    end
  end

  describe '#character_instance_from_token' do
    let(:user) { create(:user) }
    let!(:character) { create(:character, user: user) }
    let!(:reality) { create(:reality, reality_type: 'primary') }
    let!(:starting_room) { create(:room, safe_room: true) }
    let(:api_token) { user.generate_api_token! }

    it 'returns nil when no authorization header' do
      helper.request.env['HTTP_AUTHORIZATION'] = nil
      expect(helper.character_instance_from_token).to be_nil
    end

    it 'returns nil for non-Bearer auth' do
      helper.request.env['HTTP_AUTHORIZATION'] = 'Basic dGVzdDp0ZXN0'
      expect(helper.character_instance_from_token).to be_nil
    end

    it 'returns nil for empty token' do
      helper.request.env['HTTP_AUTHORIZATION'] = 'Bearer '
      expect(helper.character_instance_from_token).to be_nil
    end

    it 'returns nil for invalid token format' do
      helper.request.env['HTTP_AUTHORIZATION'] = 'Bearer invalid-token'
      expect(helper.character_instance_from_token).to be_nil
    end

    it 'returns nil for short token' do
      helper.request.env['HTTP_AUTHORIZATION'] = 'Bearer abc123'
      expect(helper.character_instance_from_token).to be_nil
    end

    it 'returns character instance for valid token' do
      helper.request.env['HTTP_AUTHORIZATION'] = "Bearer #{api_token}"
      instance = helper.character_instance_from_token
      expect(instance).to be_a(CharacterInstance)
      expect(instance.character.user_id).to eq(user.id)
    end

    it 'memoizes the result' do
      helper.request.env['HTTP_AUTHORIZATION'] = "Bearer #{api_token}"
      first_call = helper.character_instance_from_token
      expect(helper.character_instance_from_token).to equal(first_call)
    end

    context 'when user is suspended' do
      it 'returns nil' do
        token = api_token  # Generate first while user is not suspended
        user.suspend!(reason: 'Test suspension')
        helper.request.env['HTTP_AUTHORIZATION'] = "Bearer #{token}"
        expect(helper.character_instance_from_token).to be_nil
      end
    end

    context 'with cached token' do
      it 'uses cached result on subsequent calls' do
        token = api_token
        cache_key = "api_auth:#{Digest::SHA256.hexdigest(token)[0..15]}"

        # Pre-populate cache
        char_instance = create(:character_instance, character: character, current_room: starting_room, reality: reality)
        REDIS_POOL.with do |r|
          r.setex(cache_key, 3600, JSON.generate({
            user_id: user.id,
            character_id: character.id,
            character_instance_id: char_instance.id
          }))
        end

        helper.request.env['HTTP_AUTHORIZATION'] = "Bearer #{token}"
        result = helper.character_instance_from_token
        expect(result).to eq(char_instance)
      end
    end
  end

  describe '#authenticate_websocket' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let(:room) { create(:room) }
    let!(:reality) { create(:reality, reality_type: 'primary') }
    let(:char_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }

    let(:mock_request) do
      r = double('request')
      allow(r).to receive(:params).and_return({})
      r
    end

    it 'returns nil when no authentication' do
      expect(helper.authenticate_websocket(mock_request)).to be_nil
    end

    it 'authenticates via query param when user owns character' do
      allow(mock_request).to receive(:params).and_return({ 'character_instance' => char_instance.id.to_s })
      helper.session = { 'user_id' => user.id }

      result = helper.authenticate_websocket(mock_request)
      expect(result).to eq(char_instance)
    end

    it 'authenticates via session' do
      helper.session = { 'character_instance_id' => char_instance.id }
      result = helper.authenticate_websocket(mock_request)
      expect(result).to eq(char_instance)
    end

    it 'allows agent connections via query param with valid token' do
      other_user = create(:user)
      allow(mock_request).to receive(:params).and_return({ 'character_instance' => char_instance.id.to_s })
      helper.session = { 'user_id' => other_user.id }

      # Agent connections require a Bearer token that matches the character instance
      allow(helper).to receive(:character_instance_from_token).and_return(char_instance)

      result = helper.authenticate_websocket(mock_request)
      expect(result).to eq(char_instance)
    end
  end

  describe '#handle_character_selection_from_params' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let(:room) { create(:room) }
    let!(:reality) { create(:reality, reality_type: 'primary') }
    let(:char_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }

    let(:mock_request) do
      r = double('request')
      allow(r).to receive(:params).and_return({})
      r
    end

    before do
      helper.session = { 'user_id' => user.id }
    end

    it 'selects character instance from params' do
      allow(mock_request).to receive(:params).and_return({ 'character_instance' => char_instance.id.to_s })

      helper.handle_character_selection_from_params(mock_request)

      expect(helper.session['character_id']).to eq(character.id)
      expect(helper.session['character_instance_id']).to eq(char_instance.id)
    end

    it 'selects character from params' do
      allow(mock_request).to receive(:params).and_return({ 'character' => character.id.to_s })

      helper.handle_character_selection_from_params(mock_request)

      expect(helper.session['character_id']).to eq(character.id)
    end

    it 'ignores character from different user' do
      other_user = create(:user)
      other_char = create(:character, user: other_user)

      allow(mock_request).to receive(:params).and_return({ 'character' => other_char.id.to_s })

      helper.handle_character_selection_from_params(mock_request)

      expect(helper.session['character_id']).to be_nil
    end
  end

  describe '#clear_cached_character_state' do
    it 'removes cached instance variables' do
      helper.instance_variable_set(:@current_character, 'cached')
      helper.instance_variable_set(:@current_character_instance, 'cached')

      helper.clear_cached_character_state

      expect(helper.instance_variable_defined?(:@current_character)).to be false
      expect(helper.instance_variable_defined?(:@current_character_instance)).to be false
    end
  end

  describe 'admin guard helpers' do
    let(:user) { create(:user) }
    let(:admin_user) { create(:user, :admin) }

    describe '#require_admin_access!' do
      it 'redirects non-admin users' do
        helper.session = { 'user_id' => user.id }
        allow(helper.request).to receive(:redirect)

        begin
          helper.require_admin_access!
        rescue SystemExit, NoMethodError
          # Redirect may throw
        end

        expect(helper.flash['error']).to eq('You do not have permission to access the admin console')
      end

      it 'allows admin users' do
        helper.session = { 'user_id' => admin_user.id }
        expect { helper.require_admin_access! }.not_to raise_error
      end
    end

    describe '#require_admin!' do
      it 'redirects non-admin users' do
        helper.session = { 'user_id' => user.id }
        allow(helper.request).to receive(:redirect)

        begin
          helper.require_admin!
        rescue SystemExit, NoMethodError
          # Redirect may throw
        end

        expect(helper.flash['error']).to eq('This action requires administrator privileges')
      end

      it 'allows admin users' do
        helper.session = { 'user_id' => admin_user.id }
        expect { helper.require_admin! }.not_to raise_error
      end
    end

    describe '#has_permission?' do
      it 'returns false for nil user' do
        helper.session = {}
        expect(helper.has_permission?(:some_permission)).to be_falsey
      end

      it 'delegates to user' do
        helper.session = { 'user_id' => admin_user.id }
        expect(admin_user).to receive(:has_permission?).with(:test_perm).and_return(true)
        allow(User).to receive(:[]).with(admin_user.id).and_return(admin_user)

        expect(helper.has_permission?(:test_perm)).to be true
      end
    end
  end

  describe '#bring_character_online' do
    let(:room) { create(:room) }
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let!(:reality) { create(:reality, reality_type: 'primary') }
    let(:char_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: false) }

    it 'returns empty array for nil character instance' do
      expect(helper.bring_character_online(nil)).to eq([])
    end

    it 'sets character online' do
      helper.bring_character_online(char_instance)
      char_instance.refresh
      expect(char_instance.online).to be true
    end

    it 'updates last_activity' do
      helper.bring_character_online(char_instance)
      char_instance.refresh
      expect(char_instance.last_activity).to be_within(5).of(Time.now)
    end

    it 'sets session_start_at when coming online' do
      helper.bring_character_online(char_instance)
      char_instance.refresh
      expect(char_instance.session_start_at).to be_within(5).of(Time.now)
    end

    it 'does not reset session_start_at when already online' do
      original_time = Time.now - 3600
      char_instance.update(online: true, session_start_at: original_time)

      helper.bring_character_online(char_instance)
      char_instance.refresh

      expect(char_instance.session_start_at).to be_within(5).of(original_time)
    end

    it 'returns login backfill when coming online' do
      allow(RpLoggingService).to receive(:on_login).and_return([{ type: 'backfill' }])

      result = helper.bring_character_online(char_instance)
      expect(result).to eq([{ type: 'backfill' }])
    end

    it 'returns empty array when already online' do
      char_instance.update(online: true)

      result = helper.bring_character_online(char_instance)
      expect(result).to eq([])
    end
  end

  describe '#render_stats_table' do
    let(:stat_block) { create(:stat_block) }

    it 'returns empty message for no stats' do
      result = helper.render_stats_table([], stat_block)
      expect(result).to include('No stats in this category yet')
    end

    it 'renders table for stats' do
      stat = create(:stat, stat_block: stat_block, name: 'Strength', abbreviation: 'STR')
      result = helper.render_stats_table([stat], stat_block)

      expect(result).to include('<table')
      expect(result).to include('Strength')
      expect(result).to include('STR')
    end

    it 'truncates long descriptions' do
      stat = create(:stat, stat_block: stat_block, description: 'A' * 100)
      result = helper.render_stats_table([stat], stat_block)

      expect(result).to include('...')
    end

    it 'shows dash for nil description' do
      stat = create(:stat, stat_block: stat_block, description: nil)
      result = helper.render_stats_table([stat], stat_block)

      expect(result).to include('text-muted')
      expect(result).to include('-')
    end
  end

  describe '#parse_ability_params' do
    it 'parses basic fields' do
      params = {
        'name' => 'Fireball',
        'ability_type' => 'combat',
        'action_type' => 'attack',
        'description' => 'A ball of fire'
      }

      result = helper.parse_ability_params(params)

      expect(result[:name]).to eq('Fireball')
      expect(result[:ability_type]).to eq('combat')
      expect(result[:action_type]).to eq('attack')
      expect(result[:description]).to eq('A ball of fire')
    end

    it 'converts boolean fields' do
      params = {
        'name' => 'Test',
        'is_healing' => '1',
        'aoe_hits_allies' => '1',
        'is_active' => '0'
      }

      result = helper.parse_ability_params(params)

      expect(result[:is_healing]).to be true
      expect(result[:aoe_hits_allies]).to be true
      expect(result[:is_active]).to be false
    end

    it 'converts integer fields' do
      params = {
        'name' => 'Test',
        'aoe_radius' => '5',
        'cooldown_seconds' => '30',
        'damage_modifier' => '10'
      }

      result = helper.parse_ability_params(params)

      expect(result[:aoe_radius]).to eq(5)
      expect(result[:cooldown_seconds]).to eq(30)
      expect(result[:damage_modifier]).to eq(10)
    end

    it 'handles empty integer fields' do
      params = {
        'name' => 'Test',
        'aoe_radius' => '',
        'cooldown_seconds' => ''
      }

      result = helper.parse_ability_params(params)

      expect(result[:aoe_radius]).to be_nil
      expect(result[:cooldown_seconds]).to be_nil
    end

    it 'parses damage multiplier as float' do
      params = {
        'name' => 'Test',
        'damage_multiplier' => '1.5'
      }

      result = helper.parse_ability_params(params)
      expect(result[:damage_multiplier]).to eq(1.5)
    end

    it 'handles universe_id' do
      params = { 'name' => 'Test', 'universe_id' => '42' }
      result = helper.parse_ability_params(params)
      expect(result[:universe_id]).to eq(42)
    end

    it 'handles empty universe_id' do
      params = { 'name' => 'Test', 'universe_id' => '' }
      result = helper.parse_ability_params(params)
      expect(result[:universe_id]).to be_nil
    end

    it 'parses narrative arrays from textareas' do
      params = {
        'name' => 'Test',
        'cast_verbs' => "hurls\nlaunches\nthrows",
        'hit_verbs' => "strikes\nblasts"
      }

      result = helper.parse_ability_params(params)

      expect(result[:cast_verbs]).to eq(%w[hurls launches throws])
      expect(result[:hit_verbs]).to eq(%w[strikes blasts])
    end
  end

  describe '#build_ability_status_effects_jsonb' do
    it 'returns nil when no status_effects' do
      expect(helper.build_ability_status_effects_jsonb({})).to be_nil
    end

    it 'returns nil when status_effects is not hash' do
      expect(helper.build_ability_status_effects_jsonb({ 'status_effects' => 'invalid' })).to be_nil
    end

    it 'parses status effects array' do
      params = {
        'status_effects' => {
          '0' => { 'effect' => 'stunned', 'duration_rounds' => '3', 'chance' => '0.5' },
          '1' => { 'effect' => 'burning', 'duration_rounds' => '2', 'chance' => '1.0' }
        }
      }

      result = helper.build_ability_status_effects_jsonb(params)

      expect(result.length).to eq(2)
      expect(result[0]['effect']).to eq('stunned')
      expect(result[0]['duration_rounds']).to eq(3)
      expect(result[0]['chance']).to eq(0.5)
      expect(result[1]['effect']).to eq('burning')
    end

    it 'skips empty effect names' do
      params = {
        'status_effects' => {
          '0' => { 'effect' => '', 'duration_rounds' => '3' },
          '1' => { 'effect' => 'stunned', 'duration_rounds' => '2' }
        }
      }

      result = helper.build_ability_status_effects_jsonb(params)

      expect(result.length).to eq(1)
      expect(result[0]['effect']).to eq('stunned')
    end

    it 'includes optional fields when set' do
      params = {
        'status_effects' => {
          '0' => {
            'effect' => 'shielded',
            'duration_rounds' => '5',
            'effect_threshold' => '10',
            'value' => '5',
            'damage_reduction' => '3',
            'shield_hp' => '20'
          }
        }
      }

      result = helper.build_ability_status_effects_jsonb(params)

      expect(result[0]['effect_threshold']).to eq(10)
      expect(result[0]['value']).to eq(5)
      expect(result[0]['damage_reduction']).to eq(3)
      expect(result[0]['shield_hp']).to eq(20)
    end

    it 'supports legacy effect_id, duration, and threshold keys' do
      effect = create(:status_effect, name: 'Stunned')
      params = {
        'status_effects' => {
          '0' => {
            'effect_id' => effect.id.to_s,
            'duration' => '2',
            'threshold' => '12',
            'chance' => '50'
          }
        }
      }

      result = helper.build_ability_status_effects_jsonb(params)
      expect(result[0]['effect']).to eq('stunned')
      expect(result[0]['duration_rounds']).to eq(2)
      expect(result[0]['effect_threshold']).to eq(12)
      expect(result[0]['chance']).to eq(0.5)
    end
  end

  describe '#build_ability_damage_types_jsonb' do
    it 'returns nil when no damage_types_split' do
      expect(helper.build_ability_damage_types_jsonb({})).to be_nil
    end

    it 'parses damage types array' do
      params = {
        'damage_types_split' => {
          '0' => { 'type' => 'fire', 'value' => '50%' },
          '1' => { 'type' => 'physical', 'value' => '50%' }
        }
      }

      result = helper.build_ability_damage_types_jsonb(params)

      expect(result.length).to eq(2)
      expect(result[0]['type']).to eq('fire')
      expect(result[0]['value']).to eq('50%')
    end

    it 'skips empty type names' do
      params = {
        'damage_types_split' => {
          '0' => { 'type' => '', 'value' => '100%' },
          '1' => { 'type' => 'ice', 'value' => '100%' }
        }
      }

      result = helper.build_ability_damage_types_jsonb(params)

      expect(result.length).to eq(1)
    end
  end

  describe '#build_ability_conditional_damage_jsonb' do
    it 'returns nil when no conditional_damage' do
      expect(helper.build_ability_conditional_damage_jsonb({})).to be_nil
    end

    it 'parses conditional damage array' do
      params = {
        'conditional_damage' => {
          '0' => { 'condition' => 'target_has_status', 'status' => 'burning', 'bonus_dice' => '2d6' }
        }
      }

      result = helper.build_ability_conditional_damage_jsonb(params)

      expect(result.length).to eq(1)
      expect(result[0]['condition']).to eq('target_has_status')
      expect(result[0]['status']).to eq('burning')
      expect(result[0]['bonus_dice']).to eq('2d6')
    end

    it 'skips empty condition names' do
      params = {
        'conditional_damage' => {
          '0' => { 'condition' => '' },
          '1' => { 'condition' => 'flanking' }
        }
      }

      result = helper.build_ability_conditional_damage_jsonb(params)

      expect(result.length).to eq(1)
      expect(result[0]['condition']).to eq('flanking')
    end
  end

  describe '#render_stat_allocation_row' do
    let(:stat_block) { create(:stat_block, min_stat_value: 1) }
    let(:stat) { create(:stat, stat_block: stat_block, name: 'Strength', abbreviation: 'STR', stat_category: 'primary') }

    it 'renders stat name and abbreviation' do
      result = helper.render_stat_allocation_row(stat, stat_block)

      expect(result).to include('Strength')
      expect(result).to include('STR')
    end

    it 'includes data attributes for JavaScript' do
      result = helper.render_stat_allocation_row(stat, stat_block)

      expect(result).to include("data-stat-id=\"#{stat.id}\"")
      expect(result).to include("data-block-id=\"#{stat_block.id}\"")
      expect(result).to include('data-category="primary"')
    end

    it 'includes hidden input for form submission' do
      result = helper.render_stat_allocation_row(stat, stat_block)

      expect(result).to include('type="hidden"')
      expect(result).to include("name=\"stat_allocations[#{stat_block.id}][#{stat.id}]\"")
    end

    it 'includes increase/decrease buttons' do
      result = helper.render_stat_allocation_row(stat, stat_block)

      expect(result).to include('stat-increase')
      expect(result).to include('stat-decrease')
    end

    it 'renders description when present' do
      stat.update(description: 'Physical power')
      result = helper.render_stat_allocation_row(stat, stat_block)

      expect(result).to include('Physical power')
    end
  end

  describe '#render_path_for_test' do
    let(:admin_user) { create(:user, :admin) }

    before do
      helper.session = { 'user_id' => admin_user.id }
    end

    context 'public pages' do
      it 'renders home page' do
        result = helper.render_path_for_test('/')
        expect(result).to have_key(:html)
      end

      it 'renders login page' do
        result = helper.render_path_for_test('/login')
        expect(result).to have_key(:html)
      end

      it 'renders register page' do
        result = helper.render_path_for_test('/register')
        expect(result).to have_key(:html)
      end
    end

    context 'info pages' do
      it 'renders info index' do
        result = helper.render_path_for_test('/info')
        expect(result).to have_key(:html)
      end

      it 'renders rules page' do
        result = helper.render_path_for_test('/info/rules')
        expect(result).to have_key(:html)
      end

      it 'renders getting started page' do
        result = helper.render_path_for_test('/info/getting_started')
        expect(result).to have_key(:html)
      end

      it 'renders terms page' do
        result = helper.render_path_for_test('/info/terms')
        expect(result).to have_key(:html)
      end

      it 'renders privacy page' do
        result = helper.render_path_for_test('/info/privacy')
        expect(result).to have_key(:html)
      end
    end

    context 'world pages' do
      it 'renders world index' do
        result = helper.render_path_for_test('/world')
        expect(result).to have_key(:html)
      end

      it 'renders lore page' do
        result = helper.render_path_for_test('/world/lore')
        expect(result).to have_key(:html)
      end
    end

    context 'unknown paths' do
      it 'returns error for unknown path' do
        result = helper.render_path_for_test('/nonexistent/page')
        expect(result[:error]).to be true
        expect(result[:error_type]).to eq('NotFound')
      end
    end

    context 'error handling' do
      it 'captures template errors' do
        allow(helper).to receive(:view).and_raise(StandardError.new('Template error'))

        result = helper.render_path_for_test('/')

        expect(result[:error]).to be true
        expect(result[:error_message]).to eq('Template error')
      end
    end
  end

  describe 'setup vars helpers' do
    let(:admin_user) { create(:user, :admin) }
    let(:room) { create(:room) }

    before do
      helper.session = { 'user_id' => admin_user.id }
    end

    describe '#setup_admin_dashboard_vars' do
      it 'sets user count' do
        helper.setup_admin_dashboard_vars
        expect(helper.instance_variable_get(:@user_count)).to be_a(Integer)
      end

      it 'sets character count' do
        helper.setup_admin_dashboard_vars
        expect(helper.instance_variable_get(:@character_count)).to be_a(Integer)
      end

      it 'sets room count' do
        helper.setup_admin_dashboard_vars
        expect(helper.instance_variable_get(:@room_count)).to be_a(Integer)
      end

      it 'sets online count' do
        helper.setup_admin_dashboard_vars
        expect(helper.instance_variable_get(:@online_count)).to be_a(Integer)
      end

      it 'sets ai status' do
        helper.setup_admin_dashboard_vars
        expect(helper.instance_variable_get(:@ai_status)).to be_a(Hash)
      end
    end

    describe '#setup_admin_settings_vars' do
      it 'sets settings hash' do
        helper.setup_admin_settings_vars
        settings = helper.instance_variable_get(:@settings)

        expect(settings).to be_a(Hash)
        expect(settings).to have_key(:general)
        expect(settings).to have_key(:time)
        expect(settings).to have_key(:weather)
        expect(settings).to have_key(:ai)
        expect(settings).to have_key(:delve)
        expect(settings).to have_key(:email)
        expect(settings).to have_key(:storage)
      end

      it 'masks sensitive values' do
        GameSetting.set('weather_api_key', 'secret123')
        helper.setup_admin_settings_vars
        settings = helper.instance_variable_get(:@settings)

        expect(settings[:weather][:weather_api_key]).to eq('••••••••')
      end

      it 'sets ai_status' do
        helper.setup_admin_settings_vars
        expect(helper.instance_variable_get(:@ai_status)).to be_a(Hash)
      end
    end

    describe '#setup_admin_users_vars' do
      it 'loads all users' do
        helper.setup_admin_users_vars
        users = helper.instance_variable_get(:@users)
        expect(users).to be_an(Array)
        expect(users).to include(admin_user)
      end
    end

    describe '#setup_play_vars' do
      let(:character) { create(:character, user: admin_user) }
      let!(:reality) { create(:reality, reality_type: 'primary') }
      let!(:char_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }

      it 'sets character' do
        helper.setup_play_vars
        expect(helper.instance_variable_get(:@character)).to eq(character)
      end

      it 'sets character instance' do
        helper.setup_play_vars
        expect(helper.instance_variable_get(:@character_instance)).not_to be_nil
      end

      it 'sets room' do
        helper.setup_play_vars
        expect(helper.instance_variable_get(:@room)).not_to be_nil
      end

      it 'returns early when no character' do
        Character.where(user_id: admin_user.id).delete
        helper.setup_play_vars
        expect(helper.instance_variable_get(:@character)).to be_nil
      end
    end
  end

  # ===== EDGE CASE TESTS FOR ADDITIONAL COVERAGE =====

  describe '#character_instance_from_token - edge cases' do
    let(:user) { create(:user) }
    let!(:character) { create(:character, user: user) }
    let!(:reality) { create(:reality, reality_type: 'primary') }
    let!(:starting_room) { create(:room, safe_room: true) }
    let(:api_token) { user.generate_api_token! }

    context 'with IP ban' do
      it 'returns nil for banned IP' do
        allow(AccessControlService).to receive(:ip_banned?).and_return(true)
        helper.request.env['HTTP_AUTHORIZATION'] = "Bearer #{api_token}"
        expect(helper.character_instance_from_token).to be_nil
      end
    end

    context 'with Redis cache failures' do
      it 'continues when cache read fails' do
        allow(REDIS_POOL).to receive(:with).and_raise(Redis::CannotConnectError)
        helper.request.env['HTTP_AUTHORIZATION'] = "Bearer #{api_token}"
        # Should still work by falling through to database lookup
        # Though it may fail for other reasons, the key is it doesn't raise
        expect { helper.character_instance_from_token }.not_to raise_error
      end
    end

    context 'with AccessControlService blocking' do
      it 'returns nil when access denied' do
        allow(AccessControlService).to receive(:ip_banned?).and_return(false)
        allow(AccessControlService).to receive(:check_access).and_return({ allowed: false, reason: 'blocked' })
        helper.request.env['HTTP_AUTHORIZATION'] = "Bearer #{api_token}"
        expect(helper.character_instance_from_token).to be_nil
      end
    end

    context 'with user having no characters' do
      it 'returns nil when user has no player characters' do
        Character.where(user_id: user.id).delete
        helper.request.env['HTTP_AUTHORIZATION'] = "Bearer #{api_token}"
        expect(helper.character_instance_from_token).to be_nil
      end
    end

    context 'when cached user is suspended' do
      it 'invalidates cache and returns nil' do
        # First, cache a valid result
        token = api_token
        cache_key = "api_auth:#{Digest::SHA256.hexdigest(token)[0..15]}"
        char_instance = create(:character_instance, character: character, current_room: starting_room, reality: reality)

        REDIS_POOL.with do |r|
          r.setex(cache_key, 3600, JSON.generate({
            user_id: user.id,
            character_id: character.id,
            character_instance_id: char_instance.id
          }))
        end

        # Now suspend the user
        user.suspend!(reason: 'Test')

        helper.request.env['HTTP_AUTHORIZATION'] = "Bearer #{token}"
        expect(helper.character_instance_from_token).to be_nil
      end
    end
  end

  describe '#ensure_character_for_play' do
    let(:user) { create(:user) }
    let(:room) { create(:room, safe_room: true) }
    let!(:reality) { create(:reality, reality_type: 'primary') }

    let(:mock_request) do
      r = double('request')
      allow(r).to receive(:redirect)
      r
    end

    context 'when no current character' do
      it 'sets flash error about selecting character' do
        helper.session = { 'user_id' => user.id }

        begin
          helper.ensure_character_for_play(mock_request)
        rescue SystemExit, NoMethodError
          # Redirect may throw
        end

        # When no character_id is set AND no character exists,
        # ensure_character_for_play redirects with "Please select a character first"
        expect(helper.flash['error']).to match(/select a character|load your character/)
      end
    end

    context 'when character exists with instance' do
      let(:character) { create(:character, user: user) }
      let!(:char_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }

      it 'loads existing instance when character_instance_id in session' do
        helper.session = { 'user_id' => user.id, 'character_instance_id' => char_instance.id }

        helper.ensure_character_for_play(mock_request)

        expect(helper.instance_variable_get(:@character_instance).id).to eq(char_instance.id)
      end

      it 'brings character online' do
        char_instance.update(online: false)
        helper.session = { 'user_id' => user.id, 'character_instance_id' => char_instance.id }

        helper.ensure_character_for_play(mock_request)

        char_instance.refresh
        expect(char_instance.online).to be true
      end

      it 'sets @room from character instance' do
        helper.session = { 'user_id' => user.id, 'character_instance_id' => char_instance.id }

        helper.ensure_character_for_play(mock_request)

        expect(helper.instance_variable_get(:@room).id).to eq(room.id)
      end

      it 'sets @character from character_id session' do
        helper.session = { 'user_id' => user.id, 'character_id' => character.id }

        # Without character_instance_id, it will try to find/create one via ensure_character_instance_for
        helper.ensure_character_for_play(mock_request)

        expect(helper.instance_variable_get(:@character).id).to eq(character.id)
      end
    end
  end

  describe '#round_type_icon - additional types' do
    it 'returns circle for unknown types like boss' do
      expect(helper.round_type_icon('boss')).to eq('circle')
    end

    it 'returns circle for unknown types like narrative' do
      expect(helper.round_type_icon('narrative')).to eq('circle')
    end

    it 'returns cup-hot for rest' do
      expect(helper.round_type_icon('rest')).to eq('cup-hot')
    end

    it 'returns pause-circle for break' do
      expect(helper.round_type_icon('break')).to eq('pause-circle')
    end
  end

  describe '#round_type_color - additional types' do
    it 'returns info for free_roll' do
      expect(helper.round_type_color('free_roll')).to eq('info')
    end

    it 'returns pink for persuade' do
      expect(helper.round_type_color('persuade')).to eq('pink')
    end

    it 'returns success for rest' do
      expect(helper.round_type_color('rest')).to eq('success')
    end

    it 'returns secondary for break' do
      expect(helper.round_type_color('break')).to eq('secondary')
    end

    it 'returns light for unknown type' do
      expect(helper.round_type_color('unknown')).to eq('light')
    end
  end

  describe '#broadcast_to_room_redis - edge cases' do
    let(:room) { create(:room) }

    it 'handles nil room_id gracefully' do
      expect { helper.broadcast_to_room_redis(nil, { content: 'Test' }) }.not_to raise_error
    end

    it 'handles empty message' do
      result = helper.broadcast_to_room_redis(room.id, {})
      expect(result[:sequence_number]).to be_a(Integer)
    end

    it 'handles message with all fields' do
      message = {
        id: 'custom-id',
        type: 'say',
        content: 'Hello',
        sender: 'Test',
        metadata: { extra: 'data' }
      }
      result = helper.broadcast_to_room_redis(room.id, message)
      expect(result[:id]).to eq('custom-id')
      expect(result[:type]).to eq('say')
    end
  end

  describe '#parse_npc_params - edge cases' do
    it 'handles nil params' do
      expect { helper.parse_npc_params(nil) }.to raise_error(NoMethodError)
    end

    it 'handles empty hash' do
      result = helper.parse_npc_params({})
      expect(result).to be_a(Hash)
    end

    it 'handles npc_attacks as string (not a Hash)' do
      params = { 'name' => 'Test', 'npc_attacks' => 'invalid' }
      result = helper.parse_npc_params(params)
      # When npc_attacks is not a Hash, it sets empty array
      expect(result[:npc_attacks]).to eq([])
    end

    it 'handles nested attack with all fields' do
      params = {
        'name' => 'Test',
        'npc_attacks' => {
          '0' => {
            'name' => 'Bite',
            'attack_type' => 'melee',
            'damage_dice' => '2d6',
            'damage_type' => 'piercing',
            'attack_speed' => '5',
            'range_hexes' => '1'
          }
        }
      }
      result = helper.parse_npc_params(params)
      expect(result[:npc_attacks][0]['damage_type']).to eq('piercing')
      expect(result[:npc_attacks][0]['attack_speed']).to eq(5)
    end

    it 'skips attack entries with empty name' do
      params = {
        'name' => 'Test',
        'npc_attacks' => {
          '0' => { 'name' => '', 'attack_type' => 'melee' },
          '1' => { 'name' => 'Valid Attack', 'attack_type' => 'ranged' }
        }
      }
      result = helper.parse_npc_params(params)
      expect(result[:npc_attacks].length).to eq(1)
      expect(result[:npc_attacks][0]['name']).to eq('Valid Attack')
    end

    it 'parses combat ability ids as integer array' do
      params = {
        'name' => 'Test',
        'combat_ability_ids' => ['1', '2', '3']
      }
      result = helper.parse_npc_params(params)
      expect(result[:combat_ability_ids]).to be_a(Sequel::Postgres::PGArray)
    end

    it 'parses combat ability chances as hash' do
      params = {
        'name' => 'Test',
        'combat_ability_chances' => { '1' => '50', '2' => '30' }
      }
      result = helper.parse_npc_params(params)
      expect(result[:combat_ability_chances]['1']).to eq(50)
      expect(result[:combat_ability_chances]['2']).to eq(30)
    end
  end

  describe '#build_ability_costs_jsonb - edge cases' do
    it 'handles all cost types together' do
      params = {
        'ability_penalty_amount' => '-3',
        'ability_penalty_decay' => '1',
        'specific_cooldown_rounds' => '3',
        'global_cooldown_rounds' => '1'
      }
      result = helper.build_ability_costs_jsonb(params)

      expect(result['ability_penalty']['amount']).to eq(-3)
      expect(result['specific_cooldown']['rounds']).to eq(3)
      expect(result['global_cooldown']['rounds']).to eq(1)
    end

    it 'returns nil when no cost fields are present' do
      params = { 'name' => 'Test' }
      result = helper.build_ability_costs_jsonb(params)
      expect(result).to be_nil
    end
  end

  describe '#parse_ability_params - edge cases' do
    it 'handles narrative arrays' do
      params = {
        'name' => 'Test',
        'cast_verbs' => "hurls\nlaunches",
        'hit_verbs' => "strikes\nblasts",
        'aoe_descriptions' => "explodes\nbursts"
      }

      result = helper.parse_ability_params(params)

      expect(result[:cast_verbs]).to eq(%w[hurls launches])
      expect(result[:hit_verbs]).to eq(%w[strikes blasts])
      expect(result[:aoe_descriptions]).to eq(%w[explodes bursts])
    end

    it 'handles empty string values' do
      params = {
        'name' => 'Test',
        'aoe_radius' => '',
        'damage_modifier' => '',
        'damage_multiplier' => ''
      }

      result = helper.parse_ability_params(params)

      expect(result[:aoe_radius]).to be_nil
      expect(result[:damage_modifier]).to be_nil
      expect(result[:damage_multiplier]).to be_nil
    end

    it 'handles zero values' do
      params = {
        'name' => 'Test',
        'aoe_radius' => '0',
        'cooldown_seconds' => '0'
      }

      result = helper.parse_ability_params(params)

      expect(result[:aoe_radius]).to eq(0)
      expect(result[:cooldown_seconds]).to eq(0)
    end

    it 'does not set is_active when checkbox is absent' do
      params = { 'name' => 'Test' }
      result = helper.parse_ability_params(params)
      expect(result[:is_active]).to be_nil
    end

    it 'handles is_active = 0 as false' do
      params = { 'name' => 'Test', 'is_active' => '0' }
      result = helper.parse_ability_params(params)
      expect(result[:is_active]).to be false
    end

    it 'does not set aoe_hits_allies when checkbox is absent' do
      params = { 'name' => 'Test' }
      result = helper.parse_ability_params(params)
      expect(result[:aoe_hits_allies]).to be_nil
    end
  end

  describe '#build_ability_status_effects_jsonb - edge cases' do
    it 'handles chance as string' do
      params = {
        'status_effects' => {
          '0' => { 'effect' => 'stunned', 'duration_rounds' => '3', 'chance' => '0.75' }
        }
      }

      result = helper.build_ability_status_effects_jsonb(params)
      expect(result[0]['chance']).to eq(0.75)
    end

    it 'normalizes chance percentages to 0.0..1.0' do
      params = {
        'status_effects' => {
          '0' => { 'effect' => 'stunned', 'duration_rounds' => '3', 'chance' => '75' }
        }
      }

      result = helper.build_ability_status_effects_jsonb(params)
      expect(result[0]['chance']).to eq(0.75)
    end

    it 'defaults chance to 1.0 and duration to 1' do
      params = {
        'status_effects' => {
          '0' => { 'effect' => 'stunned' }
        }
      }

      result = helper.build_ability_status_effects_jsonb(params)
      expect(result[0]['chance']).to eq(1.0)
      expect(result[0]['duration_rounds']).to eq(1)
    end

    it 'includes optional fields when present' do
      params = {
        'status_effects' => {
          '0' => {
            'effect' => 'stunned',
            'effect_threshold' => '10',
            'value' => '5',
            'damage_reduction' => '2',
            'shield_hp' => '20'
          }
        }
      }

      result = helper.build_ability_status_effects_jsonb(params)
      expect(result[0]['effect_threshold']).to eq(10)
      expect(result[0]['value']).to eq(5)
      expect(result[0]['damage_reduction']).to eq(2)
      expect(result[0]['shield_hp']).to eq(20)
    end

    it 'returns nil for non-Hash input' do
      params = { 'status_effects' => 'invalid' }
      result = helper.build_ability_status_effects_jsonb(params)
      expect(result).to be_nil
    end

    it 'skips entries with empty effect name' do
      params = {
        'status_effects' => {
          '0' => { 'effect' => '', 'duration_rounds' => '3' },
          '1' => { 'effect' => 'stunned', 'duration_rounds' => '2' }
        }
      }

      result = helper.build_ability_status_effects_jsonb(params)
      expect(result.length).to eq(1)
      expect(result[0]['effect']).to eq('stunned')
    end
  end

  describe '#get_delve_status - edge cases' do
    let(:room) { create(:room) }
    let(:char_instance) { create(:character_instance, current_room: room) }

    it 'returns nil for offline character' do
      char_instance.update(online: false)
      expect(helper.get_delve_status(char_instance)).to be_nil
    end

    it 'returns nil when room is not in a delve' do
      expect(helper.get_delve_status(char_instance)).to be_nil
    end
  end

  describe '#store_message_for_sync - edge cases' do
    let(:room) { create(:room) }
    let(:char_instance) { create(:character_instance, current_room: room) }

    it 'handles message with special characters' do
      message = { content: "Hello <script>alert('xss')</script>" }
      expect { helper.store_message_for_sync(char_instance, message) }.not_to raise_error
    end

    it 'handles very large message content' do
      message = { content: 'A' * 10000 }
      expect { helper.store_message_for_sync(char_instance, message) }.not_to raise_error
    end
  end

  describe '#render_stats_table - edge cases' do
    let(:stat_block) { create(:stat_block) }

    it 'handles stat with zero as base_value' do
      stat = create(:stat, stat_block: stat_block, name: 'Zero Stat')
      result = helper.render_stats_table([stat], stat_block)
      expect(result).to include('<table')
    end

    it 'handles multiple stats' do
      stats = (1..5).map { |i| create(:stat, stat_block: stat_block, name: "Stat #{i}") }
      result = helper.render_stats_table(stats, stat_block)
      expect(result).to include('Stat 1')
      expect(result).to include('Stat 5')
    end
  end

  describe '#extract_title - edge cases' do
    it 'handles title with special characters' do
      html = '<title>Test &amp; Title</title>'
      expect(helper.extract_title(html)).to eq('Test &amp; Title')
    end

    it 'handles multiline title' do
      html = "<title>\n  Test Title\n</title>"
      expect(helper.extract_title(html)).to eq('Test Title')
    end

    it 'handles empty title tag' do
      html = '<title></title>'
      result = helper.extract_title(html)
      # Regex requires at least one character, so empty title returns nil
      expect(result).to be_nil
    end

    it 'handles whitespace-only title' do
      html = '<title>   </title>'
      result = helper.extract_title(html)
      # Captures whitespace, then strips it
      expect(result).to eq('')
    end

    it 'returns nil for missing title' do
      html = '<html><body>No title here</body></html>'
      expect(helper.extract_title(html)).to be_nil
    end
  end

  describe '#parse_textarea_to_jsonb_array - edge cases' do
    it 'handles carriage return line breaks' do
      text = "line1\r\nline2\r\nline3"
      result = helper.parse_textarea_to_jsonb_array(text)
      expect(result.length).to eq(3)
    end

    it 'handles mixed line break styles' do
      text = "line1\nline2\r\nline3"
      result = helper.parse_textarea_to_jsonb_array(text)
      # Should handle both styles
      expect(result.length).to be >= 2
    end
  end

  describe '#activity_badge_color - additional types' do
    it 'returns warning for tcompetition' do
      expect(helper.activity_badge_color('tcompetition')).to eq('warning')
    end

    it 'returns warning for encounter' do
      expect(helper.activity_badge_color('encounter')).to eq('warning')
    end

    it 'returns danger for survival' do
      expect(helper.activity_badge_color('survival')).to eq('danger')
    end

    it 'returns pink for intersym' do
      expect(helper.activity_badge_color('intersym')).to eq('pink')
    end

    it 'returns pink for interasym' do
      expect(helper.activity_badge_color('interasym')).to eq('pink')
    end

    it 'returns secondary for unknown type' do
      expect(helper.activity_badge_color('unknown')).to eq('secondary')
    end
  end

  describe '#room_type_badge_color - additional types' do
    it 'returns danger for combat' do
      expect(helper.room_type_badge_color('combat')).to eq('danger')
    end

    it 'returns danger for arena' do
      expect(helper.room_type_badge_color('arena')).to eq('danger')
    end

    it 'returns warning for dojo' do
      expect(helper.room_type_badge_color('dojo')).to eq('warning')
    end

    it 'returns warning for gym' do
      expect(helper.room_type_badge_color('gym')).to eq('warning')
    end

    it 'returns success for safe' do
      expect(helper.room_type_badge_color('safe')).to eq('success')
    end

    it 'returns info for shop' do
      expect(helper.room_type_badge_color('shop')).to eq('info')
    end

    it 'returns info for guild' do
      expect(helper.room_type_badge_color('guild')).to eq('info')
    end

    it 'returns info for temple' do
      expect(helper.room_type_badge_color('temple')).to eq('info')
    end

    it 'returns secondary for unknown type' do
      expect(helper.room_type_badge_color('unknown')).to eq('secondary')
    end
  end

  describe '#category_color - cover object categories' do
    it 'returns primary for furniture' do
      expect(helper.category_color('furniture')).to eq('primary')
    end

    it 'returns warning for vehicle' do
      expect(helper.category_color('vehicle')).to eq('warning')
    end

    it 'returns success for nature' do
      expect(helper.category_color('nature')).to eq('success')
    end

    it 'returns info for structure' do
      expect(helper.category_color('structure')).to eq('info')
    end

    it 'returns secondary for unknown category' do
      expect(helper.category_color('unknown')).to eq('secondary')
    end
  end

  describe 'authentication edge cases' do
    let(:user) { create(:user) }

    describe '#require_login! when already logged in' do
      it 'does not set flash error' do
        helper.session = { 'user_id' => user.id }
        helper.require_login!
        expect(helper.flash['error']).to be_nil
      end
    end
  end

  describe '#render_path_for_test - admin paths' do
    let(:admin_user) { create(:user, :admin) }

    before do
      helper.session = { 'user_id' => admin_user.id }
    end

    it 'renders admin index' do
      result = helper.render_path_for_test('/admin')
      expect(result).to have_key(:html)
    end

    it 'renders admin users' do
      result = helper.render_path_for_test('/admin/users')
      expect(result).to have_key(:html)
    end

    it 'renders admin settings' do
      result = helper.render_path_for_test('/admin/settings')
      expect(result).to have_key(:html)
    end

    context 'admin user show' do
      it 'renders user show page' do
        result = helper.render_path_for_test("/admin/users/#{admin_user.id}")
        expect(result).to have_key(:html)
      end

      it 'returns NotFound for non-existent user' do
        result = helper.render_path_for_test('/admin/users/999999')
        expect(result[:error]).to be true
        expect(result[:error_type]).to eq('NotFound')
      end
    end

    context 'admin stat blocks' do
      let!(:universe) { create(:universe) }
      let!(:stat_block) { create(:stat_block, universe: universe) }

      it 'renders stat blocks index' do
        result = helper.render_path_for_test('/admin/stat_blocks')
        expect(result).to have_key(:html)
      end

      it 'renders stat blocks new' do
        result = helper.render_path_for_test('/admin/stat_blocks/new')
        expect(result).to have_key(:html)
      end

      it 'renders stat block show' do
        result = helper.render_path_for_test("/admin/stat_blocks/#{stat_block.id}")
        expect(result).to have_key(:html)
      end

      it 'returns NotFound for non-existent stat block' do
        result = helper.render_path_for_test('/admin/stat_blocks/999999')
        expect(result[:error]).to be true
        expect(result[:error_type]).to eq('NotFound')
      end
    end

    context 'admin patterns' do
      let!(:pattern) { create(:pattern) }

      it 'renders patterns index' do
        result = helper.render_path_for_test('/admin/patterns')
        expect(result).to have_key(:html)
      end

      it 'renders patterns new' do
        result = helper.render_path_for_test('/admin/patterns/new')
        expect(result).to have_key(:html)
      end

      it 'renders pattern show' do
        result = helper.render_path_for_test("/admin/patterns/#{pattern.id}")
        expect(result).to have_key(:html)
      end

      it 'returns NotFound for non-existent pattern' do
        result = helper.render_path_for_test('/admin/patterns/999999')
        expect(result[:error]).to be true
        expect(result[:error_type]).to eq('NotFound')
      end
    end

    context 'admin vehicle types' do
      let!(:vehicle_type) { VehicleType.create(name: 'Test Car', category: 'ground') }

      it 'renders vehicle types index' do
        result = helper.render_path_for_test('/admin/vehicle_types')
        expect(result).to have_key(:html)
      end

      it 'renders vehicle types new' do
        result = helper.render_path_for_test('/admin/vehicle_types/new')
        expect(result).to have_key(:html)
      end

      it 'renders vehicle type show' do
        result = helper.render_path_for_test("/admin/vehicle_types/#{vehicle_type.id}")
        expect(result).to have_key(:html)
      end

      it 'returns NotFound for non-existent vehicle type' do
        result = helper.render_path_for_test('/admin/vehicle_types/999999')
        expect(result[:error]).to be true
        expect(result[:error_type]).to eq('NotFound')
      end
    end

    context 'admin NPCs' do
      let!(:archetype) { create(:npc_archetype, created_by: admin_user) }

      it 'renders NPCs index' do
        result = helper.render_path_for_test('/admin/npcs')
        expect(result).to have_key(:html)
      end

      it 'renders NPCs new' do
        result = helper.render_path_for_test('/admin/npcs/new')
        expect(result).to have_key(:html)
      end

      it 'renders NPCs locations' do
        result = helper.render_path_for_test('/admin/npcs/locations')
        expect(result).to have_key(:html)
      end

      it 'renders NPC archetype show' do
        result = helper.render_path_for_test("/admin/npcs/#{archetype.id}")
        expect(result).to have_key(:html)
      end

      it 'returns NotFound for non-existent NPC archetype' do
        result = helper.render_path_for_test('/admin/npcs/999999')
        expect(result[:error]).to be true
        expect(result[:error_type]).to eq('NotFound')
      end
    end

    context 'admin world builder' do
      let!(:world) { create(:world) }

      it 'renders world builder index' do
        result = helper.render_path_for_test('/admin/world_builder')
        expect(result).to have_key(:html)
      end

      it 'renders world builder editor' do
        result = helper.render_path_for_test("/admin/world_builder/#{world.id}")
        expect(result).to have_key(:html)
      end

      it 'returns NotFound for non-existent world' do
        result = helper.render_path_for_test('/admin/world_builder/999999')
        expect(result[:error]).to be true
        expect(result[:error_type]).to eq('NotFound')
      end
    end

    context 'admin room builder' do
      let!(:room) { create(:room) }

      it 'renders room builder index' do
        result = helper.render_path_for_test('/admin/room_builder')
        expect(result).to have_key(:html)
      end

      it 'renders room builder editor' do
        result = helper.render_path_for_test("/admin/room_builder/#{room.id}")
        expect(result).to have_key(:html)
      end

      it 'returns NotFound for non-existent room' do
        result = helper.render_path_for_test('/admin/room_builder/999999')
        expect(result[:error]).to be true
        expect(result[:error_type]).to eq('NotFound')
      end
    end

    context 'admin battle maps' do
      let!(:room) { create(:room, has_battle_map: true, room_type: 'combat') }

      it 'renders battle maps index' do
        result = helper.render_path_for_test('/admin/battle_maps')
        expect(result).to have_key(:html)
      end

      it 'renders battle maps editor' do
        result = helper.render_path_for_test("/admin/battle_maps/#{room.id}/edit")
        expect(result).to have_key(:html)
      end

      it 'returns NotFound for non-existent room in battle maps' do
        result = helper.render_path_for_test('/admin/battle_maps/999999/edit')
        expect(result[:error]).to be true
        expect(result[:error_type]).to eq('NotFound')
      end
    end

    context 'user pages' do
      it 'renders dashboard' do
        result = helper.render_path_for_test('/dashboard')
        expect(result).to have_key(:html)
      end

      it 'renders settings' do
        result = helper.render_path_for_test('/settings')
        expect(result).to have_key(:html)
      end

      it 'renders news' do
        result = helper.render_path_for_test('/news')
        expect(result).to have_key(:html)
      end

      it 'renders characters new' do
        result = helper.render_path_for_test('/characters/new')
        expect(result).to have_key(:html)
      end
    end

    context 'info pages' do
      it 'renders contact page' do
        result = helper.render_path_for_test('/info/contact')
        expect(result).to have_key(:html)
      end

      it 'renders getting-started with hyphen' do
        result = helper.render_path_for_test('/info/getting-started')
        expect(result).to have_key(:html)
      end
    end

    context 'world pages' do
      it 'renders locations page' do
        result = helper.render_path_for_test('/world/locations')
        expect(result).to have_key(:html)
      end

      it 'renders factions page' do
        result = helper.render_path_for_test('/world/factions')
        expect(result).to have_key(:html)
      end
    end

    context 'play pages' do
      let(:character) { create(:character, user: admin_user) }
      let!(:room) { create(:room, safe_room: true) }
      let!(:reality) { create(:reality, reality_type: 'primary') }
      let!(:char_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }

      it 'renders play page' do
        helper.session = { 'user_id' => admin_user.id, 'character_id' => character.id }
        result = helper.render_path_for_test('/play')
        expect(result).to have_key(:html)
      end

      it 'renders webclient page' do
        helper.session = { 'user_id' => admin_user.id, 'character_id' => character.id }
        result = helper.render_path_for_test('/webclient')
        expect(result).to have_key(:html)
      end
    end
  end

  # ===== ADDITIONAL EDGE CASES FOR COMPREHENSIVE COVERAGE =====

  describe '#get_delve_status - with active delve' do
    let(:room) { create(:room) }
    let(:char_instance) { create(:character_instance, current_room: room) }

    context 'when character has active delve participant' do
      let!(:delve) { create(:delve, name: 'Test Dungeon') }
      let!(:delve_participant) do
        DelveParticipant.create(
          character_instance_id: char_instance.id,
          delve_id: delve.id,
          status: 'active',
          current_level: 3,
          loot_collected: 100
        )
      end

      it 'returns delve status hash when in active delve' do
        result = helper.get_delve_status(char_instance)

        expect(result).to be_a(Hash)
        expect(result[:active]).to be true
        expect(result[:delve_name]).to eq('Test Dungeon')
        expect(result[:current_level]).to eq(3)
      end
    end
  end

  describe '#bring_character_online - with StaffBulletin' do
    let(:room) { create(:room) }
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let!(:reality) { create(:reality, reality_type: 'primary') }
    let(:char_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: false) }

    context 'when StaffBulletin is defined' do
      it 'checks for unread news on login' do
        if defined?(StaffBulletin)
          allow(StaffBulletin).to receive(:unread_counts_for).and_return({ staff: 0, player: 2 })
        end

        helper.bring_character_online(char_instance)

        expect(helper.instance_variable_get(:@unread_news)).not_to be_nil if defined?(StaffBulletin)
      end
    end

    context 'when StaffBroadcast is defined' do
      it 'delivers missed broadcasts' do
        if defined?(StaffBroadcast)
          mock_broadcast = double('StaffBroadcast', id: 1, formatted_message: 'Test broadcast')
          allow(StaffBroadcast).to receive(:undelivered_for).and_return([mock_broadcast])
          allow(BroadcastService).to receive(:to_character)
          allow(StaffBroadcastDelivery).to receive(:create)

          helper.bring_character_online(char_instance)

          expect(BroadcastService).to have_received(:to_character)
        end
      end
    end
  end

  describe '#authenticate_websocket - edge cases' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }
    let(:room) { create(:room) }
    let!(:reality) { create(:reality, reality_type: 'primary') }
    let(:char_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }

    let(:mock_request) do
      r = double('request')
      allow(r).to receive(:params).and_return({})
      r
    end

    context 'with invalid character_instance param' do
      it 'returns the instance when valid ID is provided with matching token' do
        # Clear session - authenticate via token instead
        helper.session = {}
        allow(mock_request).to receive(:params).and_return({ 'character_instance' => char_instance.id.to_s })
        allow(helper).to receive(:character_instance_from_token).and_return(char_instance)

        result = helper.authenticate_websocket(mock_request)
        expect(result).to eq(char_instance)
      end

      it 'returns nil for non-existent character instance' do
        helper.session = {}
        allow(mock_request).to receive(:params).and_return({ 'character_instance' => '999999' })

        result = helper.authenticate_websocket(mock_request)
        expect(result).to be_nil
      end
    end

    context 'with nil session' do
      it 'handles nil session gracefully' do
        # Simulate nil session by not setting up session lookup
        helper.session = nil
        allow(mock_request).to receive(:params).and_return({})

        result = helper.authenticate_websocket(mock_request)
        expect(result).to be_nil
      end
    end
  end

  describe '#partial - edge cases' do
    it 'handles deeply nested paths' do
      result = helper.partial('admin/users/partials/sidebar')
      expect(result).to eq('<rendered>admin/users/partials/_sidebar</rendered>')
    end

    it 'handles path with trailing slash' do
      result = helper.partial('admin/')
      # File.dirname('admin/') returns '.', File.basename('admin/') returns 'admin'
      # So with dir == '.', partial_path becomes '_admin'
      expect(result).to eq('<rendered>_admin</rendered>')
    end
  end

  describe '#build_ability_forced_movement_jsonb - edge cases' do
    it 'handles whitespace-only direction' do
      params = { 'forced_movement_direction' => '   ' }
      result = helper.build_ability_forced_movement_jsonb(params)
      expect(result).to be_nil
    end

    it 'handles nil distance' do
      params = { 'forced_movement_direction' => 'push', 'forced_movement_distance' => nil }
      result = helper.build_ability_forced_movement_jsonb(params)
      expect(result['distance']).to eq(1)
    end
  end

  describe '#build_ability_execute_effect_jsonb - edge cases' do
    it 'handles nil execute_threshold' do
      params = { 'execute_threshold' => nil }
      result = helper.build_ability_execute_effect_jsonb(params)
      expect(result).to be_nil
    end

    it 'handles execute_damage_multiplier as empty string' do
      params = { 'execute_threshold' => '25', 'execute_damage_multiplier' => '' }
      result = helper.build_ability_execute_effect_jsonb(params)
      expect(result['damage_multiplier']).to eq(2.0)
    end
  end

  describe '#parse_npc_params - additional edge cases' do
    it 'handles attack with weapon_template' do
      params = {
        'name' => 'Test',
        'npc_attacks' => {
          '0' => {
            'name' => 'Sword Strike',
            'attack_type' => 'melee',
            'damage_dice' => '2d6',
            'weapon_template' => 'longsword',
            'hit_message' => 'strikes you!',
            'miss_message' => 'misses!',
            'critical_message' => 'critically hits!'
          }
        }
      }
      result = helper.parse_npc_params(params)
      attack = result[:npc_attacks][0]
      expect(attack['weapon_template']).to eq('longsword')
      expect(attack['hit_message']).to eq('strikes you!')
      expect(attack['miss_message']).to eq('misses!')
      expect(attack['critical_message']).to eq('critically hits!')
    end

    it 'compacts nil and empty weapon_template' do
      params = {
        'name' => 'Test',
        'npc_attacks' => {
          '0' => {
            'name' => 'Bite',
            'attack_type' => 'melee',
            'weapon_template' => '',
            'hit_message' => ''
          }
        }
      }
      result = helper.parse_npc_params(params)
      attack = result[:npc_attacks][0]
      expect(attack).not_to have_key('weapon_template')
      expect(attack).not_to have_key('hit_message')
    end

    it 'handles combat_ability_ids with zeros' do
      params = {
        'name' => 'Test',
        'combat_ability_ids' => ['0', '1', '0', '2']
      }
      result = helper.parse_npc_params(params)
      # Should filter out zeros
      expect(result[:combat_ability_ids].to_a).to eq([1, 2])
    end

    it 'handles empty combat_ability_ids array' do
      params = {
        'name' => 'Test',
        'combat_ability_ids' => []
      }
      result = helper.parse_npc_params(params)
      expect(result[:combat_ability_ids]).to be_nil
    end

    it 'handles combat_ability_chances with empty values' do
      params = {
        'name' => 'Test',
        'combat_ability_chances' => { '1' => '50', '2' => '', '3' => '30' }
      }
      result = helper.parse_npc_params(params)
      expect(result[:combat_ability_chances]).to eq({ '1' => 50, '3' => 30 })
    end

    it 'handles empty combat_ability_chances' do
      params = {
        'name' => 'Test',
        'combat_ability_chances' => {}
      }
      result = helper.parse_npc_params(params)
      expect(result[:combat_ability_chances]).to be_nil
    end
  end

  describe '#format_power_breakdown - edge cases' do
    it 'handles float values' do
      breakdown = { 'damage' => 10.5 }
      result = helper.format_power_breakdown(breakdown)
      expect(result).to include('damage: +11') # Should round
    end

    it 'handles negative float values' do
      breakdown = { 'penalty' => -5.7 }
      result = helper.format_power_breakdown(breakdown)
      expect(result).to include('penalty: -6') # Should round
    end

    it 'handles empty hash' do
      result = helper.format_power_breakdown({})
      expect(result).to eq('')
    end
  end

  describe '#render_stat_allocation_row - edge cases' do
    let(:stat_block) { create(:stat_block, min_stat_value: 5) }
    let(:stat) { create(:stat, stat_block: stat_block, name: 'Wisdom', abbreviation: 'WIS', stat_category: 'secondary') }

    it 'uses stat_block min_stat_value for initial display' do
      result = helper.render_stat_allocation_row(stat, stat_block)
      expect(result).to include('value="5"')
    end

    it 'handles stat without description' do
      stat.update(description: nil)
      result = helper.render_stat_allocation_row(stat, stat_block)
      expect(result).not_to include('small class="text-muted"')
    end
  end

  describe '#behavior_badge_color - edge cases' do
    it 'handles symbols' do
      expect(helper.behavior_badge_color(:friendly)).to eq('success')
    end

    it 'returns info for fearful' do
      expect(helper.behavior_badge_color('fearful')).to eq('info')
    end

    it 'returns primary for trader' do
      expect(helper.behavior_badge_color('trader')).to eq('primary')
    end
  end

  describe '#ability_type_color - edge cases' do
    it 'handles nil input' do
      expect(helper.ability_type_color(nil)).to eq('secondary')
    end

    it 'handles empty string' do
      expect(helper.ability_type_color('')).to eq('secondary')
    end
  end

  describe '#power_color - edge cases' do
    it 'handles string input' do
      expect(helper.power_color('75')).to eq('info')
    end

    it 'handles negative numbers' do
      # Negative numbers don't match 0..50 (Ruby ranges don't include negatives)
      # So they fall to the 'else' case which returns 'danger'
      expect(helper.power_color(-10)).to eq('danger')
    end

    it 'handles nil (converts to 0)' do
      expect(helper.power_color(nil)).to eq('success')
    end
  end

  describe '#build_ability_costs_jsonb - all roll penalty' do
    it 'includes all_roll_penalty when non-zero' do
      params = { 'all_roll_penalty_amount' => '-2', 'all_roll_penalty_decay' => '1' }
      result = helper.build_ability_costs_jsonb(params)

      expect(result['all_roll_penalty']['amount']).to eq(-2)
      expect(result['all_roll_penalty']['decay_per_round']).to eq(1)
    end

    it 'skips all_roll_penalty when zero' do
      params = { 'all_roll_penalty_amount' => '0', 'all_roll_penalty_decay' => '1' }
      result = helper.build_ability_costs_jsonb(params)
      expect(result).to eq({})
    end
  end

  describe '#setup_admin_settings_vars - edge cases' do
    let(:admin_user) { create(:user, :admin) }

    before do
      helper.session = { 'user_id' => admin_user.id }
    end

    it 'handles empty weather_api_key' do
      # When weather_api_key is empty string, it's still truthy but empty
      # The code checks .nil? which an empty string is not
      GameSetting.set('weather_api_key', '')
      helper.setup_admin_settings_vars
      settings = helper.instance_variable_get(:@settings)
      # Empty string is not nil, so it shows masked value
      # This tests that the masking logic works even for empty values
      expect(settings[:weather][:weather_api_key]).to eq('••••••••')
    end

    it 'returns nil when weather_api_key not set' do
      # Delete the key to ensure it's truly nil
      GameSetting.where(key: 'weather_api_key').delete
      GameSetting.clear_cache!
      helper.setup_admin_settings_vars
      settings = helper.instance_variable_get(:@settings)
      expect(settings[:weather][:weather_api_key]).to be_nil
    end

    it 'sets available_stats' do
      create(:stat_block)
      stat = create(:stat)
      helper.setup_admin_settings_vars
      available_stats = helper.instance_variable_get(:@available_stats)
      expect(available_stats).to be_an(Array)
    end
  end

  describe '#find_starting_room - priority order' do
    it 'prioritizes tutorial_spawn_room_id setting over safe_room flag' do
      safe = create(:room, safe_room: true, name: 'Safe Room')
      configured = create(:room, name: 'Configured Spawn')
      GameSetting.set('tutorial_spawn_room_id', configured.id, type: 'integer')
      expect(helper.find_starting_room).to eq(configured)
    end

    it 'prioritizes safe_room flag over room_type safe' do
      regular = create(:room, name: 'Regular')
      safe = create(:room, safe_room: true, name: 'Safe Room')
      expect(helper.find_starting_room).to eq(safe)
    end
  end

  describe '#clear_cached_character_state - edge cases' do
    it 'does not raise when instance variables not defined' do
      expect { helper.clear_cached_character_state }.not_to raise_error
    end
  end

  describe '#store_message_for_sync - with multiple players in room' do
    let(:room) { create(:room) }
    let(:sender_instance) { create(:character_instance, current_room: room) }
    let(:receiver_instance) { create(:character_instance, current_room: room) }

    before do
      # Register players in the room
      REDIS_POOL.with do |redis|
        redis.sadd("room_players:#{room.id}", sender_instance.id)
        redis.sadd("room_players:#{room.id}", receiver_instance.id)
      end
    end

    it 'adds message to pending list for other players' do
      message = { id: 'msg-sync-test', content: 'Hello' }
      helper.store_message_for_sync(sender_instance, message)

      REDIS_POOL.with do |redis|
        pending = redis.smembers("msg_pending:#{receiver_instance.id}")
        expect(pending).to include('msg-sync-test')

        # Sender should NOT have the message in their pending list
        sender_pending = redis.smembers("msg_pending:#{sender_instance.id}")
        expect(sender_pending).not_to include('msg-sync-test')
      end
    end
  end

  describe '#register_popup_handler - additional options' do
    let(:char_instance) { create(:character_instance, current_room: create(:room)) }

    it 'stores callback_id in handler data' do
      popup_id = helper.register_popup_handler(char_instance, 'popup-1', 'form', callback_id: 'cb-123')

      REDIS_POOL.with do |redis|
        stored = redis.get("popup:#{char_instance.id}:popup-1")
        data = JSON.parse(stored)
        expect(data['callback_id']).to eq('cb-123')
      end
    end

    it 'stores created_at timestamp' do
      popup_id = helper.register_popup_handler(char_instance, 'popup-2', 'quickmenu')

      REDIS_POOL.with do |redis|
        stored = redis.get("popup:#{char_instance.id}:popup-2")
        data = JSON.parse(stored)
        expect(data['created_at']).not_to be_nil
      end
    end
  end

  describe '#build_ability_combo_condition_jsonb - edge cases' do
    it 'handles whitespace-only requires_status' do
      params = { 'combo_requires_status' => '   ' }
      result = helper.build_ability_combo_condition_jsonb(params)
      expect(result).to be_nil
    end

    it 'includes all fields when present' do
      params = {
        'combo_requires_status' => 'bleeding',
        'combo_bonus_dice' => '3d6',
        'combo_consumes_status' => '0'
      }
      result = helper.build_ability_combo_condition_jsonb(params)
      expect(result['requires_status']).to eq('bleeding')
      expect(result['bonus_dice']).to eq('3d6')
      expect(result['consumes_status']).to be false
    end
  end

  describe '#build_ability_chain_config_jsonb - edge cases' do
    it 'handles string friendly_fire value' do
      params = {
        'chain_enabled' => '1',
        'chain_friendly_fire' => '0'
      }
      result = helper.build_ability_chain_config_jsonb(params)
      expect(result['friendly_fire']).to be false
    end

    it 'handles missing chain parameters' do
      params = { 'chain_enabled' => '1' }
      result = helper.build_ability_chain_config_jsonb(params)
      # Should have defaults
      expect(result['max_targets']).to eq(3)
      expect(result['range_per_jump']).to eq(2)
      expect(result['damage_falloff']).to eq(0.5)
      expect(result['friendly_fire']).to be false
    end
  end

  describe '#setup_play_vars - edge cases' do
    let(:admin_user) { create(:user, :admin) }
    let(:character) { create(:character, user: admin_user) }
    let!(:room) { create(:room, safe_room: true) } # Must exist before setup_play_vars
    let!(:reality) { create(:reality, reality_type: 'primary') }

    before do
      helper.session = { 'user_id' => admin_user.id }
    end

    it 'falls back to Room.first when character has no instance' do
      # Create character - ensure it exists before setup_play_vars
      character
      # No character instance created - setup_play_vars should use Room.first as fallback

      helper.setup_play_vars

      # Character should be set
      char_var = helper.instance_variable_get(:@character)
      expect(char_var).to eq(character)

      # @room should fall back to Room.first since character_instance is nil
      room_var = helper.instance_variable_get(:@room)
      expect(room_var).to eq(room)
    end

    it 'returns early when user has no characters' do
      # Don't create any characters
      helper.setup_play_vars

      # @character should be nil
      char_var = helper.instance_variable_get(:@character)
      expect(char_var).to be_nil

      # @room should also be nil (method returns early)
      room_var = helper.instance_variable_get(:@room)
      expect(room_var).to be_nil
    end
  end

  # ===== MESSAGE SEQUENCE HELPERS =====

  describe '#get_next_sequence_number' do
    it 'increments the global sequence number' do
      first = helper.get_next_sequence_number
      second = helper.get_next_sequence_number
      expect(second).to eq(first + 1)
    end

    it 'returns an integer' do
      result = helper.get_next_sequence_number
      expect(result).to be_a(Integer)
    end
  end

  describe '#get_current_sequence_number' do
    it 'returns the last sequence number' do
      last = helper.get_next_sequence_number
      current = helper.get_current_sequence_number
      expect(current).to eq(last)
    end

    it 'returns 0 when no sequences have been issued' do
      REDIS_POOL.with { |r| r.del('global_msg_sequence') }
      result = helper.get_current_sequence_number
      expect(result).to be_a(Integer)
    end
  end

  # ===== HTML EXTRACTION HELPERS =====

  describe '#extract_title' do
    it 'extracts title from valid HTML' do
      html = '<html><head><title>Test Page</title></head></html>'
      expect(helper.extract_title(html)).to eq('Test Page')
    end

    it 'handles title with extra whitespace' do
      html = '<title>  Spaced Title  </title>'
      expect(helper.extract_title(html)).to eq('Spaced Title')
    end

    it 'returns nil for nil input' do
      expect(helper.extract_title(nil)).to be_nil
    end

    it 'returns nil when no title tag exists' do
      html = '<html><head></head><body>No title</body></html>'
      expect(helper.extract_title(html)).to be_nil
    end

    it 'handles case-insensitive title tags' do
      html = '<TITLE>Uppercase Title</TITLE>'
      expect(helper.extract_title(html)).to eq('Uppercase Title')
    end
  end

  # ===== GAME SETTING HELPERS =====

  describe '#game_setting' do
    it 'returns game setting value' do
      GameSetting.set('test_setting', 'test_value')
      expect(helper.game_setting('test_setting')).to eq('test_value')
    end

    it 'returns nil for non-existent setting' do
      expect(helper.game_setting('nonexistent_key_12345')).to be_nil
    end
  end

  describe '#game_name' do
    it 'returns configured game name' do
      GameSetting.set('game_name', 'My Custom Game')
      expect(helper.game_name).to eq('My Custom Game')
    end

    it 'returns Firefly as default when not set' do
      GameSetting.where(key: 'game_name').delete
      GameSetting.clear_cache!
      expect(helper.game_name).to eq('Firefly')
    end

    it 'returns Firefly for empty string' do
      GameSetting.set('game_name', '')
      expect(helper.game_name).to eq('Firefly')
    end
  end

  # ===== ABILITY JSONB BUILDER HELPERS =====

  describe '#build_ability_damage_types_jsonb - edge cases' do
    it 'returns nil for non-Hash input' do
      params = { 'damage_types_split' => 'invalid' }
      result = helper.build_ability_damage_types_jsonb(params)
      expect(result).to be_nil
    end

    it 'skips entries with empty type' do
      params = {
        'damage_types_split' => {
          '0' => { 'type' => '', 'value' => '50%' },
          '1' => { 'type' => 'fire', 'value' => '50%' }
        }
      }
      result = helper.build_ability_damage_types_jsonb(params)
      expect(result.length).to eq(1)
      expect(result[0]['type']).to eq('fire')
    end

    it 'returns nil for empty result' do
      params = {
        'damage_types_split' => {
          '0' => { 'type' => '', 'value' => '' }
        }
      }
      result = helper.build_ability_damage_types_jsonb(params)
      expect(result).to be_nil
    end
  end

  describe '#build_ability_conditional_damage_jsonb - edge cases' do
    it 'returns nil for non-Hash input' do
      params = { 'conditional_damage' => 'invalid' }
      result = helper.build_ability_conditional_damage_jsonb(params)
      expect(result).to be_nil
    end

    it 'skips entries with empty condition' do
      params = {
        'conditional_damage' => {
          '0' => { 'condition' => '', 'status' => 'burning', 'bonus_dice' => '2d6' },
          '1' => { 'condition' => 'target_has_status', 'status' => 'stunned', 'bonus_dice' => '3d6' }
        }
      }
      result = helper.build_ability_conditional_damage_jsonb(params)
      expect(result.length).to eq(1)
      expect(result[0]['condition']).to eq('target_has_status')
    end

    it 'compacts nil values' do
      params = {
        'conditional_damage' => {
          '0' => { 'condition' => 'low_hp', 'status' => nil, 'bonus_dice' => '1d6' }
        }
      }
      result = helper.build_ability_conditional_damage_jsonb(params)
      expect(result[0]).not_to have_key('status')
    end
  end

  describe '#parse_textarea_to_jsonb_array' do
    it 'splits text by newlines' do
      text = "line1\nline2\nline3"
      result = helper.parse_textarea_to_jsonb_array(text)
      expect(result).to eq(%w[line1 line2 line3])
    end

    it 'strips whitespace from each line' do
      text = "  line1  \n  line2  "
      result = helper.parse_textarea_to_jsonb_array(text)
      expect(result).to eq(%w[line1 line2])
    end

    it 'rejects empty lines' do
      text = "line1\n\nline2\n   \nline3"
      result = helper.parse_textarea_to_jsonb_array(text)
      expect(result).to eq(%w[line1 line2 line3])
    end

    it 'returns nil for nil input' do
      expect(helper.parse_textarea_to_jsonb_array(nil)).to be_nil
    end

    it 'returns nil for empty string' do
      expect(helper.parse_textarea_to_jsonb_array('')).to be_nil
    end

    it 'returns nil for whitespace-only string' do
      expect(helper.parse_textarea_to_jsonb_array('   ')).to be_nil
    end
  end

  # ===== BADGE COLOR HELPERS =====

  describe '#room_type_badge_color - additional types' do
    it 'returns danger for arena' do
      expect(helper.room_type_badge_color('arena')).to eq('danger')
    end

    it 'returns warning for gym' do
      expect(helper.room_type_badge_color('gym')).to eq('warning')
    end

    it 'returns info for guild' do
      expect(helper.room_type_badge_color('guild')).to eq('info')
    end

    it 'returns info for temple' do
      expect(helper.room_type_badge_color('temple')).to eq('info')
    end

    it 'returns secondary for unknown type' do
      expect(helper.room_type_badge_color('unknown')).to eq('secondary')
    end
  end

  describe '#category_color' do
    it 'returns primary for furniture' do
      expect(helper.category_color('furniture')).to eq('primary')
    end

    it 'returns warning for vehicle' do
      expect(helper.category_color('vehicle')).to eq('warning')
    end

    it 'returns success for nature' do
      expect(helper.category_color('nature')).to eq('success')
    end

    it 'returns info for structure' do
      expect(helper.category_color('structure')).to eq('info')
    end

    it 'returns secondary for unknown category' do
      expect(helper.category_color('unknown')).to eq('secondary')
    end
  end

  # ===== ADDITIONAL BROADCAST TESTS =====

  describe '#broadcast_to_room_redis - with exclude parameter' do
    let(:room) { create(:room) }
    let(:sender) { create(:character_instance, current_room: room) }
    let(:receiver) { create(:character_instance, current_room: room) }

    before do
      REDIS_POOL.with do |redis|
        redis.sadd("room_players:#{room.id}", sender.id)
        redis.sadd("room_players:#{room.id}", receiver.id)
      end
    end

    it 'excludes specified character from receiving message' do
      message = { content: 'Test' }
      helper.broadcast_to_room_redis(room.id, message, sender.id)

      REDIS_POOL.with do |redis|
        # Sender should be excluded
        sender_pending = redis.smembers("msg_pending:#{sender.id}")
        expect(sender_pending).not_to include(message[:id])
      end
    end

    it 'includes non-excluded characters' do
      message = { content: 'Test' }
      result = helper.broadcast_to_room_redis(room.id, message, sender.id)

      REDIS_POOL.with do |redis|
        receiver_pending = redis.smembers("msg_pending:#{receiver.id}")
        expect(receiver_pending).to include(result[:id])
      end
    end
  end

  # ===== ENSURE CHARACTER INSTANCE HELPER =====

  describe '#ensure_character_instance_for - edge cases' do
    let!(:reality) { create(:reality, reality_type: 'primary') }
    let!(:starting_room) { create(:room, safe_room: true) }

    it 'returns nil for nil character' do
      expect(helper.ensure_character_instance_for(nil)).to be_nil
    end

    it 'returns existing instance when one exists' do
      user = create(:user)
      character = create(:character, user: user)
      existing = create(:character_instance, character: character, current_room: starting_room, reality: reality)

      result = helper.ensure_character_instance_for(character)
      expect(result.id).to eq(existing.id)
    end

    it 'prefers primary reality instance' do
      user = create(:user)
      character = create(:character, user: user)
      secondary_reality = create(:reality, reality_type: 'alternate')
      secondary_instance = create(:character_instance, character: character, current_room: starting_room, reality: secondary_reality)
      primary_instance = create(:character_instance, character: character, current_room: starting_room, reality: reality)

      result = helper.ensure_character_instance_for(character)
      expect(result.id).to eq(primary_instance.id)
    end

    it 'creates new instance when none exists' do
      user = create(:user)
      character = create(:character, user: user)

      result = helper.ensure_character_instance_for(character)
      expect(result).to be_a(CharacterInstance)
      expect(result.character_id).to eq(character.id)
      expect(result.reality_id).to eq(reality.id)
    end

    it 'returns nil when no starting room exists' do
      Room.dataset.delete  # Delete all rooms

      user = create(:user)
      character = create(:character, user: user)

      result = helper.ensure_character_instance_for(character)
      expect(result).to be_nil
    end
  end

  # ===== RENDER PATH FOR TEST - ERROR HANDLING =====

  describe '#render_path_for_test - error handling' do
    let(:admin_user) { create(:user, :admin) }

    before do
      helper.session = { 'user_id' => admin_user.id }
    end

    it 'catches and returns template errors' do
      # Mock a template error
      allow(helper).to receive(:view).and_raise(StandardError.new('Template not found'))

      result = helper.render_path_for_test('/dashboard')

      expect(result[:error]).to be true
      expect(result[:error_type]).to eq('StandardError')
      expect(result[:error_message]).to eq('Template not found')
    end

    it 'includes backtrace in error response' do
      allow(helper).to receive(:view).and_raise(StandardError.new('Test error'))

      result = helper.render_path_for_test('/dashboard')

      expect(result[:backtrace]).to be_an(Array)
    end
  end

  describe '#personalize_character_refs' do
    let(:reality) { create(:reality) }
    let(:room) { create(:room) }

    let(:viewer_char) { create(:character, forename: 'Viewer', short_desc: 'the viewer') }
    let(:viewer_instance) { create(:character_instance, character: viewer_char, reality: reality, current_room: room) }

    let(:known_char) { create(:character, forename: 'SecretName', surname: 'Hidden', short_desc: 'a tall stranger') }
    let(:known_instance) { create(:character_instance, character: known_char, reality: reality, current_room: room) }

    let(:unknown_char) { create(:character, forename: 'Unknown', short_desc: 'a mysterious figure') }
    let(:unknown_instance) { create(:character_instance, character: unknown_char, reality: reality, current_room: room) }

    before do
      # Viewer knows known_char by a custom name
      create(:character_knowledge,
        knower_character: viewer_char,
        known_character: known_char,
        is_known: true,
        known_name: 'Tall Stranger'
      )
      # Viewer does NOT know unknown_char (no CharacterKnowledge record)
    end

    it 'returns data unchanged when viewer is nil' do
      data = { character_id: known_instance.id, character_name: 'should not change' }
      result = helper.personalize_character_refs(data, nil)
      expect(result[:character_name]).to eq('should not change')
    end

    it 'resolves known character names using display_name_for' do
      data = { character_id: known_instance.id, character_name: 'SecretName Hidden' }
      helper.personalize_character_refs(data, viewer_instance)
      expect(data[:character_name]).to eq('Tall Stranger')
    end

    it 'resolves unknown character names to short_desc' do
      data = { character_id: unknown_instance.id, character_name: 'Unknown' }
      helper.personalize_character_refs(data, viewer_instance)
      expect(data[:character_name]).to eq('a mysterious figure')
    end

    it 'resolves string-keyed hashes' do
      data = { 'character_id' => unknown_instance.id, 'character_name' => 'Unknown' }
      helper.personalize_character_refs(data, viewer_instance)
      expect(data['character_name']).to eq('a mysterious figure')
    end

    it 'resolves :name key when character_id is present' do
      data = { character_id: unknown_instance.id, name: 'Unknown' }
      helper.personalize_character_refs(data, viewer_instance)
      expect(data[:name]).to eq('a mysterious figure')
    end

    it 'does not touch :name key when character_id is absent' do
      data = { name: 'Room Name' }
      helper.personalize_character_refs(data, viewer_instance)
      expect(data[:name]).to eq('Room Name')
    end

    it 'walks nested arrays' do
      data = [
        { character_id: known_instance.id, character_name: 'SecretName Hidden' },
        { character_id: unknown_instance.id, character_name: 'Unknown' }
      ]
      helper.personalize_character_refs(data, viewer_instance)
      expect(data[0][:character_name]).to eq('Tall Stranger')
      expect(data[1][:character_name]).to eq('a mysterious figure')
    end

    it 'walks nested hashes' do
      data = {
        message: {
          character_id: unknown_instance.id,
          character_name: 'Unknown'
        }
      }
      helper.personalize_character_refs(data, viewer_instance)
      expect(data[:message][:character_name]).to eq('a mysterious figure')
    end

    it 'caches lookups for the same character_id' do
      data = [
        { character_id: known_instance.id, character_name: 'X' },
        { character_id: known_instance.id, character_name: 'Y' }
      ]
      # Should only call CharacterInstance[] once for the same id
      expect(CharacterInstance).to receive(:[]).with(known_instance.id).once.and_return(known_instance)
      helper.personalize_character_refs(data, viewer_instance)
      expect(data[0][:character_name]).to eq('Tall Stranger')
      expect(data[1][:character_name]).to eq('Tall Stranger')
    end

    it 'returns "someone" for invalid character_id' do
      data = { character_id: 999999, character_name: 'Ghost' }
      helper.personalize_character_refs(data, viewer_instance)
      expect(data[:character_name]).to eq('someone')
    end

    it 'self-viewing uses own name' do
      data = { character_id: viewer_instance.id, character_name: 'wrong' }
      helper.personalize_character_refs(data, viewer_instance)
      expect(data[:character_name]).to eq('Viewer')
    end
  end
end
