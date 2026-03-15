# frozen_string_literal: true

# Shared examples for common test patterns
# Include these in specs to reduce boilerplate

# Command metadata shared example
# Usage: it_behaves_like "command metadata", 'look', :navigation, ['l', 'examine']
RSpec.shared_examples "command metadata" do |expected_name, expected_category, expected_aliases = []|
  describe 'command metadata' do
    it "has correct command name" do
      expect(described_class.command_name).to eq(expected_name)
    end

    it "has correct category" do
      expect(described_class.category).to eq(expected_category)
    end

    it "has help text" do
      expect(described_class.help_text).not_to be_nil
      expect(described_class.help_text).not_to be_empty
    end

    expected_aliases.each do |expected_alias|
      it "has alias '#{expected_alias}'" do
        expect(described_class.alias_names).to include(expected_alias)
      end
    end
  end
end

# Can execute shared example
# Usage: it_behaves_like "can_execute?", -> { create_command_with_room }, -> { create_command_without_room }
RSpec.shared_examples "can_execute?" do |with_room_proc, without_room_proc|
  describe '#can_execute?' do
    it 'returns true when character is in a room' do
      command = with_room_proc.call
      expect(command.can_execute?).to be true
    end

    it 'returns false when character has no room' do
      command = without_room_proc.call
      expect(command.can_execute?).to be false
    end
  end
end

# Error result shared example
# Usage: it_behaves_like "returns error for", 'empty input', ''
RSpec.shared_examples "returns error for" do |description, input|
  it "returns error for #{description}" do
    result = command.execute(input)
    expect(result[:success]).to be false
    expect(result[:error]).not_to be_nil
  end
end

# Success result shared example
# Usage: it_behaves_like "returns success for", 'valid input', 'look around'
RSpec.shared_examples "returns success for" do |description, input|
  it "returns success for #{description}" do
    result = command.execute(input)
    expect(result[:success]).to be true
  end
end

# Disambiguation shared example
# Usage: it_behaves_like "supports disambiguation", -> { create_multiple_items }, 'get sword'
RSpec.shared_examples "supports disambiguation" do |setup_proc, input|
  context 'when multiple targets match' do
    before { setup_proc.call }

    it 'returns a quickmenu for disambiguation' do
      result = command.execute(input)
      expect(result[:success]).to be true
      expect(result[:type]).to eq(:quickmenu)
    end
  end
end

# Broadcasting shared example
# Usage: it_behaves_like "broadcasts to room", 'say hello', /says/
RSpec.shared_examples "broadcasts to room" do |input, message_pattern|
  it 'broadcasts message to room' do
    allow(BroadcastService).to receive(:to_room)

    command.execute(input)

    expect(BroadcastService).to have_received(:to_room).with(
      anything,
      a_string_matching(message_pattern),
      hash_including(:exclude)
    )
  end
end

# Staff-only command shared example
# Usage: it_behaves_like "staff-only command", :admin
RSpec.shared_examples "staff-only command" do |required_level = :staff|
  context 'when character is not staff' do
    before do
      allow(character).to receive(:staff?).and_return(false)
      allow(character).to receive(:admin?).and_return(false)
    end

    it 'returns an error' do
      result = command.execute(described_class.command_name)
      expect(result[:success]).to be false
    end
  end

  context "when character is #{required_level}" do
    before do
      allow(character).to receive(:staff?).and_return(true)
      allow(character).to receive(:admin?).and_return(required_level == :admin)
    end

    it 'allows execution' do
      # Subclass tests should verify specific behavior
    end
  end
end

# Normalized arguments shared example
# Usage: it_behaves_like "normalized arguments", 'say'
RSpec.shared_examples "normalized arguments" do |command_name|
  it "includes normalized arguments in parsed_input" do
    parsed = command.send(:parse_input, "#{command_name} test input")
    expect(parsed).to have_key(:normalized)
    expect(parsed[:normalized]).to be_a(Hash)
  end
end

# Era-restricted command shared example
# Usage: it_behaves_like "era-restricted command", [:modern, :near_future]
RSpec.shared_examples "era-restricted command" do |allowed_eras|
  context 'in a disallowed era' do
    before do
      disallowed_era = (EraService::ERAS - allowed_eras).first
      allow(EraService).to receive(:current_era).and_return(disallowed_era)
    end

    it 'returns an error about era restriction' do
      result = command.execute(described_class.command_name)
      expect(result[:success]).to be false
      expect(result[:error]).to match(/era|available/i)
    end
  end
end
