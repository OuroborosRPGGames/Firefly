# frozen_string_literal: true

class StaffBulletin < Sequel::Model
  plugin :timestamps, update_on_create: true

  NEWS_TYPES = %w[announcement ic ooc].freeze

  many_to_one :created_by_user, class: :User
  one_to_many :staff_bulletin_reads

  dataset_module do
    def published
      where(is_published: true).where { published_at <= Time.now }
    end

    def by_type(type)
      where(news_type: type)
    end

    def recent
      order(Sequel.desc(:published_at)).limit(50)
    end
  end

  def validate
    super
    errors.add(:news_type, 'must be a valid type') unless NEWS_TYPES.include?(news_type)
    errors.add(:title, 'is required') if title.nil? || title.strip.empty?
    errors.add(:content, 'is required') if content.nil? || content.strip.empty?
  end

  def before_create
    self.published_at ||= Time.now if is_published
    super
  end

  def type_display
    case news_type
    when 'announcement' then 'Announcement'
    when 'ic' then 'IC News'
    when 'ooc' then 'OOC News'
    else news_type.upcase
    end
  end

  def type_badge_class
    case news_type
    when 'announcement' then 'bg-danger'
    when 'ic' then 'bg-info'
    when 'ooc' then 'bg-secondary'
    else 'bg-primary'
    end
  end

  def read_by?(user)
    return false unless user

    StaffBulletinRead.where(staff_bulletin_id: id, user_id: user.id).any?
  end

  def mark_read_by!(user)
    return if read_by?(user)

    StaffBulletinRead.create(
      staff_bulletin_id: id,
      user_id: user.id,
      read_at: Time.now
    )
  end

  # Get unread counts per news_type for a user
  # Returns: { 'announcement' => 2, 'ic' => 0, 'ooc' => 1 }
  def self.unread_counts_for(user)
    return {} unless user

    # Get all published bulletins by type
    counts = {}
    NEWS_TYPES.each do |type|
      total = published.by_type(type).count
      read = StaffBulletinRead
             .join(:staff_bulletins, id: :staff_bulletin_id)
             .where(Sequel[:staff_bulletin_reads][:user_id] => user.id)
             .where(Sequel[:staff_bulletins][:news_type] => type)
             .where(Sequel[:staff_bulletins][:is_published] => true)
             .count
      counts[type] = total - read
    end
    counts
  end

  # Get total unread count for a user
  def self.total_unread_for(user)
    unread_counts_for(user).values.sum
  end

  def to_hash
    {
      id: id,
      news_type: news_type,
      type_display: type_display,
      title: title,
      content: content,
      is_published: is_published,
      published_at: published_at,
      created_by_username: created_by_user&.username,
      created_at: created_at
    }
  end
end
