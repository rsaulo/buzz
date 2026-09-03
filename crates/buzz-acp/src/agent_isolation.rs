//! What ambient user configuration a managed adapter may inherit.
//!
//! A long-lived harness serves many projects from one process, so anything the
//! child would otherwise pick up from the operator's own machine — a personal
//! `CLAUDE.md`, user-scoped hooks and MCP servers, a Hindsight bank selector
//! exported in the parent shell — is ambient state that does not belong to the
//! session being opened. Each item below removes exactly one such inheritance
//! path; nothing here changes what the *repository* configures.

/// Memory-bank selectors that must never cross the harness/agent boundary.
///
/// Repository-local Hindsight configuration owns bank selection (`mapPathToBank`
/// against the session cwd). A selector inherited from the parent environment
/// would pin every session of every project to one bank, silently defeating that
/// mapping — and, for an unmapped repository, route writes to the default bank
/// instead of failing closed.
pub(crate) const REMOVED_BANK_ENV: [&str; 2] = ["HINDSIGHT_BANK_ID", "HINDSIGHT_DYNAMIC_BANK_ID"];

/// Names of the bank selectors actually present in either inheritance path.
///
/// Returned for logging so an operator who exported one sees that it was
/// dropped, rather than wondering why it had no effect.
pub(crate) fn shadowed_bank_env(extra_env: &[(String, String)]) -> Vec<&'static str> {
    REMOVED_BANK_ENV
        .iter()
        .copied()
        .filter(|key| {
            std::env::var_os(key).is_some() || extra_env.iter().any(|(name, _)| name == *key)
        })
        .collect()
}

/// Environment defaults for a managed child, by normalized command identity.
///
/// Claude reads the operator's personal `CLAUDE.md` files and auto-memory from
/// `$HOME` on startup. In a managed agent those are another user's instructions
/// arriving in a project session that never asked for them, so they are off by
/// default. An operator can still opt back in by exporting the variable
/// explicitly — `AcpClient::spawn` skips injection for keys already set.
pub(crate) fn command_env_defaults(identity: &str) -> &'static [(&'static str, &'static str)] {
    match identity {
        "claude-agent-acp" | "claude-code-acp" | "claude-code" | "claudecode" => &[
            ("CLAUDE_CODE_DISABLE_CLAUDE_MDS", "1"),
            ("CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1"),
        ],
        _ => &[],
    }
}

/// The `_meta` members `session/new` should carry for this adapter, if any.
///
/// `settingSources: ["project", "local"]` overrides claude-agent-acp's
/// user-inclusive default, so the session loads the repository's settings and
/// skips user-scoped settings, hooks, MCP servers and instructions. Gated on the
/// name the adapter reported at `initialize`: no other adapter understands the
/// key, and sending it would be a silent no-op at best.
pub(crate) fn session_meta_options(
    reported_agent_name: &str,
    isolate_claude_user_config: bool,
) -> Option<serde_json::Value> {
    (isolate_claude_user_config && reported_agent_name == crate::pool::CLAUDE_AGENT_ACP_NAME).then(
        || {
            serde_json::json!({
                "claudeCode": { "options": { "settingSources": ["project", "local"] } }
            })
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pool::CLAUDE_AGENT_ACP_NAME;

    #[test]
    fn claude_isolation_is_scoped_to_claude_and_to_the_opt_out() {
        assert!(session_meta_options(CLAUDE_AGENT_ACP_NAME, true).is_some());
        assert_eq!(session_meta_options(CLAUDE_AGENT_ACP_NAME, false), None);
        for other in ["goose", "codex-acp", "buzz-agent", ""] {
            assert_eq!(
                session_meta_options(other, true),
                None,
                "{other} does not understand the Claude options key"
            );
        }
    }

    #[test]
    fn claude_meta_names_both_project_and_local_setting_sources() {
        let meta = session_meta_options(CLAUDE_AGENT_ACP_NAME, true).expect("claude gets options");
        assert_eq!(
            meta["claudeCode"]["options"]["settingSources"],
            serde_json::json!(["project", "local"]),
            "project and local settings stay; only user-scoped configuration is dropped"
        );
    }

    #[test]
    fn env_defaults_cover_every_claude_identity_and_nothing_else() {
        for identity in [
            "claude-agent-acp",
            "claude-code-acp",
            "claude-code",
            "claudecode",
        ] {
            assert_eq!(
                command_env_defaults(identity),
                &[
                    ("CLAUDE_CODE_DISABLE_CLAUDE_MDS", "1"),
                    ("CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1"),
                ],
                "unexpected env defaults for {identity}"
            );
        }
        for identity in ["goose", "codex-acp", "buzz-agent", "hermes", ""] {
            assert!(
                command_env_defaults(identity).is_empty(),
                "{identity} must inherit no Claude-specific defaults"
            );
        }
    }

    /// Both inheritance paths matter: the parent shell is the common case, but a
    /// persona pack can supply the same key, and that copy is merged into the
    /// child environment *after* the parent's — so it must be reported too.
    ///
    /// Only the persona path is asserted here: the parent environment is
    /// process-global and a test must not depend on (or mutate) it.
    #[test]
    fn shadowed_bank_env_reports_persona_supplied_selectors() {
        let persona = vec![
            ("HINDSIGHT_BANK_ID".to_string(), "coding".to_string()),
            ("GOOSE_PROVIDER".to_string(), "anthropic".to_string()),
        ];
        let shadowed = shadowed_bank_env(&persona);
        assert!(shadowed.contains(&"HINDSIGHT_BANK_ID"), "got {shadowed:?}");
        assert!(
            !shadowed.contains(&"GOOSE_PROVIDER"),
            "only bank selectors are stripped: {shadowed:?}"
        );
    }
}
