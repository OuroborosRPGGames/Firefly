# frozen_string_literal: true

# Pet represents AI-puppeted companion animals.
# Pets follow their owner and can perform simple actions.
class Pet < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :owner, class: :Character
  many_to_one :current_room, class: :Room

  PET_TYPES = %w[dog cat bird horse familiar mythical].freeze
  MOODS = %w[happy content tired hungry playful scared aggressive].freeze

  def validate
    super
    validates_presence [:owner_id, :name, :species]
    validates_max_length 50, :name
    validates_max_length 50, :species
    validates_includes PET_TYPES, :pet_type if pet_type
    validates_includes MOODS, :mood if mood
  end

  def before_save
    super
    self.pet_type ||= 'dog'
    self.mood ||= 'content'
    self.following = true if following.nil?
    self.loyalty ||= 50  # 0-100
  end

  def following?
    !!following
  end

  def follow!
    update(following: true)
  end

  def stay!
    update(following: false)
  end

  def happy?
    mood == 'happy'
  end

  def needs_attention?
    %w[hungry tired scared].include?(mood)
  end

  def loyal?
    loyalty >= 70
  end

  # Move pet to follow owner
  def follow_owner!(owner_instance)
    return unless following?
    update(current_room_id: owner_instance.current_room_id)
  end

  # Pet reacts to environment/actions
  def react_to(action_type)
    case action_type
    when :fed
      update(mood: 'happy', loyalty: [loyalty + 5, 100].min)
    when :petted
      update(mood: 'content', loyalty: [loyalty + 2, 100].min)
    when :neglected
      update(mood: 'hungry', loyalty: [loyalty - 5, 0].max)
    when :scared
      update(mood: 'scared')
    end
  end

  # Generate AI action for the pet
  def idle_action
    case mood
    when 'happy'
      ['wags its tail', 'plays excitedly', 'bounds around happily'].sample
    when 'content'
      ['rests quietly', 'watches attentively', 'sits calmly'].sample
    when 'hungry'
      ['whines softly', 'looks around hopefully', 'paws at the ground'].sample
    when 'playful'
      ['chases its tail', 'pounces at shadows', 'rolls around'].sample
    else
      ['looks around', 'sniffs the air', 'stretches'].sample
    end
  end
end
