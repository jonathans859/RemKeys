/// What live typing has to send to turn the text the PC already has
/// (`old`) into the field's new text (`new`).
///
/// The diff is a common prefix. That covers what actually happens: characters
/// added at the end, and characters backspaced off the end. The rare third
/// case, an edit in the middle, is handled by deleting back to the edit and
/// re-typing the rest.
///
/// Compared by `Character` (grapheme cluster), because that is what one
/// Backspace deletes on Windows and what the typing path sends one at a time.
/// So a combining mark or emoji modifier that joins the last character
/// (e + ◌́ → é, 👍 → 👍🏽) costs one Backspace and re-types the whole new
/// character. Walked by hand, rather than with Foundation's
/// `commonPrefix(with:)`, so the rule is explicit and tested here.
public struct LiveTypingDiff: Equatable {
    /// How many Backspaces to send first.
    public let backspaces: Int
    /// What to type after them.
    public let typed: Substring

    public init(from old: String, to new: String) {
        var oldIndex = old.startIndex
        var newIndex = new.startIndex
        while oldIndex < old.endIndex, newIndex < new.endIndex,
              old[oldIndex] == new[newIndex] {
            old.formIndex(after: &oldIndex)
            new.formIndex(after: &newIndex)
        }
        backspaces = old[oldIndex...].count
        typed = new[newIndex...]
    }

    public var isEmpty: Bool { backspaces == 0 && typed.isEmpty }
}
