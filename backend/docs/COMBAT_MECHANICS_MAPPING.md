# Combat Mechanics Mapping Report

A complete mapping of all combat mechanics from `combat_mechanics_report.md` to the Firefly ability system.

---

## 1. DAMAGE MECHANICS

### 1.1 Base Damage
**Status:** Already Supported

**Current Implementation:**
- `Ability.base_damage_dice` - Dice notation (e.g., "2d8")
- `Ability.damage_stat` - Stat modifier (intelligence, strength)
- `Ability.damage_type` - Fire, ice, lightning, physical, etc.
- `DiceNotationService.roll()` - Dice execution

**No changes needed.**

---

### 1.3 Damage Over Time (DoT)
**Status:** Needs Implementation

**Mapping Plan:**
Create new StatusEffect `effect_type: 'damage_tick'` with mechanics JSONB:
```ruby
{
  damage: "1d6",
  damage_type: "fire",
  timing: "segment_50"  # Uses segment-based timing ± 20
}
```

**Processing Location:** CombatResolutionService
- Schedule tick events at segment 50 ± 20
- Create `process_damage_tick(participant, effect)` method
- Roll damage via DiceNotationService
- Accumulate damage (added over time in each round after the application round for the duration)

**Example Effects to Seed:**
| Name | Damage | Type |
|------|--------|------|
| burning | 1d6 | fire |
| poisoned | 1d4 | poison |
| bleeding | 1d6 | physical |
| freezing | 1d4 | cold |

---

### 1.4 Bonus Damage (Conditional)
**Status:** Needs Implementation

**Mapping Plan:**
Add `Ability.conditional_damage` JSONB column:
```ruby
[
  { condition: "target_below_50_hp", bonus_dice: "2d6" },
  { condition: "target_has_status", status: "burning", bonus_damage: "5" },

]
```

**Processing Location:** AbilityProcessorService
- After resolving primary damage, check each condition
- For matching conditions, roll bonus dice and add to total

**Condition Evaluation:**
```ruby
def evaluate_condition(condition, actor, target, fight)
  case condition[:condition]
  when "target_below_50_hp"
    target.current_hp < (target.max_hp * 0.5)
  when "target_has_status"
    target.has_status_effect?(condition[:status])
  when "flanking"
    flanking?(actor, target, fight)
  when "first_attack_of_round"
    actor.attacks_this_round.zero?
  end
end
```

---

### 1.8 Split Damage
**Status:** Needs Implementation

**Mapping Plan:**
Add `Ability.damage_types` JSONB array (replaces single damage_type for multi-type abilities):
```ruby
[
  { type: "fire", value: "50%" },
  { type: "radiant", value: "50%" }
]
```

**Processing Location:** AbilityProcessorService
- If `damage_types` present, split damage result
- Apply resistance/vulnerability per type separately
- Sum totals for final damage

---

### 1.9 Overflow Damage
**Status:** Future Phase (Tier 5)

**Mapping Plan:**
Add `Ability.overflow_behavior` JSONB:
```ruby
{
  enabled: true,
  aoe_shape: "circle",
  aoe_radius: 1,
  damage_percent: 50
}
```

**Processing:** When target dies, calculate excess damage and apply to nearest enemy or nearby enemies based on aoe.

---

### 1.10 True Damage
**Status:** Needs Implementation

**Mapping Plan:**
Add `Ability.bypasses_resistances` boolean column (default: false)

**Processing Location:** AbilityProcessorService / CombatResolutionService
- When applying damage modifiers, skip resistance calculation if true
- True damage still absorbed by shields

---

## 2. HEALING MECHANICS

### 2.1 Direct Healing
**Status:** Already Supported

**Current Implementation:**
- `Ability.is_healing` flag
- `AbilityProcessorService.process_healing()`
- `FightParticipant.heal!(amount)`

**No changes needed.**

---

### 2.2 Healing Over Time (HoT)
**Status:** Needs Implementation

**Mapping Plan:**
Create new StatusEffect `effect_type: 'healing_tick'`:
```ruby
{
  healing: "0.5",
  timing: "segment_50"
}
```

**Processing Location:** CombatResolutionService
- Same scheduling as damage ticks
- Create `process_healing_tick(participant, effect)`
- Apply healing whenever tick crosses an integer, e.g. every other round with 0.5 healing.

**Example Effects to Seed:**
| Name | Healing |
|------|---------|
| regenerating | 0.5 |
| blessed | 0.25 |

---

### 2.3 Lifesteal / Life Drain
**Status:** Needs Implementation

**Mapping Plan:**
Add `Ability.lifesteal_max` integer column (0-3)

**Processing Location:** AbilityProcessorService
- After damage calculated if amount enough to cause 1 hp of damage heal 1 hp, if 2, 2 etc. Up to lifesteal_max
- Heal actor: `actor.participant.heal!(heal_amount)`
- Create fight event: `{ type: :lifesteal, actor:, amount: }`

---

### 2.5 Healing Amplification
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'healing'` with mechanics:
```ruby
{ multiplier: 1.5 }  # 50% more healing received
```

**Processing Location:** FightParticipant#heal! or StatusEffectService
- Check for healing modifier effects
- Apply multiplier to incoming healing

---

### 2.6 Healing Reduction
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'healing'` with mechanics:
```ruby
{ multiplier: 0.5 }  # 50% less healing received
```

**Processing:** Same as amplification, just with <1.0 multiplier.

---

### 2.7 Death Prevention
**Status:** Future Phase (Tier 4)

**Mapping Plan:**
Create StatusEffect `effect_type: 'death_prevention'`:
```ruby
{
  set_hp_to: 1,
  consumes_on_trigger: true,
  message: "survives with 1 HP"
}
```

**Processing Location:** FightParticipant#take_damage
- Check for death_prevention effects before applying knockout
- If present, set HP to 1 and consume effect

---

## 3. STATUS EFFECTS - DEBUFFS

### 3.1 Dazed
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'action_restriction'`:
```ruby
{ blocks_tactical: true }
```

**Processing Location:** CombatQuickmenuHandler / FightService
- Check for action restrictions when presenting options
- Skip tactical action processing if blocked

---

### 3.3 Prone
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'movement'`:
```ruby
{
  prone: true,
  stand_cost: 2,
}
```

**Processing Location:**
- Movement: Reduce movement by stand_cost at the start of next turn
- Take additional damage from hazards if knocked prone in one.
**Additional:**
Add `Ability.applies_prone` boolean to knock targets prone on hit.

---

### 3.7 Immune (Cannot Attack User)
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'targeting_restriction'`:
```ruby
{
  cannot_target_id: 456,  # The protected participant
  type: "immunity"
}
```

**Processing Location:** CombatQuickmenuHandler
- Filter target options to exclude protected participant

---

### 3.8 Slowed
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'movement'`:
```ruby
{ speed_multiplier: 0.5 }
```

**Processing Location:** FightParticipant#movement_speed
- Apply multiplier to base movement calculation

---

### 3.9 Immobilized / Rooted
**Status:** Already Partially Supported

**Current:** StatusEffect mechanics `{ can_move: false }`

**Enhancement:** Add `effect_type: 'movement'` constant for clarity.

---

### 3.11 Grappled
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'grapple'`:
```ruby
{
  grappler_participant_id: 123,
  cannot_move_away: true,
  moves_with_grappler: true,
  grappler_slow: 0.5
}
```

**Processing Location:**
- Movement: Block movement away from grappler
- Grappler Movement: Force grappled participant to move with them
- Grappler optionally slowed to grappler_slow movement speed.
---

### 3.17 Burning
**Status:** Needs Implementation (DoT variant)

**Mapping Plan:**
Create StatusEffect `effect_type: 'damage_tick'`:
```ruby
{
  damage: "4",
  damage_type: "fire",
  spreadable: true,
  extinguish_action: true  # Can use action to remove
}
```

**Special Processing:**
- At round end, check adjacent targets for spread
- Allow action to extinguish (remove effect)
- Ignites any flamable hazard they are standing on or move onto.
---

### 3.20 Taunted
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'targeting_restriction'`:
```ruby
{
  must_target_id: 456,
  penalty_otherwise: -4  # Penalty for targeting others
}
```

**Processing Location:**
- CombatQuickmenuHandler: Highlight taunter as primary target
- Attack Resolution: Apply penalty if targeting non-taunter

---

### 3.21 Vulnerable
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'incoming_damage'`:
```ruby
{
  damage_type: "fire",
  multiplier: 2.0
}
```

**Processing Location:** CombatResolutionService damage application
- Check for vulnerability effects matching damage type, or damage type is 'all'
- Multiply damage by multiplier

---

## 4. STATUS EFFECTS - BUFFS

### 4.2 Resistance
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'incoming_damage'`:
```ruby
{
  damage_type: "fire",
  multiplier: 0.5
}
```

**Processing:** Same as vulnerability, but with <1.0 multiplier.

---

### 4.3 Immunity
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'incoming_damage'`:
```ruby
{
  damage_type: "fire",
  multiplier: 0.0
}
```

**Processing:** Same as resistance, multiplier of 0 = full immunity.

---

### 4.7 Flying
**Status:** Future Phase (Tier 5)

**Mapping Plan:**
Create StatusEffect `effect_type: 'movement'`:
```ruby
{
  flying: true,
  avoids_ground_hazards: true,
  requires_landing: false
}
```

**Processing:** Skip ground hazard checks, modify reach calculations, cannot be struck by melee attacks.

---

### 4.8 Phasing
**Status:** Future Phase (Tier 5)

**Mapping Plan:**
Create StatusEffect `effect_type: 'movement'`:
```ruby
{
  phasing: true,
  can_pass_through: ["walls", "creatures"],
  cannot_end_in: ["walls", "creatures"]
}
```

---

### 4.9 Protected (Flat Damage Reduction)
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'damage_reduction'`:
```ruby
{
  flat_reduction: 5,
  types: ["all"]  # or specific types
}
```

**Processing Location:** Damage application
- Apply flat reduction after multipliers but before shields
- Cannot reduce below 0

---

### 4.10 Evasive (Per-Hit Reduction)
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'damage_reduction'`:
```ruby
{
  per_hit_reduction: 2,
  types: ["all"]
}
```

**Processing:** Apply to each individual damage instance before summing.

---

### 4.10 Empowered (Damage Bonus)
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'outgoing_damage'`:
```ruby
{ bonus: 5 }
# OR
{ bonus_percent: 0.25 }
```

**Processing Location:** AbilityProcessorService / Attack resolution
- Add flat bonus or percentage to outgoing damage

---

## 5. DEFENSIVE MECHANICS

### 5.3 Shields
**Status:** Needs Implementation

**Mapping Plan:**
Create StatusEffect `effect_type: 'shield'`:
```ruby
{
  type:["hp", "damage"]
  amount: 2,
  types_absorbed: ["all"]  # or ["fire", "physical"]
}
```

**Track Current HP:** Use `ParticipantStatusEffect.effect_value` for current shield HP.
Either subtracts amount from incoming damage until all consumed or subtracts amount from hp lost until all consumed or ends/terminated

**Processing Location:** FightParticipant#take_damage (new flow):

---

### 5.7 Evasion (AoE Defense)
**Status:** Future Phase

**Mapping Plan:**
Create StatusEffect `effect_type: 'evasion'`:
```ruby
{ aoe_damage_reduction: 0.5 }
```

**Processing:** Apply reduction specifically to AoE damage sources.

---

### 5.9 Deflection
**Status:** Future Phase (Tier 4)

**Mapping Plan:**
Create StatusEffect `effect_type: 'deflection'`:
```ruby
{
  redirects_next_attack: true,
  redirect_target: "attacker",  # or participant_id
  consumes_on_trigger: true,
  types: ["all"]
}
```

**Processing:** Check before damage application, redirect damage to new target if incoming damage is of the appropriate type, fire, melee etc.

---

### 5.11 Block
**Status:** Future Phase (Tier 4)

**Mapping Plan:**
Create StatusEffect `effect_type: 'block'`:
```ruby
{
  blocks_next_attack: true,
  attack_types: ["melee", "ranged", "fire"],  # or "all"
  consumes_on_trigger: true
}
```

**Processing:** Check before damage application, negate damage entirely.

---

## 7. TARGETING & AREA EFFECTS

### 7.1 Single Target
**Status:** Already Supported
`Ability.aoe_shape = 'single'`

### 7.3 Area of Effect (AoE)
**Status:** Already Supported
`Ability.aoe_shape` with circle/cone/line

### 7.4 Cone
**Status:** Already Supported
`Ability.aoe_shape = 'cone'` + `aoe_angle` + `aoe_length`

### 7.5 Line
**Status:** Already Supported
`Ability.aoe_shape = 'line'` + `aoe_length`

### 7.6 Sphere / Burst
**Status:** Already Supported
`Ability.aoe_shape = 'circle'` + `aoe_radius`

---

### 7.9 Aura
**Status:** Future Phase (Tier 5)

**Mapping Plan:**
New table `auras`:
```ruby
create_table :auras do
  foreign_key :fight_participant_id  # Centered on
  foreign_key :status_effect_id      # Effect applied
  Integer :radius
  String :affects  # "allies", "enemies", "all"
end
```

**Processing:** AuraService tracks and applies effects each segment.

---

### 7.10 Wall
**Status:** Future Phase (Tier 5)

**Mapping Plan:**
New table `fight_terrain`:
```ruby
create_table :fight_terrain do
  foreign_key :fight_id
  Integer :hex_x, :hex_y
  String :terrain_type  # "wall", "hazard", "difficult"
  column :effects, :jsonb
  Integer :duration_rounds
end
```

---

### 7.11 Chain
**Status:** Needs Implementation

**Mapping Plan:**
Add `Ability.chain_config` JSONB:
```ruby
{
  max_targets: 3,
  range_per_jump: 5,
  damage_falloff: "3",  # Reduce per jump
  friendly_fire: false
}
```

**Processing Location:** AbilityProcessorService
```ruby
def process_chain_ability(ability, actor, primary_target)
  targets = [primary_target]
  current_damage = ability.roll_damage

  ability.chain_config[:max_targets].times do |i|
    next_target = find_next_chain_target(targets.last, targets, ability)
    break unless next_target

    targets << next_target
    current_damage -= DiceNotationService.roll(ability.chain_config[:damage_falloff])
    current_damage = [current_damage, 0].max

    apply_damage(next_target, current_damage)
  end
end

def find_next_chain_target(from, exclude, ability)
  @fight.active_participants
    .reject { |p| exclude.include?(p) }
    .reject { |p| ability.chain_config[:friendly_fire] == false && same_team?(from, p) }
    .select { |p| from.hex_distance_to(p) <= ability.chain_config[:range_per_jump] }
    .min_by { |p| from.hex_distance_to(p) }
end
```

---

### 7.12 Touch
**Status:** Already Supported
`Ability.requires_target = true` with range of 1 hex.

### 7.13 Self
**Status:** Already Supported
`Ability.target_type = 'self'`

---

## 8. POSITIONING & MOVEMENT

### 8.1 Push
**Status:** Needs Implementation

**Mapping Plan:**
Add `Ability.forced_movement` JSONB:
```ruby
{
  direction: "away",
  distance: 2
}
```

**Processing Location:** AbilityProcessorService (after damage)
```ruby
def process_forced_movement(target, ability, actor)
  fm = ability.forced_movement
  return unless fm

  direction = case fm[:direction]
  when "away" then direction_away_from(target, actor)
  when "toward" then direction_toward(target, actor)
  when "any" then fm[:specific_direction]
  end

  move_participant(target, direction, fm[:distance])
end
```

---

### 8.2 Pull
**Status:** Needs Implementation

**Mapping Plan:**
Same as Push with `direction: "toward"`

---

### 8.3 Slide
**Status:** Needs Implementation

**Mapping Plan:**
Same as Push/Pull with `direction: "any"` and `specific_direction: [x, y]`

---

### 8.5 Knock Prone
**Status:** Needs Implementation

**Mapping Plan:**
Add `Ability.applies_prone` boolean column.

**Processing:** After damage, apply "prone" status effect if true.

---

### 8.6 Teleport
**Status:** Future Phase

**Mapping Plan:**
Add `Ability.teleport_config` JSONB:
```ruby
{
  range: 5,
  type: "self",  # or "target"
  ignores_obstacles: true
}
```

---

### 8.7 Swap Positions
**Status:** Needs Implementation


**Mapping Plan:**
Add ability effect type for position swap.

---

### 8.9 Difficult Terrain
**Status:** Needs Implementation

**Mapping Plan:**
Alters target hexes to have difficult terrain modifier.

---

## 9. TIMING & DURATION

### 9.1 Instant
**Status:** Already Supported
Default behavior for abilities.

### 9.4 Rounds
**Status:** Already Supported
`ParticipantStatusEffect.expires_at_round`

---

### 9.5 Cleansable
**Status:** Needs Implementation

**Mapping Plan:**
Add `StatusEffect.cleansable` boolean.

**Processing:** Create "cleanse" ability type that removes cleansable effects.

---

### 9.10 Delayed Activation
**Status:** Future Phase (Tier 4)

**Mapping Plan:**
New table `delayed_effects`:
```ruby
create_table :delayed_effects do
  foreign_key :fight_id
  foreign_key :ability_id
  foreign_key :actor_participant_id
  Integer :trigger_round, :trigger_segment
  column :effect_data, :jsonb
end
```

---

### 9.11 Triggered Effect
**Status:** Future Phase (Tier 4)

**Mapping Plan:**
Add `StatusEffect.trigger_condition` JSONB:
```ruby
{
  event: "takes_fire_damage",
  effect: { type: "explosion", damage: "3d6" }
}
```

---

## 14. TERRAIN & ZONE CONTROL

### 14.1-14.8 Terrain Effects
**Status:** Needs Implementation

Create hazards or walls/obstacle either temporarily or long term.
---

## 15. SPECIAL MECHANICS

### 15.1 Execute
**Status:** Needs Implementation

**Mapping Plan:**
Add `Ability.execute_threshold` integer (HP percentage).
Add `Ability.execute_effect` JSONB:
```ruby
{
  damage_multiplier: 3.0,
  # OR
  instant_kill: true,
  threshold: 25
}
```

**Processing Location:** AbilityProcessorService
```ruby
def process_execute(target, ability)
  return unless ability.execute_threshold

  hp_percent = (target.current_hp.to_f / target.max_hp) * 100
  return unless hp_percent <= ability.execute_threshold

  if ability.execute_effect[:instant_kill]
    target.knockout!
  else
    @damage_multiplier *= ability.execute_effect[:damage_multiplier]
  end
end
```

---

### 15.4 Combo / Follow-Up
**Status:** Needs Implementation

**Mapping Plan:**
Add `Ability.combo_condition` JSONB:
```ruby
{
  requires_status: "burning",
  bonus_damage: "3",
  consumes_status: true
}
```

**Processing Location:** AbilityProcessorService
```ruby
def process_combo(target, ability)
  return unless ability.combo_condition

  condition = ability.combo_condition
  return unless target.has_status_effect?(condition[:requires_status])

  bonus = DiceNotationService.roll(condition[:bonus_dice])
  @damage += bonus

  if condition[:consumes_status]
    StatusEffectService.remove(target, condition[:requires_status])
  end
end
```

---

### 15.5 Charge-Up
**Status:** Future Phase (Tier 5)

**Mapping Plan:**
Add ability state tracking for multi-turn charging.

---

### 15.6 Channel
**Status:** Future Phase (Tier 5)

**Mapping Plan:**
Add ability state tracking with interruption conditions.

---

### 15.7 Stance / Form
**Status:** Future Phase (Tier 5)

**Mapping Plan:**
Create persistent mode system with mutual exclusivity.

---

### 15.9 Mark and Trigger
**Status:** Needs Implementation

**Mapping Plan:**
Use StatusEffect with trigger_condition (see 9.11).

---

### 15.10 Reflection
**Status:** Future Phase

**Mapping Plan:**
Create StatusEffect `effect_type: 'reflection'`:
```ruby
{
  reflects_damage_percent: 50,
  damage_types: ["physical"]
}
```

---


### 15.14 Sacrifice
**Status:** Needs Implementation

**Mapping Plan:**
Add `Ability.sacrifice_config` JSONB:
```ruby
{
  hp_cost: 10,
  # OR
  hp_cost_percent: 25
}
```

---

## Summary: Implementation Priority

### Immediate (Tier 2 + 3 - Your Selection)

**Status Effects to Create:**
1. burning (damage_tick)
2. poisoned (damage_tick)
3. bleeding (damage_tick)
4. regenerating (healing_tick)
5. slowed (movement)
6. immobilized (movement)
7. prone (movement)
8. dazed (action_restriction)
9. stunned (action_restriction)
10. taunted (targeting_restriction)
11. frightened (fear)
12. shielded (shield)
13. protected (damage_reduction)
14. empowered (outgoing_damage)
15. vulnerable_fire (incoming_damage)
16. resistant_fire (incoming_damage)
17. immune_fire (incoming_damage)

**Ability Columns to Add:**
1. conditional_damage (JSONB)
2. damage_types (JSONB)
3. bypasses_resistances (boolean)
4. lifesteal_percent (integer)
5. chain_config (JSONB)
6. forced_movement (JSONB)
7. applies_prone (boolean)
8. execute_threshold (integer)
9. execute_effect (JSONB)
10. combo_condition (JSONB)

**Services to Modify:**
1. StatusEffectService - New effect type processing
2. AbilityProcessorService - New ability mechanics
3. CombatResolutionService - Tick scheduling, damage flow
4. FightParticipant - Shield absorption, damage modifiers
