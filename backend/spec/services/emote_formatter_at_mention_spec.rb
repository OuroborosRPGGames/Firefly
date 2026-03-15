# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EmoteFormatterService, '.resolve_at_mentions' do
  let(:location) { create(:location) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room', location: location) }
  let(:reality) { create(:reality) }

  let(:user1) { create(:user) }
  let(:alice) { create(:character, forename: 'Alice', surname: 'Smith', user: user1) }
  let(:alice_instance) { create(:character_instance, character: alice, current_room: room, reality: reality, online: true) }

  let(:user2) { create(:user) }
  let(:bob) { create(:character, forename: 'Bob', surname: 'Jones', user: user2, short_desc: 'a tall man with a scar') }
  let(:bob_instance) { create(:character_instance, character: bob, current_room: room, reality: reality, online: true) }

  let(:room_chars) { [alice_instance, bob_instance] }

  it 'resolves @forename to full name' do
    result = described_class.resolve_at_mentions('smiles at @Bob', alice_instance, room_chars)
    expect(result).to eq("smiles at #{bob.full_name}")
  end

  it 'resolves @partial via prefix matching' do
    result = described_class.resolve_at_mentions('winks at @Bo', alice_instance, room_chars)
    expect(result).to eq("winks at #{bob.full_name}")
  end

  it 'resolves quoted multi-word @"full name"' do
    result = described_class.resolve_at_mentions('waves at @"Bob Jones"', alice_instance, room_chars)
    expect(result).to eq("waves at #{bob.full_name}")
  end

  it 'leaves unresolved @mentions as-is' do
    result = described_class.resolve_at_mentions('looks at @nobody', alice_instance, room_chars)
    expect(result).to eq('looks at @nobody')
  end

  it 'handles text with no @mentions' do
    result = described_class.resolve_at_mentions('smiles warmly', alice_instance, room_chars)
    expect(result).to eq('smiles warmly')
  end

  it 'handles nil text' do
    result = described_class.resolve_at_mentions(nil, alice_instance, room_chars)
    expect(result).to be_nil
  end

  it 'handles multiple @mentions' do
    result = described_class.resolve_at_mentions('@Alice waves at @Bob', alice_instance, room_chars)
    expect(result).to eq("#{alice.full_name} waves at #{bob.full_name}")
  end

  it 'does not match email-like patterns' do
    result = described_class.resolve_at_mentions('types user@example.com', alice_instance, room_chars)
    expect(result).to eq('types user@example.com')
  end

  it 'is case-insensitive' do
    result = described_class.resolve_at_mentions('nods to @bob', alice_instance, room_chars)
    expect(result).to eq("nods to #{bob.full_name}")
  end
end
