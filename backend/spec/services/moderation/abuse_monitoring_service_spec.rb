# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AbuseMonitoringService do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end

  before do
    # Ensure monitoring is enabled for most tests
    GameSetting.set(described_class::ENABLED_KEY, true, type: 'boolean')
    GameSetting.set(described_class::DELAY_MODE_KEY, false, type: 'boolean')
    GameSetting.set(described_class::THRESHOLD_KEY, 100, type: 'integer')
  end

  describe 'constants' do
    it 'defines ENABLED_KEY' do
      expect(described_class::ENABLED_KEY).to eq('abuse_monitoring_enabled')
    end

    it 'defines DELAY_MODE_KEY' do
      expect(described_class::DELAY_MODE_KEY).to eq('abuse_monitoring_delay_mode')
    end

    it 'defines THRESHOLD_KEY' do
      expect(described_class::THRESHOLD_KEY).to eq('abuse_monitoring_playtime_threshold')
    end

    it 'defines DEFAULT_THRESHOLD_HOURS' do
      expect(described_class::DEFAULT_THRESHOLD_HOURS).to eq(100)
    end
  end

  describe '.enabled?' do
    it 'returns true when enabled' do
      GameSetting.set(described_class::ENABLED_KEY, true, type: 'boolean')
      expect(described_class.enabled?).to be true
    end

    it 'returns false when disabled' do
      GameSetting.set(described_class::ENABLED_KEY, false, type: 'boolean')
      expect(described_class.enabled?).to be false
    end
  end

  describe '.enable!' do
    it 'enables abuse monitoring' do
      GameSetting.set(described_class::ENABLED_KEY, false, type: 'boolean')
      expect { described_class.enable! }.to change { described_class.enabled? }.from(false).to(true)
    end

    it 'returns true' do
      expect(described_class.enable!).to be true
    end
  end

  describe '.disable!' do
    it 'disables abuse monitoring' do
      GameSetting.set(described_class::ENABLED_KEY, true, type: 'boolean')
      expect { described_class.disable! }.to change { described_class.enabled? }.from(true).to(false)
    end

    it 'returns true' do
      expect(described_class.disable!).to be true
    end
  end

  describe '.delay_mode?' do
    it 'returns true when delay mode is enabled' do
      GameSetting.set(described_class::DELAY_MODE_KEY, true, type: 'boolean')
      expect(described_class.delay_mode?).to be true
    end

    it 'returns false when delay mode is disabled' do
      GameSetting.set(described_class::DELAY_MODE_KEY, false, type: 'boolean')
      expect(described_class.delay_mode?).to be false
    end
  end

  describe '.set_delay_mode!' do
    it 'enables delay mode' do
      GameSetting.set(described_class::DELAY_MODE_KEY, false, type: 'boolean')
      expect { described_class.set_delay_mode!(true) }.to change { described_class.delay_mode? }.from(false).to(true)
    end

    it 'disables delay mode' do
      GameSetting.set(described_class::DELAY_MODE_KEY, true, type: 'boolean')
      expect { described_class.set_delay_mode!(false) }.to change { described_class.delay_mode? }.from(true).to(false)
    end

    it 'returns true' do
      expect(described_class.set_delay_mode!(true)).to be true
    end
  end

  describe '.playtime_threshold_hours' do
    it 'returns the configured threshold' do
      GameSetting.set(described_class::THRESHOLD_KEY, 50, type: 'integer')
      expect(described_class.playtime_threshold_hours).to eq(50)
    end

    it 'returns default threshold when not set' do
      GameSetting.where(key: described_class::THRESHOLD_KEY).delete
      GameSetting.clear_cache!
      expect(described_class.playtime_threshold_hours).to eq(described_class::DEFAULT_THRESHOLD_HOURS)
    end
  end

  describe '.set_playtime_threshold!' do
    it 'sets the playtime threshold' do
      expect { described_class.set_playtime_threshold!(200) }
        .to change { described_class.playtime_threshold_hours }.to(200)
    end

    it 'returns true' do
      expect(described_class.set_playtime_threshold!(50)).to be true
    end

    it 'converts string to integer' do
      described_class.set_playtime_threshold!('150')
      expect(described_class.playtime_threshold_hours).to eq(150)
    end
  end

  describe '.exempt?' do
    context 'when user has enough playtime' do
      before do
        user.update(total_playtime_seconds: 101 * 3600) # 101 hours
      end

      it 'returns true' do
        expect(described_class.exempt?(character_instance)).to be true
      end
    end

    context 'when user does not have enough playtime' do
      before do
        user.update(total_playtime_seconds: 50 * 3600) # 50 hours
      end

      it 'returns false' do
        expect(described_class.exempt?(character_instance)).to be false
      end
    end

    context 'when user has exactly the threshold playtime' do
      before do
        user.update(total_playtime_seconds: 100 * 3600) # 100 hours exactly
      end

      it 'returns true' do
        expect(described_class.exempt?(character_instance)).to be true
      end
    end

    context 'when override is active' do
      before do
        user.update(total_playtime_seconds: 200 * 3600) # 200 hours - well above threshold
        staff_user = create(:user, :admin)
        AbuseMonitoringOverride.activate!(staff_user: staff_user, reason: 'Test override')
      end

      it 'returns false even with high playtime' do
        expect(described_class.exempt?(character_instance)).to be false
      end
    end

    context 'when character_instance is nil' do
      it 'returns false' do
        expect(described_class.exempt?(nil)).to be false
      end
    end

    context 'when user has nil playtime' do
      before do
        user.update(total_playtime_seconds: nil)
      end

      it 'returns false' do
        expect(described_class.exempt?(character_instance)).to be false
      end
    end

    context 'when character_instance has no character' do
      it 'returns false' do
        ci_mock = instance_double(CharacterInstance, character: nil)
        expect(described_class.exempt?(ci_mock)).to be false
      end
    end
  end

  describe '.override_active?' do
    it 'returns false when no override exists' do
      expect(described_class.override_active?).to be false
    end

    it 'returns true when an active override exists' do
      staff_user = create(:user, :admin)
      AbuseMonitoringOverride.activate!(staff_user: staff_user)
      expect(described_class.override_active?).to be true
    end

    it 'returns false when override has expired' do
      staff_user = create(:user, :admin)
      override = AbuseMonitoringOverride.activate!(staff_user: staff_user, duration_seconds: 1)
      override.update(active_until: Time.now - 60)
      expect(described_class.override_active?).to be false
    end
  end

  describe '.current_override' do
    it 'returns nil when no override exists' do
      expect(described_class.current_override).to be_nil
    end

    it 'returns the current active override' do
      staff_user = create(:user, :admin)
      override = AbuseMonitoringOverride.activate!(staff_user: staff_user)
      expect(described_class.current_override).to eq(override)
    end

    it 'returns nil when override has expired' do
      staff_user = create(:user, :admin)
      override = AbuseMonitoringOverride.activate!(staff_user: staff_user, duration_seconds: 1)
      override.update(active_until: Time.now - 60)
      expect(described_class.current_override).to be_nil
    end
  end

  describe '.activate_override!' do
    let(:staff_user) { create(:user, :admin) }

    it 'creates an active override' do
      override = described_class.activate_override!(staff_user: staff_user)
      expect(override.active).to be true
    end

    it 'sets the correct expiry time with default duration' do
      override = described_class.activate_override!(staff_user: staff_user)
      expect(override.active_until).to be_within(5).of(Time.now + 3600)
    end

    it 'sets the correct expiry time with custom duration' do
      override = described_class.activate_override!(staff_user: staff_user, duration_seconds: 7200)
      expect(override.active_until).to be_within(5).of(Time.now + 7200)
    end

    it 'stores the reason' do
      override = described_class.activate_override!(staff_user: staff_user, reason: 'Suspicious activity')
      expect(override.reason).to eq('Suspicious activity')
    end

    it 'associates with the triggering user' do
      override = described_class.activate_override!(staff_user: staff_user)
      expect(override.triggered_by_user_id).to eq(staff_user.id)
    end
  end

  describe '.deactivate_overrides!' do
    it 'deactivates all active overrides' do
      staff_user = create(:user, :admin)
      AbuseMonitoringOverride.activate!(staff_user: staff_user)
      AbuseMonitoringOverride.activate!(staff_user: staff_user)

      count = described_class.deactivate_overrides!
      expect(count).to eq(2)
      expect(AbuseMonitoringOverride.where(active: true).count).to eq(0)
    end

    it 'returns 0 when no overrides exist' do
      expect(described_class.deactivate_overrides!).to eq(0)
    end
  end

  describe '.check_message' do
    let(:content) { 'Hello, how are you?' }
    let(:message_type) { 'say' }
    let(:context) { {} }

    context 'when monitoring is disabled' do
      before do
        described_class.disable!
      end

      it 'allows the message' do
        result = described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:allowed]).to be true
      end

      it 'does not create an abuse check record' do
        expect {
          described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
        }.not_to change { AbuseCheck.count }
      end

      it 'sets delayed to false' do
        result = described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:delayed]).to be false
      end

      it 'has nil check_id' do
        result = described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:check_id]).to be_nil
      end
    end

    context 'with empty content' do
      before do
        allow(ContentScreeningService).to receive(:screen).and_return({ flagged: false })
      end

      it 'allows empty string content' do
        result = described_class.check_message(
          content: '',
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:allowed]).to be true
      end

      it 'allows whitespace-only content' do
        result = described_class.check_message(
          content: '   ',
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:allowed]).to be true
      end

      it 'allows nil content' do
        result = described_class.check_message(
          content: nil,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:allowed]).to be true
      end
    end

    context 'when pre-LLM screening detects an exploit' do
      let(:exploit_content) { "'; DROP TABLE users; --" }

      before do
        allow(ContentScreeningService).to receive(:screen).and_return({
          flagged: true,
          category: 'exploit_attempt',
          exploit_type: 'sql_injection',
          severity: 'critical',
          details: { pattern_matched: 'DROP TABLE' }
        })
        allow(AutoModerationService).to receive(:execute_actions).and_return([])
      end

      it 'denies the message' do
        result = described_class.check_message(
          content: exploit_content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:allowed]).to be false
      end

      it 'creates an abuse check record' do
        expect {
          described_class.check_message(
            content: exploit_content,
            message_type: message_type,
            character_instance: character_instance
          )
        }.to change { AbuseCheck.count }.by(1)
      end

      it 'executes moderation actions' do
        expect(AutoModerationService).to receive(:execute_actions)
        described_class.check_message(
          content: exploit_content,
          message_type: message_type,
          character_instance: character_instance
        )
      end

      it 'returns the check_id' do
        result = described_class.check_message(
          content: exploit_content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:check_id]).not_to be_nil
      end

      it 'includes reason in result' do
        result = described_class.check_message(
          content: exploit_content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:reason]).to include('exploit')
      end

      it 'sets delayed to true for denied messages' do
        result = described_class.check_message(
          content: exploit_content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:delayed]).to be true
      end
    end

    context 'when user is exempt from LLM checks' do
      before do
        user.update(total_playtime_seconds: 200 * 3600) # 200 hours
        allow(ContentScreeningService).to receive(:screen).and_return({ flagged: false })
      end

      it 'allows the message without creating an abuse check' do
        result = described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:allowed]).to be true
      end

      it 'does not create an abuse check record' do
        expect {
          described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
        }.not_to change { AbuseCheck.count }
      end
    end

    context 'in async mode (non-delay mode)' do
      before do
        described_class.set_delay_mode!(false)
        allow(ContentScreeningService).to receive(:screen).and_return({ flagged: false })
      end

      it 'allows the message immediately' do
        result = described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:allowed]).to be true
      end

      it 'creates an abuse check record' do
        expect {
          described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
        }.to change { AbuseCheck.count }.by(1)
      end

      it 'returns the check_id' do
        result = described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:check_id]).not_to be_nil
      end

      it 'sets delayed to false' do
        result = described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:delayed]).to be false
      end

      it 'marks the check as not delayed' do
        described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: character_instance
        )
        check = AbuseCheck.last
        expect(check.message_delayed).to be false
      end
    end

    context 'in sync mode (delay mode)' do
      before do
        described_class.set_delay_mode!(true)
        allow(ContentScreeningService).to receive(:screen).and_return({ flagged: false })
      end

      context 'when Gemini does not flag the content' do
        before do
          allow(AbuseDetectionService).to receive(:gemini_check).and_return({
            flagged: false,
            confidence: 0.1,
            reasoning: 'Normal greeting'
          })
        end

        it 'allows the message' do
          result = described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          expect(result[:allowed]).to be true
        end

        it 'sets delayed to true' do
          result = described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          expect(result[:delayed]).to be true
        end

        it 'updates the abuse check with Gemini result' do
          described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          check = AbuseCheck.last
          expect(check.gemini_flagged).to be false
          expect(check.status).to eq('cleared')
        end

        it 'records Gemini confidence' do
          described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          check = AbuseCheck.last
          expect(check.gemini_confidence).to eq(0.1)
        end

        it 'records Gemini reasoning' do
          described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          check = AbuseCheck.last
          expect(check.gemini_reasoning).to eq('Normal greeting')
        end
      end

      context 'when Gemini flags content but Claude rejects' do
        before do
          allow(AbuseDetectionService).to receive(:gemini_check).and_return({
            flagged: true,
            confidence: 0.7,
            reasoning: 'Possible harassment',
            category: 'harassment'
          })
          allow(AbuseDetectionService).to receive(:claude_verify).and_return({
            confirmed: false,
            confidence: 0.3,
            reasoning: 'In-character conflict, not real harassment'
          })
        end

        it 'allows the message' do
          result = described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          expect(result[:allowed]).to be true
        end

        it 'updates the abuse check with both results' do
          described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          check = AbuseCheck.last
          expect(check.gemini_flagged).to be true
          expect(check.claude_confirmed).to be false
          expect(check.status).to eq('cleared')
        end

        it 'sets category to false_positive when Claude rejects' do
          described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          check = AbuseCheck.last
          expect(check.abuse_category).to eq('false_positive')
        end
      end

      context 'when both Gemini and Claude confirm abuse' do
        before do
          allow(AbuseDetectionService).to receive(:gemini_check).and_return({
            flagged: true,
            confidence: 0.9,
            reasoning: 'Clear harassment',
            category: 'harassment'
          })
          allow(AbuseDetectionService).to receive(:claude_verify).and_return({
            confirmed: true,
            confidence: 0.95,
            reasoning: 'OOC harassment confirmed',
            category: 'harassment',
            severity: 'high'
          })
          allow(AutoModerationService).to receive(:execute_actions).and_return([])
        end

        it 'denies the message' do
          result = described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          expect(result[:allowed]).to be false
        end

        it 'updates the abuse check with confirmed status' do
          described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          check = AbuseCheck.last
          expect(check.claude_confirmed).to be true
          expect(check.status).to eq('confirmed')
        end

        it 'executes moderation actions' do
          expect(AutoModerationService).to receive(:execute_actions)
          described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
        end

        it 'records severity' do
          described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          check = AbuseCheck.last
          expect(check.severity).to eq('high')
        end

        it 'records processing time' do
          described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          check = AbuseCheck.last
          expect(check.processing_time_ms).not_to be_nil
        end

        it 'includes reason in denial result' do
          result = described_class.check_message(
            content: content,
            message_type: message_type,
            character_instance: character_instance
          )
          expect(result[:reason]).to include('moderation')
        end
      end
    end

    context 'when an error occurs' do
      before do
        allow(ContentScreeningService).to receive(:screen).and_raise(StandardError.new('Test error'))
      end

      it 'allows the message on error' do
        result = described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:allowed]).to be true
      end

      it 'includes error in result' do
        result = described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: character_instance
        )
        expect(result[:error]).to include('Test error')
      end
    end

    context 'with universe theme context' do
      let(:themed_universe) { create(:universe, theme: 'cyberpunk') }
      let(:themed_world) { create(:world, universe: themed_universe) }
      let(:themed_zone) { create(:zone, world: themed_world) }
      let(:themed_location) { create(:location, zone: themed_zone) }
      let(:themed_room) { create(:room, location: themed_location) }
      let(:themed_character_instance) do
        create(:character_instance,
               character: character,
               current_room: themed_room,
               reality: reality,
               online: true)
      end

      before do
        allow(ContentScreeningService).to receive(:screen).and_return({ flagged: false })
      end

      it 'passes universe theme to abuse check context' do
        described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: themed_character_instance
        )
        check = AbuseCheck.last
        context_data = check.parsed_context
        expect(context_data['universe_theme']).to eq('cyberpunk')
      end
    end

    context 'when room has no location' do
      let(:orphan_room) { create(:room) }
      let(:orphan_ci) do
        create(:character_instance,
               character: character,
               current_room: orphan_room,
               reality: reality,
               online: true)
      end

      before do
        # Stub location to return nil to simulate a room without a location
        allow(orphan_room).to receive(:location).and_return(nil)
        allow(orphan_ci).to receive(:current_room).and_return(orphan_room)
        allow(ContentScreeningService).to receive(:screen).and_return({ flagged: false })
      end

      it 'defaults to fantasy theme' do
        described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: orphan_ci
        )
        check = AbuseCheck.last
        expect(check.parsed_context['universe_theme']).to eq('fantasy')
      end
    end
  end

  describe '.process_pending_checks!' do
    context 'when monitoring is disabled' do
      before do
        described_class.disable!
      end

      it 'returns zero counts' do
        result = described_class.process_pending_checks!
        expect(result).to eq({ gemini: 0, escalated: 0, errors: 0 })
      end
    end

    context 'when there are pending Gemini checks' do
      let!(:pending_check) do
        AbuseCheck.create(
          character_instance_id: character_instance.id,
          user_id: user.id,
          message_type: 'say',
          message_content: 'Test message',
          status: 'pending'
        )
      end

      before do
        allow(AbuseDetectionService).to receive(:gemini_check).and_return({
          flagged: false,
          confidence: 0.1,
          reasoning: 'Normal content'
        })
      end

      it 'processes pending checks' do
        result = described_class.process_pending_checks!(limit: 10)
        expect(result[:gemini]).to eq(1)
      end

      it 'updates the check status to cleared' do
        described_class.process_pending_checks!(limit: 10)
        pending_check.refresh
        expect(pending_check.status).to eq('cleared')
      end

      it 'respects the limit parameter' do
        3.times do
          AbuseCheck.create(
            character_instance_id: character_instance.id,
            user_id: user.id,
            message_type: 'say',
            message_content: 'Test',
            status: 'pending'
          )
        end
        result = described_class.process_pending_checks!(limit: 2)
        expect(result[:gemini]).to eq(2)
      end
    end

    context 'when Gemini flags content during batch processing' do
      let!(:pending_check) do
        AbuseCheck.create(
          character_instance_id: character_instance.id,
          user_id: user.id,
          message_type: 'say',
          message_content: 'Suspicious message',
          status: 'pending'
        )
      end

      before do
        allow(AbuseDetectionService).to receive(:gemini_check).and_return({
          flagged: true,
          confidence: 0.8,
          reasoning: 'Potentially abusive',
          category: 'harassment'
        })
        # Also mock claude_verify since process_pending_checks! processes escalations too
        allow(AbuseDetectionService).to receive(:claude_verify).and_return({
          confirmed: true,
          confidence: 0.9,
          reasoning: 'Confirmed abusive',
          category: 'harassment',
          severity: 'medium'
        })
      end

      it 'updates the check status to flagged after Gemini check' do
        # Only process the Gemini check by checking status before escalation
        allow(AbuseCheck).to receive(:pending_escalation).and_return([])
        described_class.process_pending_checks!(limit: 10)
        pending_check.refresh
        expect(pending_check.status).to eq('flagged')
      end

      it 'records the Gemini flag' do
        allow(AbuseCheck).to receive(:pending_escalation).and_return([])
        described_class.process_pending_checks!(limit: 10)
        pending_check.refresh
        expect(pending_check.gemini_flagged).to be true
      end
    end

    context 'when there are pending escalations' do
      let!(:flagged_check) do
        AbuseCheck.create(
          character_instance_id: character_instance.id,
          user_id: user.id,
          message_type: 'say',
          message_content: 'Test message',
          status: 'flagged',
          gemini_flagged: true,
          gemini_confidence: 0.8,
          abuse_category: 'harassment'
        )
      end

      before do
        allow(AbuseDetectionService).to receive(:claude_verify).and_return({
          confirmed: false,
          confidence: 0.2,
          reasoning: 'False positive'
        })
      end

      it 'processes pending escalations' do
        result = described_class.process_pending_checks!(limit: 10)
        expect(result[:escalated]).to eq(1)
      end

      it 'updates the check status to cleared' do
        described_class.process_pending_checks!(limit: 10)
        flagged_check.refresh
        expect(flagged_check.status).to eq('cleared')
      end

      it 'records Claude did not confirm' do
        described_class.process_pending_checks!(limit: 10)
        flagged_check.refresh
        expect(flagged_check.claude_confirmed).to be false
      end
    end

    context 'when errors occur during processing' do
      let!(:pending_check) do
        AbuseCheck.create(
          character_instance_id: character_instance.id,
          user_id: user.id,
          message_type: 'say',
          message_content: 'Test message',
          status: 'pending'
        )
      end

      before do
        allow(AbuseDetectionService).to receive(:gemini_check).and_raise(StandardError.new('API error'))
      end

      it 'counts errors' do
        result = described_class.process_pending_checks!(limit: 10)
        expect(result[:errors]).to eq(1)
      end

      it 'continues processing other checks after error' do
        good_check = AbuseCheck.create(
          character_instance_id: character_instance.id,
          user_id: user.id,
          message_type: 'say',
          message_content: 'Good message',
          status: 'pending'
        )

        call_count = 0
        allow(AbuseDetectionService).to receive(:gemini_check) do
          call_count += 1
          if call_count == 1
            raise StandardError.new('API error')
          else
            { flagged: false, confidence: 0.1, reasoning: 'OK' }
          end
        end

        result = described_class.process_pending_checks!(limit: 10)
        expect(result[:errors]).to eq(1)
        expect(result[:gemini]).to eq(1)
      end
    end

    context 'when Claude confirms abuse during escalation' do
      let!(:flagged_check) do
        AbuseCheck.create(
          character_instance_id: character_instance.id,
          user_id: user.id,
          message_type: 'say',
          message_content: 'Harassing content',
          status: 'flagged',
          gemini_flagged: true,
          gemini_confidence: 0.9,
          abuse_category: 'harassment'
        )
      end

      before do
        allow(AbuseDetectionService).to receive(:claude_verify).and_return({
          confirmed: true,
          confidence: 0.95,
          reasoning: 'Confirmed harassment',
          category: 'harassment',
          severity: 'high'
        })
        allow(AutoModerationService).to receive(:execute_actions).and_return([])
      end

      it 'executes moderation actions' do
        expect(AutoModerationService).to receive(:execute_actions)
        described_class.process_pending_checks!(limit: 10)
      end

      it 'updates the check to confirmed' do
        described_class.process_pending_checks!(limit: 10)
        flagged_check.refresh
        expect(flagged_check.status).to eq('confirmed')
        expect(flagged_check.claude_confirmed).to be true
      end

      it 'records the severity' do
        described_class.process_pending_checks!(limit: 10)
        flagged_check.refresh
        expect(flagged_check.severity).to eq('high')
      end

      it 'records processing time' do
        described_class.process_pending_checks!(limit: 10)
        flagged_check.refresh
        expect(flagged_check.processing_time_ms).not_to be_nil
      end
    end

    context 'when escalation errors occur' do
      let!(:flagged_check) do
        AbuseCheck.create(
          character_instance_id: character_instance.id,
          user_id: user.id,
          message_type: 'say',
          message_content: 'Test',
          status: 'flagged',
          gemini_flagged: true
        )
      end

      before do
        allow(AbuseDetectionService).to receive(:claude_verify).and_raise(StandardError.new('Claude error'))
      end

      it 'counts escalation errors' do
        result = described_class.process_pending_checks!(limit: 10)
        expect(result[:errors]).to eq(1)
      end
    end
  end

  describe '.status' do
    before do
      described_class.enable!
      described_class.set_delay_mode!(true)
      described_class.set_playtime_threshold!(100)
    end

    it 'returns enabled status' do
      expect(described_class.status[:enabled]).to be true
    end

    it 'returns delay mode status' do
      expect(described_class.status[:delay_mode]).to be true
    end

    it 'returns playtime threshold' do
      expect(described_class.status[:playtime_threshold_hours]).to eq(100)
    end

    it 'returns override status' do
      expect(described_class.status[:override_active]).to be false
    end

    it 'returns nil override when none active' do
      expect(described_class.status[:override]).to be_nil
    end

    it 'returns pending checks count' do
      AbuseCheck.create(
        character_instance_id: character_instance.id,
        user_id: user.id,
        message_type: 'say',
        message_content: 'Test',
        status: 'pending'
      )
      expect(described_class.status[:pending_checks]).to eq(1)
    end

    it 'returns flagged checks count' do
      AbuseCheck.create(
        character_instance_id: character_instance.id,
        user_id: user.id,
        message_type: 'say',
        message_content: 'Test',
        status: 'flagged'
      )
      expect(described_class.status[:flagged_checks]).to eq(1)
    end

    it 'returns confirmed today count' do
      AbuseCheck.create(
        character_instance_id: character_instance.id,
        user_id: user.id,
        message_type: 'say',
        message_content: 'Test',
        status: 'confirmed'
      )
      expect(described_class.status[:confirmed_today]).to eq(1)
    end

    context 'with active override' do
      let(:staff_user) { create(:user, :admin) }

      it 'includes override_active as true' do
        AbuseMonitoringOverride.activate!(staff_user: staff_user, reason: 'Test')
        status = described_class.status
        expect(status[:override_active]).to be true
      end

      it 'includes override information' do
        AbuseMonitoringOverride.activate!(staff_user: staff_user, reason: 'Test')
        status = described_class.status
        expect(status[:override]).to include(reason: 'Test')
      end
    end

    context 'with disabled monitoring' do
      before do
        described_class.disable!
        described_class.set_delay_mode!(false)
      end

      it 'returns enabled as false' do
        expect(described_class.status[:enabled]).to be false
      end

      it 'returns delay_mode as false' do
        expect(described_class.status[:delay_mode]).to be false
      end
    end
  end

  describe 'error handling in check_message' do
    let(:content) { 'test message' }
    let(:message_type) { 'say' }

    before do
      allow(ContentScreeningService).to receive(:screen).and_return({ flagged: false })
    end

    it 'handles AbuseCheck.create_for_message errors gracefully' do
      allow(AbuseCheck).to receive(:create_for_message).and_raise(Sequel::Error.new('DB error'))

      result = described_class.check_message(
        content: content,
        message_type: message_type,
        character_instance: character_instance
      )

      expect(result[:allowed]).to be true
      expect(result[:error]).to include('DB error')
    end

    it 'handles unexpected errors during sync processing' do
      described_class.set_delay_mode!(true)

      allow(AbuseDetectionService).to receive(:gemini_check).and_raise(RuntimeError.new('Unexpected'))

      result = described_class.check_message(
        content: content,
        message_type: message_type,
        character_instance: character_instance
      )

      expect(result[:allowed]).to be true
      expect(result[:error]).to include('Unexpected')
    end
  end

  describe 'get_universe_theme edge cases' do
    let(:content) { 'test message' }
    let(:message_type) { 'say' }

    before do
      allow(ContentScreeningService).to receive(:screen).and_return({ flagged: false })
    end

    context 'when universe theme lookup returns empty string' do
      let(:test_universe) { create(:universe) }
      let(:test_world) { create(:world, universe: test_universe) }
      let(:test_zone) { create(:zone, world: test_world) }
      let(:test_location) { create(:location, zone: test_zone) }
      let(:test_room) { create(:room, location: test_location) }
      let(:test_ci) do
        create(:character_instance,
               character: character,
               current_room: test_room,
               reality: reality,
               online: true)
      end

      it 'defaults to fantasy when theme is empty' do
        # Stub the theme method to return empty string
        allow(test_universe).to receive(:theme).and_return('')
        allow(test_world).to receive(:universe).and_return(test_universe)

        described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: test_ci
        )
        check = AbuseCheck.last
        expect(check.parsed_context['universe_theme']).to eq('fantasy')
      end
    end

    context 'when universe theme lookup returns whitespace only' do
      let(:test_universe) { create(:universe) }
      let(:test_world) { create(:world, universe: test_universe) }
      let(:test_zone) { create(:zone, world: test_world) }
      let(:test_location) { create(:location, zone: test_zone) }
      let(:test_room) { create(:room, location: test_location) }
      let(:test_ci) do
        create(:character_instance,
               character: character,
               current_room: test_room,
               reality: reality,
               online: true)
      end

      it 'defaults to fantasy when theme is whitespace' do
        # Stub the theme method to return whitespace
        allow(test_universe).to receive(:theme).and_return('   ')
        allow(test_world).to receive(:universe).and_return(test_universe)

        described_class.check_message(
          content: content,
          message_type: message_type,
          character_instance: test_ci
        )
        check = AbuseCheck.last
        expect(check.parsed_context['universe_theme']).to eq('fantasy')
      end
    end
  end
end
