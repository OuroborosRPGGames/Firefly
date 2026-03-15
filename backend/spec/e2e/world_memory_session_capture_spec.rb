# frozen_string_literal: true

describe "World Memory Session Capture E2E", type: :integration do
  let(:reality) { Reality.first || Reality.create(name: 'Test Reality', reality_type: 'primary', time_offset: 0) }

  describe "Phase 1.1: Basic Session Creation with Multi-Agent Conversation" do
    it "creates a world memory session when two characters exchange IC messages" do
      # Setup characters and room
      char1 = create_test_character(forename: 'WME2E_Alpha')
      char2 = create_test_character(forename: 'WME2E_Bravo')
      room = create_test_room(name: 'WME2E Test Room')

      # Setup instances
      inst1 = create_test_character_instance(character: char1, room:, reality:)
      inst2 = create_test_character_instance(character: char2, room:, reality:)

      # Track conversation
      messages = [
        { sender: inst1, content: "Hello there, friend!", type: 'say' },
        { sender: inst1, content: "waves warmly.", type: 'emote' },
        { sender: inst2, content: "Well met, stranger!", type: 'say' },
        { sender: inst2, content: "nods in greeting.", type: 'emote' },
        { sender: inst1, content: "How have you been?", type: 'say' },
        { sender: inst2, content: "I have been well, thank you.", type: 'say' },
        { sender: inst1, content: "Let me tell you about the dragon I saw yesterday.", type: 'say' },
        { sender: inst1, content: "leans in conspiratorially.", type: 'emote' },
        { sender: inst2, content: "listens intently.", type: 'emote' },
        { sender: inst1, content: "It was enormous, with scales like obsidian.", type: 'say' }
      ]

      session = nil
      messages.each do |msg|
        session = WorldMemoryService.track_ic_message(
          room_id: room.id,
          content: msg[:content],
          sender: msg[:sender],
          type: msg[:type]
        )
      end

      # Verify session was created
      expect(session).not_to be_nil
      expect(session).to be_active
      expect(session.message_count).to be >= messages.length
      expect(session.active_character_count).to eq(2)
      expect(session.active_character_ids).to match_array([char1.id, char2.id])
      expect(session.room_id).to eq(room.id)
    end
  end

  describe "Phase 1.2: Individual IC Message Types" do
    it "tracks 'say' messages" do
      char = create_test_character(forename: 'WME2E_Speaker')
      char2 = create_test_character(forename: 'WME2E_Listener')
      room = create_test_room(name: 'WME2E Room_Say')
      inst1 = create_test_character_instance(character: char, room:, reality:)
      inst2 = create_test_character_instance(character: char2, room:, reality:)

      session = WorldMemoryService.track_ic_message(
        room_id: room.id,
        content: "This is a test of IC message types",
        sender: inst1,
        type: 'say'
      )

      expect(session).not_to be_nil
      expect(session.message_count).to be >= 1
    end

    it "tracks 'emote' messages" do
      char = create_test_character(forename: 'WME2E_Emoter')
      char2 = create_test_character(forename: 'WME2E_Watcher')
      room = create_test_room(name: 'WME2E Room_Emote')
      inst1 = create_test_character_instance(character: char, room:, reality:)
      inst2 = create_test_character_instance(character: char2, room:, reality:)

      session = WorldMemoryService.track_ic_message(
        room_id: room.id,
        content: "stretches quietly.",
        sender: inst1,
        type: 'emote'
      )

      expect(session).not_to be_nil
      expect(session.message_count).to be >= 1
    end

    it "tracks 'think' messages" do
      char = create_test_character(forename: 'WME2E_Thinker')
      char2 = create_test_character(forename: 'WME2E_Mindreader')
      room = create_test_room(name: 'WME2E Room_Think')
      inst1 = create_test_character_instance(character: char, room:, reality:)
      inst2 = create_test_character_instance(character: char2, room:, reality:)

      session = WorldMemoryService.track_ic_message(
        room_id: room.id,
        content: "I wonder if this works",
        sender: inst1,
        type: 'think'
      )

      expect(session).not_to be_nil
      expect(session.message_count).to be >= 1
    end
  end

  describe "Phase 1.5: Solo Character (No Session Creation)" do
    it "returns nil when only one character in room (no session needed)" do
      char = create_test_character(forename: 'WME2E_Solo')
      room = create_test_room(name: 'WME2E Room_Solo')
      inst1 = create_test_character_instance(character: char, room:, reality:)

      session = WorldMemoryService.track_ic_message(
        room_id: room.id,
        content: "Hello? Is anyone there?",
        sender: inst1,
        type: 'say'
      )

      expect(session).to be_nil
    end

    it "returns nil for emote when solo" do
      char = create_test_character(forename: 'WME2E_Solo2')
      room = create_test_room(name: 'WME2E Room_SoloEmote')
      inst1 = create_test_character_instance(character: char, room:, reality:)

      session = WorldMemoryService.track_ic_message(
        room_id: room.id,
        content: "looks around nervously.",
        sender: inst1,
        type: 'emote'
      )

      expect(session).to be_nil
    end
  end
end
