# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LogBreakpoint do
  let(:character_instance) { create(:character_instance) }
  let(:room) { create(:room) }

  # Helper to create a valid log breakpoint
  def create_breakpoint(attrs = {})
    bp = LogBreakpoint.new
    bp.character_instance = attrs[:character_instance] || character_instance
    bp.breakpoint_type = attrs[:breakpoint_type] || 'Wake'
    bp.happened_at = attrs[:happened_at] || Time.now
    bp.room = attrs[:room] if attrs[:room]
    bp.room_title = attrs[:room_title] if attrs[:room_title]
    bp.weather = attrs[:weather] if attrs[:weather]
    bp.subtype = attrs[:subtype] if attrs[:subtype]
    bp.save
    bp
  end

  describe 'associations' do
    it 'belongs to character_instance' do
      bp = create_breakpoint(character_instance: character_instance)
      expect(bp.character_instance.id).to eq(character_instance.id)
    end

    it 'belongs to room' do
      bp = create_breakpoint(room: room)
      expect(bp.room.id).to eq(room.id)
    end
  end

  describe 'validations' do
    it 'requires character_instance_id' do
      bp = LogBreakpoint.new
      bp.breakpoint_type = 'Wake'
      expect(bp.valid?).to be false
      expect(bp.errors[:character_instance_id]).not_to be_empty
    end

    it 'requires valid breakpoint_type' do
      bp = LogBreakpoint.new
      bp.character_instance = character_instance
      bp.breakpoint_type = 'invalid'
      expect(bp.valid?).to be false
      expect(bp.errors[:breakpoint_type]).not_to be_empty
    end

    %w[Wake Sleep Move RP].each do |type|
      it "accepts #{type} as breakpoint_type" do
        bp = LogBreakpoint.new
        bp.character_instance = character_instance
        bp.breakpoint_type = type
        bp.happened_at = Time.now
        expect(bp.valid?).to be true
      end
    end
  end

  describe '.recent_for' do
    it 'returns recent breakpoints for character' do
      bp1 = create_breakpoint(happened_at: Time.now - 60)
      bp2 = create_breakpoint(happened_at: Time.now - 30)

      results = LogBreakpoint.recent_for(character_instance)

      expect(results).to include(bp1)
      expect(results).to include(bp2)
    end

    it 'orders by happened_at descending' do
      older = create_breakpoint(happened_at: Time.now - 120)
      newer = create_breakpoint(happened_at: Time.now - 30)

      results = LogBreakpoint.recent_for(character_instance)

      expect(results.first.id).to eq(newer.id)
      expect(results.last.id).to eq(older.id)
    end

    it 'respects limit' do
      3.times { create_breakpoint }

      results = LogBreakpoint.recent_for(character_instance, limit: 2).all

      expect(results.length).to eq(2)
    end

    it 'does not return breakpoints for other characters' do
      other_instance = create(:character_instance)
      other_bp = LogBreakpoint.new
      other_bp.character_instance = other_instance
      other_bp.breakpoint_type = 'Wake'
      other_bp.happened_at = Time.now
      other_bp.save

      results = LogBreakpoint.recent_for(character_instance)

      expect(results).not_to include(other_bp)
    end
  end

  describe '.sessions_for' do
    it 'returns only Wake and Sleep breakpoints' do
      wake_bp = create_breakpoint(breakpoint_type: 'Wake')
      sleep_bp = create_breakpoint(breakpoint_type: 'Sleep')
      move_bp = create_breakpoint(breakpoint_type: 'Move')
      rp_bp = create_breakpoint(breakpoint_type: 'RP')

      results = LogBreakpoint.sessions_for(character_instance)

      expect(results).to include(wake_bp)
      expect(results).to include(sleep_bp)
      expect(results).not_to include(move_bp)
      expect(results).not_to include(rp_bp)
    end

    it 'orders by happened_at descending' do
      older = create_breakpoint(breakpoint_type: 'Wake', happened_at: Time.now - 120)
      newer = create_breakpoint(breakpoint_type: 'Sleep', happened_at: Time.now - 30)

      results = LogBreakpoint.sessions_for(character_instance)

      expect(results.first.id).to eq(newer.id)
    end
  end

  describe '.record_login' do
    before do
      allow(character_instance).to receive(:current_room).and_return(room)
    end

    it 'creates a Wake breakpoint' do
      bp = LogBreakpoint.record_login(character_instance)

      expect(bp.breakpoint_type).to eq('Wake')
      expect(bp.character_instance.id).to eq(character_instance.id)
    end

    it 'sets room information' do
      bp = LogBreakpoint.record_login(character_instance)

      expect(bp.room_id).to eq(room.id)
      expect(bp.room_title).to eq(room.name)
    end

    it 'sets happened_at to current time' do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      bp = LogBreakpoint.record_login(character_instance)

      expect(bp.happened_at).to be_within(1).of(freeze_time)
    end
  end

  describe '.record_logout' do
    before do
      allow(character_instance).to receive(:current_room).and_return(room)
    end

    it 'creates a Sleep breakpoint' do
      bp = LogBreakpoint.record_logout(character_instance)

      expect(bp.breakpoint_type).to eq('Sleep')
      expect(bp.character_instance.id).to eq(character_instance.id)
    end

    it 'sets room information' do
      bp = LogBreakpoint.record_logout(character_instance)

      expect(bp.room_id).to eq(room.id)
      expect(bp.room_title).to eq(room.name)
    end
  end

  describe '.record_move' do
    let(:to_room) { create(:room, name: 'Destination Room') }

    it 'creates a Move breakpoint' do
      bp = LogBreakpoint.record_move(character_instance, to_room)

      expect(bp.breakpoint_type).to eq('Move')
      expect(bp.character_instance.id).to eq(character_instance.id)
    end

    it 'sets room to destination' do
      bp = LogBreakpoint.record_move(character_instance, to_room)

      expect(bp.room_id).to eq(to_room.id)
      expect(bp.room_title).to eq('Destination Room')
    end

    it 'sets subtype to room name' do
      bp = LogBreakpoint.record_move(character_instance, to_room)

      expect(bp.subtype).to eq('Destination Room')
    end
  end

  describe '#to_api_hash' do
    it 'returns hash with all API fields' do
      freeze_time = Time.now
      bp = create_breakpoint(
        breakpoint_type: 'Wake',
        subtype: 'Morning',
        happened_at: freeze_time,
        room_title: 'Test Room',
        weather: 'Sunny'
      )

      api_hash = bp.to_api_hash

      expect(api_hash[:id]).to eq(bp.id)
      expect(api_hash[:type]).to eq('Wake')
      expect(api_hash[:subtype]).to eq('Morning')
      expect(api_hash[:room_name]).to eq('Test Room')
      expect(api_hash[:weather]).to eq('Sunny')
      expect(api_hash[:happened_at]).to eq(freeze_time.iso8601)
    end
  end
end
