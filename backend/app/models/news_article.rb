# frozen_string_literal: true

# NewsArticle represents IC news generated from significant events.
# Can be auto-generated or staff-written.
class NewsArticle < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :metaplot_event
  many_to_one :author, class: :Character
  many_to_one :location  # Where the news is from

  CATEGORIES = %w[breaking local politics crime business entertainment
                  sports weather obituary editorial].freeze
  status_enum :status, %w[draft published archived retracted]

  def validate
    super
    validates_presence [:headline, :body, :category]
    validates_max_length 200, :headline
    validates_includes CATEGORIES, :category
    validate_status_enum
  end

  def before_save
    super
    self.status ||= 'draft'
    self.written_at ||= Time.now
  end

  def publish!
    update(status: 'published', published_at: Time.now)
  end

  def archive!
    update(status: 'archived')
  end

  def retract!
    update(status: 'retracted')
  end

  def breaking?
    category == 'breaking'
  end

  # Auto-generate news from a metaplot event
  def self.generate_from_event(event, category: 'local')
    create(
      metaplot_event_id: event.id,
      location_id: event.location_id,
      headline: event.title,
      body: event.summary,
      category: category,
      byline: 'Staff Reporter',
      is_ai_generated: true
    )
  end

  def self.published_news
    where(status: 'published').order(Sequel.desc(:published_at))
  end

  def self.for_location(location)
    where(location_id: location.id).published_news
  end

  def self.breaking_news
    where(category: 'breaking', status: 'published')
      .order(Sequel.desc(:published_at))
      .limit(5)
  end
end
