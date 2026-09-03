//! MCP server construction and per-session environment stamping.
//!
//! Buzz's own MCP server is handed the agent's signing identity explicitly.
//! Operator-added servers are not: their declared environment carries only
//! non-secret session context, attached when the ACP session is created.
//!
//! ⚠️ That is a narrower guarantee than "extra servers cannot see Buzz
//! credentials", and the difference is load-bearing. These entries describe
//! servers that a *third-party ACP adapter* spawns on our behalf, and
//! `AcpClient::spawn` does not `env_clear` the adapter — so the adapter
//! inherits the harness environment, `BUZZ_PRIVATE_KEY` included, and whatever
//! it spawns inherits from it. Declaring no environment here keeps the
//! credential out of the *declaration*; it does not keep it out of the
//! *process*. Closing that would mean clearing the environment at the adapter
//! spawn boundary, which affects every adapter, not just extra MCP servers.
//! Upstream reached the same conclusion on the same code in block/buzz#6651.

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

    // Extra servers declare no environment of their own: the Buzz signing key
    // and auth tag are never handed to them. See the module docs for what that
    // does and does not guarantee once an adapter spawns them.
    //
    // Upstream is landing the same capability as `BUZZ_ACP_EXTRA_MCP_COMMANDS`
    // (block/buzz#6651), with two things this does not have: shell-aware argv
    // parsing, and a newline entry delimiter so a comma inside an argument
    // survives. It is deliberately not adopted yet — the nine managed agents
    // configure `BUZZ_ACP_MCP_EXTRA` today, so switching names is a production
    // config change, not a code change. When that PR merges, the right move is
    // to delete this loop and keep only `for_session` below, which upstream
    // explicitly scoped out of the PR.
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

/// Split an entry into `(name, command)`.
///
/// Accepts `name=/path/to/server` and a bare `/path/to/server`, the latter named
/// after its file stem. The explicit form exists because a derived name depends
/// on the entry's position in the list, so reordering silently renames a server
/// and the agent loses those tools with no error.
///
/// The `=` only separates when the left side is a plausible server name: ASCII
/// alphanumeric plus `-` and `_`. Anything else is part of the command, which is
/// what keeps a URL like `https://host/mcp/?apiKey=x` from being read as a
/// server named `https://host/mcp/?apiKey`.
fn parse_extra_mcp_entry(entry: &str) -> (String, String) {
    if let Some((name, command)) = entry.split_once('=') {
        let name = name.trim();
        let command = command.trim();
        if !name.is_empty() && !command.is_empty() && is_valid_server_name(name) {
            return (name.to_string(), command.to_string());
        }
    }
    (mcp_server_name(entry), entry.to_string())
}

fn is_valid_server_name(name: &str) -> bool {
    name.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Name a server after its command, since the protocol wants a stable id.
///
/// A remote endpoint is identified by its host, not by its last path segment:
/// that segment is usually a query string, which is both unusable as a name and
/// frequently carries an API key — `?apiKey=secret` would put the credential in
/// the server's name, and from there into every log line that mentions it.
///
/// Whatever the source, the result is reduced to the characters a name may
/// contain, falling back to `mcp` when nothing usable is left.
fn mcp_server_name(command: &str) -> String {
    if let Some((_scheme, rest)) = command.split_once("://") {
        let host = rest
            .split(['/', '?', '#'])
            .next()
            .unwrap_or_default()
            // Strip userinfo, which is another place a credential hides.
            .rsplit('@')
            .next()
            .unwrap_or_default();
        let host = sanitize_server_name(host);
        if !host.is_empty() {
            return host;
        }
    }
    let stem = Path::new(command)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or_default();
    let stem = sanitize_server_name(stem);
    if stem.is_empty() {
        "mcp".to_string()
    } else {
        stem
    }
}

/// Reduce a derived name to `is_valid_server_name`'s alphabet, collapsing runs
/// of rejected characters into a single `-`.
fn sanitize_server_name(raw: &str) -> String {
    let mut name = String::with_capacity(raw.len());
    for c in raw.chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            name.push(c);
        } else if !name.ends_with('-') {
            name.push('-');
        }
    }
    name.trim_matches('-').to_string()
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
    if let Ok(display_name) = std::env::var("BUZZ_ACP_DISPLAY_NAME") {
        if !display_name.is_empty() {
            env.push(EnvVar {
                name: "BUZZ_ACP_DISPLAY_NAME".into(),
                value: display_name,
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

    /// A remote MCP endpoint carries `=` inside a query parameter. Reading that
    /// as `name=command` would name the server after half a URL and truncate
    /// the command to the key's value.
    #[test]
    fn a_url_with_equals_in_a_query_param_is_not_a_name_prefix() {
        let url = "https://mcp.example.com/mcp/?apiKey=test-key";
        let (name, command) = parse_extra_mcp_entry(url);
        assert_eq!(command, url, "the whole URL is the command");
        assert_eq!(name, "mcp-example-com", "named after the host");
    }

    /// The derived name reaches logs and telemetry, so it must not be able to
    /// carry a secret — and the last path segment of an MCP URL routinely is
    /// one.
    #[test]
    fn a_derived_name_never_carries_url_credentials() {
        for (url, expected) in [
            (
                "https://mcp.example.com/mcp/?apiKey=super-secret",
                "mcp-example-com",
            ),
            (
                "https://user:super-secret@mcp.example.com/mcp",
                "mcp-example-com",
            ),
            (
                "http://127.0.0.1:8080/mcp?token=super-secret",
                "127-0-0-1-8080",
            ),
        ] {
            let (name, _) = parse_extra_mcp_entry(url);
            assert_eq!(name, expected, "for {url}");
            assert!(
                !name.contains("super-secret"),
                "{url} leaked its credential into the server name: {name}"
            );
            assert!(
                is_valid_server_name(&name),
                "{url} derived a name the explicit syntax would reject: {name}"
            );
        }
    }

    #[test]
    fn a_local_path_is_still_named_after_its_file_stem() {
        assert_eq!(
            mcp_server_name("/opt/tools/hindsight-mcp.js"),
            "hindsight-mcp"
        );
        assert_eq!(mcp_server_name(""), "mcp", "nothing usable falls back");
    }

    /// An explicit name is what makes a server's identity independent of its
    /// position in the list: a derived name shifts when entries are reordered,
    /// silently renaming the server and taking its tools away from the agent.
    #[test]
    fn explicit_names_are_stable_across_reordering() {
        let memory = "memory=/opt/memory-mcp.js";
        let search = "search=/opt/search-mcp.js";
        let forward = [parse_extra_mcp_entry(memory), parse_extra_mcp_entry(search)];
        let reversed = [parse_extra_mcp_entry(search), parse_extra_mcp_entry(memory)];
        assert_eq!(forward[0].0, "memory");
        assert_eq!(forward[1].0, "search");
        assert_eq!(reversed[0].0, "search");
        assert_eq!(reversed[1].0, "memory");
    }

    #[test]
    fn a_left_side_that_cannot_be_a_server_name_stays_part_of_the_command() {
        for entry in [
            "not a name=/opt/server.js",
            "quote\"=/opt/server.js",
            "a/b=/opt/server.js",
        ] {
            let (name, command) = parse_extra_mcp_entry(entry);
            assert_eq!(command, entry, "{entry} must be taken whole as a command");
            assert!(
                !name.contains('=') && !name.contains('/'),
                "{entry} derived an unusable name: {name}"
            );
        }
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
