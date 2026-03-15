# frozen_string_literal: true

FactoryBot.define do
  factory :character do
    association :user
    sequence(:forename) { |n| "Testchar#{n}" }
    surname { nil }
    short_desc { 'a test character' }
    is_npc { false }
    active { true }

    # Set name from forename for backward compatibility
    after(:build) do |character|
      character.name ||= character.forename
    end

    trait :npc do
      user { nil }
      is_npc { true }
    end

    trait :with_surname do
      sequence(:surname) { |n| "Surname#{n}" }
    end
  end
end
