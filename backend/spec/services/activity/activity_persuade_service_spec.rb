# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityPersuadeService do
  let(:room) { create(:room) }
  let(:character) { create(:character, forename: 'Test', surname: 'Player') }
  let(:char_instance) { create(:character_instance, character: character, current_room: room, online: true) }

  let(:round) do
    double('ActivityRound',
           id: 1,
           persuade_npc_name: 'Merchant',
           persuade_npc_personality: 'A shrewd trader',
           persuade_goal: 'Get a discount',
           persuade_dc: 15,
           persuade_base_dc: 15,
           persuade_stat_id: nil,
           stat_set_a: nil)
  end

  let(:instance) do
    double('ActivityInstance',
           id: 1,
           room: room,
           persuade_attempts: 0,
           increment_persuade_attempts!: true)
  end

  let(:participant) do
    double('ActivityParticipant',
           id: 1,
           character_instance: char_instance,
           character: character,
           willpower_to_spend: 0,
           available_willpower: 3,
           update: true,
           use_willpower!: true)
  end

  let(:conversation) do
    double('LLMConversation',
           id: 1,
           system_prompt: 'You are a merchant.',
           llm_messages: [])
  end

  before do
    allow(GameSetting).to receive(:boolean).with('activity_persuade_enabled').and_return(true)
    allow(LLMConversation).to receive(:first).and_return(conversation)
    allow(LLMConversation).to receive(:create).and_return(conversation)
    allow(LLMMessage).to receive(:create)
    allow(LLM::TextGenerationService).to receive(:generate).and_return({
      success: true,
      text: 'I consider your offer.'
    })
    allow(GamePrompts).to receive(:get).and_return('prompt text')
    allow(round).to receive(:persuade_dc).with(anything).and_return(15)
    # Default to no observer effects for existing tests
    allow(ObserverEffectService).to receive(:persuade_dc_modifier).and_return(0)
  end

  describe 'PERSUASION_RATINGS' do
    it 'has 5 rating levels' do
      expect(described_class::PERSUASION_RATINGS.keys).to eq([1, 2, 3, 4, 5])
    end

    it 'rating 1 has +10 modifier' do
      expect(described_class::PERSUASION_RATINGS[1][:modifier]).to eq(10)
    end

    it 'rating 3 has 0 modifier' do
      expect(described_class::PERSUASION_RATINGS[3][:modifier]).to eq(0)
    end

    it 'rating 5 has -10 modifier' do
      expect(described_class::PERSUASION_RATINGS[5][:modifier]).to eq(-10)
    end

    it 'each rating has a label' do
      described_class::PERSUASION_RATINGS.each do |_key, config|
        expect(config).to have_key(:label)
      end
    end
  end

  describe 'EvaluationResult' do
    it 'has rating attribute' do
      result = described_class::EvaluationResult.new(rating: 3)
      expect(result.rating).to eq(3)
    end

    it 'has dc_modifier attribute' do
      result = described_class::EvaluationResult.new(dc_modifier: -5)
      expect(result.dc_modifier).to eq(-5)
    end

    it 'has adjusted_dc attribute' do
      result = described_class::EvaluationResult.new(adjusted_dc: 10)
      expect(result.adjusted_dc).to eq(10)
    end

    it 'has feedback attribute' do
      result = described_class::EvaluationResult.new(feedback: 'Good work')
      expect(result.feedback).to eq('Good work')
    end
  end

  describe 'AttemptResult' do
    it 'has success attribute' do
      result = described_class::AttemptResult.new(success: true)
      expect(result.success).to be true
    end

    it 'has roll_total attribute' do
      result = described_class::AttemptResult.new(roll_total: 18)
      expect(result.roll_total).to eq(18)
    end

    it 'has dc attribute' do
      result = described_class::AttemptResult.new(dc: 15)
      expect(result.dc).to eq(15)
    end

    it 'has npc_response attribute' do
      result = described_class::AttemptResult.new(npc_response: 'Very well.')
      expect(result.npc_response).to eq('Very well.')
    end

    it 'has attempts_made attribute' do
      result = described_class::AttemptResult.new(attempts_made: 2)
      expect(result.attempts_made).to eq(2)
    end
  end

  describe '.enabled?' do
    context 'when setting is true' do
      it 'returns true' do
        expect(described_class.enabled?).to be true
      end
    end

    context 'when setting is false' do
      before do
        allow(GameSetting).to receive(:boolean).with('activity_persuade_enabled').and_return(false)
      end

      it 'returns false' do
        expect(described_class.enabled?).to be false
      end
    end
  end

  describe '.npc_respond' do
    let(:user_message) do
      double('LLMMessage',
             role: 'user',
             content: 'Test Player says: Hello!',
             created_at: Time.now)
    end

    context 'when persuade is enabled' do
      before do
        # Simulate a message existing after add_message is called
        allow(conversation).to receive(:llm_messages).and_return([user_message])
      end

      it 'returns NPC response text' do
        result = described_class.npc_respond(instance, round, 'Hello!', character)

        expect(result).to eq('I consider your offer.')
      end

      it 'adds player message to conversation' do
        expect(LLMMessage).to receive(:create).with(
          hash_including(
            llm_conversation_id: 1,
            role: 'user',
            content: include('Test Player says: Hello!')
          )
        )

        described_class.npc_respond(instance, round, 'Hello!', character)
      end

      it 'adds NPC response to conversation' do
        expect(LLMMessage).to receive(:create).with(
          hash_including(
            llm_conversation_id: 1,
            role: 'assistant',
            content: 'I consider your offer.'
          )
        )

        described_class.npc_respond(instance, round, 'Hello!', character)
      end

      it 'calls LLM for response' do
        expect(LLM::TextGenerationService).to receive(:generate).with(
          hash_including(
            model: described_class::PERSUADE_MODEL,
            provider: described_class::PERSUADE_PROVIDER
          )
        )

        described_class.npc_respond(instance, round, 'Hello!', character)
      end
    end

    context 'when persuade is disabled' do
      before do
        allow(GameSetting).to receive(:boolean).with('activity_persuade_enabled').and_return(false)
      end

      it 'raises PersuadeError' do
        expect {
          described_class.npc_respond(instance, round, 'Hello!', character)
        }.to raise_error(described_class::PersuadeError, 'Persuade not enabled')
      end
    end

    context 'when LLM call fails' do
      before do
        allow(conversation).to receive(:llm_messages).and_return([user_message])
        allow(LLM::TextGenerationService).to receive(:generate).and_return({ success: false })
      end

      it 'returns fallback response' do
        result = described_class.npc_respond(instance, round, 'Hello!', character)

        expect(result).to include('Merchant')
        expect(result).to include('distracted')
      end
    end
  end

  describe '.evaluate_persuasion' do
    before do
      allow(LLM::TextGenerationService).to receive(:generate).and_return({
        success: true,
        text: '{"rating": 4, "feedback": "Good arguments"}'
      })
    end

    context 'when persuade is enabled' do
      it 'returns EvaluationResult' do
        result = described_class.evaluate_persuasion(instance, round)

        expect(result).to be_a(described_class::EvaluationResult)
      end

      it 'parses rating from LLM response' do
        result = described_class.evaluate_persuasion(instance, round)

        expect(result.rating).to eq(4)
      end

      it 'calculates dc_modifier based on rating' do
        result = described_class.evaluate_persuasion(instance, round)

        expect(result.dc_modifier).to eq(-5)
      end

      it 'includes feedback from LLM' do
        result = described_class.evaluate_persuasion(instance, round)

        expect(result.feedback).to eq('Good arguments')
      end
    end

    context 'when persuade is disabled' do
      before do
        allow(GameSetting).to receive(:boolean).with('activity_persuade_enabled').and_return(false)
      end

      it 'raises PersuadeError' do
        expect {
          described_class.evaluate_persuasion(instance, round)
        }.to raise_error(described_class::PersuadeError, 'Persuade not enabled')
      end
    end

    context 'when LLM call fails' do
      before do
        allow(LLM::TextGenerationService).to receive(:generate).and_return({ success: false })
      end

      it 'returns neutral rating' do
        result = described_class.evaluate_persuasion(instance, round)

        expect(result.rating).to eq(3)
      end

      it 'returns zero dc_modifier' do
        result = described_class.evaluate_persuasion(instance, round)

        expect(result.dc_modifier).to eq(0)
      end

      it 'returns error feedback' do
        result = described_class.evaluate_persuasion(instance, round)

        expect(result.feedback).to eq('Unable to evaluate persuasion.')
      end
    end

    context 'when LLM returns invalid JSON' do
      before do
        allow(LLM::TextGenerationService).to receive(:generate).and_return({
          success: true,
          text: 'not valid json'
        })
      end

      it 'returns neutral rating' do
        result = described_class.evaluate_persuasion(instance, round)

        expect(result.rating).to eq(3)
      end
    end

    context 'when LLM returns non-object JSON' do
      before do
        allow(LLM::TextGenerationService).to receive(:generate).and_return({
          success: true,
          text: '["unexpected", "array"]'
        })
      end

      it 'falls back to neutral evaluation' do
        result = described_class.evaluate_persuasion(instance, round)

        expect(result.rating).to eq(3)
        expect(result.dc_modifier).to eq(0)
      end
    end
  end

  describe '.attempt_persuasion' do
    before do
      allow(LLM::TextGenerationService).to receive(:generate).and_return({
        success: true,
        text: '{"rating": 3, "feedback": "Reasonable"}'
      })
      allow(instance).to receive(:persuade_attempts).and_return(1)
      # Mock dice rolls for predictable testing
      allow(DiceRollService).to receive(:roll).with(2, 8, explode_on: 8).and_return(
        DiceRollService::RollResult.new(
          dice: [5, 5], base_dice: [5, 5], explosions: [],
          modifier: 0, total: 10, count: 2, sides: 8, explode_on: 8
        )
      )
    end

    context 'when persuade is enabled' do
      it 'returns AttemptResult' do
        result = described_class.attempt_persuasion(participant, instance, round)

        expect(result).to be_a(described_class::AttemptResult)
      end

      it 'increments persuade attempts' do
        expect(instance).to receive(:increment_persuade_attempts!)

        described_class.attempt_persuasion(participant, instance, round)
      end

      it 'updates participant with roll result' do
        expect(participant).to receive(:update).with(
          hash_including(:roll_result, :expect_roll)
        )

        described_class.attempt_persuasion(participant, instance, round)
      end

      it 'returns attempts_made count' do
        result = described_class.attempt_persuasion(participant, instance, round)

        expect(result.attempts_made).to eq(1)
      end
    end

    context 'when persuade is disabled' do
      before do
        allow(GameSetting).to receive(:boolean).with('activity_persuade_enabled').and_return(false)
      end

      it 'raises PersuadeError' do
        expect {
          described_class.attempt_persuasion(participant, instance, round)
        }.to raise_error(described_class::PersuadeError, 'Persuade not enabled')
      end
    end

    context 'when roll succeeds' do
      before do
        # Roll 10 (2x5) vs DC 15 with rating 5 (-10 modifier = DC 5) = success
        allow(LLM::TextGenerationService).to receive(:generate).and_return({
          success: true,
          text: '{"rating": 5, "feedback": "Excellent"}'
        })
        # When modifier -10 is applied, DC becomes 5
        allow(round).to receive(:persuade_dc).with(-10).and_return(5)
      end

      it 'returns success true' do
        result = described_class.attempt_persuasion(participant, instance, round)

        expect(result.success).to be true
      end

      it 'includes success NPC response' do
        result = described_class.attempt_persuasion(participant, instance, round)

        expect(result.npc_response).to be_a(String)
      end
    end

    context 'when roll fails' do
      before do
        # Roll 10 (2x5) vs DC 15 with rating 1 (+10 modifier = DC 25) = failure
        allow(LLM::TextGenerationService).to receive(:generate).and_return({
          success: true,
          text: '{"rating": 1, "feedback": "Not convincing"}'
        })
      end

      it 'returns success false' do
        result = described_class.attempt_persuasion(participant, instance, round)

        expect(result.success).to be false
      end

      it 'includes failure NPC response' do
        result = described_class.attempt_persuasion(participant, instance, round)

        expect(result.npc_response).to be_a(String)
      end
    end

    context 'DC reduction from prior attempts' do
      before do
        # Rating 3 = modifier 0, base DC 15 → adjusted DC 15
        allow(LLM::TextGenerationService).to receive(:generate).and_return({
          success: true,
          text: '{"rating": 3, "feedback": "Reasonable"}'
        })
        allow(DiceRollService).to receive(:roll).with(2, 8, explode_on: 8).and_return(
        DiceRollService::RollResult.new(
          dice: [5, 5], base_dice: [5, 5], explosions: [],
          modifier: 0, total: 10, count: 2, sides: 8, explode_on: 8
        )
      )
      end

      it 'reduces DC by 1 for each prior attempt' do
        allow(instance).to receive(:persuade_attempts).and_return(3)

        result = described_class.attempt_persuasion(participant, instance, round)

        # DC 15 (base + 0 modifier) - 3 (prior attempts) = 12
        expect(result.dc).to eq(12)
      end

      it 'does not reduce DC below 5' do
        allow(instance).to receive(:persuade_attempts).and_return(20)

        result = described_class.attempt_persuasion(participant, instance, round)

        expect(result.dc).to eq(5)
      end

      it 'has no reduction on first attempt' do
        allow(instance).to receive(:persuade_attempts).and_return(0)

        result = described_class.attempt_persuasion(participant, instance, round)

        expect(result.dc).to eq(15)
      end
    end

    context 'with 1 willpower dice' do
      before do
        allow(participant).to receive(:willpower_to_spend).and_return(1)
        allow(DiceRollService).to receive(:roll).with(1, 8, explode_on: 8).and_return(
          DiceRollService::RollResult.new(
            dice: [4], base_dice: [4], explosions: [],
            modifier: 0, total: 4, count: 1, sides: 8, explode_on: 8
          )
        )
      end

      it 'uses willpower for extra dice' do
        expect(participant).to receive(:use_willpower!).with(1)

        described_class.attempt_persuasion(participant, instance, round)
      end
    end

    context 'with 2 willpower dice' do
      before do
        allow(participant).to receive(:willpower_to_spend).and_return(2)
        allow(DiceRollService).to receive(:roll).with(2, 8, explode_on: 8).and_return(
          DiceRollService::RollResult.new(
            dice: [4, 3], base_dice: [4, 3], explosions: [],
            modifier: 0, total: 7, count: 2, sides: 8, explode_on: 8
          )
        )
      end

      it 'uses 2 willpower for extra dice' do
        expect(participant).to receive(:use_willpower!).with(1).twice

        described_class.attempt_persuasion(participant, instance, round)
      end
    end
  end

  describe '.conversation_history' do
    let(:message1) do
      double('LLMMessage',
             role: 'user',
             content: 'Hello there',
             created_at: Time.now - 300)
    end

    let(:message2) do
      double('LLMMessage',
             role: 'assistant',
             content: 'Greetings traveler',
             created_at: Time.now - 200)
    end

    before do
      allow(conversation).to receive(:llm_messages).and_return([message1, message2])
    end

    it 'returns array of message hashes' do
      result = described_class.conversation_history(instance, round)

      expect(result).to be_an(Array)
    end

    it 'includes role as NPC name for assistant' do
      result = described_class.conversation_history(instance, round)

      expect(result[1][:role]).to eq('Merchant')
    end

    it 'includes role as Player for user' do
      result = described_class.conversation_history(instance, round)

      expect(result[0][:role]).to eq('Player')
    end

    it 'includes content' do
      result = described_class.conversation_history(instance, round)

      expect(result[0][:content]).to eq('Hello there')
    end

    it 'includes timestamp' do
      result = described_class.conversation_history(instance, round)

      expect(result[0][:timestamp]).to be_a(Time)
    end

    context 'when no conversation exists' do
      before do
        allow(LLMConversation).to receive(:first).and_return(nil)
        allow(LLMConversation).to receive(:create).and_return(nil)
      end

      it 'returns empty array' do
        result = described_class.conversation_history(instance, round)

        expect(result).to eq([])
      end
    end
  end

  describe 'private methods' do
    describe 'roll_persuasion uses DiceRollService' do
      it 'calls DiceRollService.roll for base dice' do
        expect(DiceRollService).to receive(:roll).with(2, 8, explode_on: 8).and_return(
          DiceRollService::RollResult.new(
            dice: [5, 5], base_dice: [5, 5], explosions: [],
            modifier: 0, total: 10, count: 2, sides: 8, explode_on: 8
          )
        )

        participant = double('ActivityParticipant',
                             willpower_to_spend: 0,
                             character_instance: double('CharacterInstance', respond_to?: false))
        round = double('ActivityRound', persuade_stat_id: nil, stat_set_a: nil)

        described_class.send(:roll_persuasion, participant, round)
      end

      it 'uses stat_set_a when persuade_stat_id is not configured' do
        allow(DiceRollService).to receive(:roll).with(2, 8, explode_on: 8).and_return(
          DiceRollService::RollResult.new(
            dice: [4, 4], base_dice: [4, 4], explosions: [],
            modifier: 0, total: 8, count: 2, sides: 8, explode_on: 8
          )
        )

        stat_a = double('Stat', abbreviation: 'cha')
        stat_b = double('Stat', abbreviation: 'per')
        allow(Stat).to receive(:[]).with(3).and_return(stat_a)
        allow(Stat).to receive(:[]).with(8).and_return(stat_b)

        character_instance = double('CharacterInstance')
        allow(StatAllocationService).to receive(:get_stat_value).with(character_instance, 'cha').and_return(2)
        allow(StatAllocationService).to receive(:get_stat_value).with(character_instance, 'per').and_return(5)

        participant = double('ActivityParticipant',
                             willpower_to_spend: 0,
                             available_willpower: 0,
                             character_instance: character_instance)
        round = double('ActivityRound', persuade_stat_id: nil, stat_set_a: [3, 8])

        total = described_class.send(:roll_persuasion, participant, round)
        expect(total).to eq(13) # 8 base + max(2,5)
      end
    end
  end

  describe '.adjusted_dc' do
    let(:round_with_base_dc) do
      double('ActivityRound',
             persuade_base_dc: 10)
    end

    context 'without observer effects' do
      before do
        allow(ObserverEffectService).to receive(:persuade_dc_modifier).with(instance).and_return(0)
      end

      it 'returns base DC when no modifier' do
        result = described_class.adjusted_dc(instance, round_with_base_dc)
        expect(result).to eq(10)
      end

      it 'adds evaluation modifier to base DC' do
        result = described_class.adjusted_dc(instance, round_with_base_dc, 5)
        expect(result).to eq(15)
      end

      it 'defaults base DC to 10 when nil' do
        round_nil_dc = double('ActivityRound', persuade_base_dc: nil)
        result = described_class.adjusted_dc(instance, round_nil_dc)
        expect(result).to eq(10)
      end
    end

    context 'with distraction support' do
      before do
        allow(ObserverEffectService).to receive(:persuade_dc_modifier).with(instance).and_return(-2)
      end

      it 'reduces persuade DC by 2' do
        result = described_class.adjusted_dc(instance, round_with_base_dc)
        expect(result).to eq(8)
      end

      it 'stacks with evaluation modifier' do
        result = described_class.adjusted_dc(instance, round_with_base_dc, 5)
        expect(result).to eq(13) # 10 + 5 - 2
      end
    end

    context 'with draw_attention opposition' do
      before do
        allow(ObserverEffectService).to receive(:persuade_dc_modifier).with(instance).and_return(2)
      end

      it 'increases persuade DC by 2' do
        result = described_class.adjusted_dc(instance, round_with_base_dc)
        expect(result).to eq(12)
      end

      it 'stacks with evaluation modifier' do
        result = described_class.adjusted_dc(instance, round_with_base_dc, -5)
        expect(result).to eq(7) # 10 - 5 + 2
      end
    end

    context 'with multiple observers' do
      before do
        # Two distractions (-4) and one draw_attention (+2) = -2 net
        allow(ObserverEffectService).to receive(:persuade_dc_modifier).with(instance).and_return(-2)
      end

      it 'applies net modifier' do
        result = described_class.adjusted_dc(instance, round_with_base_dc)
        expect(result).to eq(8)
      end
    end

    context 'DC clamping' do
      it 'clamps DC to minimum of 5' do
        allow(ObserverEffectService).to receive(:persuade_dc_modifier).with(instance).and_return(-10)
        round_low_dc = double('ActivityRound', persuade_base_dc: 8)

        result = described_class.adjusted_dc(instance, round_low_dc, -10)
        expect(result).to eq(5) # 8 - 10 - 10 = -12, clamped to 5
      end

      it 'clamps DC to maximum of 30' do
        allow(ObserverEffectService).to receive(:persuade_dc_modifier).with(instance).and_return(10)
        round_high_dc = double('ActivityRound', persuade_base_dc: 25)

        result = described_class.adjusted_dc(instance, round_high_dc, 10)
        expect(result).to eq(30) # 25 + 10 + 10 = 45, clamped to 30
      end
    end
  end

  describe 'observer effects integration' do
    before do
      allow(LLM::TextGenerationService).to receive(:generate).and_return({
        success: true,
        text: '{"rating": 3, "feedback": "Reasonable"}'
      })
    end

    context 'in evaluate_persuasion' do
      before do
        allow(ObserverEffectService).to receive(:persuade_dc_modifier).with(instance).and_return(-2)
      end

      it 'applies observer effects to adjusted_dc' do
        # Base DC from round double is set to return 15 by default
        # With rating 3, dc_modifier = 0
        # With observer modifier -2, adjusted_dc should be base - 2
        # But we need to mock the round to have persuade_base_dc
        round_with_base = double('ActivityRound',
                                 id: 1,
                                 persuade_npc_name: 'Merchant',
                                 persuade_npc_personality: 'A shrewd trader',
                                 persuade_goal: 'Get a discount',
                                 persuade_base_dc: 15,
                                 persuade_stat_id: nil)

        result = described_class.evaluate_persuasion(instance, round_with_base)

        # 15 (base) + 0 (rating 3 modifier) - 2 (observer) = 13
        expect(result.adjusted_dc).to eq(13)
      end
    end

    context 'when LLM fails' do
      before do
        allow(LLM::TextGenerationService).to receive(:generate).and_return({ success: false })
        allow(ObserverEffectService).to receive(:persuade_dc_modifier).with(instance).and_return(2)
      end

      it 'still applies observer effects in fallback' do
        round_with_base = double('ActivityRound',
                                 id: 1,
                                 persuade_npc_name: 'Merchant',
                                 persuade_npc_personality: 'A shrewd trader',
                                 persuade_goal: 'Get a discount',
                                 persuade_base_dc: 15,
                                 persuade_stat_id: nil)

        result = described_class.evaluate_persuasion(instance, round_with_base)

        # 15 (base) + 0 (fallback modifier) + 2 (observer) = 17
        expect(result.adjusted_dc).to eq(17)
      end
    end
  end
end
