# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveMonsterService do
  let(:delve) do
    instance_double('Delve',
                    id: 1,
                    difficulty: 'normal',
                    monster_difficulty_for_level: 50)
  end
  let(:room) do
    instance_double('DelveRoom',
                    id: 1,
                    room_type: 'corridor',
                    is_entrance: false,
                    is_exit: false)
  end
  let(:monster) do
    instance_double('DelveMonster',
                    id: 1,
                    monster_type: 'Goblin',
                    hp: 6,
                    max_hp: 6,
                    pick_direction!: nil)
  end
  let(:participant) do
    instance_double('DelveParticipant', id: 1)
  end

  describe 'constants' do
    it 'defines MOVEMENT_THRESHOLD_SECONDS via GameConfig' do
      expect(GameConfig::DelveMonster::MOVEMENT_THRESHOLD_SECONDS).to eq(10)
    end
  end

  describe 'class methods' do
    it 'responds to spawn_monsters!' do
      expect(described_class).to respond_to(:spawn_monsters!)
    end

    it 'responds to tick_movement!' do
      expect(described_class).to respond_to(:tick_movement!)
    end

    it 'responds to check_collision' do
      expect(described_class).to respond_to(:check_collision)
    end

    it 'responds to start_combat!' do
      expect(described_class).to respond_to(:start_combat!)
    end
  end

  describe '.spawn_monsters!' do
    let(:rng) { Random.new(12345) }

    before do
      # Service calls: rooms_on_level.exclude(...).exclude(...).exclude(...).where(...).all
      chain = double('query_chain')
      allow(chain).to receive(:exclude).and_return(chain)
      allow(chain).to receive(:where).and_return(chain)
      allow(chain).to receive(:all).and_return([room])
      allow(delve).to receive(:rooms_on_level).and_return(chain)
      allow(DelveMonster).to receive(:create).and_return(monster)
    end

    it 'returns empty array when no rooms available' do
      empty_chain = double('empty_query_chain')
      allow(empty_chain).to receive(:exclude).and_return(empty_chain)
      allow(empty_chain).to receive(:where).and_return(empty_chain)
      allow(empty_chain).to receive(:all).and_return([])
      allow(delve).to receive(:rooms_on_level).and_return(empty_chain)
      result = described_class.spawn_monsters!(delve, 1, rng)
      expect(result).to eq([])
    end

    it 'creates monsters with correct attributes' do
      expect(DelveMonster).to receive(:create).with(hash_including(
                                                      delve_id: delve.id,
                                                      level: 1
                                                    )).at_least(:once)
      described_class.spawn_monsters!(delve, 1, rng)
    end

    it 'returns array of spawned monsters' do
      result = described_class.spawn_monsters!(delve, 1, rng)
      expect(result).to be_an(Array)
      expect(result.first).to eq(monster)
    end
  end

  describe '.tick_movement!' do
    it 'returns empty array if time spent is below threshold' do
      result = described_class.tick_movement!(delve, 5)
      expect(result).to eq([])
    end

    it 'calls delve.tick_monster_movement! when time is above threshold' do
      expect(delve).to receive(:tick_monster_movement!).with(15).and_return([])
      described_class.tick_movement!(delve, 15)
    end
  end

  describe '.check_collision' do
    it 'returns monster in room' do
      allow(delve).to receive(:monsters_in_room).with(room).and_return([monster])
      result = described_class.check_collision(delve, room)
      expect(result).to eq(monster)
    end

    it 'returns nil when no monsters in room' do
      allow(delve).to receive(:monsters_in_room).with(room).and_return([])
      result = described_class.check_collision(delve, room)
      expect(result).to be_nil
    end
  end

  describe '.start_combat!' do
    it 'delegates to DelveCombatService' do
      expect(DelveCombatService).to receive(:create_fight!).with(delve, monster, [participant])
      described_class.start_combat!(delve, monster, [participant])
    end
  end

  describe '.spawn_lurkers!' do
    let(:rng) { Random.new(12345) }
    let(:terminal_room) do
      instance_double('DelveRoom',
                      id: 10,
                      room_type: 'chamber',
                      is_entrance: false,
                      is_exit: false,
                      is_terminal: true)
    end
    let(:lurker) do
      instance_double('DelveMonster',
                      id: 99,
                      monster_type: 'Goblin',
                      hp: 6,
                      max_hp: 6)
    end

    before do
      chain = double('query_chain')
      allow(chain).to receive(:where).and_return(chain)
      allow(chain).to receive(:exclude).and_return(chain)
      allow(chain).to receive(:all).and_return([terminal_room])
      allow(delve).to receive(:rooms_on_level).and_return(chain)
      allow(DelveMonster).to receive(:create).and_return(lurker)
    end

    it 'responds to spawn_lurkers!' do
      expect(described_class).to respond_to(:spawn_lurkers!)
    end

    it 'creates lurking monsters with lurking: true' do
      stub_const('GameConfig::Delve::CONTENT', { lurker_chance: 1.0 })

      expect(DelveMonster).to receive(:create).with(hash_including(
                                                      lurking: true,
                                                      delve_id: delve.id,
                                                      current_room_id: terminal_room.id,
                                                      level: 1
                                                    )).and_return(lurker)

      described_class.spawn_lurkers!(delve, 1, rng)
    end

    it 'excludes entrance rooms' do
      chain = double('query_chain')
      allow(chain).to receive(:where).with(is_terminal: true).and_return(chain)
      allow(chain).to receive(:exclude).with(is_entrance: true).and_return(chain)
      allow(chain).to receive(:exclude).with(is_exit: true).and_return(chain)
      allow(chain).to receive(:exclude).with(is_boss: true).and_return(chain)
      allow(chain).to receive(:all).and_return([])
      allow(delve).to receive(:rooms_on_level).with(1).and_return(chain)

      result = described_class.spawn_lurkers!(delve, 1, rng)
      expect(result).to eq([])
    end

    it 'returns array of spawned lurkers' do
      stub_const('GameConfig::Delve::CONTENT', { lurker_chance: 1.0 })

      result = described_class.spawn_lurkers!(delve, 1, rng)
      expect(result).to be_an(Array)
      expect(result).to include(lurker)
    end

    it 'skips rooms when RNG exceeds lurker_chance' do
      stub_const('GameConfig::Delve::CONTENT', { lurker_chance: 0.0 })

      expect(DelveMonster).not_to receive(:create)

      result = described_class.spawn_lurkers!(delve, 1, rng)
      expect(result).to eq([])
    end
  end

  describe 'spawn count calculation' do
    # Test indirectly through spawn_monsters!
    let(:rng) { Random.new(12345) }

    before do
      # Service calls: rooms_on_level.exclude(...).exclude(...).exclude(...).where(...).all
      chain = double('query_chain')
      allow(chain).to receive(:exclude).and_return(chain)
      allow(chain).to receive(:where).and_return(chain)
      allow(chain).to receive(:all).and_return([room, room, room])
      allow(delve).to receive(:rooms_on_level).and_return(chain)
      allow(DelveMonster).to receive(:create).and_return(monster)
    end

    it 'spawns more monsters on harder difficulties' do
      allow(delve).to receive(:difficulty).and_return('nightmare')
      result_hard = described_class.spawn_monsters!(delve, 1, Random.new(12345))

      allow(delve).to receive(:difficulty).and_return('easy')
      result_easy = described_class.spawn_monsters!(delve, 1, Random.new(12345))

      expect(result_hard.length).to be >= result_easy.length
    end

    it 'spawns more monsters on deeper levels' do
      result_level1 = described_class.spawn_monsters!(delve, 1, Random.new(12345))
      result_level5 = described_class.spawn_monsters!(delve, 5, Random.new(12345))

      expect(result_level5.length).to be >= result_level1.length
    end
  end
end
