//! Text that came from an issue or a reader is shown, never trusted. These are
//! the only functions that put such text into a tracker body, a comment or a
//! file name.

use std::sync::LazyLock;

use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};
use regex::Regex;

static INVISIBLE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\p{Cc}\p{Cf}]+").expect("a fixed pattern"));
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").expect("a fixed pattern"));
static BACKTICKS: LazyLock<Regex> = LazyLock::new(|| Regex::new("`+").expect("a fixed pattern"));

/// A zero-width space after "@" keeps "@name" from notifying anyone.
const AT: &str = "@\u{200B}";

/// At most `max` characters, with "..." marking a cut.
pub fn truncate(s: &str, max: usize) -> String {
    match s.char_indices().nth(max) {
        Some((cut, _)) => format!("{}...", &s[..cut]),
        None => s.to_string(),
    }
}

/// One line of prose for a tracker: no control or invisible characters,
/// nothing that opens an HTML comment, a code span or a link, and no "@name"
/// that would notify someone.
pub fn clean(s: &str, max: usize) -> String {
    let s = INVISIBLE.replace_all(s, " ");
    let s = SPACES.replace_all(&s, " ");
    truncate(&defuse(s.trim_matches(' ')), max)
}

/// No HTML, no code span, no link and no mention. The backslash is escaped
/// first: text that brings its own would otherwise turn the escape before "["
/// into an escaped backslash and a live bracket.
fn defuse(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('<', "&lt;")
        .replace('`', "'")
        .replace('[', "\\[")
        .replace('@', AT)
}

/// One line shown as code: backticks inside become apostrophes, so the span
/// cannot be closed early.
pub fn code(s: &str, max: usize) -> String {
    let s = INVISIBLE.replace_all(s, " ").replace('`', "'");
    format!("`{}`", truncate(&s, max))
}

/// Text kept at full length (a commit subject or a note in a closing comment):
/// control and invisible characters out, no HTML, no code span, no link, no
/// mention.
pub fn safe(s: &str) -> String {
    defuse(&INVISIBLE.replace_all(s, " "))
}

/// A code span that holds `s` exactly: fenced by one more backtick than the
/// longest run inside, and padded when `s` starts or ends with one.
pub fn span(s: &str) -> String {
    let longest = BACKTICKS.find_iter(s).map(|m| m.len()).max().unwrap_or(0);
    let fence = "`".repeat(longest + 1);
    let pad = if s.starts_with('`') || s.ends_with('`') {
        " "
    } else {
        ""
    };
    format!("{fence}{pad}{s}{pad}{fence}")
}

/// An issue or PR number: digits only, no sign, no leading zero.
pub fn parse_number(s: &str) -> Option<u64> {
    let digits = !s.is_empty() && !s.starts_with('0') && s.bytes().all(|b| b.is_ascii_digit());
    if digits { s.parse().ok() } else { None }
}

/// How a quoted line is compared with a line of the file: tabs are spaces,
/// runs of spaces are one, and the ends are trimmed. Indentation and alignment
/// changes do not make a quote wrong.
pub fn norm_quote(s: &str) -> String {
    s.replace('\t', " ")
        .split(' ')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whether `s` names a file inside the repo: not empty, not absolute, not an
/// option, and no empty, "." or ".." part. `Err` says why not. Every path a
/// reader or a session names goes through this before git or a queue sees it.
pub fn repo_path(s: &str) -> Result<(), &'static str> {
    if s.is_empty() || s.starts_with(['/', '-']) || s.split('/').any(|part| matches!(part, "" | "." | "..")) {
        return Err("is not a repo-relative path");
    }
    if s.chars().any(char::is_control) {
        return Err("has a control character in its path");
    }
    Ok(())
}

pub fn sha7(sha: &str) -> &str {
    sha.get(..7).unwrap_or(sha)
}

/// "1 unit", "2 units".
pub fn count(n: usize, word: &str) -> String {
    format!("{n} {word}{}", if n == 1 { "" } else { "s" })
}

const SEGMENT: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'_').remove(b'.').remove(b'~');

/// One path segment of a URL.
pub fn uri_segment(s: &str) -> String {
    utf8_percent_encode(s, SEGMENT).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_defuses_markup_and_mentions() {
        assert_eq!(
            clean("  a\tb\n<!-- x --> `c` [d](e) @f  ", 80),
            "a b &lt;!-- x --> 'c' \\[d](e) @\u{200B}f"
        );
    }

    #[test]
    fn a_backslash_in_the_text_cannot_undo_the_escape() {
        // "\[x](u)" once came out as "\\[x](u)": an escaped backslash, then a link.
        assert_eq!(clean("\\[x](u)", 80), "\\\\\\[x](u)");
        assert_eq!(safe("\\[x](u)"), "\\\\\\[x](u)");
    }

    #[test]
    fn safe_text_opens_no_link_span_or_mention() {
        assert_eq!(
            safe("fix [a](http://x) `b` <i> @c\u{7}d"),
            "fix \\[a](http://x) 'b' &lt;i> @\u{200B}c d"
        );
    }

    #[test]
    fn clean_drops_invisible_characters() {
        assert_eq!(clean("a\u{200B}\u{202E}b\u{0007}", 80), "a b");
    }

    #[test]
    fn truncation_counts_characters_not_bytes() {
        assert_eq!(clean("ééééé", 3), "ééé...");
        assert_eq!(clean("ééé", 3), "ééé");
    }

    #[test]
    fn code_cannot_be_closed_from_inside() {
        assert_eq!(code("a`b\nc", 80), "`a'b c`");
    }

    #[test]
    fn span_outnumbers_the_backticks_inside() {
        assert_eq!(span("a"), "`a`");
        assert_eq!(span("a``b"), "```a``b```");
        assert_eq!(span("`a"), "`` `a ``");
    }

    #[test]
    fn a_number_is_digits_only() {
        assert_eq!(parse_number("42"), Some(42));
        for bad in [
            "",
            "0",
            "042",
            "-1",
            "+1",
            "4 2",
            "4.2",
            "#42",
            "99999999999999999999999",
        ] {
            assert_eq!(parse_number(bad), None, "{bad}");
        }
    }

    #[test]
    fn a_repo_path_stays_inside_the_repo() {
        for good in ["a", "src/a.ts", ".github/workflows/ci.yml", "a..b/c", "src/-x"] {
            assert_eq!(repo_path(good), Ok(()), "{good}");
        }
        for bad in ["", "/a", "-a", "..", "a/../b", "./a", "a/./b", "a//b", "a/", "a/.."] {
            assert_eq!(repo_path(bad), Err("is not a repo-relative path"), "{bad}");
        }
        assert_eq!(repo_path("a\u{7}b"), Err("has a control character in its path"));
        assert_eq!(repo_path("a\nb"), Err("has a control character in its path"));
    }

    #[test]
    fn quotes_compare_without_their_spacing() {
        assert_eq!(norm_quote("\t\treturn  a +\tb;  "), "return a + b;");
    }

    #[test]
    fn count_knows_one_from_many() {
        assert_eq!(count(1, "closure"), "1 closure");
        assert_eq!(count(0, "unit"), "0 units");
    }

    #[test]
    fn a_url_segment_keeps_only_unreserved_characters() {
        assert_eq!(uri_segment("src/a b.ts"), "src%2Fa%20b.ts");
        assert_eq!(uri_segment("a-b_c.d~e"), "a-b_c.d~e");
    }
}
