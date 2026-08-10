//! Discovery of Buzz channel declarations in local repository checkouts.
//!
//! Repositories opt in with `.buzz/workspace.json`. Discovery is intentionally
//! independent from ACP session creation: this module owns root resolution,
//! containment checks, conflict handling, caching, and diagnostics only.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Deserialize;
use thiserror::Error;
use uuid::Uuid;

/// Explicit checkout roots, separated by `:` on the supported Unix hosts.
pub const REPOS_ROOTS_ENV: &str = "BUZZ_ACP_REPOS_ROOTS";

const WORKSPACE_DECLARATION: &str = ".buzz/workspace.json";

/// How long a channel known to be absent stays negatively cached.
///
/// Thirty seconds bounds filesystem discovery for undeclared channels (including
/// the DM/root-mode cases introduced in the next phase) to two scans per minute
/// per channel, while keeping the delay after adding a declaration short enough
/// for an operator to retry without restarting the harness.
pub const NEGATIVE_CACHE_WINDOW: Duration = Duration::from_secs(30);

/// A rejected root, repository, declaration, channel entry, or conflict.
///
/// Discovery is best-effort: errors are logged and excluded from the resulting
/// index rather than aborting the harness. Every diagnostic names the roots the
/// scan was configured to inspect so an operator can fix the right checkout.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum WorkspaceIndexError {
    #[error(
        "cannot resolve the default Buzz repositories root because HOME is unavailable; \
         set {REPOS_ROOTS_ENV} to one or more absolute paths (configured roots: {roots})"
    )]
    HomeUnavailable { roots: String },

    #[error(
        "repository root `{root}` is not absolute; every {REPOS_ROOTS_ENV} entry must be an \
         absolute path (configured roots: {roots})"
    )]
    RootNotAbsolute { root: PathBuf, roots: String },

    #[error("cannot canonicalize repository root `{root}`: {reason} (configured roots: {roots})")]
    RootCanonicalize {
        root: PathBuf,
        reason: String,
        roots: String,
    },

    #[error("repository root `{root}` is not a directory (configured roots: {roots})")]
    RootNotDirectory { root: PathBuf, roots: String },

    #[error("cannot enumerate repository root `{root}`: {reason} (roots scanned: {roots})")]
    RootRead {
        root: PathBuf,
        reason: String,
        roots: String,
    },

    #[error(
        "cannot canonicalize repository candidate `{repository}` under `{root}`: {reason} \
         (roots scanned: {roots})"
    )]
    RepositoryCanonicalize {
        repository: PathBuf,
        root: PathBuf,
        reason: String,
        roots: String,
    },

    #[error(
        "repository candidate `{repository}` canonicalized to `{canonical}`, outside root \
         `{root}`; entry rejected (roots scanned: {roots})"
    )]
    RepositoryOutsideRoot {
        repository: PathBuf,
        canonical: PathBuf,
        root: PathBuf,
        roots: String,
    },

    #[error(
        "cannot read workspace declaration `{declaration}` for repository `{repository}`: \
         {reason} (roots scanned: {roots})"
    )]
    DeclarationRead {
        declaration: PathBuf,
        repository: PathBuf,
        reason: String,
        roots: String,
    },

    #[error(
        "invalid workspace JSON `{declaration}` for repository `{repository}`: {reason} \
         (roots scanned: {roots})"
    )]
    DeclarationJson {
        declaration: PathBuf,
        repository: PathBuf,
        reason: String,
        roots: String,
    },

    #[error(
        "workspace declaration `{declaration}` for repository `{repository}` has no \
         `channels` array (roots scanned: {roots})"
    )]
    ChannelsMissing {
        declaration: PathBuf,
        repository: PathBuf,
        roots: String,
    },

    #[error(
        "workspace declaration `{declaration}` for repository `{repository}` has an empty \
         `channels` array (roots scanned: {roots})"
    )]
    ChannelsEmpty {
        declaration: PathBuf,
        repository: PathBuf,
        roots: String,
    },

    #[error(
        "workspace declaration `{declaration}` for repository `{repository}` contains invalid \
         channel UUID `{channel}`; that entry was rejected (roots scanned: {roots})"
    )]
    InvalidChannel {
        channel: String,
        declaration: PathBuf,
        repository: PathBuf,
        roots: String,
    },

    #[error(
        "channel `{channel}` is declared by multiple repositories [{repositories}]; all sides \
         were rejected instead of choosing by scan order (roots scanned: {roots})"
    )]
    ChannelConflict {
        channel: Uuid,
        repositories: String,
        roots: String,
    },
}

impl WorkspaceIndexError {
    fn log(&self) {
        match self {
            Self::RepositoryOutsideRoot { .. } | Self::ChannelConflict { .. } => {
                tracing::error!(error = %self, "workspace index rejected entry");
            }
            _ => tracing::warn!(error = %self, "workspace index skipped invalid input"),
        }
    }
}

#[derive(Debug, Deserialize)]
struct WorkspaceDeclaration {
    // No `deny_unknown_fields`: newer writers may add metadata without making
    // their declarations unreadable by this version.
    channels: Option<Vec<String>>,
}

trait WorkspaceFilesystem {
    fn canonicalize(&self, path: &Path) -> std::io::Result<PathBuf>;
    fn is_dir(&self, path: &Path) -> bool;
    fn read_dir(&self, path: &Path) -> std::io::Result<Vec<PathBuf>>;
    fn read_to_string(&self, path: &Path) -> std::io::Result<String>;
}

#[derive(Clone, Copy)]
struct RealFilesystem;

impl WorkspaceFilesystem for RealFilesystem {
    fn canonicalize(&self, path: &Path) -> std::io::Result<PathBuf> {
        path.canonicalize()
    }

    fn is_dir(&self, path: &Path) -> bool {
        path.is_dir()
    }

    fn read_dir(&self, path: &Path) -> std::io::Result<Vec<PathBuf>> {
        std::fs::read_dir(path)?
            .map(|entry| entry.map(|entry| entry.path()))
            .collect()
    }

    fn read_to_string(&self, path: &Path) -> std::io::Result<String> {
        std::fs::read_to_string(path)
    }
}

#[derive(Clone, Debug)]
struct DiscoverySource {
    roots_env: Option<String>,
    home_dir: Option<PathBuf>,
}

impl DiscoverySource {
    fn from_process() -> Self {
        Self {
            roots_env: std::env::var_os(REPOS_ROOTS_ENV)
                .map(|value| value.to_string_lossy().into_owned()),
            home_dir: std::env::var_os("HOME").map(PathBuf::from),
        }
    }

    fn configured_roots(&self) -> Result<Vec<PathBuf>, WorkspaceIndexError> {
        if let Some(raw) = &self.roots_env {
            // An explicitly-set empty value is an invalid explicit root, not a
            // request to silently fall back to HOME.
            return Ok(raw.split(':').map(PathBuf::from).collect());
        }

        self.home_dir
            .as_ref()
            .map(|home| vec![home.join(".buzz").join("REPOS")])
            .ok_or_else(|| WorkspaceIndexError::HomeUnavailable {
                roots: "[]".to_string(),
            })
    }
}

#[derive(Default)]
struct Discovery {
    channels: BTreeMap<Uuid, PathBuf>,
    roots: Vec<PathBuf>,
    errors: Vec<WorkspaceIndexError>,
}

fn display_paths<'a>(paths: impl IntoIterator<Item = &'a PathBuf>) -> String {
    let values = paths
        .into_iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>();
    format!("[{}]", values.join(", "))
}

/// Pure discovery core: environment values and filesystem access are supplied
/// by the caller, so tests never mutate process-global environment state.
fn discover_with(source: &DiscoverySource, fs: &impl WorkspaceFilesystem) -> Discovery {
    let mut discovery = Discovery::default();
    let configured_roots = match source.configured_roots() {
        Ok(roots) => roots,
        Err(error) => {
            discovery.errors.push(error);
            return discovery;
        }
    };
    let configured_roots_display = display_paths(&configured_roots);

    let mut canonical_roots = BTreeSet::new();
    for root in &configured_roots {
        if !root.is_absolute() {
            discovery.errors.push(WorkspaceIndexError::RootNotAbsolute {
                root: root.clone(),
                roots: configured_roots_display.clone(),
            });
            continue;
        }
        let canonical = match fs.canonicalize(root) {
            Ok(path) => path,
            Err(error) => {
                discovery
                    .errors
                    .push(WorkspaceIndexError::RootCanonicalize {
                        root: root.clone(),
                        reason: error.to_string(),
                        roots: configured_roots_display.clone(),
                    });
                continue;
            }
        };
        if !fs.is_dir(&canonical) {
            discovery
                .errors
                .push(WorkspaceIndexError::RootNotDirectory {
                    root: canonical,
                    roots: configured_roots_display.clone(),
                });
            continue;
        }
        canonical_roots.insert(canonical);
    }
    discovery.roots = canonical_roots.into_iter().collect();
    let scanned_roots_display = display_paths(&discovery.roots);

    let mut seen_repositories = BTreeSet::new();
    let mut candidates: BTreeMap<Uuid, BTreeSet<PathBuf>> = BTreeMap::new();

    for root in &discovery.roots {
        let mut entries = match fs.read_dir(root) {
            Ok(entries) => entries,
            Err(error) => {
                discovery.errors.push(WorkspaceIndexError::RootRead {
                    root: root.clone(),
                    reason: error.to_string(),
                    roots: scanned_roots_display.clone(),
                });
                continue;
            }
        };
        entries.sort();

        for entry in entries {
            // Ordinary files directly under a repos root are not repository
            // candidates. `is_dir` follows symlinks, allowing the containment
            // check below to explicitly reject directory links that escape.
            if !fs.is_dir(&entry) {
                continue;
            }
            let repository = match fs.canonicalize(&entry) {
                Ok(path) => path,
                Err(error) => {
                    discovery
                        .errors
                        .push(WorkspaceIndexError::RepositoryCanonicalize {
                            repository: entry,
                            root: root.clone(),
                            reason: error.to_string(),
                            roots: scanned_roots_display.clone(),
                        });
                    continue;
                }
            };
            if !repository.starts_with(root) {
                discovery
                    .errors
                    .push(WorkspaceIndexError::RepositoryOutsideRoot {
                        repository: entry,
                        canonical: repository,
                        root: root.clone(),
                        roots: scanned_roots_display.clone(),
                    });
                continue;
            }
            // Overlapping or duplicate roots can expose the same canonical
            // checkout twice. It is one repository, not a channel conflict.
            if !seen_repositories.insert(repository.clone()) {
                continue;
            }

            let declaration_path = repository.join(WORKSPACE_DECLARATION);
            let contents = match fs.read_to_string(&declaration_path) {
                Ok(contents) => contents,
                Err(error) if error.kind() == ErrorKind::NotFound => continue,
                Err(error) => {
                    discovery.errors.push(WorkspaceIndexError::DeclarationRead {
                        declaration: declaration_path,
                        repository,
                        reason: error.to_string(),
                        roots: scanned_roots_display.clone(),
                    });
                    continue;
                }
            };
            let declaration: WorkspaceDeclaration = match serde_json::from_str(&contents) {
                Ok(declaration) => declaration,
                Err(error) => {
                    discovery.errors.push(WorkspaceIndexError::DeclarationJson {
                        declaration: declaration_path,
                        repository,
                        reason: error.to_string(),
                        roots: scanned_roots_display.clone(),
                    });
                    continue;
                }
            };
            let channels = match declaration.channels {
                Some(channels) if channels.is_empty() => {
                    discovery.errors.push(WorkspaceIndexError::ChannelsEmpty {
                        declaration: declaration_path,
                        repository,
                        roots: scanned_roots_display.clone(),
                    });
                    continue;
                }
                Some(channels) => channels,
                None => {
                    discovery.errors.push(WorkspaceIndexError::ChannelsMissing {
                        declaration: declaration_path,
                        repository,
                        roots: scanned_roots_display.clone(),
                    });
                    continue;
                }
            };

            for raw_channel in channels {
                match raw_channel.parse::<Uuid>() {
                    Ok(channel) => {
                        candidates
                            .entry(channel)
                            .or_default()
                            .insert(repository.clone());
                    }
                    Err(_) => discovery.errors.push(WorkspaceIndexError::InvalidChannel {
                        channel: raw_channel,
                        declaration: declaration_path.clone(),
                        repository: repository.clone(),
                        roots: scanned_roots_display.clone(),
                    }),
                }
            }
        }
    }

    for (channel, repositories) in candidates {
        if repositories.len() == 1 {
            discovery.channels.insert(
                channel,
                repositories
                    .into_iter()
                    .next()
                    .expect("length checked above"),
            );
        } else {
            discovery.errors.push(WorkspaceIndexError::ChannelConflict {
                channel,
                repositories: display_paths(&repositories),
                roots: scanned_roots_display.clone(),
            });
        }
    }

    discovery
}

type Rebuilder = Box<dyn FnMut() -> Discovery + Send>;
type Clock = Box<dyn Fn() -> Instant + Send + Sync>;
type DirectoryCheck = Box<dyn Fn(&Path) -> bool + Send + Sync>;

struct WorkspaceIndexState {
    channels: BTreeMap<Uuid, PathBuf>,
    roots: Vec<PathBuf>,
    negative_cache: BTreeMap<Uuid, Instant>,
    rebuild: Rebuilder,
}

/// Cached channel-to-repository index.
///
/// The index is built at construction. Lookups use interior mutability so one
/// index can be shared by every harness task. A miss performs at most one full
/// rebuild per channel per [`NEGATIVE_CACHE_WINDOW`]. Cached paths are checked
/// before use so session rotation refuses a repository removed after startup.
pub struct WorkspaceIndex {
    state: Mutex<WorkspaceIndexState>,
    negative_cache_window: Duration,
    clock: Clock,
    is_directory: DirectoryCheck,
}

impl fmt::Debug for WorkspaceIndex {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        formatter
            .debug_struct("WorkspaceIndex")
            .field("channels", &state.channels)
            .field("roots", &state.roots)
            .field("negative_cache_window", &self.negative_cache_window)
            .finish_non_exhaustive()
    }
}

impl WorkspaceIndex {
    /// Build an index from the real process environment and filesystem.
    pub fn from_env() -> Self {
        let source = DiscoverySource::from_process();
        Self::with_components(
            move || discover_with(&source, &RealFilesystem),
            NEGATIVE_CACHE_WINDOW,
            Instant::now,
            Path::is_dir,
        )
    }

    #[cfg(test)]
    fn with_rebuilder(rebuild: impl FnMut() -> Discovery + Send + 'static) -> Self {
        Self::with_components(rebuild, NEGATIVE_CACHE_WINDOW, Instant::now, |_| true)
    }

    fn with_components(
        rebuild: impl FnMut() -> Discovery + Send + 'static,
        negative_cache_window: Duration,
        clock: impl Fn() -> Instant + Send + Sync + 'static,
        is_directory: impl Fn(&Path) -> bool + Send + Sync + 'static,
    ) -> Self {
        let index = Self {
            state: Mutex::new(WorkspaceIndexState {
                channels: BTreeMap::new(),
                roots: Vec::new(),
                negative_cache: BTreeMap::new(),
                rebuild: Box::new(rebuild),
            }),
            negative_cache_window,
            clock: Box::new(clock),
            is_directory: Box::new(is_directory),
        };
        index.rebuild("built");
        index
    }

    #[cfg(test)]
    pub(crate) fn from_test_channels(
        channels: BTreeMap<Uuid, PathBuf>,
        is_directory: impl Fn(&Path) -> bool + Send + Sync + 'static,
    ) -> Self {
        Self::with_components(
            move || Discovery {
                channels: channels.clone(),
                roots: Vec::new(),
                errors: Vec::new(),
            },
            NEGATIVE_CACHE_WINDOW,
            Instant::now,
            is_directory,
        )
    }

    /// Return the canonical repository path for `channel_id`.
    ///
    /// On a cache miss, discovery is rerun once before absence is reported,
    /// unless that channel was already absent within the negative-cache window.
    pub fn lookup(&self, channel_id: Uuid) -> Option<PathBuf> {
        let now = (self.clock)();
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());

        if let Some(path) = state.channels.get(&channel_id) {
            if (self.is_directory)(path) {
                return Some(path.clone());
            }
            tracing::warn!(
                channel = %channel_id,
                repository = %path.display(),
                "workspace index cached repository disappeared; rebuilding"
            );
        }

        if state
            .negative_cache
            .get(&channel_id)
            .is_some_and(|cached_at| {
                now.saturating_duration_since(*cached_at) < self.negative_cache_window
            })
        {
            tracing::debug!(
                channel = %channel_id,
                window_seconds = self.negative_cache_window.as_secs(),
                "workspace index negative-cache hit"
            );
            return None;
        }

        tracing::info!(
            channel = %channel_id,
            roots = %display_paths(&state.roots),
            window_seconds = self.negative_cache_window.as_secs(),
            "workspace index cache miss; rebuilding once per negative-cache window"
        );
        Self::rebuild_locked(&mut state, "rebuilt after cache miss");

        let resolved = state
            .channels
            .get(&channel_id)
            .filter(|path| (self.is_directory)(path))
            .cloned();
        if resolved.is_some() {
            state.negative_cache.remove(&channel_id);
        } else {
            // Start the quiet window after discovery finishes, not before it;
            // a slow scan must not consume its own negative-cache interval.
            state.negative_cache.insert(channel_id, (self.clock)());
        }
        resolved
    }

    /// Number of channels currently mapped without conflicts.
    pub fn channel_count(&self) -> usize {
        self.state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .channels
            .len()
    }

    /// Number of canonical repositories represented in the current index.
    pub fn repository_count(&self) -> usize {
        self.state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .channels
            .values()
            .collect::<BTreeSet<_>>()
            .len()
    }

    fn rebuild(&self, action: &str) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        Self::rebuild_locked(&mut state, action);
    }

    fn rebuild_locked(state: &mut WorkspaceIndexState, action: &str) {
        let discovery = (state.rebuild)();
        for error in &discovery.errors {
            error.log();
        }
        state.channels = discovery.channels;
        state.roots = discovery.roots;

        let mappings = state
            .channels
            .iter()
            .map(|(channel, path)| format!("{channel} → {}", path.display()))
            .collect::<Vec<_>>()
            .join(", ");
        tracing::info!(
            repositories = state.channels.values().collect::<BTreeSet<_>>().len(),
            channels = state.channels.len(),
            roots = %display_paths(&state.roots),
            mappings = %format!("[{mappings}]"),
            "workspace index {action}"
        );
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, VecDeque};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    use super::*;

    const CHANNEL_A: &str = "4659175a-4ff6-478c-be9a-b646f938eb8e";
    const CHANNEL_B: &str = "99560936-0e46-4868-a0c6-0c90ca955e5d";

    fn source_for(roots: &[&Path]) -> DiscoverySource {
        DiscoverySource {
            roots_env: Some(
                roots
                    .iter()
                    .map(|root| root.display().to_string())
                    .collect::<Vec<_>>()
                    .join(":"),
            ),
            home_dir: None,
        }
    }

    fn repository(root: &Path, name: &str, json: &str) -> PathBuf {
        let repository = root.join(name);
        std::fs::create_dir_all(repository.join(".buzz")).expect("create declaration directory");
        std::fs::write(repository.join(WORKSPACE_DECLARATION), json)
            .expect("write workspace declaration");
        repository.canonicalize().expect("canonical repository")
    }

    fn discover(roots: &[&Path]) -> Discovery {
        discover_with(&source_for(roots), &RealFilesystem)
    }

    #[test]
    fn discovers_one_channel_and_multiple_channels_per_repository() {
        let temp = tempfile::tempdir().expect("temporary root");
        let one = repository(
            temp.path(),
            "one",
            &format!(r#"{{"channels":["{CHANNEL_A}"]}}"#),
        );
        let multiple = repository(
            temp.path(),
            "multiple",
            &format!(r#"{{"channels":["{CHANNEL_B}","{}"]}}"#, Uuid::nil()),
        );

        let result = discover(&[temp.path()]);

        assert_eq!(result.channels[&Uuid::parse_str(CHANNEL_A).unwrap()], one);
        assert_eq!(
            result.channels[&Uuid::parse_str(CHANNEL_B).unwrap()],
            multiple
        );
        assert_eq!(result.channels[&Uuid::nil()], multiple);
        assert!(result.errors.is_empty());
    }

    #[test]
    fn rejects_every_repository_in_a_channel_conflict() {
        let temp = tempfile::tempdir().expect("temporary root");
        let first = repository(
            temp.path(),
            "first",
            &format!(r#"{{"channels":["{CHANNEL_A}"]}}"#),
        );
        let second = repository(
            temp.path(),
            "second",
            &format!(r#"{{"channels":["{CHANNEL_A}"]}}"#),
        );

        let result = discover(&[temp.path()]);

        assert!(!result
            .channels
            .contains_key(&Uuid::parse_str(CHANNEL_A).unwrap()));
        let conflict = result
            .errors
            .iter()
            .find(|error| matches!(error, WorkspaceIndexError::ChannelConflict { .. }))
            .expect("conflict diagnostic");
        let message = conflict.to_string();
        assert!(message.contains(&first.display().to_string()));
        assert!(message.contains(&second.display().to_string()));
    }

    #[test]
    fn reports_malformed_missing_empty_and_invalid_channels_independently() {
        let temp = tempfile::tempdir().expect("temporary root");
        repository(temp.path(), "malformed", "{");
        repository(temp.path(), "missing", r#"{"metadata":"newer writer"}"#);
        repository(temp.path(), "empty", r#"{"channels":[]}"#);
        let valid = repository(
            temp.path(),
            "invalid-entry",
            &format!(r#"{{"channels":["not-a-uuid","{CHANNEL_A}"]}}"#),
        );

        let result = discover(&[temp.path()]);

        assert_eq!(result.channels[&Uuid::parse_str(CHANNEL_A).unwrap()], valid);
        assert!(result
            .errors
            .iter()
            .any(|error| matches!(error, WorkspaceIndexError::DeclarationJson { .. })));
        assert!(result
            .errors
            .iter()
            .any(|error| matches!(error, WorkspaceIndexError::ChannelsMissing { .. })));
        assert!(result
            .errors
            .iter()
            .any(|error| matches!(error, WorkspaceIndexError::ChannelsEmpty { .. })));
        assert!(result.errors.iter().any(|error| matches!(
            error,
            WorkspaceIndexError::InvalidChannel { channel, .. } if channel == "not-a-uuid"
        )));
    }

    #[test]
    fn ignores_unknown_json_keys() {
        let temp = tempfile::tempdir().expect("temporary root");
        let repo = repository(
            temp.path(),
            "future-schema",
            &format!(r#"{{"channels":["{CHANNEL_A}"],"metadata":{{"version":2}},"tags":["x"]}}"#),
        );

        let result = discover(&[temp.path()]);

        assert_eq!(result.channels[&Uuid::parse_str(CHANNEL_A).unwrap()], repo);
        assert!(result.errors.is_empty());
    }

    #[test]
    fn silently_ignores_subdirectory_without_buzz_declaration() {
        let temp = tempfile::tempdir().expect("temporary root");
        std::fs::create_dir(temp.path().join("ordinary-repo")).expect("create ordinary repo");

        let result = discover(&[temp.path()]);

        assert!(result.channels.is_empty());
        assert!(result.errors.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn follows_and_canonicalizes_a_symlinked_root() {
        use std::os::unix::fs::symlink;

        let temp = tempfile::tempdir().expect("temporary parent");
        let real_root = temp.path().join("checkouts");
        std::fs::create_dir(&real_root).expect("create real root");
        let repo = repository(
            &real_root,
            "repo",
            &format!(r#"{{"channels":["{CHANNEL_A}"]}}"#),
        );
        let linked_root = temp.path().join("REPOS");
        symlink(&real_root, &linked_root).expect("symlink root");

        let result = discover(&[&linked_root]);

        assert_eq!(result.roots, vec![real_root.canonicalize().unwrap()]);
        assert_eq!(result.channels[&Uuid::parse_str(CHANNEL_A).unwrap()], repo);
        assert!(result.errors.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn rejects_repository_symlink_that_canonicalizes_outside_root() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().expect("temporary root");
        let outside = tempfile::tempdir().expect("outside repository parent");
        let outside_repo = repository(
            outside.path(),
            "escaped",
            &format!(r#"{{"channels":["{CHANNEL_A}"]}}"#),
        );
        let linked_repo = root.path().join("escaped");
        symlink(&outside_repo, &linked_repo).expect("symlink escaped repository");

        let result = discover(&[root.path()]);

        assert!(result.channels.is_empty());
        assert!(result.errors.iter().any(|error| matches!(
            error,
            WorkspaceIndexError::RepositoryOutsideRoot {
                repository,
                canonical,
                ..
            } if repository.file_name() == linked_repo.file_name() && canonical == &outside_repo
        )));
    }

    #[test]
    fn scans_multiple_roots_from_the_env_value() {
        let first = tempfile::tempdir().expect("first root");
        let second = tempfile::tempdir().expect("second root");
        let first_repo = repository(
            first.path(),
            "first",
            &format!(r#"{{"channels":["{CHANNEL_A}"]}}"#),
        );
        let second_repo = repository(
            second.path(),
            "second",
            &format!(r#"{{"channels":["{CHANNEL_B}"]}}"#),
        );

        let result = discover(&[first.path(), second.path()]);

        assert_eq!(
            result.channels[&Uuid::parse_str(CHANNEL_A).unwrap()],
            first_repo
        );
        assert_eq!(
            result.channels[&Uuid::parse_str(CHANNEL_B).unwrap()],
            second_repo
        );
        assert_eq!(result.roots.len(), 2);
        assert!(result.errors.is_empty());
    }

    #[test]
    fn cache_miss_performs_exactly_one_rebuild() {
        let channel = Uuid::parse_str(CHANNEL_A).unwrap();
        let expected = PathBuf::from("/tmp/repository-created-after-boot");
        let rebuilds = Arc::new(AtomicUsize::new(0));
        let results = Arc::new(Mutex::new(VecDeque::from([
            Discovery::default(),
            Discovery {
                channels: BTreeMap::from([(channel, expected.clone())]),
                roots: vec![PathBuf::from("/tmp")],
                errors: Vec::new(),
            },
        ])));
        let rebuild_count = Arc::clone(&rebuilds);
        let queued_results = Arc::clone(&results);

        let mut index = WorkspaceIndex::with_rebuilder(move || {
            rebuild_count.fetch_add(1, Ordering::SeqCst);
            queued_results
                .lock()
                .expect("result queue lock")
                .pop_front()
                .expect("one result per expected rebuild")
        });
        assert_eq!(rebuilds.load(Ordering::SeqCst), 1, "boot build");

        assert_eq!(index.lookup(channel), Some(expected.clone()));
        assert_eq!(rebuilds.load(Ordering::SeqCst), 2, "one miss rebuild");

        assert_eq!(index.lookup(channel), Some(expected));
        assert_eq!(
            rebuilds.load(Ordering::SeqCst),
            2,
            "cache hit does not rebuild"
        );
    }

    #[test]
    fn negative_cache_rebuilds_absent_channel_at_most_once_per_window() {
        let channel = Uuid::parse_str(CHANNEL_A).unwrap();
        let expected = PathBuf::from("/tmp/repository-created-later");
        let rebuilds = Arc::new(AtomicUsize::new(0));
        let now = Arc::new(Mutex::new(Instant::now()));
        let rebuild_count = Arc::clone(&rebuilds);
        let test_now = Arc::clone(&now);

        let index = WorkspaceIndex::with_components(
            move || {
                let rebuild = rebuild_count.fetch_add(1, Ordering::SeqCst);
                Discovery {
                    channels: (rebuild >= 2)
                        .then(|| BTreeMap::from([(channel, expected.clone())]))
                        .unwrap_or_default(),
                    roots: vec![PathBuf::from("/tmp")],
                    errors: Vec::new(),
                }
            },
            NEGATIVE_CACHE_WINDOW,
            move || *test_now.lock().expect("test clock lock"),
            |_| true,
        );
        assert_eq!(rebuilds.load(Ordering::SeqCst), 1, "boot build");

        assert_eq!(index.lookup(channel), None);
        assert_eq!(rebuilds.load(Ordering::SeqCst), 2, "first miss rebuild");

        assert_eq!(index.lookup(channel), None);
        assert_eq!(
            rebuilds.load(Ordering::SeqCst),
            2,
            "same-window miss is negatively cached"
        );

        *now.lock().expect("test clock lock") += NEGATIVE_CACHE_WINDOW;
        assert_eq!(
            index.lookup(channel),
            Some(PathBuf::from("/tmp/repository-created-later"))
        );
        assert_eq!(
            rebuilds.load(Ordering::SeqCst),
            3,
            "expired negative entry permits one new rebuild"
        );
    }
}
