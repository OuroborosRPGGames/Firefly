/// Segment timeline for scheduling combat events across a 100-segment round.
///
/// Each combat round is divided into 100 segments. Actions (movement, attacks,
/// abilities, DOT ticks, etc.) are scheduled at specific segments and then
/// resolved in order. This allows interleaving of different participants'
/// actions based on timing (e.g., long weapons strike first, movement is
/// distributed across the round).

/// Sort priority for events within the same segment.
///
/// Ruby sorts each segment so movement resolves before attacks, with
/// retreat/maintain movement before approach movement. This enum encodes
/// that ordering (lower = higher priority).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum EventPriority {
    /// Retreat, maintain distance, move-to-hex, flee — resolves first.
    MovementRetreat = 0,
    /// Towards person — resolves after retreat but before non-movement.
    MovementApproach = 1,
    /// Attacks, abilities, DOTs, stand-up, etc. — resolves last.
    NonMovement = 2,
}

/// Intent behind a movement event: determines whether the destination is
/// recalculated dynamically from live positions during segment processing.
#[derive(Debug, Clone)]
pub enum MovementIntent {
    /// Fixed destination (flee path, move-to-hex). Use stored coordinates.
    Fixed,
    /// Dynamically recalculate each step toward target's current position.
    TowardsPerson(u64),
    /// Dynamically recalculate each step away from target's current position.
    AwayFrom(u64),
}

/// A single scheduled event within the segment timeline.
#[derive(Debug, Clone)]
pub struct SegmentEvent {
    /// Segment number (1-100) when this event occurs.
    pub segment: u32,
    /// The participant performing or receiving this event.
    pub participant_id: u64,
    /// What kind of event this is.
    pub event_type: SegmentEventType,
    /// Sort priority within the same segment (movement before attacks).
    pub priority: EventPriority,
}

/// The different kinds of events that can be scheduled.
#[derive(Debug, Clone)]
pub enum SegmentEventType {
    /// Move to target hex (x, y) with intent for dynamic recalculation.
    Movement {
        target_x: i32,
        target_y: i32,
        intent: MovementIntent,
    },
    /// Attack a target participant.
    Attack(u64),
    /// Attack a large-monster segment (player-vs-monster).
    /// attacker = event.participant_id.
    AttackMonster {
        monster_id: u64,
        segment_id: u64,
    },
    /// Use an ability, optionally targeting a participant.
    AbilityUse {
        ability_id: u64,
        target_id: Option<u64>,
    },
    /// Damage-over-time tick from a status effect.
    DotTick {
        effect_name: String,
        damage: i32,
    },
    /// Monster scheduled attack segment.
    MonsterAttack {
        segment_id: u64,
        target_id: u64,
    },
    /// Monster scheduled shake-off attempt. Dispatches `process_monster_shake_off`
    /// at the segment chosen by `schedule_monster_attacks_targeted` when
    /// `should_shake_off(&monster, &threats)` is true.
    MonsterShakeOff {
        monster_id: u64,
    },
    /// Element tactic (break / detonate / ignite). Scheduled at segment
    /// `config.segments.tactical_fallback` (= 20, matching Ruby
    /// `combat_resolution_service.rb:662-667`) when a participant's
    /// `TacticChoice` is `Break`, `Detonate`, or `Ignite`. Dispatched by
    /// `process_element_tactic_event` which routes to break/detonate/ignite
    /// handlers in `interactive_objects.rs`.
    ElementTactic {
        /// "break" | "detonate" | "ignite" — the tactic kind.
        tactic_type: String,
        /// Target BattleMapElement id (break/detonate). None for ignite.
        element_id: Option<u64>,
        /// Target hex coordinates (ignite, and window-break). None for
        /// BattleMapElement-based tactics.
        target_x: Option<i32>,
        target_y: Option<i32>,
    },
    /// Stand up from prone.
    StandUp,
    /// Participant is dangling off a ledge — scheduled from build_timeline instead of
    /// normal actions. Processing moves participant to `climb_back_x/y` and removes
    /// the 'dangling' status effect.
    DanglingClimbBack,
    /// Wall flip landing at position (x, y).
    WallFlip(i32, i32),
}

/// Timeline that collects and orders all events for a combat round.
pub struct SegmentTimeline {
    events: Vec<SegmentEvent>,
}

impl SegmentTimeline {
    pub fn new() -> Self {
        Self {
            events: Vec::new(),
        }
    }

    /// Schedule an event at a specific segment for a participant.
    pub fn schedule(
        &mut self,
        segment: u32,
        participant_id: u64,
        event_type: SegmentEventType,
        priority: EventPriority,
    ) {
        self.events.push(SegmentEvent {
            segment,
            participant_id,
            event_type,
            priority,
        });
    }

    /// Get all events sorted by segment number, then priority within segment.
    ///
    /// Within the same segment, movement resolves before attacks (matching Ruby's
    /// `segment_event_sort_key`), and retreat movement before approach movement.
    pub fn events_in_order(&self) -> Vec<&SegmentEvent> {
        let mut sorted: Vec<_> = self.events.iter().collect();
        sorted.sort_by_key(|e| (e.segment, e.priority));
        sorted
    }

    /// Number of scheduled events.
    pub fn len(&self) -> usize {
        self.events.len()
    }

    /// Whether the timeline has no events.
    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }
}

impl Default for SegmentTimeline {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn movement_approach(x: i32, y: i32) -> SegmentEventType {
        SegmentEventType::Movement {
            target_x: x,
            target_y: y,
            intent: MovementIntent::Fixed,
        }
    }

    #[test]
    fn test_new_timeline_is_empty() {
        let tl = SegmentTimeline::new();
        assert!(tl.is_empty());
        assert_eq!(tl.len(), 0);
    }

    #[test]
    fn test_schedule_adds_event() {
        let mut tl = SegmentTimeline::new();
        tl.schedule(50, 1, SegmentEventType::Attack(2), EventPriority::NonMovement);
        assert_eq!(tl.len(), 1);
        assert!(!tl.is_empty());
    }

    #[test]
    fn test_events_in_order_sorted_by_segment() {
        let mut tl = SegmentTimeline::new();
        tl.schedule(75, 1, SegmentEventType::Attack(2), EventPriority::NonMovement);
        tl.schedule(25, 2, SegmentEventType::Attack(1), EventPriority::NonMovement);
        tl.schedule(50, 1, movement_approach(2, 4), EventPriority::MovementApproach);
        let ordered = tl.events_in_order();
        assert_eq!(ordered.len(), 3);
        assert_eq!(ordered[0].segment, 25);
        assert_eq!(ordered[1].segment, 50);
        assert_eq!(ordered[2].segment, 75);
    }

    #[test]
    fn test_movement_before_attacks_at_same_segment() {
        let mut tl = SegmentTimeline::new();
        // Insert attack first, then movement — movement should sort before attack
        tl.schedule(50, 2, SegmentEventType::Attack(1), EventPriority::NonMovement);
        tl.schedule(50, 1, movement_approach(2, 4), EventPriority::MovementApproach);
        let ordered = tl.events_in_order();
        assert_eq!(ordered[0].participant_id, 1); // movement first
        assert_eq!(ordered[1].participant_id, 2); // attack second
    }

    #[test]
    fn test_retreat_before_approach_at_same_segment() {
        let mut tl = SegmentTimeline::new();
        // Insert approach first, then retreat — retreat should sort before approach
        tl.schedule(50, 1, movement_approach(4, 4), EventPriority::MovementApproach);
        tl.schedule(50, 2, movement_approach(0, 0), EventPriority::MovementRetreat);
        let ordered = tl.events_in_order();
        assert_eq!(ordered[0].participant_id, 2); // retreat first
        assert_eq!(ordered[1].participant_id, 1); // approach second
    }

    #[test]
    fn test_full_priority_ordering_within_segment() {
        let mut tl = SegmentTimeline::new();
        // Insert in reverse priority order
        tl.schedule(50, 3, SegmentEventType::StandUp, EventPriority::NonMovement);
        tl.schedule(50, 2, movement_approach(2, 4), EventPriority::MovementApproach);
        tl.schedule(50, 1, movement_approach(0, 0), EventPriority::MovementRetreat);
        let ordered = tl.events_in_order();
        assert_eq!(ordered[0].participant_id, 1); // retreat movement
        assert_eq!(ordered[1].participant_id, 2); // approach movement
        assert_eq!(ordered[2].participant_id, 3); // non-movement
    }

    #[test]
    fn test_schedule_all_event_types() {
        let mut tl = SegmentTimeline::new();
        tl.schedule(10, 1, movement_approach(0, 2), EventPriority::MovementApproach);
        tl.schedule(20, 1, SegmentEventType::Attack(2), EventPriority::NonMovement);
        tl.schedule(
            30,
            1,
            SegmentEventType::AbilityUse {
                ability_id: 5,
                target_id: Some(2),
            },
            EventPriority::NonMovement,
        );
        tl.schedule(
            40,
            2,
            SegmentEventType::DotTick {
                effect_name: "poison".to_string(),
                damage: 3,
            },
            EventPriority::NonMovement,
        );
        tl.schedule(
            50,
            3,
            SegmentEventType::MonsterAttack {
                segment_id: 1,
                target_id: 1,
            },
            EventPriority::NonMovement,
        );
        tl.schedule(60, 1, SegmentEventType::StandUp, EventPriority::NonMovement);
        tl.schedule(70, 1, SegmentEventType::WallFlip(4, 6), EventPriority::NonMovement);
        assert_eq!(tl.len(), 7);
    }

    #[test]
    fn test_default_timeline() {
        let tl = SegmentTimeline::default();
        assert!(tl.is_empty());
    }
}
