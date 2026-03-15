# frozen_string_literal: true

# NpcRelationship tracks evolving relationships between NPCs and player characters.
# Sentiment ranges from -1.0 (hostile) to 1.0 (fond).
# Trust ranges from 0.0 (no trust) to 1.0 (full trust).
class NpcRelationship < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :npc_character, class: :Character, key: :npc_character_id
  many_to_one :pc_character, class: :Character, key: :pc_character_id

  def validate
    super
    validates_presence %i[npc_character_id pc_character_id]
  end

  # Clamp values to valid ranges before save
  def before_save
    super
    self.sentiment = clamp(sentiment || 0.0, -1.0, 1.0)
    self.trust = clamp(trust || 0.5, 0.0, 1.0)
    self.first_interaction_at ||= Time.now if new?
  end

  # ============================================
  # Relationship Descriptors for LLM Context
  # ============================================

  def sentiment_descriptor
    case sentiment
    when 0.7..1.0 then 'very fond of'
    when 0.3..0.7 then 'friendly toward'
    when -0.3..0.3 then 'neutral toward'
    when -0.7..-0.3 then 'wary of'
    else 'hostile toward'
    end
  end

  def trust_descriptor
    case trust
    when 0.8..1.0 then 'completely trusts'
    when 0.6..0.8 then 'trusts'
    when 0.4..0.6 then 'is uncertain about'
    when 0.2..0.4 then 'distrusts'
    else 'deeply distrusts'
    end
  end

  # Format for LLM context
  def to_context_string
    npc_name = npc_character&.forename || 'The NPC'
    pc_name = pc_character&.forename || 'them'
    "#{npc_name} is #{sentiment_descriptor} and #{trust_descriptor} #{pc_name}."
  end

  # ============================================
  # Knowledge Tier Methods
  # ============================================

  # Check if NPC knows a specific tier of reputation about the PC
  # @param tier [Integer] Tier to check (1, 2, or 3)
  # @return [Boolean]
  def knows_tier?(tier)
    (knowledge_tier || 1) >= tier
  end

  # Returns human-readable descriptor of knowledge level
  def knowledge_tier_descriptor
    case knowledge_tier
    when 3 then 'knows them intimately'
    when 2 then 'knows them socially'
    else 'knows them by reputation only'
    end
  end

  # Short form for context
  def knowledge_label
    case knowledge_tier
    when 3 then 'close associate'
    when 2 then 'social acquaintance'
    else 'by reputation'
    end
  end

  # ============================================
  # Relationship Queries
  # ============================================

  def positive?
    sentiment > 0.3
  end

  def negative?
    sentiment < -0.3
  end

  def neutral?
    sentiment >= -0.3 && sentiment <= 0.3
  end

  def trusting?
    trust >= 0.6
  end

  def distrustful?
    trust < 0.4
  end

  def well_known?
    interaction_count >= 5
  end

  def new_acquaintance?
    interaction_count < 3
  end

  # ============================================
  # Class Methods
  # ============================================

  # Find or create a relationship
  def self.find_or_create_for(npc:, pc:)
    find_or_create(npc_character_id: npc.id, pc_character_id: pc.id) do |r|
      r.first_interaction_at = Time.now
    end
  end

  # Get all relationships for an NPC
  def self.for_npc(npc)
    where(npc_character_id: npc.id).order(Sequel.desc(:last_interaction_at))
  end

  # Get all relationships for a PC
  def self.for_pc(pc)
    where(pc_character_id: pc.id).order(Sequel.desc(:last_interaction_at))
  end

  # Get positive relationships
  def self.positive_for_npc(npc)
    for_npc(npc).where { sentiment > 0.3 }
  end

  # Get negative relationships
  def self.negative_for_npc(npc)
    for_npc(npc).where { sentiment < -0.3 }
  end

  # ============================================
  # Relationship Updates
  # ============================================

  # Update relationship after an interaction
  # @param sentiment_delta [Float] Change in sentiment (-0.2 to 0.2)
  # @param trust_delta [Float] Change in trust (-0.1 to 0.1)
  # @param notable_event [String, nil] Optional notable event to record
  def record_interaction(sentiment_delta: 0.0, trust_delta: 0.0, notable_event: nil)
    new_sentiment = sentiment + clamp(sentiment_delta, -0.2, 0.2)
    new_trust = trust + clamp(trust_delta, -0.1, 0.1)

    updates = {
      sentiment: new_sentiment,
      trust: new_trust,
      interaction_count: interaction_count + 1,
      last_interaction_at: Time.now
    }

    # Add notable event if provided
    if notable_event
      # Convert JSONB array to Ruby array for manipulation
      events = (notable_events || []).to_a.dup
      events << {
        'event' => notable_event,
        'timestamp' => Time.now.iso8601,
        'sentiment_at' => new_sentiment.round(2),
        'trust_at' => new_trust.round(2)
      }
      # Keep only last 10 events
      updates[:notable_events] = Sequel.pg_jsonb(events.last(10))
    end

    update(updates)

    # Evaluate knowledge tier in background (non-blocking)
    evaluate_knowledge_tier_async
  end

  # Evaluate and potentially update knowledge tier via LLM (async)
  def evaluate_knowledge_tier_async
    Thread.new do
      new_tier = evaluate_knowledge_tier_via_llm
      if new_tier && new_tier != knowledge_tier
        update(knowledge_tier: new_tier)
      end
    rescue StandardError => e
      warn "[NpcRelationship] Knowledge tier eval failed: #{e.message}"
    end
  end

  # Evaluate knowledge tier via LLM based on relationship data
  # @return [Integer, nil] New tier (1, 2, or 3) or nil if evaluation failed
  def evaluate_knowledge_tier_via_llm
    return nil unless pc_character && npc_character

    events_text = (notable_events || []).last(5).map { |e| e['event'] }.compact.join('; ')
    events_text = 'None recorded' if events_text.strip.empty?

    prompt = GamePrompts.get('npc_relationships.knowledge_tier',
                              npc_name: npc_character.forename,
                              pc_name: pc_character.full_name,
                              interaction_count: interaction_count,
                              sentiment: sentiment.round(2),
                              sentiment_descriptor: sentiment_descriptor,
                              trust: trust.round(2),
                              trust_descriptor: trust_descriptor,
                              current_tier: knowledge_tier || 1,
                              events_text: events_text)

    result = LLM::Client.generate(
      prompt: prompt,
      model: 'gemini-3-flash-preview',
      provider: 'google_gemini',
      options: { max_tokens: 10, temperature: 0.2 }
    )

    return nil unless result[:success]

    # Parse the response - expect just a number
    tier_text = result[:text].strip.gsub(/[^123]/, '')
    tier = tier_text[0]&.to_i
    tier.between?(1, 3) ? tier : nil
  rescue StandardError => e
    warn "[NpcRelationship] LLM knowledge tier eval failed: #{e.message}"
    nil
  end

  # ============================================
  # Leadership Rejection Cooldowns
  # ============================================

  # Check if this PC is on lead cooldown for this NPC
  # @return [Boolean]
  def on_lead_cooldown?
    return false unless last_lead_rejection_at

    last_lead_rejection_at > Time.now - GameConfig::NpcRelationship::REJECTION_COOLDOWN_SECONDS
  end

  # Check if this PC is on summon cooldown for this NPC
  # @return [Boolean]
  def on_summon_cooldown?
    return false unless last_summon_rejection_at

    last_summon_rejection_at > Time.now - GameConfig::NpcRelationship::REJECTION_COOLDOWN_SECONDS
  end

  # Record that the NPC rejected a lead request from this PC
  def record_lead_rejection!
    update(
      last_lead_rejection_at: Time.now,
      lead_rejection_count: (lead_rejection_count || 0) + 1
    )
  end

  # Record that the NPC rejected a summon request from this PC
  def record_summon_rejection!
    update(
      last_summon_rejection_at: Time.now,
      summon_rejection_count: (summon_rejection_count || 0) + 1
    )
  end

  # Get remaining cooldown time in seconds for lead
  # @return [Integer] seconds remaining, or 0 if not on cooldown
  def lead_cooldown_remaining
    return 0 unless on_lead_cooldown?

    (last_lead_rejection_at + GameConfig::NpcRelationship::REJECTION_COOLDOWN_SECONDS - Time.now).to_i
  end

  # Get remaining cooldown time in seconds for summon
  # @return [Integer] seconds remaining, or 0 if not on cooldown
  def summon_cooldown_remaining
    return 0 unless on_summon_cooldown?

    (last_summon_rejection_at + GameConfig::NpcRelationship::REJECTION_COOLDOWN_SECONDS - Time.now).to_i
  end

  private

  def clamp(value, min, max)
    [[value, min].max, max].min
  end
end
