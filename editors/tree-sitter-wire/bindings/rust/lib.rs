//! Rust binding for tree-sitter-wire.
//!
//! Exposes the compiled Wire grammar as a [`LanguageFn`] that downstream
//! crates can install on a [`tree_sitter::Parser`]. Queries ship alongside
//! the grammar as `&'static str` constants so consumers don't have to
//! re-read them from disk at runtime.

use tree_sitter_language::LanguageFn;

extern "C" {
    fn tree_sitter_wire() -> *const ();
}

/// The tree-sitter [`LanguageFn`] for Wire.
///
/// This can be installed on a parser with
/// `parser.set_language(&LANGUAGE.into())`.
pub const LANGUAGE: LanguageFn = unsafe { LanguageFn::from_raw(tree_sitter_wire) };

/// The syntax highlight query source.
pub const HIGHLIGHTS_QUERY: &str = include_str!("../../queries/highlights.scm");

/// The fold-range query source.
pub const FOLDS_QUERY: &str = include_str!("../../queries/folds.scm");

/// The indentation-rule query source.
pub const INDENTS_QUERY: &str = include_str!("../../queries/indents.scm");

#[cfg(test)]
mod tests {
    #[test]
    fn test_can_load_grammar() {
        let mut parser = tree_sitter::Parser::new();
        parser
            .set_language(&super::LANGUAGE.into())
            .expect("Error loading Wire parser");
    }
}
