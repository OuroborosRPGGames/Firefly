# frozen_string_literal: true

require 'spec_helper'

RSpec.describe "Phase 6 and Phase 9 E2E Tests", type: :integration do
  let(:user1) { create(:user) }
  let(:char1) { create(:character, forename: 'Alice', surname: 'Test', user: user1) }
  let(:room) { create(:room, name: 'Test Room') }
  let(:reality) { create(:reality) }
  let(:instance1) { create(:character_instance, character: char1, current_room: room, reality: reality, stance: 'standing') }

  let(:user2) { create(:user) }
  let(:char2) { create(:character, forename: 'Bob', surname: 'Smith', user: user2) }
  let!(:instance2) { create(:character_instance, character: char2, current_room: room, reality: reality, stance: 'standing') }

  describe "Phase 6: Attempt Consent" do
    it "submits a valid attempt" do
      cmd = Commands::Communication::Attempt.new(instance1)
      result = cmd.execute('attempt Bob hugs warmly')
      
      expect(result[:success]).to be true
      expect(instance1.reload.attempt_target_id).to eq(instance2.id)
    end

    it "target receives pending attempt" do
      cmd = Commands::Communication::Attempt.new(instance1)
      cmd.execute('attempt Bob hugs warmly')
      
      expect(instance2.reload.pending_attempt_text).to eq('hugs warmly')
      expect(instance2.pending_attempter_id).to eq(instance1.id)
    end

    it "rejects attempt with no arguments" do
      cmd = Commands::Communication::Attempt.new(instance1)
      result = cmd.execute('attempt')
      
      expect(result[:success]).to be false
    end

    it "rejects attempt on non-existent target" do
      cmd = Commands::Communication::Attempt.new(instance1)
      result = cmd.execute('attempt NoOne does something')
      
      expect(result[:success]).to be false
    end

    it "rejects attempt on self" do
      cmd = Commands::Communication::Attempt.new(instance1)
      result = cmd.execute('attempt Alice hugs herself')
      
      expect(result[:success]).to be false
    end
  end

  describe "Phase 9: Prisoner Mechanics" do
    let(:user3) { create(:user) }
    let(:char3) { create(:character, forename: 'Charlie', surname: 'Actor', user: user3) }
    let!(:instance3) { create(:character_instance, character: char3, current_room: room, reality: reality, stance: 'standing') }

    it "helpless command toggles state" do
      cmd = Commands::Prisoner::Helpless.new(instance2)
      result = cmd.execute('helpless on')
      
      expect(result[:success]).to be true
      expect(instance2.reload.is_helpless?).to be true
    end

    it "tie command binds helpless target" do
      # Make target helpless first
      Commands::Prisoner::Helpless.new(instance2).execute('helpless on')
      
      cmd = Commands::Prisoner::Tie.new(instance3)
      result = cmd.execute('tie Bob')
      
      expect(result[:success]).to be true
      expect(instance2.reload.hands_bound?).to be true
    end

    it "blindfold command blinds target" do
      # Make target helpless first
      Commands::Prisoner::Helpless.new(instance2).execute('helpless on')
      
      cmd = Commands::Prisoner::Blindfold.new(instance3)
      result = cmd.execute('blindfold Bob')
      
      expect(result[:success]).to be true
      expect(instance2.reload.is_blindfolded?).to be true
    end

    it "gag command gags target" do
      # Make target helpless first
      Commands::Prisoner::Helpless.new(instance2).execute('helpless on')
      
      cmd = Commands::Prisoner::Gag.new(instance3)
      result = cmd.execute('gag Bob')
      
      expect(result[:success]).to be true
      expect(instance2.reload.is_gagged?).to be true
    end

    it "carry command picks up restrained target" do
      # Make target helpless and tie them
      Commands::Prisoner::Helpless.new(instance2).execute('helpless on')
      Commands::Prisoner::Tie.new(instance3).execute('tie Bob')
      
      cmd = Commands::Prisoner::Carry.new(instance3)
      result = cmd.execute('carry Bob')
      
      expect(result[:success]).to be true
      expect(instance2.reload.being_carried?).to be true
      expect(instance2.being_carried_by_id).to eq(instance3.id)
    end

    it "drop prisoner releases carried target" do
      # Make target helpless, tie, and carry them
      Commands::Prisoner::Helpless.new(instance2).execute('helpless on')
      Commands::Prisoner::Tie.new(instance3).execute('tie Bob')
      Commands::Prisoner::Carry.new(instance3).execute('carry Bob')
      
      cmd = Commands::Prisoner::DropPrisoner.new(instance3)
      result = cmd.execute('drop prisoner')
      
      expect(result[:success]).to be true
      expect(instance2.reload.being_carried?).to be false
      expect(instance2.being_carried_by_id).to be_nil
    end

    it "untie command removes restraints" do
      # Make target helpless and restrain them
      Commands::Prisoner::Helpless.new(instance2).execute('helpless on')
      Commands::Prisoner::Tie.new(instance3).execute('tie Bob')
      Commands::Prisoner::Blindfold.new(instance3).execute('blindfold Bob')
      Commands::Prisoner::Gag.new(instance3).execute('gag Bob')
      
      # Now untie them
      cmd = Commands::Prisoner::Untie.new(instance3)
      result = cmd.execute('untie Bob all')
      
      expect(result[:success]).to be true
      instance2.reload
      expect(instance2.hands_bound?).to be false
      expect(instance2.is_blindfolded?).to be false
      expect(instance2.is_gagged?).to be false
    end

    it "helpless off clears helpless state" do
      # Make helpless then turn it off
      Commands::Prisoner::Helpless.new(instance2).execute('helpless on')
      expect(instance2.reload.is_helpless?).to be true
      
      cmd = Commands::Prisoner::Helpless.new(instance2)
      result = cmd.execute('helpless off')
      
      expect(result[:success]).to be true
      expect(instance2.reload.is_helpless?).to be false
    end
  end
end
