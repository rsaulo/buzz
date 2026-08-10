//! Relay-backed classification of Buzz project channels.
//!
//! NIP-01 filters only expose single-letter generic tags (`#e`, `#p`, `#d`,
//! and so on), and the relay's request path consumes that same
//! `SingleLetterTag` map. `buzz-channel` is therefore not filterable without a
//! private protocol extension. Projects are intentionally few, so we query the
//! live kind:30621 heads and scan their `buzz-channel` tags client-side.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use buzz_core::kind::KIND_PROJECT;
use nostr::Event;
use serde_json::Value;
use uuid::Uuid;

use crate::relay::RestClient;

/// A minute keeps the relay off the per-turn path while bounding the interval
/// in which a newly-created project could still be treated as ad-hoc.
pub(crate) const PROJECT_CHANNEL_CACHE_TTL: Duration = Duration::from_secs(60);

/// Session policy input derived from the project query.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ProjectChannelSignal {
    Project,
    NotProject,
    /// No positive project/non-project fact is available, but this is not a
    /// transport failure eligible for fail-open behavior.
    #[allow(dead_code)]
    // Production transport returns a fact or FailOpen; policy tests inject this.
    Indeterminate,
    /// Transport, timeout, and malformed-response failures are deliberately
    /// distinct from confirmed absence so callers can fail open.
    FailOpen(String),
}

type QueryFuture<'a> = Pin<Box<dyn Future<Output = Result<Value, String>> + Send + 'a>>;

trait ProjectQueryTransport: Send + Sync {
    fn fetch_projects(&self) -> QueryFuture<'_>;
}

#[derive(Debug)]
struct RestProjectQuery {
    rest: RestClient,
}

impl ProjectQueryTransport for RestProjectQuery {
    fn fetch_projects(&self) -> QueryFuture<'_> {
        Box::pin(async move {
            // No `#buzz-channel` filter: nostr::Filter only models single-letter
            // generic tags, as does buzz-relay's filter execution path.
            let filter = nostr::Filter::new().kind(nostr::Kind::Custom(KIND_PROJECT as u16));
            self.rest
                .query(&[filter])
                .await
                .map_err(|error| format!("project query failed: {error}"))
        })
    }
}

#[derive(Debug, Clone)]
struct CachedSignal {
    cached_at: Instant,
    signal: ProjectChannelSignal,
}

/// Per-channel TTL cache around the relay project signal.
pub(crate) struct ProjectChannelResolver {
    transport: Arc<dyn ProjectQueryTransport>,
    cache: Mutex<HashMap<Uuid, CachedSignal>>,
    ttl: Duration,
    timeout: Duration,
    clock: Arc<dyn Fn() -> Instant + Send + Sync>,
}

impl std::fmt::Debug for ProjectChannelResolver {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ProjectChannelResolver")
            .field("ttl", &self.ttl)
            .field("timeout", &self.timeout)
            .finish_non_exhaustive()
    }
}

impl ProjectChannelResolver {
    pub(crate) fn new(rest: RestClient) -> Self {
        Self::with_components(
            Arc::new(RestProjectQuery { rest }),
            PROJECT_CHANNEL_CACHE_TTL,
            Duration::from_secs(2),
            Instant::now,
        )
    }

    fn with_components(
        transport: Arc<dyn ProjectQueryTransport>,
        ttl: Duration,
        timeout: Duration,
        clock: impl Fn() -> Instant + Send + Sync + 'static,
    ) -> Self {
        Self {
            transport,
            cache: Mutex::new(HashMap::new()),
            ttl,
            timeout,
            clock: Arc::new(clock),
        }
    }

    pub(crate) async fn classify(&self, channel_id: Uuid) -> ProjectChannelSignal {
        let now = (self.clock)();
        if let Some(cached) = self
            .cache
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .get(&channel_id)
            .filter(|cached| now.saturating_duration_since(cached.cached_at) < self.ttl)
            .cloned()
        {
            return cached.signal;
        }

        let signal =
            match tokio::time::timeout(self.timeout, self.transport.fetch_projects()).await {
                Ok(Ok(value)) => classify_response(&value, channel_id)
                    .unwrap_or_else(ProjectChannelSignal::FailOpen),
                Ok(Err(reason)) => ProjectChannelSignal::FailOpen(reason),
                Err(_) => ProjectChannelSignal::FailOpen(format!(
                    "project query timed out after {}ms",
                    self.timeout.as_millis()
                )),
            };

        self.cache
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .insert(
                channel_id,
                CachedSignal {
                    cached_at: (self.clock)(),
                    signal: signal.clone(),
                },
            );
        signal
    }

    #[cfg(test)]
    pub(crate) fn from_test_signals(
        signals: impl IntoIterator<Item = ProjectChannelSignal>,
    ) -> Self {
        struct SignalTransport {
            signals: Mutex<std::collections::VecDeque<ProjectChannelSignal>>,
        }

        impl ProjectQueryTransport for SignalTransport {
            fn fetch_projects(&self) -> QueryFuture<'_> {
                let signal = self
                    .signals
                    .lock()
                    .unwrap()
                    .pop_front()
                    .expect("test project signal");
                Box::pin(async move {
                    match signal {
                        ProjectChannelSignal::Project => {
                            Err("direct project signal requires policy injection".to_string())
                        }
                        ProjectChannelSignal::NotProject => Ok(serde_json::json!([])),
                        ProjectChannelSignal::Indeterminate => {
                            Err("direct indeterminate signal requires policy injection".to_string())
                        }
                        ProjectChannelSignal::FailOpen(reason) => Err(reason),
                    }
                })
            }
        }

        let signals = signals
            .into_iter()
            .collect::<std::collections::VecDeque<_>>();
        // This helper is used only where NotProject/FailOpen must travel through
        // the real cache. Project decisions use the pure policy seam in pool.rs.
        Self::with_components(
            Arc::new(SignalTransport {
                signals: Mutex::new(signals),
            }),
            PROJECT_CHANNEL_CACHE_TTL,
            Duration::from_secs(1),
            Instant::now,
        )
    }
}

/// Decode a successful relay response. Any malformed event makes the answer
/// indeterminate: malformed data must never be collapsed into "not a project".
fn classify_response(value: &Value, channel_id: Uuid) -> Result<ProjectChannelSignal, String> {
    let events = value
        .as_array()
        .ok_or_else(|| "project query returned a non-array response".to_string())?;

    for raw in events {
        let event: Event = serde_json::from_value(raw.clone())
            .map_err(|error| format!("project query returned a malformed event: {error}"))?;
        if event.kind.as_u16() as u32 != KIND_PROJECT {
            return Err(format!(
                "project query returned unexpected kind {}",
                event.kind.as_u16()
            ));
        }
        event
            .verify()
            .map_err(|error| format!("project query returned an unverifiable event: {error}"))?;

        let mut channel_tags = event
            .tags
            .iter()
            .filter(|tag| tag.as_slice().first().map(String::as_str) == Some("buzz-channel"));
        let Some(first) = channel_tags.next() else {
            continue;
        };
        if channel_tags.next().is_some() {
            return Err("project event has multiple buzz-channel tags".to_string());
        }
        let raw_channel = first
            .as_slice()
            .get(1)
            .ok_or_else(|| "project event has a valueless buzz-channel tag".to_string())?;
        let project_channel = Uuid::parse_str(raw_channel)
            .map_err(|error| format!("project event has an invalid buzz-channel UUID: {error}"))?;
        if project_channel == channel_id {
            return Ok(ProjectChannelSignal::Project);
        }
    }

    Ok(ProjectChannelSignal::NotProject)
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use nostr::{EventBuilder, Keys, Kind, Tag};
    use serde_json::json;

    use super::*;

    struct StubTransport {
        calls: AtomicUsize,
        responses: Mutex<VecDeque<Result<Value, String>>>,
    }

    impl StubTransport {
        fn new(responses: impl IntoIterator<Item = Result<Value, String>>) -> Self {
            Self {
                calls: AtomicUsize::new(0),
                responses: Mutex::new(responses.into_iter().collect()),
            }
        }
    }

    impl ProjectQueryTransport for StubTransport {
        fn fetch_projects(&self) -> QueryFuture<'_> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let response = self
                .responses
                .lock()
                .unwrap()
                .pop_front()
                .expect("stub response");
            Box::pin(async move { response })
        }
    }

    fn project(channel: Uuid) -> Value {
        let keys = Keys::generate();
        let channel = channel.to_string();
        let event = EventBuilder::new(Kind::Custom(KIND_PROJECT as u16), "")
            .tags([
                Tag::parse(["d", "project"]).unwrap(),
                Tag::parse(["buzz-channel", channel.as_str()]).unwrap(),
            ])
            .sign_with_keys(&keys)
            .unwrap();
        serde_json::to_value(event).unwrap()
    }

    #[tokio::test]
    async fn finds_project_channel_by_scanning_multi_character_tag_client_side() {
        let channel = Uuid::new_v4();
        let transport = Arc::new(StubTransport::new([Ok(json!([project(channel)]))]));
        let resolver = ProjectChannelResolver::with_components(
            transport,
            Duration::from_secs(60),
            Duration::from_secs(1),
            Instant::now,
        );

        assert_eq!(
            resolver.classify(channel).await,
            ProjectChannelSignal::Project
        );
    }

    #[tokio::test]
    async fn confirmed_absence_is_not_project() {
        let channel = Uuid::new_v4();
        let transport = Arc::new(StubTransport::new([Ok(json!([]))]));
        let resolver = ProjectChannelResolver::with_components(
            transport,
            Duration::from_secs(60),
            Duration::from_secs(1),
            Instant::now,
        );

        assert_eq!(
            resolver.classify(channel).await,
            ProjectChannelSignal::NotProject
        );
    }

    #[tokio::test]
    async fn transport_error_is_fail_open_and_never_confirmed_absence() {
        let channel = Uuid::new_v4();
        let transport = Arc::new(StubTransport::new([Err("offline".to_string())]));
        let resolver = ProjectChannelResolver::with_components(
            transport,
            Duration::from_secs(60),
            Duration::from_secs(1),
            Instant::now,
        );

        assert!(matches!(
            resolver.classify(channel).await,
            ProjectChannelSignal::FailOpen(reason) if reason == "offline"
        ));
    }

    #[tokio::test]
    async fn malformed_response_is_fail_open() {
        let channel = Uuid::new_v4();
        let transport = Arc::new(StubTransport::new([Ok(json!({"not": "events"}))]));
        let resolver = ProjectChannelResolver::with_components(
            transport,
            Duration::from_secs(60),
            Duration::from_secs(1),
            Instant::now,
        );

        assert!(matches!(
            resolver.classify(channel).await,
            ProjectChannelSignal::FailOpen(reason) if reason.contains("non-array")
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn timeout_is_bounded_and_fail_open() {
        struct PendingTransport;
        impl ProjectQueryTransport for PendingTransport {
            fn fetch_projects(&self) -> QueryFuture<'_> {
                Box::pin(std::future::pending())
            }
        }

        let resolver = ProjectChannelResolver::with_components(
            Arc::new(PendingTransport),
            Duration::from_secs(60),
            Duration::from_secs(2),
            Instant::now,
        );
        assert!(matches!(
            resolver.classify(Uuid::new_v4()).await,
            ProjectChannelSignal::FailOpen(reason) if reason.contains("timed out after 2000ms")
        ));
    }

    #[tokio::test]
    async fn second_query_inside_ttl_does_not_hit_transport() {
        let channel = Uuid::new_v4();
        let transport = Arc::new(StubTransport::new([Ok(json!([]))]));
        let resolver = ProjectChannelResolver::with_components(
            transport.clone(),
            Duration::from_secs(60),
            Duration::from_secs(1),
            Instant::now,
        );

        assert_eq!(
            resolver.classify(channel).await,
            ProjectChannelSignal::NotProject
        );
        assert_eq!(
            resolver.classify(channel).await,
            ProjectChannelSignal::NotProject
        );
        assert_eq!(transport.calls.load(Ordering::SeqCst), 1);
    }
}
