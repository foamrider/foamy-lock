//! Tests only. Tests that start processes take a [`Shared`] guard; a test
//! that must not have a fork in flight takes the [`Alone`] guard (a child
//! between fork and exec keeps a copy of every descriptor, so a `flock`
//! dropped and taken again in that window looks held). Unlike an `RwLock`,
//! a shared guard never waits while its thread already holds one, so a test
//! may hold several.

use std::sync::{Condvar, Mutex, MutexGuard};

/// (shared holders, alone held)
static STATE: Mutex<(usize, bool)> = Mutex::new((0, false));
static CHANGED: Condvar = Condvar::new();

fn state() -> MutexGuard<'static, (usize, bool)> {
    STATE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn wait(guard: MutexGuard<'static, (usize, bool)>) -> MutexGuard<'static, (usize, bool)> {
    CHANGED
        .wait(guard)
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub struct Shared(());

impl Shared {
    /// Waits only while an `Alone` guard is held, which never happens while
    /// any `Shared` one is.
    pub fn take() -> Shared {
        let mut guard = state();
        while guard.1 {
            guard = wait(guard);
        }
        guard.0 += 1;
        Shared(())
    }
}

impl Drop for Shared {
    fn drop(&mut self) {
        state().0 -= 1;
        CHANGED.notify_all();
    }
}

pub struct Alone(());

impl Alone {
    pub fn take() -> Alone {
        let mut guard = state();
        while guard.0 > 0 || guard.1 {
            guard = wait(guard);
        }
        guard.1 = true;
        Alone(())
    }
}

impl Drop for Alone {
    fn drop(&mut self) {
        state().1 = false;
        CHANGED.notify_all();
    }
}
