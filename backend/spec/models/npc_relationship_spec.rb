# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcRelationship do
  let(:npc) { create(:character, :npc) }
  let(:pc) { create(:character) }

  describe 'validations' do
    it 'requires npc_character_id' do
      rel = NpcRelationship.new(pc_character_id: pc.id)
      expect(rel.valid?).to be false
      expect(rel.errors[:npc_character_id]).not_to be_empty
    end

    it 'requires pc_character_id' do
      rel = NpcRelationship.new(npc_character_id: npc.id)
      expect(rel.valid?).to be false
      expect(rel.errors[:pc_character_id]).not_to be_empty
    end

    it 'is valid with both character IDs' do
      rel = NpcRelationship.new(npc_character_id: npc.id, pc_character_id: pc.id)
      expect(rel.valid?).to be true
    end
  end

  describe 'before_save' do
    it 'clamps sentiment to -1.0..1.0' do
      rel = NpcRelationship.create(npc_character_id: npc.id, pc_character_id: pc.id, sentiment: 2.0)
      expect(rel.sentiment).to eq(1.0)

      rel.update(sentiment: -2.0)
      expect(rel.sentiment).to eq(-1.0)
    end

    it 'clamps trust to 0.0..1.0' do
      rel = NpcRelationship.create(npc_character_id: npc.id, pc_character_id: pc.id, trust: 1.5)
      expect(rel.trust).to eq(1.0)

      rel.update(trust: -0.5)
      expect(rel.trust).to eq(0.0)
    end

    it 'sets first_interaction_at on new records' do
      rel = NpcRelationship.create(npc_character_id: npc.id, pc_character_id: pc.id)
      expect(rel.first_interaction_at).not_to be_nil
    end
  end

  describe 'sentiment descriptors' do
    let(:rel) { NpcRelationship.create(npc_character_id: npc.id, pc_character_id: pc.id) }

    it 'returns very fond of for high sentiment' do
      rel.update(sentiment: 0.8)
      expect(rel.sentiment_descriptor).to eq('very fond of')
    end

    it 'returns friendly toward for moderate positive sentiment' do
      rel.update(sentiment: 0.5)
      expect(rel.sentiment_descriptor).to eq('friendly toward')
    end

    it 'returns neutral toward for neutral sentiment' do
      rel.update(sentiment: 0.0)
      expect(rel.sentiment_descriptor).to eq('neutral toward')
    end

    it 'returns wary of for moderate negative sentiment' do
      rel.update(sentiment: -0.5)
      expect(rel.sentiment_descriptor).to eq('wary of')
    end

    it 'returns hostile toward for very negative sentiment' do
      rel.update(sentiment: -0.9)
      expect(rel.sentiment_descriptor).to eq('hostile toward')
    end
  end

  describe 'trust descriptors' do
    let(:rel) { NpcRelationship.create(npc_character_id: npc.id, pc_character_id: pc.id) }

    it 'returns completely trusts for high trust' do
      rel.update(trust: 0.9)
      expect(rel.trust_descriptor).to eq('completely trusts')
    end

    it 'returns trusts for moderate trust' do
      rel.update(trust: 0.7)
      expect(rel.trust_descriptor).to eq('trusts')
    end

    it 'returns is uncertain about for neutral trust' do
      rel.update(trust: 0.5)
      expect(rel.trust_descriptor).to eq('is uncertain about')
    end

    it 'returns distrusts for low trust' do
      rel.update(trust: 0.3)
      expect(rel.trust_descriptor).to eq('distrusts')
    end

    it 'returns deeply distrusts for very low trust' do
      rel.update(trust: 0.1)
      expect(rel.trust_descriptor).to eq('deeply distrusts')
    end
  end

  describe '#to_context_string' do
    it 'formats relationship for LLM context' do
      rel = NpcRelationship.create(
        npc_character_id: npc.id,
        pc_character_id: pc.id,
        sentiment: 0.5,
        trust: 0.7
      )

      context = rel.to_context_string
      expect(context).to include(npc.forename)
      expect(context).to include('friendly toward')
      expect(context).to include('trusts')
    end
  end

  describe '#record_interaction' do
    let(:rel) { NpcRelationship.create(npc_character_id: npc.id, pc_character_id: pc.id) }

    it 'updates sentiment and trust' do
      initial_sentiment = rel.sentiment
      initial_trust = rel.trust

      rel.record_interaction(sentiment_delta: 0.1, trust_delta: 0.05)
      rel.refresh

      expect(rel.sentiment).to eq(initial_sentiment + 0.1)
      expect(rel.trust).to eq(initial_trust + 0.05)
    end

    it 'increments interaction count' do
      expect { rel.record_interaction(sentiment_delta: 0.1) }
        .to change { rel.refresh; rel.interaction_count }.by(1)
    end

    it 'clamps deltas to allowed ranges' do
      rel.update(sentiment: 0.9)
      rel.record_interaction(sentiment_delta: 0.5) # Should be clamped to 0.2
      rel.refresh

      expect(rel.sentiment).to be <= 1.0
    end

    it 'records notable events' do
      rel.record_interaction(sentiment_delta: 0.1, notable_event: 'Helped with a task')
      rel.refresh

      # notable_events can be a Sequel::Postgres::JSONBArray or Array
      events = rel.notable_events.to_a
      expect(events.first['event']).to eq('Helped with a task')
    end

    it 'keeps only last 10 notable events' do
      12.times do |i|
        rel.record_interaction(notable_event: "Event #{i}")
      end
      rel.refresh

      expect(rel.notable_events.to_a.length).to be <= 10
    end
  end

  describe '.find_or_create_for' do
    it 'creates a new relationship if one does not exist' do
      expect {
        NpcRelationship.find_or_create_for(npc: npc, pc: pc)
      }.to change(NpcRelationship, :count).by(1)
    end

    it 'returns existing relationship if one exists' do
      existing = NpcRelationship.create(npc_character_id: npc.id, pc_character_id: pc.id)

      found = NpcRelationship.find_or_create_for(npc: npc, pc: pc)
      expect(found.id).to eq(existing.id)
    end
  end

  describe 'query helpers' do
    let(:rel) { NpcRelationship.create(npc_character_id: npc.id, pc_character_id: pc.id) }

    it '#positive? returns true when sentiment > 0.3' do
      rel.update(sentiment: 0.5)
      expect(rel.positive?).to be true
    end

    it '#negative? returns true when sentiment < -0.3' do
      rel.update(sentiment: -0.5)
      expect(rel.negative?).to be true
    end

    it '#neutral? returns true when sentiment is near zero' do
      rel.update(sentiment: 0.1)
      expect(rel.neutral?).to be true
    end

    it '#trusting? returns true when trust >= 0.6' do
      rel.update(trust: 0.7)
      expect(rel.trusting?).to be true
    end

    it '#distrustful? returns true when trust < 0.4' do
      rel.update(trust: 0.2)
      expect(rel.distrustful?).to be true
    end

    it '#well_known? returns true when interaction_count >= 5' do
      rel.update(interaction_count: 5)
      expect(rel.well_known?).to be true
    end

    it '#new_acquaintance? returns true when interaction_count < 3' do
      rel.update(interaction_count: 1)
      expect(rel.new_acquaintance?).to be true
    end
  end

  describe 'knowledge tier methods' do
    let(:rel) { NpcRelationship.create(npc_character_id: npc.id, pc_character_id: pc.id) }

    describe '#knows_tier?' do
      it 'returns true when knowledge_tier is at or above requested tier' do
        rel.update(knowledge_tier: 2)
        expect(rel.knows_tier?(1)).to be true
        expect(rel.knows_tier?(2)).to be true
      end

      it 'returns false when knowledge_tier is below requested tier' do
        rel.update(knowledge_tier: 1)
        expect(rel.knows_tier?(2)).to be false
        expect(rel.knows_tier?(3)).to be false
      end

      it 'defaults to tier 1 when knowledge_tier is nil' do
        rel.update(knowledge_tier: nil)
        expect(rel.knows_tier?(1)).to be true
        expect(rel.knows_tier?(2)).to be false
      end
    end

    describe '#knowledge_tier_descriptor' do
      it 'returns "knows them intimately" for tier 3' do
        rel.update(knowledge_tier: 3)
        expect(rel.knowledge_tier_descriptor).to eq('knows them intimately')
      end

      it 'returns "knows them socially" for tier 2' do
        rel.update(knowledge_tier: 2)
        expect(rel.knowledge_tier_descriptor).to eq('knows them socially')
      end

      it 'returns "knows them by reputation only" for tier 1 or nil' do
        rel.update(knowledge_tier: 1)
        expect(rel.knowledge_tier_descriptor).to eq('knows them by reputation only')

        rel.update(knowledge_tier: nil)
        expect(rel.knowledge_tier_descriptor).to eq('knows them by reputation only')
      end
    end

    describe '#knowledge_label' do
      it 'returns "close associate" for tier 3' do
        rel.update(knowledge_tier: 3)
        expect(rel.knowledge_label).to eq('close associate')
      end

      it 'returns "social acquaintance" for tier 2' do
        rel.update(knowledge_tier: 2)
        expect(rel.knowledge_label).to eq('social acquaintance')
      end

      it 'returns "by reputation" for tier 1 or lower' do
        rel.update(knowledge_tier: 1)
        expect(rel.knowledge_label).to eq('by reputation')
      end
    end
  end

  describe 'leadership rejection cooldowns' do
    let(:rel) { NpcRelationship.create(npc_character_id: npc.id, pc_character_id: pc.id) }

    describe '#on_lead_cooldown?' do
      it 'returns false when last_lead_rejection_at is nil' do
        expect(rel.on_lead_cooldown?).to be false
      end

      it 'returns true when within cooldown period' do
        rel.update(last_lead_rejection_at: Time.now - 60)
        expect(rel.on_lead_cooldown?).to be true
      end

      it 'returns false when cooldown has expired' do
        rel.update(last_lead_rejection_at: Time.now - GameConfig::NpcRelationship::REJECTION_COOLDOWN_SECONDS - 60)
        expect(rel.on_lead_cooldown?).to be false
      end
    end

    describe '#on_summon_cooldown?' do
      it 'returns false when last_summon_rejection_at is nil' do
        expect(rel.on_summon_cooldown?).to be false
      end

      it 'returns true when within cooldown period' do
        rel.update(last_summon_rejection_at: Time.now - 60)
        expect(rel.on_summon_cooldown?).to be true
      end

      it 'returns false when cooldown has expired' do
        rel.update(last_summon_rejection_at: Time.now - GameConfig::NpcRelationship::REJECTION_COOLDOWN_SECONDS - 60)
        expect(rel.on_summon_cooldown?).to be false
      end
    end

    describe '#record_lead_rejection!' do
      it 'sets last_lead_rejection_at to current time' do
        rel.record_lead_rejection!
        rel.refresh
        expect(rel.last_lead_rejection_at).to be_within(5).of(Time.now)
      end

      it 'increments lead_rejection_count' do
        expect { rel.record_lead_rejection!; rel.refresh }
          .to change { rel.lead_rejection_count }.by(1)
      end

      it 'increments existing count' do
        rel.update(lead_rejection_count: 3)
        rel.record_lead_rejection!
        rel.refresh
        expect(rel.lead_rejection_count).to eq(4)
      end
    end

    describe '#record_summon_rejection!' do
      it 'sets last_summon_rejection_at to current time' do
        rel.record_summon_rejection!
        rel.refresh
        expect(rel.last_summon_rejection_at).to be_within(5).of(Time.now)
      end

      it 'increments summon_rejection_count' do
        expect { rel.record_summon_rejection!; rel.refresh }
          .to change { rel.summon_rejection_count }.by(1)
      end
    end

    describe '#lead_cooldown_remaining' do
      it 'returns 0 when not on cooldown' do
        expect(rel.lead_cooldown_remaining).to eq(0)
      end

      it 'returns remaining seconds when on cooldown' do
        rel.update(last_lead_rejection_at: Time.now - 60)
        remaining = rel.lead_cooldown_remaining
        expect(remaining).to be > 0
        expect(remaining).to be <= GameConfig::NpcRelationship::REJECTION_COOLDOWN_SECONDS
      end
    end

    describe '#summon_cooldown_remaining' do
      it 'returns 0 when not on cooldown' do
        expect(rel.summon_cooldown_remaining).to eq(0)
      end

      it 'returns remaining seconds when on cooldown' do
        rel.update(last_summon_rejection_at: Time.now - 60)
        remaining = rel.summon_cooldown_remaining
        expect(remaining).to be > 0
        expect(remaining).to be <= GameConfig::NpcRelationship::REJECTION_COOLDOWN_SECONDS
      end
    end
  end

  describe 'class query methods' do
    let(:npc2) { create(:character, :npc) }
    let(:pc2) { create(:character) }

    before do
      # Create various relationships for testing
      @positive_rel = NpcRelationship.create(
        npc_character_id: npc.id,
        pc_character_id: pc.id,
        sentiment: 0.5,
        last_interaction_at: Time.now
      )
      @negative_rel = NpcRelationship.create(
        npc_character_id: npc.id,
        pc_character_id: pc2.id,
        sentiment: -0.5,
        last_interaction_at: Time.now - 3600
      )
      @other_npc_rel = NpcRelationship.create(
        npc_character_id: npc2.id,
        pc_character_id: pc.id,
        sentiment: 0.2,
        last_interaction_at: Time.now - 7200
      )
    end

    describe '.for_npc' do
      it 'returns relationships for the specified NPC' do
        rels = NpcRelationship.for_npc(npc).all
        expect(rels.map(&:id)).to include(@positive_rel.id, @negative_rel.id)
        expect(rels.map(&:id)).not_to include(@other_npc_rel.id)
      end

      it 'orders by last_interaction_at descending' do
        rels = NpcRelationship.for_npc(npc).all
        expect(rels.first.id).to eq(@positive_rel.id)
      end
    end

    describe '.for_pc' do
      it 'returns relationships for the specified PC' do
        rels = NpcRelationship.for_pc(pc).all
        expect(rels.map(&:id)).to include(@positive_rel.id, @other_npc_rel.id)
        expect(rels.map(&:id)).not_to include(@negative_rel.id)
      end

      it 'orders by last_interaction_at descending' do
        rels = NpcRelationship.for_pc(pc).all
        expect(rels.first.id).to eq(@positive_rel.id)
      end
    end

    describe '.positive_for_npc' do
      it 'returns only positive relationships' do
        rels = NpcRelationship.positive_for_npc(npc).all
        expect(rels.map(&:id)).to include(@positive_rel.id)
        expect(rels.map(&:id)).not_to include(@negative_rel.id)
      end
    end

    describe '.negative_for_npc' do
      it 'returns only negative relationships' do
        rels = NpcRelationship.negative_for_npc(npc).all
        expect(rels.map(&:id)).to include(@negative_rel.id)
        expect(rels.map(&:id)).not_to include(@positive_rel.id)
      end
    end
  end

  describe '#evaluate_knowledge_tier_async' do
    let(:rel) { NpcRelationship.create(npc_character_id: npc.id, pc_character_id: pc.id) }

    it 'runs without error' do
      # This spawns a thread, so we just ensure it doesn't crash
      expect { rel.evaluate_knowledge_tier_async }.not_to raise_error
    end
  end
end
