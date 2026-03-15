# frozen_string_literal: true

# Skip loading if table doesn't exist
return unless DB.table_exists?(:friends)

# Friend represents an OOC friendship between users.
# Friends can bypass certain permissions and see each other's characters.
class Friend < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :user
  many_to_one :friend_user, class: :User

  def validate
    super
    validates_presence [:user_id, :friend_user_id]
    validates_unique [:user_id, :friend_user_id]

    # Can't friend yourself
    if user_id == friend_user_id
      errors.add(:friend_user_id, 'cannot be yourself')
    end
  end

  def before_save
    super
    self.status ||= 'pending'
    self.requested_at ||= Time.now
  end

  def pending?
    status == 'pending'
  end

  def accepted?
    status == 'accepted'
  end

  def blocked?
    status == 'blocked'
  end

  def accept!
    update(status: 'accepted', accepted_at: Time.now)
    # Create reciprocal friendship
    Friend.find_or_create(user_id: friend_user_id, friend_user_id: user_id) do |f|
      f.status = 'accepted'
      f.accepted_at = Time.now
    end
  end

  def reject!
    destroy
  end

  def block!
    update(status: 'blocked')
  end

  def self.friends?(user1, user2)
    where(user_id: user1.id, friend_user_id: user2.id, status: 'accepted').any?
  end
end
