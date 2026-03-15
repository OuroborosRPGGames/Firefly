# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EmailSceneNotifier do
  let(:redis) { instance_double('Redis') }

  before do
    allow(EmailService).to receive(:configured?).and_return(true)
    allow(EmailService).to receive(:send_email)

    allow(REDIS_POOL).to receive(:with).and_yield(redis)
    allow(redis).to receive(:get).and_return(nil)
    allow(redis).to receive(:exists?).and_return(false)
    allow(redis).to receive(:setex)
  end

  describe '.notify_if_needed' do
    it 'emails eligible offline players and sets cooldown' do
      room = create(:room, name: 'Testing Tavern')
      recipient_user = create(:user, email: 'recipient@example.com')
      recipient_character = create(:character, user: recipient_user)
      create(:character_instance, character: recipient_character, current_room: room, online: false)
      create(:character_instance, character: create(:character, :npc), current_room: room, online: false)

      sender = create(:character_instance, current_room: room, online: true)

      allow(redis).to receive(:get).with("settings:user:#{recipient_user.id}").and_return('{"emailscene":true}')
      expect(redis).to receive(:exists?).with("email_scene_cooldown:#{recipient_user.id}:#{room.id}").and_return(false)
      expect(redis).to receive(:setex).with("email_scene_cooldown:#{recipient_user.id}:#{room.id}", 900, '1')

      expect(EmailService).to receive(:send_email) do |args|
        expect(args[:to]).to eq('recipient@example.com')
        expect(args[:subject]).to eq('New RP activity in Testing Tavern')
        expect(args[:body]).to include(sender.character.full_name)
        expect(args[:body]).to include('Hello world')
        expect(args[:html]).to be(false)
      end

      described_class.notify_if_needed(room.id, '<b>Hello</b> world', sender)
    end

    it 'does not email when cooldown already exists' do
      room = create(:room)
      recipient_user = create(:user)
      recipient_character = create(:character, user: recipient_user)
      create(:character_instance, character: recipient_character, current_room: room, online: false)
      sender = create(:character_instance, current_room: room, online: true)

      allow(redis).to receive(:get).with("settings:user:#{recipient_user.id}").and_return('{"emailscene":true}')
      expect(redis).to receive(:exists?).with("email_scene_cooldown:#{recipient_user.id}:#{room.id}").and_return(true)
      expect(redis).not_to receive(:setex)
      expect(EmailService).not_to receive(:send_email)

      described_class.notify_if_needed(room.id, 'content', sender)
    end

    it 'does not email when emailscene setting is disabled' do
      room = create(:room)
      recipient_user = create(:user)
      recipient_character = create(:character, user: recipient_user)
      create(:character_instance, character: recipient_character, current_room: room, online: false)
      sender = create(:character_instance, current_room: room, online: true)

      allow(redis).to receive(:get).with("settings:user:#{recipient_user.id}").and_return('{"emailscene":false}')

      expect(redis).not_to receive(:exists?)
      expect(EmailService).not_to receive(:send_email)

      described_class.notify_if_needed(room.id, 'content', sender)
    end
  end
end
