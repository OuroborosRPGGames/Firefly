# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::System::News, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end
  let(:staff_user) { create(:user) }

  subject(:command) { described_class.new(character_instance) }

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['news']).to eq(described_class)
    end

    it 'has alias announcements' do
      cmd_class, = Commands::Base::Registry.find_command('announcements')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('news')
    end

    it 'has category system' do
      expect(described_class.category).to eq(:system)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('announcement')
    end

    it 'has usage' do
      expect(described_class.usage).to include('news')
    end

    it 'has examples' do
      expect(described_class.examples).to include('news')
    end
  end

  describe '#execute' do
    context 'with no arguments' do
      before do
        allow(::StaffBulletin).to receive(:unread_counts_for).with(user).and_return({
                                                                                      'announcement' => 2,
                                                                                      'ic' => 0,
                                                                                      'ooc' => 1
                                                                                    })
      end

      it 'shows news categories with unread counts' do
        result = command.execute('news')

        expect(result[:success]).to be true
        expect(result[:message]).to include('<h3>News</h3>')
        expect(result[:message]).to include('Announcements')
        expect(result[:message]).to include('IC News')
        expect(result[:message]).to include('OOC News')
      end

      it 'shows unread count for announcements' do
        result = command.execute('news')

        expect(result[:message]).to include('Announcements: 2 unread')
      end

      it 'shows up to date for ic' do
        result = command.execute('news')

        expect(result[:message]).to include('IC News: up to date')
      end

      it 'includes counts in data' do
        result = command.execute('news')

        expect(result[:data][:action]).to eq('news_categories')
        expect(result[:data][:counts]['announcement']).to eq(2)
      end
    end

    context 'with category argument' do
      let(:article1) do
        double('StaffBulletin',
               id: 1,
               title: 'Test Article',
               published_at: Time.now - 86_400,
               created_by_user: staff_user,
               read_by?: false,
               to_hash: { id: 1, title: 'Test Article' })
      end
      let(:article2) do
        double('StaffBulletin',
               id: 2,
               title: 'Old Article',
               published_at: Time.now - 172_800,
               created_by_user: staff_user,
               read_by?: true,
               to_hash: { id: 2, title: 'Old Article' })
      end

      before do
        # Instead of stubbing the frozen NEWS_TYPES constant, stub the command's
        # validation method or use valid news types directly
        query = double
        allow(::StaffBulletin).to receive(:published).and_return(query)
        allow(query).to receive(:by_type).with('announcement').and_return(query)
        allow(query).to receive(:recent).and_return(query)
        allow(query).to receive(:all).and_return([article1, article2])
      end

      it 'shows articles for announcement category' do
        result = command.execute('news announcement')

        expect(result[:success]).to be true
        expect(result[:message]).to include('<h3>Announcements</h3>')
        expect(result[:message]).to include('Test Article')
        expect(result[:message]).to include('Old Article')
      end

      it 'marks unread articles with [NEW]' do
        result = command.execute('news announcement')

        expect(result[:message]).to include('[NEW] #1 Test Article')
      end

      it 'shows article ID for reading' do
        result = command.execute('news announcement')

        expect(result[:message]).to include("#1")
        expect(result[:message]).to include("#2")
      end

      it 'shows instructions for reading articles' do
        result = command.execute('news announcement')

        expect(result[:message]).to include("Use 'news <id>' to read")
      end

      it 'normalizes category aliases' do
        query = double
        allow(::StaffBulletin).to receive(:published).and_return(query)
        allow(query).to receive(:by_type).with('announcement').and_return(query)
        allow(query).to receive(:recent).and_return(query)
        allow(query).to receive(:all).and_return([article1])

        result = command.execute('news announcements')

        expect(result[:success]).to be true
      end

      it 'normalizes ic category' do
        query = double
        allow(::StaffBulletin).to receive(:published).and_return(query)
        allow(query).to receive(:by_type).with('ic').and_return(query)
        allow(query).to receive(:recent).and_return(query)
        allow(query).to receive(:all).and_return([])

        result = command.execute('news icnews')

        expect(result[:success]).to be true
      end

      it 'returns error for unknown category' do
        # 'invalid' is not in NEWS_TYPES so this should fail naturally
        result = command.execute('news invalid')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown category')
        expect(result[:error]).to include('announcement, ic, ooc')
      end

      it 'handles empty article list' do
        query = double
        allow(::StaffBulletin).to receive(:published).and_return(query)
        allow(query).to receive(:by_type).and_return(query)
        allow(query).to receive(:recent).and_return(query)
        allow(query).to receive(:all).and_return([])

        result = command.execute('news announcement')

        expect(result[:success]).to be true
        expect(result[:message]).to include('No announcement news articles')
      end
    end

    context 'with article ID argument' do
      let(:article) do
        double('StaffBulletin',
               id: 5,
               title: 'Important Update',
               content: 'This is the article content.',
               published_at: Time.now - 3600,
               created_by_user: staff_user,
               type_display: 'announcement',
               to_hash: { id: 5, title: 'Important Update' })
      end

      before do
        query = double
        allow(::StaffBulletin).to receive(:published).and_return(query)
        allow(query).to receive(:first).with(id: 5).and_return(article)
        allow(article).to receive(:mark_read_by!).with(user)
      end

      it 'displays the article' do
        result = command.execute('news 5')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Important Update')
        expect(result[:message]).to include('This is the article content.')
      end

      it 'shows article header with type' do
        result = command.execute('news 5')

        expect(result[:message]).to include('[ANNOUNCEMENT]')
      end

      it 'marks article as read' do
        expect(article).to receive(:mark_read_by!).with(user)

        command.execute('news 5')
      end

      it 'shows posted by information' do
        allow(staff_user).to receive(:username).and_return('admin')

        result = command.execute('news 5')

        expect(result[:message]).to include('Posted by admin')
      end

      it 'returns error for invalid article ID' do
        query = double
        allow(::StaffBulletin).to receive(:published).and_return(query)
        allow(query).to receive(:first).with(id: 999).and_return(nil)

        result = command.execute('news 999')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Article #999 not found')
      end

      it 'returns error for zero or negative ID' do
        result = command.execute('news 0')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Please specify an article ID')
      end
    end

    context 'with "read" syntax' do
      let(:article) do
        double('StaffBulletin',
               id: 3,
               title: 'Article Title',
               content: 'Content here',
               published_at: Time.now,
               created_by_user: staff_user,
               type_display: 'ic',
               to_hash: { id: 3 })
      end

      before do
        query = double
        allow(::StaffBulletin).to receive(:published).and_return(query)
        allow(query).to receive(:first).with(id: 3).and_return(article)
        allow(article).to receive(:mark_read_by!)
      end

      it 'supports "news read 3" syntax' do
        result = command.execute('news read 3')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Article Title')
      end

      it 'handles extra whitespace' do
        result = command.execute('news read  3')

        expect(result[:success]).to be true
      end
    end
  end
end
