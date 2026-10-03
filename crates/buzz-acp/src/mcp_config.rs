//! MCP server construction and per-session environment stamping.
//!
//! Buzz's own MCP server receives the agent's signing identity. Operator-added
//! servers never receive those credentials; they get only non-secret session
//! context when the ACP session is created.

use std::path::Path;

use nostr::ToBech32;
use uuid::Uuid;

use crate::acp::{EnvVar, McpServer};
use crate::config::Config;

/// Build the static MCP list configured for every ACP session.
pub(crate) fn build_mcp_servers(config: &Config) -> Vec<McpServer> {
    let mut servers = Vec::new();
    if !config.mcp_command.is_empty() {
        servers.push(build_buzz_mcp_server(config));
    }

    // Extra servers intentionally start with an empty environment. In
    // particular, the Buzz signing key and auth tag stay confined to buzz-mcp.
    for entry in config
        .mcp_extra
        .iter()
        .map(|entry| entry.trim())
        .filter(|entry| !entry.is_empty())
    {
        let (name, command) = parse_extra_mcp_entry(entry);
        servers.push(McpServer {
            name,
            command,
            args: Vec::new(),
            env: Vec::new(),
        });
    }
    servers
}

/// Clone configured servers and attach context that belongs to one ACP session.
pub(crate) fn for_session(
    servers: &[McpServer],
    channel_id: Option<Uuid>,
    channel_type: Option<&str>,
    agent_name: Option<&str>,
    session_cwd: &Path,
) -> Vec<McpServer> {
    let mut servers = servers.to_vec();
    let cwd = session_cwd.to_string_lossy().into_owned();
    for server in &mut servers {
        upsert_env(&mut server.env, "HINDSIGHT_MCP_PROJECT_CWD", cwd.clone());
    }

    let origin = match (channel_id, channel_type) {
        (Some(channel_id), Some("stream")) => Some(EnvVar {
            name: "BUZZ_GIT_ORIGIN_CHANNEL_ID".into(),
            value: channel_id.to_string(),
        }),
        (Some(_), _) => agent_name
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(|name| EnvVar {
                name: "BUZZ_GIT_ORIGIN_AGENT_NAME".into(),
                value: name.to_string(),
            }),
        (None, _) => None,
    };
    if let Some(origin) = origin {
        for server in &mut servers {
            upsert_env(&mut server.env, &origin.name, origin.value.clone());
        }
    }
    servers
}

fn upsert_env(env: &mut Vec<EnvVar>, name: &str, value: String) {
    if let Some(existing) = env.iter_mut().find(|entry| entry.name == name) {
        existing.value = value;
    } else {
        env.push(EnvVar {
            name: name.to_string(),
            value,
        });
    }
}

fn parse_extra_mcp_entry(entry: &str) -> (String, String) {
    if let Some((name, command)) = entry.split_once('=') {
        let name = name.trim();
        let command = command.trim();
        // A slash identifies a command path, where '=' is legal, rather than
        // the optional `name=command` syntax.
        if !name.is_empty() && !command.is_empty() && !name.contains('/') {
            return (name.to_string(), command.to_string());
        }
    }
    (mcp_server_name(entry), entry.to_string())
}

fn mcp_server_name(command: &str) -> String {
    Path::new(command)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("mcp")
        .to_string()
}

fn build_buzz_mcp_server(config: &Config) -> McpServer {
    let mut env = vec![
        EnvVar {
            name: "BUZZ_RELAY_URL".into(),
            value: config.relay_url.clone(),
        },
        EnvVar {
            name: "BUZZ_PRIVATE_KEY".into(),
            value: config
                .keys
                .secret_key()
                .to_bech32()
                .expect("secret key bech32 encoding should never fail"),
        },
    ];
    if let Ok(auth_tag) = std::env::var("BUZZ_AUTH_TAG") {
        if !auth_tag.is_empty() {
            env.push(EnvVar {
                name: "BUZZ_AUTH_TAG".into(),
                value: auth_tag,
            });
        }
    }
    // Preserve the display-name contract for tools. Git authorship is
    // already normalized by the harness bootstrap.
    if let Ok(display_name) = std::env::var("BUZZ_ACP_DISPLAY_NAME") {
        if !display_name.is_empty() {
            env.push(EnvVar {
                name: "BUZZ_ACP_DISPLAY_NAME".into(),
                value: display_name,
            });
        }
    }
    // The harness-owned Git block (identity, credential helper, signing key
    // path) is composed once at startup and reaches buzz-mcp whole, replacing
    // any same-named entry above. Operator extra servers never get it: it
    // carries the agent's signing key.
    for (name, value) in &config.persona_env_vars {
        if crate::git::is_managed_env(name) {
            env.retain(|entry| entry.name != *name);
            env.push(EnvVar {
                name: name.clone(),
                value: value.clone(),
            });
        }
    }
    McpServer {
        name: mcp_server_name(&config.mcp_command),
        command: config.mcp_command.clone(),
        args: Vec::new(),
        env,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server(name: &str, env: Vec<EnvVar>) -> McpServer {
        McpServer {
            name: name.into(),
            command: format!("/{name}"),
            args: Vec::new(),
            env,
        }
    }

    #[test]
    fn parses_named_bare_and_equals_in_path_entries() {
        assert_eq!(
            parse_extra_mcp_entry("hindsight=/opt/mcp-server.js"),
            ("hindsight".into(), "/opt/mcp-server.js".into())
        );
        assert_eq!(
            parse_extra_mcp_entry("/opt/hindsight-mcp.js"),
            ("hindsight-mcp".into(), "/opt/hindsight-mcp.js".into())
        );
        assert_eq!(
            parse_extra_mcp_entry("/opt/a=b/server.js"),
            ("server".into(), "/opt/a=b/server.js".into())
        );
    }

    #[test]
    fn session_cwd_is_upserted_for_every_server() {
        let servers = vec![
            server("buzz", Vec::new()),
            server(
                "hindsight",
                vec![EnvVar {
                    name: "HINDSIGHT_MCP_PROJECT_CWD".into(),
                    value: "/stale".into(),
                }],
            ),
        ];
        let stamped = for_session(&servers, None, None, None, Path::new("/repo"));
        for server in stamped {
            let matching = server
                .env
                .iter()
                .filter(|entry| entry.name == "HINDSIGHT_MCP_PROJECT_CWD")
                .collect::<Vec<_>>();
            assert_eq!(matching.len(), 1);
            assert_eq!(matching[0].value, "/repo");
        }
    }

    #[test]
    fn stream_and_private_origins_preserve_upstream_semantics() {
        let channel = Uuid::new_v4();
        let servers = vec![server("mcp", Vec::new())];
        let public = for_session(
            &servers,
            Some(channel),
            Some("stream"),
            Some("Opus"),
            Path::new("/repo"),
        );
        assert!(public[0].env.iter().any(|entry| {
            entry.name == "BUZZ_GIT_ORIGIN_CHANNEL_ID" && entry.value == channel.to_string()
        }));

        let private = for_session(
            &servers,
            Some(channel),
            Some("private"),
            Some(" Opus "),
            Path::new("/repo"),
        );
        assert!(private[0]
            .env
            .iter()
            .any(|entry| { entry.name == "BUZZ_GIT_ORIGIN_AGENT_NAME" && entry.value == "Opus" }));
    }
}
