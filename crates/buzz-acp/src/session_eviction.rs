//! When a live ACP session should be closed, and by which rule.
//!
//! Thread-scoped sessions turn "one session per channel" into "one session per
//! thread ever touched", which is only affordable if idle ones are reclaimed:
//! what a live session costs is set by the adapter, from a whole CLI process
//! down to a map entry. This module owns the policy and the selection; the pool
//! owns the wire calls and the state they mutate.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::pool::CLAUDE_AGENT_ACP_NAME;
use crate::scope::SessionScope;

/// Whether the adapter advertised `session/close` at `initialize`.
///
/// Capability-gated rather than probed: an adapter that does not implement the
/// method answers `-32601`, and treating that as "closed" would drop local
/// state while the remote session stays alive forever.
pub(crate) fn advertises_session_close(init_result: &serde_json::Value) -> bool {
    init_result
        .pointer("/agentCapabilities/sessionCapabilities/close")
        .is_some()
}

/// How aggressively one agent's sessions are reclaimed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SessionEvictionPolicy {
    /// Idle time after which a session is closed. Zero disables idle eviction.
    pub idle_ttl: Duration,
    /// Maximum sessions one agent may hold. Zero means unbounded.
    pub max_live_sessions: usize,
}

impl SessionEvictionPolicy {
    /// `claude-agent-acp` spawns a CLI process per session, so its sessions are
    /// the expensive ones and are evicted hard.
    const CLAUDE: Self = Self {
        idle_ttl: Duration::from_secs(10 * 60),
        max_live_sessions: 3,
    };
    /// `codex-acp` shares one core process across sessions; what still costs per
    /// session is the MCP servers it spawns.
    const CODEX: Self = Self {
        idle_ttl: Duration::from_secs(30 * 60),
        max_live_sessions: 12,
    };
    /// Adapters that keep sessions in-process pay little per session, so here
    /// eviction is hygiene — bounded state, real session boundaries — rather
    /// than survival.
    const IN_PROCESS: Self = Self {
        idle_ttl: Duration::from_secs(2 * 60 * 60),
        max_live_sessions: 64,
    };

    /// The default for a harness, with operator overrides applied.
    ///
    /// `None` keeps the harness default; `Some(0)` disables that one limit.
    pub(crate) fn resolve(
        agent_name: &str,
        idle_ttl_secs: Option<u64>,
        max_live_sessions: Option<usize>,
    ) -> Self {
        let mut policy = if agent_name == CLAUDE_AGENT_ACP_NAME {
            Self::CLAUDE
        } else if agent_name.contains("codex") {
            Self::CODEX
        } else {
            Self::IN_PROCESS
        };
        if let Some(secs) = idle_ttl_secs {
            policy.idle_ttl = Duration::from_secs(secs);
        }
        if let Some(max) = max_live_sessions {
            policy.max_live_sessions = max;
        }
        policy
    }
}

/// Sessions that should be closed now, oldest-idle first.
///
/// Two independent reasons, unioned: idle past `idle_ttl`, and — once the agent
/// holds more than `max_live_sessions` — the least recently used ones beyond the
/// cap. The cap is what covers a burst of conversations arriving faster than the
/// TTL can retire them.
///
/// Returns `(scope, session_id)` so the caller can close on the wire before
/// dropping local state.
pub(crate) fn evictable(
    sessions: &HashMap<SessionScope, String>,
    last_active: &HashMap<SessionScope, Instant>,
    policy: &SessionEvictionPolicy,
    now: Instant,
) -> Vec<(SessionScope, String)> {
    // Oldest idle first, so both rules and the caller agree on priority.
    // `None` (no activity record) sorts ahead of every timestamp: a bookkeeping
    // gap must not create an immortal session.
    let mut ranked: Vec<(&SessionScope, Option<Instant>)> = sessions
        .keys()
        .map(|scope| (scope, last_active.get(scope).copied()))
        .collect();
    ranked.sort_by(|(left_scope, left), (right_scope, right)| {
        left.cmp(right).then_with(|| {
            // Ties are broken deterministically so a sweep cannot depend on
            // HashMap iteration order.
            left_scope
                .telemetry_label()
                .cmp(&right_scope.telemetry_label())
        })
    });

    let over_cap = if policy.max_live_sessions == 0 {
        0
    } else {
        ranked.len().saturating_sub(policy.max_live_sessions)
    };

    ranked
        .iter()
        .enumerate()
        .filter(|(rank, (_, last))| {
            let idle_expired = !policy.idle_ttl.is_zero()
                && match last {
                    None => true,
                    Some(last) => now.saturating_duration_since(*last) >= policy.idle_ttl,
                };
            idle_expired || *rank < over_cap
        })
        .filter_map(|(_, (scope, _))| {
            sessions
                .get(*scope)
                .map(|session_id| ((*scope).clone(), session_id.clone()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn scope(n: u8) -> SessionScope {
        SessionScope::Thread {
            channel_id: Uuid::from_u128(1),
            root_event_id: format!("{n:064x}"),
        }
    }

    fn state(
        entries: &[(SessionScope, Option<Instant>)],
    ) -> (
        HashMap<SessionScope, String>,
        HashMap<SessionScope, Instant>,
    ) {
        let mut sessions = HashMap::new();
        let mut last_active = HashMap::new();
        for (index, (scope, last)) in entries.iter().enumerate() {
            sessions.insert(scope.clone(), format!("ses-{index}"));
            if let Some(last) = last {
                last_active.insert(scope.clone(), *last);
            }
        }
        (sessions, last_active)
    }

    #[test]
    fn selects_only_sessions_idle_past_the_ttl() {
        let now = Instant::now();
        let (sessions, last_active) = state(&[
            (scope(1), Some(now - Duration::from_secs(11 * 60))),
            (scope(2), Some(now - Duration::from_secs(60))),
        ]);
        let policy = SessionEvictionPolicy::resolve(CLAUDE_AGENT_ACP_NAME, None, None);

        let victims = evictable(&sessions, &last_active, &policy, now);
        assert_eq!(victims.len(), 1, "got {victims:?}");
        assert_eq!(victims[0].0, scope(1));
    }

    #[test]
    fn trims_least_recently_used_beyond_the_cap_even_when_fresh() {
        let now = Instant::now();
        // Four sessions, all active seconds ago: the TTL alone would keep every
        // one of them, which is exactly the burst the cap exists to bound.
        let (sessions, last_active) = state(&[
            (scope(1), Some(now - Duration::from_secs(40))),
            (scope(2), Some(now - Duration::from_secs(30))),
            (scope(3), Some(now - Duration::from_secs(20))),
            (scope(4), Some(now - Duration::from_secs(10))),
        ]);
        let policy = SessionEvictionPolicy::resolve(CLAUDE_AGENT_ACP_NAME, None, None);

        let victims = evictable(&sessions, &last_active, &policy, now);
        assert_eq!(victims.len(), 1, "cap is 3 of 4: {victims:?}");
        assert_eq!(victims[0].0, scope(1), "the least recently used one goes");
    }

    #[test]
    fn a_session_with_no_activity_record_is_reclaimable() {
        let now = Instant::now();
        let (sessions, last_active) = state(&[
            (scope(1), None),
            (scope(2), Some(now - Duration::from_secs(5))),
        ]);
        let policy = SessionEvictionPolicy::resolve("goose", Some(600), None);

        let victims = evictable(&sessions, &last_active, &policy, now);
        assert_eq!(victims.len(), 1);
        assert_eq!(
            victims[0].0,
            scope(1),
            "a bookkeeping gap must not create an immortal session"
        );
    }

    #[test]
    fn zero_disables_each_limit_independently() {
        let now = Instant::now();
        let (sessions, last_active) = state(&[
            (scope(1), Some(now - Duration::from_secs(10 * 3600))),
            (scope(2), Some(now - Duration::from_secs(10 * 3600))),
        ]);

        let no_ttl = SessionEvictionPolicy::resolve(CLAUDE_AGENT_ACP_NAME, Some(0), None);
        assert!(
            evictable(&sessions, &last_active, &no_ttl, now).is_empty(),
            "ttl=0 disables idle eviction; the cap of 3 is not reached by 2"
        );

        let no_cap = SessionEvictionPolicy::resolve(CLAUDE_AGENT_ACP_NAME, Some(0), Some(0));
        assert!(
            evictable(&sessions, &last_active, &no_cap, now).is_empty(),
            "both limits disabled evicts nothing"
        );

        let cap_only = SessionEvictionPolicy::resolve(CLAUDE_AGENT_ACP_NAME, Some(0), Some(1));
        assert_eq!(
            evictable(&sessions, &last_active, &cap_only, now).len(),
            1,
            "the cap still applies with the TTL disabled"
        );
    }

    #[test]
    fn defaults_follow_the_harness_and_overrides_replace_them() {
        assert_eq!(
            SessionEvictionPolicy::resolve(CLAUDE_AGENT_ACP_NAME, None, None),
            SessionEvictionPolicy::CLAUDE
        );
        assert_eq!(
            SessionEvictionPolicy::resolve("codex-acp", None, None),
            SessionEvictionPolicy::CODEX
        );
        for in_process in ["goose", "opencode", "buzz-agent", ""] {
            assert_eq!(
                SessionEvictionPolicy::resolve(in_process, None, None),
                SessionEvictionPolicy::IN_PROCESS,
                "{in_process} keeps sessions in process"
            );
        }
        assert_eq!(
            SessionEvictionPolicy::resolve(CLAUDE_AGENT_ACP_NAME, Some(42), Some(7)),
            SessionEvictionPolicy {
                idle_ttl: Duration::from_secs(42),
                max_live_sessions: 7,
            }
        );
    }

    #[test]
    fn session_close_support_is_read_from_the_advertised_capability() {
        assert!(advertises_session_close(&serde_json::json!({
            "agentCapabilities": { "sessionCapabilities": { "close": true } }
        })));
        // Present-but-false still means the adapter knows the method; the pool
        // only needs to know the request will not come back as -32601.
        assert!(advertises_session_close(&serde_json::json!({
            "agentCapabilities": { "sessionCapabilities": { "close": false } }
        })));
        assert!(!advertises_session_close(&serde_json::json!({
            "agentCapabilities": { "sessionCapabilities": {} }
        })));
        assert!(!advertises_session_close(&serde_json::json!({
            "agentCapabilities": {}
        })));
        assert!(!advertises_session_close(&serde_json::json!({})));
    }
}
