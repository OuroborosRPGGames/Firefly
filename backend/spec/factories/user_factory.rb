# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    sequence(:username) { |n| "user#{n}" }
    sequence(:email) { |n| "user#{n}@example.com" }
    active { true }
    created_at { Time.now }
    updated_at { Time.now }

    # Transient attributes
    transient do
      make_admin { false }
      password { 'password' }
    end

    after(:build) do |user, evaluator|
      user.set_password(evaluator.password)
    end

    # Override the before_create auto-admin logic for test consistency
    # Use Sequel's this.update to bypass model callbacks
    after(:create) do |user, evaluator|
      if evaluator.make_admin
        user.this.update(is_admin: true)
        user.refresh
      else
        user.this.update(is_admin: false)
        user.refresh
      end
    end

    trait :admin do
      make_admin { true }
    end

    trait :with_character do
      after(:create) do |user|
        create(:character, user: user)
      end
    end
  end
end
