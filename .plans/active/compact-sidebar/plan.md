# Compact sidebar

## Problem Statement

The sidebar needs about 30 columns. That is a lot of room to keep open
beside my work all day, when most of the time I only want to know which
session needs me. herdr's sidebar has a compact mode
(`sidebar_collapsed_mode = "compact"`) that shrinks to a narrow strip with
a number and a status for each workspace. The dashboard has nothing like
it: below 24 columns the sidebar shows only "Make the window at least
24×10."

## Solution

A compact view of the sidebar, a few cells wide, that shows each session's
number and the status of its agents, and each agent's icon and status.

- `--compact` always shows the compact view, at any width. It implies
  `--sidebar`, so the dashboard stays open after a switch.
- `--sidebar` shows the compact view by itself when the pane is narrower
  than the full sidebar's minimum of 24 columns, and the full sidebar again
  when the pane is wide enough. The user resizes the pane with the
  multiplexer's own keys. The dashboard does not resize its own pane.
- The flag is named `--compact` and not `--collapsed`, because
  `--tabs collapsed` already means hidden tabs.

Example, with two zellij sessions and the tabs of the first one shown,
and one tmux session. The background marks the selected row, here tab 2:

```
━━━      zellij, in its color
1 ×      session 1: an agent is blocked
 1×      its tab 1 holds that agent
 2       tab 2, selected
 3◐      tab 3: an agent is working
2 ◐      session 2
━━━      tmux
1        no agents
         a blank row between the lists
━━━      zellij
✻ ×      an agent's icon and its status
◎ ◐
```

A session row takes three cells: the number, a space and the status. A tab
row puts its number in that space, one cell right of the session numbers,
so the status stays in the last column whether tabs show or not. An agent
row takes three cells too: the icon, a space and the status. A pane of 3
columns fits every row while there are fewer than 10 sessions and every
shown tab number has one digit.

## User Stories

Turning it on

1. As a user, I want `--compact` in my sidebar layout or binding, so that the sidebar always takes only a few columns.
2. As a user of `--sidebar`, I want a pane narrower than the full sidebar to show the compact view instead of a "too small" message, so that I can shrink the pane with my multiplexer's keys and widen it again to get the full sidebar.
3. As a user, I want `--compact` to keep the dashboard open after a switch, as `--sidebar` does, so that I do not have to pass both flags.
4. As a user, I want the full dashboard, without `--sidebar` or `--compact`, to keep working as it does today.

Sessions

5. As a user, I want each session to show its number in its multiplexer, so that I can tell the sessions apart without names.
6. As a user, I want each session to show the most urgent status of its agents, so that I can see which session needs me: blocked or error first, then working, idle, done and unknown.
7. As a user, I want a session whose agents report no status, such as tmux agents, to show that it holds agents, so that I can still find them.
8. As a user, I want a session without agents to show no status, so that the strip stays quiet.
9. As a user, I want the current session's number highlighted, as the `●` mark does in the full sidebar.
10. As a user, I want an exited zellij session's number drawn muted, as its name is in the full sidebar.
11. As a user, I want each multiplexer's sessions under a bar in that multiplexer's color, so that I can tell which multiplexer a session belongs to.
12. As a user, I want a multiplexer's bar drawn muted while it loads and in the alert color when it fails, since there is no room for the text.

Tabs

13. As a user, I want `h`, `l`, `H`, `L` and `--tabs expanded` to show and hide tabs in the compact view as they do in the full sidebar.
14. As a user, I want tab rows one cell to the right of their session's number, with the tab's number and the most urgent status of its agents, so that the nesting stays clear.
15. As a user, I want the active tab's number in bold, as in the full sidebar.
16. As a user, I want a space between a session's number and its status, as between an agent's icon and its status, and the tab numbers in that space, so that the strip reads easily and stays 3 columns wide with tabs shown.

Agents

17. As a user, I want the Agents list below the Sessions list, with each agent's icon and status, so that I can still jump straight to an agent.
18. As a user, I want a blank row between the two lists, so that I can tell where one ends.
19. As a user, I want Tab to switch between the lists as it does now, with the selected row's background brighter in the list that has focus. There is no cursor cell, so that every cell goes to the content.

Keys and mouse

20. As a user, I want `j` `k` `↑` `↓`, `Alt+j` `Alt+k`, `g` `G`, `h` `l` `H` `L`, Tab, Enter, Escape, `q` and Ctrl+L to work in the compact view as they do in the full sidebar.
21. As a user, I want `/`, `n`, `r`, `x` and `?` to do nothing in the compact view, since their dialogs do not fit. I widen the pane to use them.
22. As a user, I want a dialog or filter input that is open when the pane turns compact to close as if I pressed Escape, so that no hidden dialog takes my keys.
23. As a user, I want a filter that I kept before the pane turned compact to stay, marked by a `/` in the row between the lists, and Escape to clear it, as it does today.
24. As a user, I want a warning, such as a failed switch, to show as a `!` in the row between the lists while it lasts, since there is no footer.
25. As a user, I want to click a row to select it, click it again to go there, and scroll to move, as in the full sidebar.

Narrow and short panes

26. As a user, I want the number column as wide as the largest number, so that sessions 1 to 12 line up.
27. As a user, I want a pane narrower than the compact view's rows to cut the rows from the right rather than wrap them.

## Implementation Decisions

Flags and options

- `--compact`, a `store_true` flag. `--help` says "show the sidebar as a narrow strip of numbers and statuses; implies --sidebar".
- `Options` gets `compact: bool`. `main` sets `sidebar` too when `--compact` is given, and `Term` asks for focus events when `sidebar` is set, as it does today.

When the view is compact

- `App.width` holds the last width that `View.render` drew. `App.compact` is true when `options.compact` is set, or when `options.sidebar` is set and `width < SIDEBAR_MIN_COLS`. The app needs it for key routing, so it lives on the app and not only in the view.
- `View.render` checks compact before the minimum size check. The compact view has no minimum width. It needs at least `COMPACT_MIN_ROWS` rows (4); below that it shows blank rows.
- When `View.render` finds the view compact and `app.mode` is set, it closes the mode as Escape does: a filter input clears the filter, and any other dialog closes without acting. A kill dialog never runs its kill this way. `render` already changes app state (hits, offsets and clamp), so this fits the current pattern.

Rows

- The compact view uses `app.rows(which)` unchanged, so expansion, the filter, the cursor, `item_key` and `touched` all work as they do in the full sidebar.
- A session's number is its position among the session rows of its group, starting at 1. It is computed while drawing and is not stored on `Session`.
- A new module function `summary_status(agents) -> str | None` returns the most urgent status of a list of agents in the order of a new `STATUS_ORDER = ("blocked", "error", "working", "idle", "done", "unknown")`. It returns `"agents"` when there are agents but none reports a status, and `None` without agents. Session rows use `app.agents_of(s)` and tab rows use `app.agents_in_tab(tab)`.

Drawing

- A new `View.compact(cols, rows)` draws the whole compact screen: the Sessions list, the row between the lists, and the Agents list, with no header, borders, preview or footer. The lists split the height as the full sidebar does: `sh = max(4, (h * 11 + 19) // 20)` with `h = rows - 1` for the row between the lists.
- A new `View.compact_list(which, y, w, h)` draws one list. It reuses `scroll_offset` and `app.offset`, and records `Hit`s with the same `which` and item indices as `list_panel`, so `App.mouse` needs no change. A row's hit covers the whole pane width.
- Column layout: the session number column, at the left edge of the pane, as wide as the largest session number in the list, then a tab number column as wide as the largest tab number shown, and one cell wide without tab rows, then the status cell. A session row leaves the tab number column blank, and a tab row the session number column. Session numbers and tab numbers are right aligned in their columns.
- The status cell uses the `STATUS_ICONS` glyphs and the colors of `View.status`, without the word. For `"agents"` it shows `◆` in gold.
- The background of the selected row is the same as in the full sidebar: `hl_med` in the focused list and `hl_low` in the other one.
- Session number colors: the current session in `love` and bold, an exited session in `muted` and italic, the selected one bold, the others `text`. Tab number colors follow `tab_row`: the active tab, or the selected one, in `text`, the others in `subtle`, and the active tab bold.
- An agent row shows `agent_icon(a.name)` in the agent's color (in `love` when blocked, as `agent_row` does), a space, and the status cell. An agent without a status has a blank status cell.
- A group row is `━` across the pane width in `t.mux(mux)`; in `muted` while it loads, and in `love` when the group has an error.
- The row between the lists shows `!` in `love` and bold while a warning toast lasts, `/` in `gold` and bold while a filter is set, and is blank otherwise. Info toasts do not show.
- Every line is cut or padded to exactly `cols` cells with `fit`, as every other line is.

Keys

- In `App.list_key`, `/`, `?`, `n`, `r` and `x` return without acting while `App.compact` is true. Every other key works as it does now.
- The help dialog and the footer stay as they are, since the compact view never shows them.

Documentation

- README: in "Keep it open in a sidebar", one paragraph saying that `--compact` shows a narrow strip with each session's number and the status of its agents, and that a `--sidebar` pane that is too narrow shows the same strip. Add `--compact` to the options synopsis and list. Keep the glyphs and the column layout out of the README.
- AGENTS.md: nothing new unless implementing finds a pitfall.

## Testing Decisions

- Unit tests:
  - `summary_status` orders statuses as `STATUS_ORDER` says, returns `"agents"` for agents with no status, and `None` without agents.
  - `--compact` sets both `compact` and `sidebar` in `Options`. `--sidebar` alone sets only `sidebar`.
  - `App.compact` is true for `--compact` at 80 columns, true for `--sidebar` at 23 columns, false for `--sidebar` at 24 columns, and false without either flag at any width.
  - Rendering at 4 columns, with ANSI removed: session rows show their numbers and status glyphs, group rows are bars, the lists are split by a blank row, and agent rows show their icons and status glyphs.
  - A space separates a session's number from its status. With one session expanded, tab numbers sit in that space, and the status column stays put.
  - With 12 sessions, numbers 1 to 9 are right aligned under 10 to 12.
  - The current session's number is drawn in `love`, checked through the SGR codes as other tests do.
  - The selected row has the `hl_med` background in the focused list and `hl_low` in the other one, and Tab swaps them.
  - A click on a compact row selects it, and a second click switches, through the recorded hits.
  - `/`, `?`, `n`, `r` and `x` change nothing while compact. They still work at 24 columns.
  - An open rename dialog and a filter input close when the view turns compact, and a kept filter shows the `/` marker and is cleared by Escape.
  - A warning toast shows `!` in the row between the lists.
  - Below 4 rows the compact view is blank and does not fail.
- End-to-end tests, in `scripts/e2e.sh`, since key routing changes:
  - tmux: a sidebar pane started with `--compact` and 3 columns wide shows the session numbers. `j` and Enter switch the client to the second session, and the pane stays open.
  - tmux: a `--sidebar` pane resized from 32 to 3 columns shows the compact view, and resized back shows the full sidebar with its session names.

## Out of Scope

- A key that switches between the full and the compact view, and any resizing of the dashboard's own pane. tmux could do it, but zellij can only resize in steps and herdr cannot resize at all.
- Digit keys that jump to a session by its number.
- The compact view for the full dashboard without `--sidebar` or `--compact`. It keeps its "Make the window at least" message.
- A setting for the width at which `--sidebar` turns compact. It is the full sidebar's minimum width.
- Hiding the sidebar entirely, as herdr's `sidebar_collapsed_mode = "hidden"` does. The multiplexer can already close or hide the pane.
