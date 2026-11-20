//! `foamy-lock-helper studio login-screen …`: copying the lock look to the
//! SDDM login screen (docs/plans/lock-login-screen.md). Both subcommands
//! follow the `studio` contract in [`super`]: one JSON line on stdout.
//!
//! - `studio login-screen status`: see [`status`].
//! - `studio login-screen stage`: see [`stage`].

pub mod stage;
pub mod status;
