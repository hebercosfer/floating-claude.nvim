---
description: Propose a trivial, reversible edit to visually check the float's minimize/restore around a diff. Cleans itself up if accepted.
---

Propose ONE trivial, obviously-reversible edit for a manual visual test of
floating-claude.nvim: whether the float minimizes to the corner while this
diff is open, and restores once the diff is resolved and its tab is closed.

Target: the first line of README.md. Add exactly this line right after it,
and nothing else:

    <!-- manual test: reject me -->

Propose that edit and stop. Don't explain the mechanism, don't touch anything
else, don't ask a clarifying question first.

- If it's denied: nothing further to do, the diff leaves no trace in the file.
- If it's accepted: as your very next message, propose removing that exact
  line again, as a fresh edit, so README.md ends up clean either way. Don't
  wait to be asked, and don't add anything else while you're there.
