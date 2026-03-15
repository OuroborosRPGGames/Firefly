# frozen_string_literal: true

FactoryBot.define do
  factory :message do
    association :character_instance
    association :reality
    content { "Hello, world!" }
    message_type { 'say' }

    # Backward compatibility - set character_id from character_instance
    after(:build) do |message|
      if message.character_instance_id && !message.character_id
        message.character_id = message.character_instance.character_id
      end
    end
  end
end