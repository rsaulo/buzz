//! What happens to a message delivered mid-turn, after the turn ends.
//!
//! A steer hands a message to a turn that is already running. The adapter
//! acknowledging it proves the message was *delivered*, not that it was
//! *answered* — the turn is free to finish without saying anything, and when it
//! does the message is gone: it was taken out of the queue on the ack, and no
//! reply ever went out. The user sees an agent that read their message and
//! ignored it, with nothing in the logs.
//!
//! So a delivered steer is not discarded at ack time. It is held here until the
//! turn that received it ends, and only then judged.
//!
//! ## What counts as an answer
//!
//! Only one of our own messages coming back off the relay. A managed agent
//! replies by shelling out to `buzz messages send`, so at the ACP layer
//! "answered the steer" and "kept working and ignored it" are the same
//! completed tool call — adapter activity cannot tell them apart, and reading it
//! as an answer is exactly how a message gets dropped silently.
//!
//! A threaded reply credits its own thread *and* the channel's ambient
//! conversation: an ambient mention is answered by opening a thread rooted at
//! it, so crediting only the thread would leave the ambient session looking
//! unanswered and requeue a message that was in fact replied to. It never
//! credits a sibling thread.

use std::collections::HashMap;

use crate::queue::QueuedEvent;
use crate::scope::SessionScope;

/// A steer the adapter accepted, awaiting the verdict of its own turn.
#[derive(Debug)]
struct DeliveredSteer {
    /// Kept whole so an owed message can go back to the queue unchanged,
    /// original `received_at` included.
    event: QueuedEvent,
    /// The turn that accepted it. A turn only settles its own deliveries.
    turn_id: String,
    /// How many messages we had published to this scope when it was delivered.
    /// The turn answered it only if that count moved afterwards.
    published_at_delivery: u64,
}

/// What the end of a turn decided about one delivered steer.
#[derive(Debug)]
pub(crate) enum SteerVerdict {
    /// A message went out after delivery. Nothing to do.
    Answered { event_id: String },
    /// The turn ended without publishing anything. The event goes back to the
    /// queue so ordinary dispatch delivers it to the next turn.
    Owed(Box<QueuedEvent>),
}

/// Delivered-but-unsettled steers, and the published-message counters that
/// decide them.
#[derive(Debug, Default)]
pub(crate) struct SteerLedger {
    pending: HashMap<SessionScope, Vec<DeliveredSteer>>,
    /// Messages we published per scope. Only tracked while a scope has
    /// something to settle, so the map cannot grow with every channel the
    /// agent has ever spoken in.
    published: HashMap<SessionScope, u64>,
}

impl SteerLedger {
    /// Hold `event` until `turn_id` ends.
    pub(crate) fn record_delivered(
        &mut self,
        scope: &SessionScope,
        event: QueuedEvent,
        turn_id: &str,
    ) {
        let published_at_delivery = self.published_epoch(scope);
        self.pending
            .entry(scope.clone())
            .or_default()
            .push(DeliveredSteer {
                event,
                turn_id: turn_id.to_string(),
                published_at_delivery,
            });
    }

    /// Count one of our own messages published to `scope`.
    ///
    /// Ignored when the scope has nothing pending: the counter exists to settle
    /// deliveries, and keeping one for every scope ever spoken in would make
    /// this map grow without bound.
    pub(crate) fn note_published(&mut self, scope: &SessionScope) {
        if !self.pending.contains_key(scope) {
            return;
        }
        *self.published.entry(scope.clone()).or_default() += 1;
    }

    pub(crate) fn published_epoch(&self, scope: &SessionScope) -> u64 {
        self.published.get(scope).copied().unwrap_or_default()
    }

    /// Whether `scope` is holding anything at all.
    #[cfg(test)]
    pub(crate) fn has_pending(&self, scope: &SessionScope) -> bool {
        self.pending.contains_key(scope)
    }

    /// Decide every steer `turn_id` accepted on `scope`.
    ///
    /// Deliveries belonging to other turns stay pending: a sibling turn's
    /// silence says nothing about them.
    pub(crate) fn settle_turn(&mut self, scope: &SessionScope, turn_id: &str) -> Vec<SteerVerdict> {
        let Some(entries) = self.pending.get_mut(scope) else {
            return Vec::new();
        };
        let published_now = self.published.get(scope).copied().unwrap_or_default();

        let mut verdicts = Vec::new();
        let mut retained = Vec::with_capacity(entries.len());
        for entry in entries.drain(..) {
            if entry.turn_id != turn_id {
                retained.push(entry);
                continue;
            }
            if published_now > entry.published_at_delivery {
                verdicts.push(SteerVerdict::Answered {
                    event_id: entry.event.event.id.to_hex(),
                });
            } else {
                verdicts.push(SteerVerdict::Owed(Box::new(entry.event)));
            }
        }

        if retained.is_empty() {
            self.pending.remove(scope);
            // Nothing left to settle here, so the counter has no reader. Drop it
            // rather than let it accumulate for the life of the process.
            self.published.remove(scope);
        } else {
            *entries = retained;
        }
        verdicts
    }

    /// Release everything held for `scope`, whatever turn it belongs to.
    ///
    /// For the paths that end every turn at once — the agent process died, the
    /// channel was left. Nothing can answer these now, so they are all owed.
    pub(crate) fn drain_scope(&mut self, scope: &SessionScope) -> Vec<QueuedEvent> {
        self.published.remove(scope);
        self.pending
            .remove(scope)
            .map(|entries| entries.into_iter().map(|entry| entry.event).collect())
            .unwrap_or_default()
    }

    /// Every scope currently holding something, for channel-wide teardown.
    pub(crate) fn pending_scopes(&self) -> Vec<SessionScope> {
        self.pending.keys().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Kind};
    use uuid::Uuid;

    fn conv(channel_id: Uuid) -> SessionScope {
        SessionScope::Conversation { channel_id }
    }

    fn thread(channel_id: Uuid, root: &str) -> SessionScope {
        SessionScope::Thread {
            channel_id,
            root_event_id: root.to_string(),
        }
    }

    fn queued_in(scope: &SessionScope, content: &str) -> QueuedEvent {
        QueuedEvent {
            channel_id: scope.channel_id(),
            scope: scope.clone(),
            event: EventBuilder::new(Kind::Custom(9), content)
                .sign_with_keys(&Keys::generate())
                .expect("sign test event"),
            received_at: std::time::Instant::now(),
            prompt_tag: "test".into(),
            edit: None,
        }
    }

    fn owed_contents(verdicts: &[SteerVerdict]) -> Vec<String> {
        verdicts
            .iter()
            .filter_map(|verdict| match verdict {
                SteerVerdict::Owed(event) => Some(event.event.content.clone()),
                SteerVerdict::Answered { .. } => None,
            })
            .collect()
    }

    /// The 2026-08-13 incident: the turn accepted the steer, kept calling tools,
    /// published nothing, and ended. Adapter activity had advanced, and reading
    /// that as an answer is what dropped the user's message.
    #[test]
    fn a_turn_that_ends_without_publishing_owes_the_message() {
        let channel_id = Uuid::new_v4();
        let scope = conv(channel_id);
        let mut ledger = SteerLedger::default();
        ledger.record_delivered(&scope, queued_in(&scope, "steered mention"), "turn-1");

        let verdicts = ledger.settle_turn(&scope, "turn-1");

        assert_eq!(owed_contents(&verdicts), vec!["steered mention"]);
        assert!(!ledger.has_pending(&scope), "settling clears the scope");
    }

    #[test]
    fn a_turn_that_publishes_after_delivery_settles_the_message() {
        let channel_id = Uuid::new_v4();
        let scope = conv(channel_id);
        let mut ledger = SteerLedger::default();
        ledger.record_delivered(&scope, queued_in(&scope, "steered mention"), "turn-1");
        ledger.note_published(&scope);

        let verdicts = ledger.settle_turn(&scope, "turn-1");

        assert!(owed_contents(&verdicts).is_empty());
        assert!(matches!(
            verdicts.as_slice(),
            [SteerVerdict::Answered { .. }]
        ));
    }

    /// A message published *before* the steer was delivered cannot settle it —
    /// it answered whatever came earlier in the turn.
    #[test]
    fn a_message_published_before_delivery_does_not_settle_it() {
        let channel_id = Uuid::new_v4();
        let scope = conv(channel_id);
        let mut ledger = SteerLedger::default();
        ledger.record_delivered(&scope, queued_in(&scope, "first"), "turn-1");
        ledger.note_published(&scope);
        ledger.record_delivered(&scope, queued_in(&scope, "second"), "turn-1");

        let verdicts = ledger.settle_turn(&scope, "turn-1");

        assert_eq!(
            owed_contents(&verdicts),
            vec!["second"],
            "only the delivery that predates the publish is answered"
        );
    }

    #[test]
    fn a_turn_settles_only_its_own_deliveries() {
        let channel_id = Uuid::new_v4();
        let scope = conv(channel_id);
        let mut ledger = SteerLedger::default();
        ledger.record_delivered(&scope, queued_in(&scope, "for turn-1"), "turn-1");
        ledger.record_delivered(&scope, queued_in(&scope, "for turn-2"), "turn-2");

        let verdicts = ledger.settle_turn(&scope, "turn-1");

        assert_eq!(owed_contents(&verdicts), vec!["for turn-1"]);
        assert!(
            ledger.has_pending(&scope),
            "turn-2's delivery is still awaiting its own turn"
        );
    }

    /// Sibling threads are independent conversations: one answering says nothing
    /// about the other, and must not settle its messages.
    #[test]
    fn a_sibling_thread_publishing_does_not_settle_this_one() {
        let channel_id = Uuid::new_v4();
        let mine = thread(channel_id, &"a".repeat(64));
        let sibling = thread(channel_id, &"b".repeat(64));
        let mut ledger = SteerLedger::default();
        ledger.record_delivered(&mine, queued_in(&mine, "mine"), "turn-1");
        ledger.record_delivered(&sibling, queued_in(&sibling, "sibling"), "turn-1");

        ledger.note_published(&sibling);

        assert_eq!(
            owed_contents(&ledger.settle_turn(&mine, "turn-1")),
            vec!["mine"],
            "the sibling's reply is not mine"
        );
        assert!(owed_contents(&ledger.settle_turn(&sibling, "turn-1")).is_empty());
    }

    /// The counter only exists to settle deliveries; without one it must not be
    /// created, or the map grows with every channel the agent speaks in.
    #[test]
    fn publishing_into_a_scope_with_nothing_pending_is_not_tracked() {
        let channel_id = Uuid::new_v4();
        let scope = conv(channel_id);
        let mut ledger = SteerLedger::default();

        ledger.note_published(&scope);
        assert_eq!(ledger.published_epoch(&scope), 0);

        // And a delivery recorded afterwards starts from zero, so the earlier
        // publish cannot retroactively settle it.
        ledger.record_delivered(&scope, queued_in(&scope, "later"), "turn-1");
        assert_eq!(
            owed_contents(&ledger.settle_turn(&scope, "turn-1")),
            vec!["later"]
        );
    }

    #[test]
    fn settling_the_last_delivery_drops_the_counter() {
        let channel_id = Uuid::new_v4();
        let scope = conv(channel_id);
        let mut ledger = SteerLedger::default();
        ledger.record_delivered(&scope, queued_in(&scope, "one"), "turn-1");
        ledger.note_published(&scope);
        assert_eq!(ledger.published_epoch(&scope), 1);

        let _ = ledger.settle_turn(&scope, "turn-1");

        assert_eq!(
            ledger.published_epoch(&scope),
            0,
            "a counter with no pending delivery has no reader"
        );
    }

    #[test]
    fn draining_a_scope_owes_everything_it_held() {
        let channel_id = Uuid::new_v4();
        let scope = conv(channel_id);
        let mut ledger = SteerLedger::default();
        ledger.record_delivered(&scope, queued_in(&scope, "one"), "turn-1");
        ledger.record_delivered(&scope, queued_in(&scope, "two"), "turn-2");

        let drained: Vec<String> = ledger
            .drain_scope(&scope)
            .into_iter()
            .map(|event| event.event.content)
            .collect();

        assert_eq!(drained, vec!["one", "two"]);
        assert!(!ledger.has_pending(&scope));
        assert!(ledger.pending_scopes().is_empty());
    }

    #[test]
    fn settling_an_unknown_turn_or_scope_changes_nothing() {
        let channel_id = Uuid::new_v4();
        let scope = conv(channel_id);
        let mut ledger = SteerLedger::default();
        assert!(ledger.settle_turn(&scope, "turn-1").is_empty());

        ledger.record_delivered(&scope, queued_in(&scope, "one"), "turn-1");
        assert!(ledger.settle_turn(&scope, "other-turn").is_empty());
        assert!(
            ledger.has_pending(&scope),
            "an unrelated turn must not consume the delivery"
        );
    }
}
