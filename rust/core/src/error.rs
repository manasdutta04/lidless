use thiserror::Error;

/// Every user-facing failure, with the exit codes from spec/cli.md.
#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum LidlessError {
    #[error("{0}")]
    Usage(String),
    #[error("{0}")]
    NotReady(String),
    #[error("{0}")]
    VerificationFailed(String),
    #[error("No active Lidless session.")]
    NoSession,
    #[error("A Lidless session is already active. Use `lidless extend` to add time.")]
    SessionActive,
    #[error("{0}")]
    RestoreIncomplete(String),
    #[error("{0}")]
    System(String),
    #[error("Timed out waiting for the Lidless state lock. Another Lidless process may be stuck; see `lidless status`.")]
    LockTimeout,
}

impl LidlessError {
    pub fn exit_code(&self) -> i32 {
        match self {
            LidlessError::Usage(_) => 2,
            LidlessError::NotReady(_) => 3,
            LidlessError::VerificationFailed(_) => 4,
            LidlessError::NoSession => 5,
            LidlessError::SessionActive => 6,
            LidlessError::RestoreIncomplete(_) => 7,
            LidlessError::System(_) | LidlessError::LockTimeout => 1,
        }
    }

    pub fn system(context: impl Into<String>, err: impl std::fmt::Display) -> Self {
        LidlessError::System(format!("{}: {}", context.into(), err))
    }
}

impl From<std::io::Error> for LidlessError {
    fn from(e: std::io::Error) -> Self {
        LidlessError::System(e.to_string())
    }
}

impl From<serde_json::Error> for LidlessError {
    fn from(e: serde_json::Error) -> Self {
        LidlessError::System(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, LidlessError>;
