# frozen_string_literal: true

# Permission defines the available permissions in the system.
# Permissions are stored as JSONB on the User model, not as separate records.
#
# Usage:
#   Permission.all               # => ['can_create_staff_characters', ...]
#   Permission.valid?('can_build') # => true
#   Permission.info('can_build')   # => { name: 'Build', ... }
#
module Permission
  PERMISSIONS = {
    'can_create_staff_characters' => {
      name: 'Create Staff Characters',
      description: 'Ability to create characters marked as staff',
      category: :staff
    },
    'can_see_all_rp' => {
      name: 'See All Roleplay',
      description: 'Receive broadcasts from all non-private rooms via staff vision',
      category: :staff
    },
    'can_go_invisible' => {
      name: 'Go Invisible',
      description: 'Hide from player "who" lists and room presence',
      category: :staff
    },
    'can_access_admin_console' => {
      name: 'Access Admin Console',
      description: 'View and modify game configuration settings',
      category: :admin
    },
    'can_manage_users' => {
      name: 'Manage Users',
      description: 'View user accounts and modify their status',
      category: :admin
    },
    'can_manage_permissions' => {
      name: 'Manage Permissions',
      description: 'Grant or revoke permissions on other users',
      category: :admin
    },
    'can_build' => {
      name: 'Build',
      description: 'Create and modify rooms, exits, and world content',
      category: :world
    },
    'can_manage_npcs' => {
      name: 'Manage All NPCs',
      description: 'Create, edit, and configure any NPC regardless of creator',
      category: :world
    },
    'can_moderate' => {
      name: 'Moderate',
      description: 'Access moderation tools like banning and muting',
      category: :moderation
    }
  }.freeze

  CATEGORIES = {
    staff: 'Staff Character Powers',
    admin: 'Administration',
    world: 'World Building',
    moderation: 'Moderation'
  }.freeze

  class << self
    # Get all permission keys
    # @return [Array<String>]
    def all
      PERMISSIONS.keys
    end

    # Get permission info by key
    # @param permission_name [String, Symbol]
    # @return [Hash, nil]
    def info(permission_name)
      PERMISSIONS[permission_name.to_s]
    end

    # Check if a permission key is valid
    # @param permission_name [String, Symbol]
    # @return [Boolean]
    def valid?(permission_name)
      PERMISSIONS.key?(permission_name.to_s)
    end

    # Get permissions grouped by category
    # @return [Hash<Symbol, Array<Hash>>]
    def by_category
      PERMISSIONS.each_with_object({}) do |(key, info), grouped|
        cat = info[:category]
        grouped[cat] ||= []
        grouped[cat] << { key: key, **info }
      end
    end

    # Get category name
    # @param category [Symbol]
    # @return [String]
    def category_name(category)
      CATEGORIES[category] || NamingHelper.titleize(category.to_s)
    end
  end
end
