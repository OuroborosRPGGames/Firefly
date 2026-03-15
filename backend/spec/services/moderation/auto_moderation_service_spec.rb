# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AutoModerationService do
  let(:user) { create(:user, username: 'testuser') }
  let(:character) { create(:character, user: user) }
  let(:room) { create(:room) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, online: true)
  end

  # Create a mock AbuseCheck
  let(:abuse_check) do
    check = double('AbuseCheck',
                   id: 1,
                   user: user,
                   user_id: user.id,
                   character_instance: character_instance,
                   abuse_category: 'hate_speech',
                   severity: 'critical',
                   ip_address: '192.168.1.100',
                   message_content: 'This is offensive content',
                   abuse_confirmed?: true,
                   pre_llm_detected?: false)
    allow(check).to receive(:mark_actioned!)
    check
  end

  before do
    # Mock StaffAlertService
    allow(StaffAlertService).to receive(:broadcast_to_staff)

    # Mock BroadcastService
    allow(BroadcastService).to receive(:to_room)

    # Mock GameSetting
    allow(GameSetting).to receive(:get).and_return(nil)
    allow(GameSetting).to receive(:set)
  end

  describe 'constants' do
    it 'defines SERIOUS_ABUSE_CATEGORIES' do
      expect(described_class::SERIOUS_ABUSE_CATEGORIES).to include(
        'hate_speech', 'threats', 'doxxing', 'csam', 'exploit_attempt'
      )
    end

    it 'defines GRADUATED_RESPONSE_CATEGORIES' do
      expect(described_class::GRADUATED_RESPONSE_CATEGORIES).to include(
        'spam', 'immersion_breaking', 'griefing'
      )
    end

    it 'defines REGISTRATION_FREEZE_KEY' do
      expect(described_class::REGISTRATION_FREEZE_KEY).to eq('registration_frozen_until')
    end

    it 'defines duration constants from GameConfig' do
      expect(described_class::IP_BAN_DURATION).to be_a(Integer)
      expect(described_class::RANGE_BAN_DURATION).to be_a(Integer)
      expect(described_class::REGISTRATION_FREEZE_DURATION).to be_a(Integer)
      expect(described_class::ONE_WEEK_SUSPENSION).to be_a(Integer)
      expect(described_class::TEMP_MUTE_DURATION).to be_a(Integer)
    end

    it 'has SERIOUS_ABUSE_CATEGORIES frozen' do
      expect(described_class::SERIOUS_ABUSE_CATEGORIES).to be_frozen
    end

    it 'has GRADUATED_RESPONSE_CATEGORIES frozen' do
      expect(described_class::GRADUATED_RESPONSE_CATEGORIES).to be_frozen
    end
  end

  describe '.execute_actions' do
    context 'when check is not confirmed' do
      let(:unconfirmed_check) do
        double('AbuseCheck',
               abuse_confirmed?: false,
               pre_llm_detected?: false)
      end

      it 'returns empty array' do
        result = described_class.execute_actions(unconfirmed_check)
        expect(result).to eq([])
      end
    end

    context 'when check is pre-llm detected' do
      let(:pre_llm_check) do
        check = double('AbuseCheck',
                       id: 2,
                       user: user,
                       abuse_category: 'hate_speech',
                       ip_address: '192.168.1.100',
                       abuse_confirmed?: false,
                       pre_llm_detected?: true)
        allow(check).to receive(:mark_actioned!)
        check
      end

      before do
        allow(described_class).to receive(:execute_serious_abuse_actions).and_return([])
      end

      it 'processes the check' do
        described_class.execute_actions(pre_llm_check)
        expect(described_class).to have_received(:execute_serious_abuse_actions).with(pre_llm_check)
      end
    end

    context 'when category is serious abuse' do
      described_class::SERIOUS_ABUSE_CATEGORIES.each do |category|
        it "calls execute_serious_abuse_actions for #{category}" do
          check = double('AbuseCheck',
                         id: 1,
                         user: user,
                         abuse_category: category,
                         abuse_confirmed?: true,
                         pre_llm_detected?: false)
          allow(described_class).to receive(:execute_serious_abuse_actions).and_return([])

          described_class.execute_actions(check)

          expect(described_class).to have_received(:execute_serious_abuse_actions).with(check)
        end
      end
    end

    context 'when category is graduated response' do
      described_class::GRADUATED_RESPONSE_CATEGORIES.each do |category|
        it "calls execute_graduated_response for #{category}" do
          check = double('AbuseCheck',
                         id: 1,
                         user: user,
                         abuse_category: category,
                         abuse_confirmed?: true,
                         pre_llm_detected?: false)
          allow(described_class).to receive(:execute_graduated_response).and_return([])

          described_class.execute_actions(check)

          expect(described_class).to have_received(:execute_graduated_response).with(check)
        end
      end
    end

    context 'when category is unknown' do
      it 'defaults to serious abuse handling' do
        check = double('AbuseCheck',
                       id: 1,
                       user: user,
                       abuse_category: 'unknown_category',
                       abuse_confirmed?: true,
                       pre_llm_detected?: false)
        allow(described_class).to receive(:execute_serious_abuse_actions).and_return([])

        described_class.execute_actions(check)

        expect(described_class).to have_received(:execute_serious_abuse_actions).with(check)
      end
    end

    context 'when error occurs' do
      it 'catches error and returns empty array' do
        allow(abuse_check).to receive(:abuse_category).and_raise(StandardError, 'Test error')

        result = described_class.execute_actions(abuse_check)

        expect(result).to eq([])
      end

      it 'notifies staff of the error' do
        allow(abuse_check).to receive(:abuse_category).and_raise(StandardError, 'Test error')

        described_class.execute_actions(abuse_check)

        expect(StaffAlertService).to have_received(:broadcast_to_staff)
          .with(/AUTO-MOD ERROR/)
      end
    end
  end

  describe '.execute_serious_abuse_actions' do
    let(:ip_ban_action) { double('ModerationAction', action_type: 'ip_ban') }
    let(:range_ban_action) { double('ModerationAction', action_type: 'range_ban') }
    let(:freeze_action) { double('ModerationAction', action_type: 'registration_freeze') }
    let(:suspend_action) { double('ModerationAction', action_type: 'suspend') }
    let(:logout_action) { double('ModerationAction', action_type: 'logout') }

    before do
      # Mock IpBan
      allow(IpBan).to receive(:ban_ip!)

      # Mock ModerationAction creation methods
      allow(ModerationAction).to receive(:create_ip_ban).and_return(ip_ban_action)
      allow(ModerationAction).to receive(:create_range_ban).and_return(range_ban_action)
      allow(ModerationAction).to receive(:create_registration_freeze).and_return(freeze_action)
      allow(ModerationAction).to receive(:create_suspension).and_return(suspend_action)
      allow(ModerationAction).to receive(:create_logout).and_return(logout_action)

      # Mock user methods
      allow(user).to receive(:suspend!)
      allow(user).to receive(:characters).and_return([character])
      allow(character).to receive(:character_instances).and_return(
        double(where: double(each: [].each))
      )
    end

    it 'bans the IP address' do
      described_class.execute_serious_abuse_actions(abuse_check)

      expect(IpBan).to have_received(:ban_ip!).with(
        '192.168.1.100',
        hash_including(:reason, :expires_at)
      )
    end

    it 'bans the IP range' do
      described_class.execute_serious_abuse_actions(abuse_check)

      expect(IpBan).to have_received(:ban_ip!).with(
        '192.168.1.0/24',
        hash_including(:reason, :expires_at)
      )
    end

    it 'freezes registration' do
      described_class.execute_serious_abuse_actions(abuse_check)

      expect(GameSetting).to have_received(:set).with(
        'registration_frozen_until',
        anything,
        type: 'string'
      )
    end

    it 'suspends the user permanently' do
      described_class.execute_serious_abuse_actions(abuse_check)

      expect(user).to have_received(:suspend!).with(
        hash_including(:reason, until_time: nil)
      )
    end

    it 'marks the check as actioned' do
      described_class.execute_serious_abuse_actions(abuse_check)

      expect(abuse_check).to have_received(:mark_actioned!).with('moderated')
    end

    it 'notifies staff' do
      described_class.execute_serious_abuse_actions(abuse_check)

      expect(StaffAlertService).to have_received(:broadcast_to_staff)
    end

    it 'returns array of actions' do
      result = described_class.execute_serious_abuse_actions(abuse_check)

      expect(result).to be_an(Array)
    end

    context 'when IP address is nil' do
      let(:no_ip_check) do
        check = double('AbuseCheck',
                       id: 1,
                       user: user,
                       abuse_category: 'hate_speech',
                       severity: 'critical',
                       ip_address: nil,
                       message_content: 'Test',
                       character_instance: character_instance)
        allow(check).to receive(:mark_actioned!)
        check
      end

      it 'skips IP ban' do
        described_class.execute_serious_abuse_actions(no_ip_check)

        expect(IpBan).not_to have_received(:ban_ip!)
      end
    end

    context 'when IP address is empty' do
      let(:empty_ip_check) do
        check = double('AbuseCheck',
                       id: 1,
                       user: user,
                       abuse_category: 'hate_speech',
                       severity: 'critical',
                       ip_address: '  ',
                       message_content: 'Test',
                       character_instance: character_instance)
        allow(check).to receive(:mark_actioned!)
        check
      end

      it 'skips IP ban' do
        described_class.execute_serious_abuse_actions(empty_ip_check)

        expect(IpBan).not_to have_received(:ban_ip!)
      end
    end
  end

  describe '.execute_graduated_response' do
    let(:warning_action) { double('ModerationAction', action_type: 'warning') }
    let(:mute_action) { double('ModerationAction', action_type: 'temp_mute') }
    let(:suspend_action) { double('ModerationAction', action_type: 'suspend') }
    let(:logout_action) { double('ModerationAction', action_type: 'logout') }

    let(:spam_check) do
      check = double('AbuseCheck',
                     id: 1,
                     user: user,
                     user_id: user.id,
                     abuse_category: 'spam',
                     severity: 'low',
                     ip_address: '192.168.1.100',
                     message_content: 'Buy now! Click here!',
                     character_instance: character_instance)
      allow(check).to receive(:mark_actioned!)
      check
    end

    before do
      allow(ModerationAction).to receive(:where).and_return(
        double(where: double(where: double(count: 0)))
      )
      allow(ModerationAction).to receive(:create).and_return(warning_action)
      allow(ModerationAction).to receive(:create_suspension).and_return(suspend_action)
      allow(ModerationAction).to receive(:create_logout).and_return(logout_action)
      allow(user).to receive(:mute!)
      allow(user).to receive(:suspend!)
      allow(user).to receive(:characters).and_return([])
    end

    context 'when user is nil' do
      let(:no_user_check) do
        check = double('AbuseCheck',
                       id: 1,
                       user: nil,
                       abuse_category: 'spam',
                       abuse_confirmed?: true)
        check
      end

      it 'returns empty array' do
        result = described_class.execute_graduated_response(no_user_check)
        expect(result).to eq([])
      end
    end

    context 'first offense (warning_count = 0)' do
      before do
        allow(described_class).to receive(:warning_count).and_return(0)
      end

      it 'issues a warning' do
        described_class.execute_graduated_response(spam_check)

        expect(ModerationAction).to have_received(:create).with(
          hash_including(action_type: 'warning')
        )
      end

      it 'marks check as warned' do
        described_class.execute_graduated_response(spam_check)

        expect(spam_check).to have_received(:mark_actioned!).with('warned')
      end

      it 'does not mute user' do
        described_class.execute_graduated_response(spam_check)

        expect(user).not_to have_received(:mute!)
      end
    end

    context 'second offense (warning_count = 1)' do
      before do
        allow(described_class).to receive(:warning_count).and_return(1)
      end

      it 'issues a warning and temp mute' do
        described_class.execute_graduated_response(spam_check)

        expect(ModerationAction).to have_received(:create).at_least(:twice)
        expect(user).to have_received(:mute!)
      end

      it 'marks check as muted' do
        described_class.execute_graduated_response(spam_check)

        expect(spam_check).to have_received(:mark_actioned!).with('muted')
      end
    end

    context 'third+ offense (warning_count >= 2)' do
      before do
        allow(described_class).to receive(:warning_count).and_return(2)
      end

      it 'issues a warning and suspends' do
        described_class.execute_graduated_response(spam_check)

        expect(ModerationAction).to have_received(:create).at_least(:once)
        expect(user).to have_received(:suspend!)
      end

      it 'marks check as suspended' do
        described_class.execute_graduated_response(spam_check)

        expect(spam_check).to have_received(:mark_actioned!).with('suspended')
      end
    end
  end

  describe '.warning_count' do
    context 'when user is nil' do
      it 'returns 0' do
        expect(described_class.warning_count(nil, 'spam')).to eq(0)
      end
    end

    context 'when user exists' do
      let(:mock_dataset) do
        ds = double('Dataset')
        allow(ds).to receive(:where).and_return(ds)
        allow(ds).to receive(:count).and_return(2)
        ds
      end

      before do
        allow(ModerationAction).to receive(:where).and_return(mock_dataset)
      end

      it 'counts warnings in last 30 days' do
        result = described_class.warning_count(user, 'spam')

        expect(ModerationAction).to have_received(:where).with(user_id: user.id)
        expect(result).to eq(2)
      end
    end
  end

  describe '.registration_frozen?' do
    context 'when setting is nil' do
      before do
        allow(GameSetting).to receive(:get).with('registration_frozen_until').and_return(nil)
      end

      it 'returns false' do
        expect(described_class.registration_frozen?).to be false
      end
    end

    context 'when setting is empty' do
      before do
        allow(GameSetting).to receive(:get).with('registration_frozen_until').and_return('')
      end

      it 'returns false' do
        expect(described_class.registration_frozen?).to be false
      end
    end

    context 'when freeze time is in the past' do
      before do
        past_time = (Time.now - 3600).iso8601
        allow(GameSetting).to receive(:get).with('registration_frozen_until').and_return(past_time)
      end

      it 'returns false' do
        expect(described_class.registration_frozen?).to be false
      end
    end

    context 'when freeze time is in the future' do
      before do
        future_time = (Time.now + 3600).iso8601
        allow(GameSetting).to receive(:get).with('registration_frozen_until').and_return(future_time)
      end

      it 'returns true' do
        expect(described_class.registration_frozen?).to be true
      end
    end

    context 'when setting has invalid time format' do
      before do
        allow(GameSetting).to receive(:get).with('registration_frozen_until').and_return('not-a-time')
      end

      it 'returns false' do
        expect(described_class.registration_frozen?).to be false
      end
    end
  end

  describe '.registration_frozen_until' do
    context 'when setting is nil' do
      before do
        allow(GameSetting).to receive(:get).with('registration_frozen_until').and_return(nil)
      end

      it 'returns nil' do
        expect(described_class.registration_frozen_until).to be_nil
      end
    end

    context 'when freeze time is in the past' do
      before do
        past_time = (Time.now - 3600).iso8601
        allow(GameSetting).to receive(:get).with('registration_frozen_until').and_return(past_time)
      end

      it 'returns nil' do
        expect(described_class.registration_frozen_until).to be_nil
      end
    end

    context 'when freeze time is in the future' do
      let(:future_time) { Time.now + 3600 }

      before do
        allow(GameSetting).to receive(:get).with('registration_frozen_until').and_return(future_time.iso8601)
      end

      it 'returns the freeze time' do
        result = described_class.registration_frozen_until

        expect(result).to be_within(1).of(future_time)
      end
    end

    context 'when setting has invalid format' do
      before do
        allow(GameSetting).to receive(:get).with('registration_frozen_until').and_return('invalid')
      end

      it 'returns nil' do
        expect(described_class.registration_frozen_until).to be_nil
      end
    end
  end

  describe '.reverse_action!' do
    let(:moderation_action) do
      action = double('ModerationAction',
                      id: 1,
                      action_type: 'ip_ban',
                      ip_address: '192.168.1.100',
                      ip_range: nil,
                      user: user,
                      reversed: false)
      allow(action).to receive(:reverse!)
      action
    end

    let(:staff_user) { create(:user, username: 'staffuser') }

    context 'when action is already reversed' do
      before do
        allow(moderation_action).to receive(:reversed).and_return(true)
      end

      it 'returns false' do
        result = described_class.reverse_action!(moderation_action, by_user: staff_user, reason: 'Test')

        expect(result).to be false
      end
    end

    context 'when reversing ip_ban' do
      let(:ip_ban) { double('IpBan', deactivate!: true) }

      before do
        allow(IpBan).to receive(:where).and_return(double(first: ip_ban))
      end

      it 'deactivates the IP ban' do
        described_class.reverse_action!(moderation_action, by_user: staff_user, reason: 'Appeal granted')

        expect(ip_ban).to have_received(:deactivate!)
      end

      it 'marks action as reversed' do
        described_class.reverse_action!(moderation_action, by_user: staff_user, reason: 'Appeal granted')

        expect(moderation_action).to have_received(:reverse!).with(
          by_user: staff_user,
          reason: 'Appeal granted'
        )
      end

      it 'returns true on success' do
        result = described_class.reverse_action!(moderation_action, by_user: staff_user, reason: 'Test')

        expect(result).to be true
      end
    end

    context 'when reversing range_ban' do
      let(:range_ban_action) do
        action = double('ModerationAction',
                        id: 1,
                        action_type: 'range_ban',
                        ip_address: nil,
                        ip_range: '192.168.1.0/24',
                        user: user,
                        reversed: false)
        allow(action).to receive(:reverse!)
        action
      end

      let(:ip_ban) { double('IpBan', deactivate!: true) }

      before do
        allow(IpBan).to receive(:where).and_return(double(first: ip_ban))
      end

      it 'deactivates the range ban' do
        described_class.reverse_action!(range_ban_action, by_user: staff_user, reason: 'Test')

        expect(ip_ban).to have_received(:deactivate!)
      end
    end

    context 'when reversing suspend' do
      let(:suspend_action) do
        action = double('ModerationAction',
                        id: 1,
                        action_type: 'suspend',
                        ip_address: nil,
                        ip_range: nil,
                        user: user,
                        reversed: false)
        allow(action).to receive(:reverse!)
        action
      end

      before do
        allow(user).to receive(:unsuspend!)
      end

      it 'unsuspends the user' do
        described_class.reverse_action!(suspend_action, by_user: staff_user, reason: 'Test')

        expect(user).to have_received(:unsuspend!)
      end
    end

    context 'when reversing registration_freeze' do
      let(:freeze_action) do
        action = double('ModerationAction',
                        id: 1,
                        action_type: 'registration_freeze',
                        ip_address: nil,
                        ip_range: nil,
                        user: nil,
                        reversed: false)
        allow(action).to receive(:reverse!)
        action
      end

      it 'clears the registration freeze' do
        described_class.reverse_action!(freeze_action, by_user: staff_user, reason: 'Test')

        expect(GameSetting).to have_received(:set).with(
          'registration_frozen_until',
          nil,
          type: 'string'
        )
      end
    end

    context 'when error occurs' do
      before do
        allow(IpBan).to receive(:where).and_raise(StandardError, 'DB error')
      end

      it 'returns false' do
        result = described_class.reverse_action!(moderation_action, by_user: staff_user, reason: 'Test')

        expect(result).to be false
      end
    end
  end

  describe 'private helper methods' do
    describe 'IP range calculation' do
      # Test via execute_serious_abuse_actions which calls ban_ip_range

      it 'calculates /24 range correctly' do
        allow(IpBan).to receive(:ban_ip!)
        allow(ModerationAction).to receive(:create_ip_ban)
        allow(ModerationAction).to receive(:create_range_ban)
        allow(ModerationAction).to receive(:create_registration_freeze)
        allow(ModerationAction).to receive(:create_suspension)
        allow(ModerationAction).to receive(:create_logout)
        allow(user).to receive(:suspend!)
        allow(user).to receive(:characters).and_return([])

        described_class.execute_serious_abuse_actions(abuse_check)

        expect(IpBan).to have_received(:ban_ip!).with(
          '192.168.1.0/24',
          hash_including(:reason)
        )
      end
    end
  end

  describe 'staff notifications' do
    before do
      allow(IpBan).to receive(:ban_ip!)
      allow(ModerationAction).to receive(:create_ip_ban)
      allow(ModerationAction).to receive(:create_range_ban)
      allow(ModerationAction).to receive(:create_registration_freeze)
      allow(ModerationAction).to receive(:create_suspension)
      allow(ModerationAction).to receive(:create_logout)
      allow(user).to receive(:suspend!)
      allow(user).to receive(:characters).and_return([])
    end

    it 'includes user information in notification' do
      described_class.execute_serious_abuse_actions(abuse_check)

      expect(StaffAlertService).to have_received(:broadcast_to_staff)
        .with(/testuser/i)
    end

    it 'includes abuse category in notification' do
      described_class.execute_serious_abuse_actions(abuse_check)

      expect(StaffAlertService).to have_received(:broadcast_to_staff)
        .with(/hate_speech/)
    end

    it 'includes severity in notification' do
      described_class.execute_serious_abuse_actions(abuse_check)

      expect(StaffAlertService).to have_received(:broadcast_to_staff)
        .with(/critical/)
    end
  end

  describe 'Discord notifications' do
    before do
      allow(IpBan).to receive(:ban_ip!)
      allow(ModerationAction).to receive(:create_ip_ban)
      allow(ModerationAction).to receive(:create_range_ban)
      allow(ModerationAction).to receive(:create_registration_freeze)
      allow(ModerationAction).to receive(:create_suspension)
      allow(ModerationAction).to receive(:create_logout)
      allow(user).to receive(:suspend!)
      allow(user).to receive(:characters).and_return([])
    end

    context 'when webhook is not configured' do
      before do
        allow(GameSetting).to receive(:get).with('staff_discord_webhook').and_return(nil)
      end

      it 'does not attempt to send webhook' do
        expect(Faraday).not_to receive(:post)

        described_class.execute_serious_abuse_actions(abuse_check)
      end
    end

    context 'when webhook is configured' do
      let(:webhook_url) { 'https://discord.com/api/webhooks/123/abc' }

      before do
        allow(GameSetting).to receive(:get).with('staff_discord_webhook').and_return(webhook_url)
        allow(Faraday).to receive(:post).and_return(double(status: 200))
      end

      it 'sends webhook to Discord' do
        described_class.execute_serious_abuse_actions(abuse_check)

        expect(Faraday).to have_received(:post).with(webhook_url)
      end
    end

    context 'when webhook fails' do
      before do
        allow(GameSetting).to receive(:get).with('staff_discord_webhook').and_return('http://test.com')
        allow(Faraday).to receive(:post).and_raise(Faraday::Error.new('Connection failed'))
      end

      it 'does not raise error' do
        expect {
          described_class.execute_serious_abuse_actions(abuse_check)
        }.not_to raise_error
      end
    end
  end

  describe 'character logout' do
    let(:online_instance) do
      instance = double('CharacterInstance',
                        id: 1,
                        current_room_id: room.id,
                        online: true)
      allow(instance).to receive(:update)
      instance
    end

    before do
      allow(IpBan).to receive(:ban_ip!)
      allow(ModerationAction).to receive(:create_ip_ban)
      allow(ModerationAction).to receive(:create_range_ban)
      allow(ModerationAction).to receive(:create_registration_freeze)
      allow(ModerationAction).to receive(:create_suspension)
      allow(ModerationAction).to receive(:create_logout)
      allow(user).to receive(:suspend!)
      allow(user).to receive(:characters).and_return([character])
      allow(character).to receive(:full_name).and_return('Test Character')

      instances_dataset = double('Dataset')
      allow(instances_dataset).to receive(:where).with(online: true).and_return(instances_dataset)
      allow(instances_dataset).to receive(:each).and_yield(online_instance)
      allow(character).to receive(:character_instances).and_return(instances_dataset)
    end

    it 'logs out all online character instances' do
      described_class.execute_serious_abuse_actions(abuse_check)

      expect(online_instance).to have_received(:update).with(
        hash_including(online: false)
      )
    end

    it 'broadcasts disconnect message to room' do
      described_class.execute_serious_abuse_actions(abuse_check)

      expect(BroadcastService).to have_received(:to_room).with(
        room.id,
        /disconnected by the system/,
        hash_including(:exclude)
      )
    end
  end
end
