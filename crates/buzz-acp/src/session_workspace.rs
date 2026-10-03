//! Per-session workspace resolution for ACP sessions.
//!
//! [`WorkspaceIndex`](crate::workspace_index::WorkspaceIndex) owns local
//! channel-to-checkout discovery. This module owns the runtime policy that
//! turns that discovery into one immutable cwd decision per [`SessionScope`].

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use thiserror::Error;
use uuid::Uuid;

use crate::config::UnindexedChannelPolicy;
use crate::prompt_project::PromptProjectInfo;
use crate::workspace_index::{display_paths, WorkspaceIndex};

/// Environment variable an operator sets to pin every channel session cwd.
///
/// This is PF-4 from `crates/buzz-persona/PERSONA_PACK_SPEC.md`.
pub(crate) const AGENT_CWD_ENV: &str = "AGENT_CWD";

/// One hour makes a refusal visible without turning a busy channel into a
/// notice loop while its workspace declaration is being repaired.
const REFUSAL_NOTICE_WINDOW: Duration = Duration::from_secs(60 * 60);

#[derive(Debug, Error, PartialEq, Eq)]
pub(crate) enum AgentCwdError {
    #[error(
        "{AGENT_CWD_ENV} is set to `{0}`, which is not an absolute path; the session cwd must be absolute"
    )]
    NotAbsolute(String),

    #[error("{AGENT_CWD_ENV} is set to `{0}`, which is not an existing directory")]
    NotADirectory(String),

    #[error(
        "cannot determine the session working directory: {AGENT_CWD_ENV} is unset and the current directory is unavailable ({0})"
    )]
    Undeterminable(String),

    #[error("current working directory is not absolute: {0}")]
    ProcessCwdNotAbsolute(String),
}

/// The process cwd plus an optional operator pin resolved at startup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StartupCwds {
    pub(crate) process: PathBuf,
    pub(crate) pinned: Option<PathBuf>,
}

/// Resolve the process and operator-pinned working directories without reading
/// process-global state. Keeping the inputs injectable makes the precedence
/// testable without serializing tests around environment mutation.
pub(crate) fn resolve_startup_cwds_with(
    env_value: Option<String>,
    current_dir: Result<PathBuf, std::io::Error>,
    is_dir: impl Fn(&Path) -> bool,
) -> Result<StartupCwds, AgentCwdError> {
    let process = current_dir.map_err(|error| AgentCwdError::Undeterminable(error.to_string()))?;
    if !process.is_absolute() {
        return Err(AgentCwdError::ProcessCwdNotAbsolute(
            process.to_string_lossy().into_owned(),
        ));
    }

    let pinned = env_value
        .map(|raw| raw.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(|value| {
            let path = PathBuf::from(&value);
            if !path.is_absolute() {
                return Err(AgentCwdError::NotAbsolute(value));
            }
            if !is_dir(&path) {
                return Err(AgentCwdError::NotADirectory(value));
            }
            Ok(path)
        })
        .transpose()?;

    Ok(StartupCwds { process, pinned })
}

/// Process-level entry point for [`resolve_startup_cwds_with`].
pub(crate) fn resolve_startup_cwds() -> Result<StartupCwds, AgentCwdError> {
    resolve_startup_cwds_with(
        std::env::var(AGENT_CWD_ENV).ok(),
        std::env::current_dir(),
        Path::is_dir,
    )
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SessionCwdDecision {
    Pinned(PathBuf),
    Workspace(PathBuf),
    RootMode(PathBuf),
    Refused(String),
}

/// Thread-safe resolver shared by every prompt task.
#[derive(Debug)]
pub(crate) struct SessionCwdResolver {
    pinned_cwd: Option<PathBuf>,
    process_cwd: PathBuf,
    workspace_index: WorkspaceIndex,
    unindexed_policy: UnindexedChannelPolicy,
    refusal_notices: Mutex<HashMap<Uuid, Instant>>,
}

impl SessionCwdResolver {
    pub(crate) fn new(
        startup: StartupCwds,
        workspace_index: WorkspaceIndex,
        unindexed_policy: UnindexedChannelPolicy,
    ) -> Self {
        Self {
            pinned_cwd: startup.pinned,
            process_cwd: startup.process,
            workspace_index,
            unindexed_policy,
            refusal_notices: Mutex::new(HashMap::new()),
        }
    }

    /// Resolve a channel with strict, auditable precedence:
    /// operator pin → indexed checkout → explicit root opt-in → refusal.
    pub(crate) fn resolve_channel(&self, channel_id: Uuid) -> SessionCwdDecision {
        if let Some(path) = &self.pinned_cwd {
            return SessionCwdDecision::Pinned(path.clone());
        }
        if let Some(path) = self.workspace_index.lookup(channel_id) {
            self.refusal_notices
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .remove(&channel_id);
            return SessionCwdDecision::Workspace(path);
        }
        match self.unindexed_policy {
            UnindexedChannelPolicy::Root => {
                SessionCwdDecision::RootMode(self.process_cwd.clone())
            }
            UnindexedChannelPolicy::Refuse => SessionCwdDecision::Refused(format!(
                "channel {channel_id} is not declared by any indexed workspace (scanned roots: {}); refusing to use the harness process directory",
                display_paths(&self.workspace_index.roots())
            )),
        }
    }

    pub(crate) fn heartbeat_cwd(&self) -> &Path {
        &self.process_cwd
    }

    /// Atomically claim this channel's user-visible notice slot.
    pub(crate) fn should_post_refusal_notice(&self, channel_id: Uuid) -> bool {
        let now = Instant::now();
        let mut notices = self
            .refusal_notices
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if notices.get(&channel_id).is_some_and(|posted_at| {
            now.saturating_duration_since(*posted_at) < REFUSAL_NOTICE_WINDOW
        }) {
            return false;
        }
        notices.insert(channel_id, now);
        true
    }

    /// Actionable refusal text, enriched from the authoritative upstream
    /// project-home resolution when the channel belongs to a listed project.
    pub(crate) fn refusal_notice(
        &self,
        channel_id: Uuid,
        project: Option<&PromptProjectInfo>,
    ) -> String {
        let project = project
            .map(|project| format!(" for Buzz project `{}`", project.name))
            .unwrap_or_default();
        format!(
            "Cannot start an ACP session for channel `{channel_id}`{project} because it is not declared by any local workspace. Create `<repo>/.buzz/workspace.json` with `{{\"channels\":[\"{channel_id}\"]}}`. Scanned roots: {}.",
            display_paths(&self.workspace_index.roots())
        )
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;

    fn startup(pinned: Option<&str>) -> StartupCwds {
        StartupCwds {
            process: PathBuf::from("/tmp/harness-process"),
            pinned: pinned.map(PathBuf::from),
        }
    }

    fn resolver(
        pinned: Option<&str>,
        channels: BTreeMap<Uuid, PathBuf>,
        policy: UnindexedChannelPolicy,
    ) -> SessionCwdResolver {
        SessionCwdResolver::new(
            startup(pinned),
            WorkspaceIndex::from_test_channels(channels, |_| true),
            policy,
        )
    }

    fn io_error() -> std::io::Error {
        std::io::Error::new(std::io::ErrorKind::NotFound, "cwd unavailable")
    }

    #[test]
    fn operator_pin_wins_over_index_and_policy() {
        let channel = Uuid::new_v4();
        let resolver = resolver(
            Some("/tmp/pinned"),
            BTreeMap::from([(channel, PathBuf::from("/tmp/repository"))]),
            UnindexedChannelPolicy::Refuse,
        );
        assert_eq!(
            resolver.resolve_channel(channel),
            SessionCwdDecision::Pinned(PathBuf::from("/tmp/pinned"))
        );
    }

    #[test]
    fn indexed_workspace_wins_over_root_opt_in() {
        let channel = Uuid::new_v4();
        let resolver = resolver(
            None,
            BTreeMap::from([(channel, PathBuf::from("/tmp/repository"))]),
            UnindexedChannelPolicy::Root,
        );
        assert_eq!(
            resolver.resolve_channel(channel),
            SessionCwdDecision::Workspace(PathBuf::from("/tmp/repository"))
        );
    }

    #[test]
    fn unindexed_channel_fails_closed_by_default() {
        let channel = Uuid::new_v4();
        let resolver = resolver(None, BTreeMap::new(), UnindexedChannelPolicy::Refuse);
        assert!(matches!(
            resolver.resolve_channel(channel),
            SessionCwdDecision::Refused(reason)
                if reason.contains(&channel.to_string()) && reason.contains("refusing")
        ));
    }

    #[test]
    fn root_mode_requires_explicit_policy() {
        let resolver = resolver(None, BTreeMap::new(), UnindexedChannelPolicy::Root);
        assert_eq!(
            resolver.resolve_channel(Uuid::new_v4()),
            SessionCwdDecision::RootMode(PathBuf::from("/tmp/harness-process"))
        );
    }

    #[test]
    fn heartbeat_always_uses_process_cwd() {
        let resolver = resolver(
            Some("/tmp/pinned"),
            BTreeMap::new(),
            UnindexedChannelPolicy::Refuse,
        );
        assert_eq!(resolver.heartbeat_cwd(), Path::new("/tmp/harness-process"));
    }

    #[test]
    fn valid_agent_cwd_is_trimmed_and_pinned() {
        let resolved = resolve_startup_cwds_with(
            Some("  /srv/project\n".into()),
            Ok(PathBuf::from("/opt/buzz")),
            |path| path == Path::new("/srv/project"),
        )
        .expect("valid cwd");
        assert_eq!(resolved.process, PathBuf::from("/opt/buzz"));
        assert_eq!(resolved.pinned, Some(PathBuf::from("/srv/project")));
    }

    #[test]
    fn blank_agent_cwd_is_unset() {
        let resolved =
            resolve_startup_cwds_with(Some(" \t\n".into()), Ok(PathBuf::from("/opt/buzz")), |_| {
                false
            })
            .expect("blank falls through");
        assert_eq!(resolved.pinned, None);
    }

    #[test]
    fn relative_or_missing_agent_cwd_is_refused() {
        assert_eq!(
            resolve_startup_cwds_with(Some("repo".into()), Ok(PathBuf::from("/opt/buzz")), |_| {
                true
            },),
            Err(AgentCwdError::NotAbsolute("repo".into()))
        );
        assert_eq!(
            resolve_startup_cwds_with(
                Some("/missing".into()),
                Ok(PathBuf::from("/opt/buzz")),
                |_| false,
            ),
            Err(AgentCwdError::NotADirectory("/missing".into()))
        );
    }

    #[test]
    fn unavailable_or_relative_process_cwd_is_refused() {
        assert!(matches!(
            resolve_startup_cwds_with(None, Err(io_error()), |_| true),
            Err(AgentCwdError::Undeterminable(_))
        ));
        assert_eq!(
            resolve_startup_cwds_with(None, Ok(PathBuf::from("relative")), |_| true),
            Err(AgentCwdError::ProcessCwdNotAbsolute("relative".into()))
        );
    }

    #[test]
    fn refusal_notices_are_rate_limited_and_reset_after_index_hit() {
        let channel = Uuid::new_v4();
        let resolver = resolver(
            None,
            BTreeMap::from([(channel, PathBuf::from("/tmp/repository"))]),
            UnindexedChannelPolicy::Refuse,
        );
        assert!(resolver.should_post_refusal_notice(channel));
        assert!(!resolver.should_post_refusal_notice(channel));
        assert!(matches!(
            resolver.resolve_channel(channel),
            SessionCwdDecision::Workspace(_)
        ));
        assert!(resolver.should_post_refusal_notice(channel));
    }

    #[test]
    fn project_refusal_notice_uses_authoritative_project_name() {
        let channel = Uuid::new_v4();
        let resolver = resolver(None, BTreeMap::new(), UnindexedChannelPolicy::Refuse);
        let project = PromptProjectInfo {
            name: "MetaGastos".into(),
            ..PromptProjectInfo::default()
        };
        let notice = resolver.refusal_notice(channel, Some(&project));
        assert!(notice.contains("Buzz project `MetaGastos`"));
        assert!(notice.contains(&channel.to_string()));
    }
}
