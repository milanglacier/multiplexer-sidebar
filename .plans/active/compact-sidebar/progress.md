# Progress

- [x] Plan written (`plan.md`).
- [x] `--compact` flag, `Options.compact` and `App.compact`.
- [x] `summary_status` and `STATUS_ORDER`.
- [x] Compact view: lists, columns, group bars, the row between the lists.
- [x] Key routing and closing open dialogs in the compact view.
- [x] Unit tests.
- [x] End-to-end tests.
- [x] README and `--help` text.

Notes:

- The plan's height split, `max(4, ...)`, does not fit a pane of 4 rows, so
  the Sessions list gets `max(1, min(h - 1, (h * 11 + 19) // 20))` rows and
  the Agents list always keeps at least one.
- `parse_args` sets `sidebar` when `--compact` is given, rather than
  `main`, so that a unit test can check it.
- Escape in a dialog and the compact view share `App.close_dialog`.
- Until the first draw, `App.width` is None, and only `--compact` makes the
  view compact.
