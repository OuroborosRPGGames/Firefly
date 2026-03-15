# frozen_string_literal: true

# Memo represents longer messages/letters between characters.
# Can be IC (letter) or OOC (memo), and can have multiple recipients.
#
# Database schema:
# - sender_id (FK to characters)
# - recipient_id (FK to characters)
# - subject (varchar)
# - content (text body)
# - read (boolean)
# - read_at (timestamp)
class Memo < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :sender, class: :Character, key: :sender_id
  many_to_one :recipient, class: :Character, key: :recipient_id

  MEMO_TYPES = %w[letter memo note report].freeze

  # Alias for compatibility with older code
  def body
    content
  end

  def body=(value)
    self.content = value
  end

  def sent_at
    created_at
  end

  def validate
    super
    validates_presence [:sender_id, :recipient_id, :subject, :content]
    validates_max_length 200, :subject if subject
  end

  def before_save
    super
    self.read = false if read.nil?
  end

  def letter?
    false
  end

  def mark_read!
    update(read: true, read_at: Time.now)
  end

  def unread?
    !read
  end

  def reply_to!(reply_body)
    Memo.create(
      sender_id: recipient_id,
      recipient_id: sender_id,
      subject: "Re: #{subject}",
      content: reply_body
    )
  end

  def self.unread_for(character)
    where(recipient_id: character.id, read: false).order(Sequel.desc(:created_at))
  end

  def self.inbox_for(character)
    where(recipient_id: character.id).order(Sequel.desc(:created_at))
  end

  def self.sent_by(character)
    where(sender_id: character.id).order(Sequel.desc(:created_at))
  end
end
