//! Relay-backed classification of Buzz project channels.
//!
//! NIP-01 filters only expose single-letter generic tags (`#e`, `#p`, `#d`,
//! and so on), and the relay's request path consumes that same
//! `SingleLetterTag` map. `buzz-channel` is therefore not filterable without a
//! private protocol extension. Projects are intentionally few, so we query the
//! live kind:30621 heads and scan their `buzz-channel` tags client-side.

use std::collections::HashSet;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
#[cfg(test)]
use std::sync::Mutex;
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
struct CachedProjectQuery {
    cached_at: Instant,
    result: Result<HashSet<Uuid>, String>,
}

/// Query-level TTL cache around the relay project signal.
pub(crate) struct ProjectChannelResolver {
    transport: Arc<dyn ProjectQueryTransport>,
    // Held through a cache miss so concurrent channel classifications share the
    // same in-flight relay query instead of multiplying identical kind-only
    // fetches. Project queries are bounded by `timeout`, so lock occupancy is
    // bounded as well.
    cache: tokio::sync::Mutex<Option<CachedProjectQuery>>,
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
            cache: tokio::sync::Mutex::new(None),
            ttl,
            timeout,
            clock: Arc::new(clock),
        }
    }

    pub(crate) async fn classify(&self, channel_id: Uuid) -> ProjectChannelSignal {
        let now = (self.clock)();
        let mut cache = self.cache.lock().await;
        if let Some(cached) = cache
            .as_ref()
            .filter(|cached| now.saturating_duration_since(cached.cached_at) < self.ttl)
        {
            return signal_for_channel(&cached.result, channel_id);
        }

        let result = match tokio::time::timeout(self.timeout, self.transport.fetch_projects()).await
        {
            Ok(Ok(value)) => project_channels_from_response(&value),
            Ok(Err(reason)) => Err(reason),
            Err(_) => Err(format!(
                "project query timed out after {}ms",
                self.timeout.as_millis()
            )),
        };

        let signal = signal_for_channel(&result, channel_id);
        *cache = Some(CachedProjectQuery {
            cached_at: (self.clock)(),
            result,
        });
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

fn signal_for_channel(
    result: &Result<HashSet<Uuid>, String>,
    channel_id: Uuid,
) -> ProjectChannelSignal {
    match result {
        Ok(channels) if channels.contains(&channel_id) => ProjectChannelSignal::Project,
        Ok(_) => ProjectChannelSignal::NotProject,
        Err(reason) => ProjectChannelSignal::FailOpen(reason.clone()),
    }
}

/// Decode a successful relay response into the complete project-channel set.
/// Any malformed event makes the whole answer indeterminate: malformed data
/// must never be collapsed into a confident negative for any channel.
fn project_channels_from_response(value: &Value) -> Result<HashSet<Uuid>, String> {
    let events = value
        .as_array()
        .ok_or_else(|| "project query returned a non-array response".to_string())?;
    let mut project_channels = HashSet::new();

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
        project_channels.insert(project_channel);
    }

    Ok(project_channels)
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
    use std::sync::Mutex;

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
    async fn fail_open_is_cached_without_becoming_confirmed_absence() {
        let transport = Arc::new(StubTransport::new([Err("offline".to_string())]));
        let resolver = ProjectChannelResolver::with_components(
            transport.clone(),
            Duration::from_secs(60),
            Duration::from_secs(1),
            Instant::now,
        );

        for channel in [Uuid::new_v4(), Uuid::new_v4()] {
            assert!(matches!(
                resolver.classify(channel).await,
                ProjectChannelSignal::FailOpen(reason) if reason == "offline"
            ));
        }
        assert_eq!(transport.calls.load(Ordering::SeqCst), 1);
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
    async fn different_channels_inside_ttl_share_one_transport_query() {
        let first_channel = Uuid::new_v4();
        let second_channel = Uuid::new_v4();
        let transport = Arc::new(StubTransport::new([Ok(json!([]))]));
        let resolver = ProjectChannelResolver::with_components(
            transport.clone(),
            Duration::from_secs(60),
            Duration::from_secs(1),
            Instant::now,
        );

        assert_eq!(
            resolver.classify(first_channel).await,
            ProjectChannelSignal::NotProject
        );
        assert_eq!(
            resolver.classify(second_channel).await,
            ProjectChannelSignal::NotProject
        );
        assert_eq!(transport.calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn expired_query_cache_is_refreshed_for_any_channel() {
        let project_channel = Uuid::new_v4();
        let elapsed_secs = Arc::new(AtomicU64::new(0));
        let start = Instant::now();
        let clock = {
            let elapsed_secs = elapsed_secs.clone();
            move || start + Duration::from_secs(elapsed_secs.load(Ordering::SeqCst))
        };
        let transport = Arc::new(StubTransport::new([
            Ok(json!([])),
            Ok(json!([project(project_channel)])),
        ]));
        let resolver = ProjectChannelResolver::with_components(
            transport.clone(),
            Duration::from_secs(60),
            Duration::from_secs(1),
            clock,
        );

        assert_eq!(
            resolver.classify(Uuid::new_v4()).await,
            ProjectChannelSignal::NotProject
        );
        elapsed_secs.store(60, Ordering::SeqCst);
        assert_eq!(
            resolver.classify(project_channel).await,
            ProjectChannelSignal::Project
        );
        assert_eq!(transport.calls.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn concurrent_channel_misses_share_one_in_flight_query() {
        struct SlowTransport {
            calls: AtomicUsize,
        }

        impl ProjectQueryTransport for SlowTransport {
            fn fetch_projects(&self) -> QueryFuture<'_> {
                self.calls.fetch_add(1, Ordering::SeqCst);
                Box::pin(async {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    Ok(json!([]))
                })
            }
        }

        let transport = Arc::new(SlowTransport {
            calls: AtomicUsize::new(0),
        });
        let resolver = ProjectChannelResolver::with_components(
            transport.clone(),
            Duration::from_secs(60),
            Duration::from_secs(1),
            Instant::now,
        );

        let (first, second) = tokio::join!(
            resolver.classify(Uuid::new_v4()),
            resolver.classify(Uuid::new_v4())
        );

        assert_eq!(first, ProjectChannelSignal::NotProject);
        assert_eq!(second, ProjectChannelSignal::NotProject);
        assert_eq!(transport.calls.load(Ordering::SeqCst), 1);
    }
}
