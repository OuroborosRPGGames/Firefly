# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NewsArticle do
  let(:character) { create(:character) }
  let(:news_article) { create(:news_article, author: character) }

  describe 'constants' do
    it 'defines CATEGORIES' do
      expect(NewsArticle::CATEGORIES).to include('breaking', 'local', 'politics', 'crime')
    end

    it 'defines STATUSES' do
      expect(NewsArticle::STATUSES).to eq(%w[draft published archived retracted])
    end
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(news_article).to be_valid
    end
  end

  describe 'before_save callbacks' do
    it 'sets status to draft by default' do
      article = NewsArticle.new(headline: 'Test', body: 'Body', category: 'local')
      article.save
      expect(article.status).to eq('draft')
    end

    it 'sets written_at if not set' do
      article = NewsArticle.new(headline: 'Test', body: 'Body', category: 'local')
      article.save
      expect(article.written_at).not_to be_nil
    end
  end

  describe '#draft?' do
    it 'returns true for draft status' do
      expect(news_article.draft?).to be true
    end

    it 'returns false for published status' do
      news_article = create(:news_article, :published)
      expect(news_article.draft?).to be false
    end
  end

  describe '#published?' do
    it 'returns true for published status' do
      news_article = create(:news_article, :published)
      expect(news_article.published?).to be true
    end

    it 'returns false for draft status' do
      expect(news_article.published?).to be false
    end
  end

  describe '#publish!' do
    it 'changes status to published' do
      news_article.publish!
      expect(news_article.reload.status).to eq('published')
    end

    it 'sets published_at' do
      news_article.publish!
      expect(news_article.reload.published_at).not_to be_nil
    end
  end

  describe '#archive!' do
    it 'changes status to archived' do
      news_article.archive!
      expect(news_article.reload.status).to eq('archived')
    end
  end

  describe '#retract!' do
    it 'changes status to retracted' do
      news_article.retract!
      expect(news_article.reload.status).to eq('retracted')
    end
  end

  describe '#breaking?' do
    it 'returns true for breaking category' do
      news_article = create(:news_article, :breaking)
      expect(news_article.breaking?).to be true
    end

    it 'returns false for other categories' do
      expect(news_article.breaking?).to be false
    end
  end

  describe '.published_news' do
    let!(:published) { create(:news_article, :published) }
    let!(:draft) { create(:news_article) }

    it 'returns only published articles' do
      results = described_class.published_news.all
      expect(results).to include(published)
      expect(results).not_to include(draft)
    end
  end

  describe '.breaking_news' do
    let!(:breaking) { create(:news_article, :breaking, :published) }
    let!(:regular) { create(:news_article, :published) }

    it 'returns only breaking published news' do
      results = described_class.breaking_news.all
      expect(results).to include(breaking)
      expect(results).not_to include(regular)
    end
  end
end
