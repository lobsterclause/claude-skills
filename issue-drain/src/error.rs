//! One failure type for every command: a message for stderr and an exit code.
//!
//! The exit codes are the contract callers script against:
//!   2  bad arguments, a missing input file or a missing setting
//!   3  a rule refused the action
//!   1  GitHub, git or the filesystem failed
//!   4  only `merge-gate`: the merge call was accepted but the PR is not merged
//!      yet (a merge queue)

#[derive(Debug)]
pub struct Fail {
    pub code: u8,
    pub msg: String,
    /// The command already wrote its one line about this failure to stderr,
    /// so `main` prints nothing more.
    pub reported: bool,
}

pub type Res<T> = Result<T, Fail>;

impl Fail {
    pub fn usage(msg: impl Into<String>) -> Fail {
        Fail {
            code: 2,
            msg: msg.into(),
            reported: false,
        }
    }

    pub fn refused(msg: impl Into<String>) -> Fail {
        Fail {
            code: 3,
            msg: msg.into(),
            reported: false,
        }
    }

    pub fn queued(msg: impl Into<String>) -> Fail {
        Fail {
            code: 4,
            msg: msg.into(),
            reported: false,
        }
    }

    pub fn failed(msg: impl Into<String>) -> Fail {
        Fail {
            code: 1,
            msg: msg.into(),
            reported: false,
        }
    }
}
