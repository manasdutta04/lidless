//! Lidless core: the behaviour shared by every platform (spec/).
//! Platform crates implement [`engine::Engine`]; the CLI and tray app drive
//! [`owner::SessionOwner`], [`recovery`] and [`control`] through it.

pub mod agents;
pub mod cli;
pub mod control;
pub mod duration;
pub mod engine;
pub mod error;
pub mod floors;
pub mod history;
pub mod log;
pub mod model;
pub mod notify;
pub mod owner;
pub mod paths;
pub mod process;
pub mod recovery;
pub mod status;
pub mod store;
pub mod testing;
pub mod update;

pub use error::{LidlessError, Result};
pub use update::VERSION;
