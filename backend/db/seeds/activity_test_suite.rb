# frozen_string_literal: true

# Activity Test Suite Seed
# Creates test activities with all expanded round types for testing
# Run: bundle exec ruby db/seeds/activity_test_suite.rb

require_relative '../../config/application'

puts 'Creating Activity Test Suite...'

# Get a default stat for testing (or create one)
test_stat = Stat.first || Stat.create(name: 'Agility', abbrev: 'AGI', category: 'physical')

# ============================================
# Activity 1: Standard Mission (basic rounds)
# ============================================
standard_activity = Activity.find_or_create(aname: 'Test Standard Mission') do |a|
  a.atype = 'mission'
  a.adesc = 'A test mission with standard rounds for basic testing'
  a.is_public = true
  a.first_string = 'You embark on a standard test mission.'
  a.last_string = 'The standard test mission is complete!'
end

# Clear existing rounds for this activity
ActivityRound.where(activity_id: standard_activity.id).delete

# Create standard rounds
ActivityRound.create(
  activity_id: standard_activity.id,
  round_number: 1,
  branch: 0,
  rtype: 'standard',
  emit: 'Round 1: A simple challenge awaits. Choose your approach.',
  succ_text: 'You successfully complete the first challenge!',
  fail_text: 'The first challenge proves too difficult.',
  fail_repeat: true
)

ActivityRound.create(
  activity_id: standard_activity.id,
  round_number: 2,
  branch: 0,
  rtype: 'standard',
  emit: 'Round 2: The path grows more treacherous.',
  succ_text: 'You navigate the treacherous path!',
  fail_text: 'You stumble on the difficult terrain.'
)

puts "  Created: #{standard_activity.aname} with #{standard_activity.rounds.count} rounds"

# ============================================
# Activity 2: Reflex Test
# ============================================
reflex_activity = Activity.find_or_create(aname: 'Test Reflex Challenge') do |a|
  a.atype = 'mission'
  a.adesc = 'A test of quick reflexes'
  a.is_public = true
  a.first_string = 'Danger approaches! Your reflexes will be tested.'
  a.last_string = 'You survived the reflex challenge!'
end

ActivityRound.where(activity_id: reflex_activity.id).delete

ActivityRound.create(
  activity_id: reflex_activity.id,
  round_number: 1,
  branch: 0,
  rtype: 'reflex',
  emit: 'A boulder rolls toward you! Everyone must dodge!',
  succ_text: 'You leap out of the way!',
  fail_text: 'The boulder clips you! (1 damage)',
  reflex_stat_id: test_stat.id,
  timeout_seconds: 120
)

ActivityRound.create(
  activity_id: reflex_activity.id,
  round_number: 2,
  branch: 0,
  rtype: 'reflex',
  emit: 'Arrows fly from the walls! React quickly!',
  succ_text: 'You evade the arrows!',
  fail_text: 'An arrow grazes you! (1 damage)',
  reflex_stat_id: test_stat.id,
  timeout_seconds: 120
)

puts "  Created: #{reflex_activity.aname} with #{reflex_activity.rounds.count} rounds"

# ============================================
# Activity 3: Group Check Mission
# ============================================
group_activity = Activity.find_or_create(aname: 'Test Group Effort') do |a|
  a.atype = 'mission'
  a.adesc = 'A challenge requiring the whole group to work together'
  a.is_public = true
  a.first_string = 'This challenge requires everyone to contribute!'
  a.last_string = 'The group effort paid off!'
end

ActivityRound.where(activity_id: group_activity.id).delete

ActivityRound.create(
  activity_id: group_activity.id,
  round_number: 1,
  branch: 0,
  rtype: 'group_check',
  emit: 'A heavy door blocks your path. Everyone must push together!',
  succ_text: 'Together, you force the door open!',
  fail_text: 'The door holds firm against your efforts.'
)

ActivityRound.create(
  activity_id: group_activity.id,
  round_number: 2,
  branch: 0,
  rtype: 'group_check',
  emit: 'A chasm must be crossed. Everyone helps build a bridge!',
  succ_text: 'The makeshift bridge holds and everyone crosses!',
  fail_text: 'The bridge is unstable and you must find another way.'
)

puts "  Created: #{group_activity.aname} with #{group_activity.rounds.count} rounds"

# ============================================
# Activity 4: Branch Path Mission
# ============================================
branch_activity = Activity.find_or_create(aname: 'Test Branching Paths') do |a|
  a.atype = 'mission'
  a.adesc = 'A mission with choices that affect the outcome'
  a.is_public = true
  a.first_string = 'You reach a crossroads. Your choice will shape the journey.'
  a.last_string = 'Your choices led you to the end!'
end

ActivityRound.where(activity_id: branch_activity.id).delete

# Initial challenge
ActivityRound.create(
  activity_id: branch_activity.id,
  round_number: 1,
  branch: 0,
  rtype: 'standard',
  emit: 'You approach the ancient temple entrance.',
  succ_text: 'You find the entrance mechanism!',
  fail_text: 'The entrance remains hidden.'
)

# Branch choice
branch_round = ActivityRound.create(
  activity_id: branch_activity.id,
  round_number: 2,
  branch: 0,
  rtype: 'branch',
  emit: 'Two passages lead from the temple entrance. Which do you take?',
  branch_choice_one: 'Take the left passage (dark but shorter)',
  branch_choice_two: 'Take the right passage (lit but longer)'
)

# Left branch (branch 1)
ActivityRound.create(
  activity_id: branch_activity.id,
  round_number: 3,
  branch: 1,
  rtype: 'reflex',
  emit: 'The dark passage is trapped! Dodge the swinging blades!',
  succ_text: 'You navigate the traps!',
  fail_text: 'A blade catches you! (1 damage)',
  reflex_stat_id: test_stat.id
)

# Right branch (branch 2)
ActivityRound.create(
  activity_id: branch_activity.id,
  round_number: 3,
  branch: 2,
  rtype: 'standard',
  emit: 'The lit passage has a puzzle. Solve the riddle on the wall.',
  succ_text: 'You solve the riddle!',
  fail_text: 'The riddle confounds you.'
)

# Both branches converge
ActivityRound.create(
  activity_id: branch_activity.id,
  round_number: 4,
  branch: 0,
  rtype: 'standard',
  emit: 'The passages converge at the treasure chamber.',
  succ_text: 'You claim the treasure!',
  fail_text: 'The treasure eludes you.'
)

puts "  Created: #{branch_activity.aname} with #{branch_activity.rounds.count} rounds"

# ============================================
# Activity 5: Rest and Recovery Mission
# ============================================
rest_activity = Activity.find_or_create(aname: 'Test Long Journey') do |a|
  a.atype = 'mission'
  a.adesc = 'A long journey with rest stops'
  a.is_public = true
  a.first_string = 'A long journey lies ahead. Pace yourself.'
  a.last_string = 'You complete the long journey!'
end

ActivityRound.where(activity_id: rest_activity.id).delete

ActivityRound.create(
  activity_id: rest_activity.id,
  round_number: 1,
  branch: 0,
  rtype: 'standard',
  emit: 'The first leg of the journey tests your endurance.',
  succ_text: 'You push through the first stretch!',
  fail_text: 'The journey takes its toll.',
  fail_con: 'injury'
)

ActivityRound.create(
  activity_id: rest_activity.id,
  round_number: 2,
  branch: 0,
  rtype: 'rest',
  emit: 'You find a campsite. Rest here to recover before continuing.',
  succ_text: 'Well rested, you continue.',
  fail_text: 'You push on without rest.'
)

ActivityRound.create(
  activity_id: rest_activity.id,
  round_number: 3,
  branch: 0,
  rtype: 'reflex',
  emit: 'Bandits ambush the camp! React quickly!',
  succ_text: 'You fend off the bandits!',
  fail_text: 'The bandits get the drop on you! (1 damage)',
  reflex_stat_id: test_stat.id
)

ActivityRound.create(
  activity_id: rest_activity.id,
  round_number: 4,
  branch: 0,
  rtype: 'rest',
  emit: 'A friendly inn offers shelter. Rest before the final push.',
  succ_text: 'Fully refreshed, you set out.',
  fail_text: 'You skip the inn and continue.'
)

ActivityRound.create(
  activity_id: rest_activity.id,
  round_number: 5,
  branch: 0,
  rtype: 'group_check',
  emit: 'The final mountain pass requires the whole group!',
  succ_text: 'Everyone makes it through!',
  fail_text: 'Some struggle on the pass.'
)

puts "  Created: #{rest_activity.aname} with #{rest_activity.rounds.count} rounds"

# ============================================
# Activity 6: Mixed Challenge (all types)
# ============================================
mixed_activity = Activity.find_or_create(aname: 'Test Ultimate Challenge') do |a|
  a.atype = 'mission'
  a.adesc = 'A mission testing all skills with every round type'
  a.is_public = true
  a.first_string = 'The ultimate challenge awaits! Every skill will be tested.'
  a.last_string = 'You have conquered the ultimate challenge!'
end

ActivityRound.where(activity_id: mixed_activity.id).delete

ActivityRound.create(
  activity_id: mixed_activity.id,
  round_number: 1,
  branch: 0,
  rtype: 'standard',
  emit: 'Phase 1: Enter the dungeon. Find your way in.',
  succ_text: 'You find the entrance!',
  fail_text: 'The entrance is hidden.',
  fail_repeat: true
)

ActivityRound.create(
  activity_id: mixed_activity.id,
  round_number: 2,
  branch: 0,
  rtype: 'reflex',
  emit: 'Phase 2: Trap corridor! Dodge the darts!',
  succ_text: 'You weave through the darts!',
  fail_text: 'A dart hits you! (1 damage)',
  reflex_stat_id: test_stat.id,
  timeout_seconds: 120
)

ActivityRound.create(
  activity_id: mixed_activity.id,
  round_number: 3,
  branch: 0,
  rtype: 'group_check',
  emit: 'Phase 3: A massive gate. Everyone must lift together!',
  succ_text: 'The gate rises!',
  fail_text: 'The gate is too heavy.'
)

ActivityRound.create(
  activity_id: mixed_activity.id,
  round_number: 4,
  branch: 0,
  rtype: 'branch',
  emit: 'Phase 4: Two paths. Left leads to treasure, right to knowledge.',
  branch_choice_one: 'Seek the treasure room',
  branch_choice_two: 'Seek the library'
)

ActivityRound.create(
  activity_id: mixed_activity.id,
  round_number: 5,
  branch: 0,
  rtype: 'rest',
  emit: 'Phase 5: A safe room. Heal your wounds before the final battle.',
  succ_text: 'Rested and ready!',
  fail_text: 'You push on tired.'
)

ActivityRound.create(
  activity_id: mixed_activity.id,
  round_number: 6,
  branch: 0,
  rtype: 'standard',
  emit: 'Phase 6: The final chamber. Face the guardian!',
  succ_text: 'You defeat the guardian!',
  fail_text: 'The guardian defeats you.'
)

puts "  Created: #{mixed_activity.aname} with #{mixed_activity.rounds.count} rounds"

puts ''
puts 'Activity Test Suite created!'
puts ''
puts 'Activities available for testing:'
Activity.where(is_public: true).each do |a|
  puts "  - #{a.aname} (#{a.atype}): #{a.rounds.count} rounds"
  a.rounds.order(:branch, :round_number).each do |r|
    branch_info = r.branch > 0 ? " [Branch #{r.branch}]" : ''
    puts "      Round #{r.round_number}#{branch_info}: #{r.round_type}"
  end
end
