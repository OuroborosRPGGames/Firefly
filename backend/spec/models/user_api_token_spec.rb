# frozen_string_literal: true

require 'spec_helper'

RSpec.describe User, "API token methods" do
  let(:user) { create(:user) }

  describe "#generate_api_token!" do
    it "returns a 64-character hex token" do
      token = user.generate_api_token!
      expect(token).to match(/\A[a-f0-9]{64}\z/)
    end

    it "stores a BCrypt hash, not plaintext" do
      token = user.generate_api_token!
      user.reload
      expect(user[:api_token_digest]).not_to eq(token)
      expect(user[:api_token_digest]).to start_with('$2a$')
    end

    it "sets created_at timestamp" do
      user.generate_api_token!
      user.reload
      expect(user[:api_token_created_at]).to be_within(1).of(Time.now)
    end

    it "clears last_used_at" do
      user.generate_api_token!
      user[:api_token_last_used_at] = Time.now
      user.save(validate: false)
      user.generate_api_token!
      user.reload
      expect(user[:api_token_last_used_at]).to be_nil
    end

    it "can set expiration" do
      user.generate_api_token!(expires_in: 3600)
      user.reload
      expect(user[:api_token_expires_at]).to be_within(5).of(Time.now + 3600)
    end
  end

  describe "#api_token_valid?" do
    let!(:token) { user.generate_api_token! }

    it "returns true for valid token" do
      expect(user.api_token_valid?(token)).to be true
    end

    it "returns false for invalid token" do
      expect(user.api_token_valid?("wrong_token")).to be false
    end

    it "returns false for nil token" do
      expect(user.api_token_valid?(nil)).to be false
    end

    it "returns false for empty token" do
      expect(user.api_token_valid?("")).to be false
    end

    it "returns false for malformed token" do
      expect(user.api_token_valid?("not-hex-format")).to be false
    end

    it "returns false for expired token" do
      user[:api_token_expires_at] = Time.now - 1
      user.save(validate: false)
      expect(user.api_token_valid?(token)).to be false
    end

    it "returns true when expires_at is nil (never expires)" do
      expect(user[:api_token_expires_at]).to be_nil
      expect(user.api_token_valid?(token)).to be true
    end
  end

  describe "#clear_api_token!" do
    it "clears all token fields" do
      user.generate_api_token!(expires_in: 3600)
      user.touch_api_token_usage!
      user.clear_api_token!
      user.reload

      expect(user[:api_token_digest]).to be_nil
      expect(user[:api_token_expires_at]).to be_nil
      expect(user[:api_token_created_at]).to be_nil
      expect(user[:api_token_last_used_at]).to be_nil
    end
  end

  describe ".find_by_api_token" do
    let!(:token) { user.generate_api_token! }

    it "finds user by valid token" do
      found = User.find_by_api_token(token)
      expect(found.id).to eq(user.id)
    end

    it "returns nil for invalid token" do
      expect(User.find_by_api_token("a" * 64)).to be_nil
    end

    it "returns nil for nil token" do
      expect(User.find_by_api_token(nil)).to be_nil
    end

    it "returns nil for malformed token" do
      expect(User.find_by_api_token("short")).to be_nil
    end

    it "updates last_used_at" do
      expect(user[:api_token_last_used_at]).to be_nil
      User.find_by_api_token(token)
      user.reload
      expect(user[:api_token_last_used_at]).not_to be_nil
    end

    it "returns nil for expired token" do
      user[:api_token_expires_at] = Time.now - 1
      user.save(validate: false)
      expect(User.find_by_api_token(token)).to be_nil
    end
  end

  describe "#touch_api_token_usage!" do
    it "updates last_used_at timestamp" do
      user.generate_api_token!
      expect(user[:api_token_last_used_at]).to be_nil

      user.touch_api_token_usage!
      user.reload

      expect(user[:api_token_last_used_at]).to be_within(1).of(Time.now)
    end
  end

  describe "#api_token_expired?" do
    it "returns false when expires_at is nil" do
      user.generate_api_token!
      expect(user.api_token_expired?).to be false
    end

    it "returns false when token not yet expired" do
      user.generate_api_token!(expires_in: 3600)
      expect(user.api_token_expired?).to be false
    end

    it "returns true when token is expired" do
      user.generate_api_token!
      user[:api_token_expires_at] = Time.now - 1
      user.save(validate: false)
      expect(user.api_token_expired?).to be true
    end
  end
end
