#!/usr/bin/env bash
# Opens a made-up scene of coding agents at work, in a zellij or tmux of its
# own, or spread over zellij, tmux and herdr, for screenshots of the
# dashboard, the sidebar or the compact sidebar.
#
#   nix develop -c scripts/showcase.sh [dashboard|sidebar|compact|outside]
#       [--mux zellij|tmux] [--theme dark|light] [--plain]
#
# The default is the dashboard in zellij. Run it in a terminal outside any
# multiplexer, at the size the screenshot should have. The scene fills the
# terminal; leave it as you leave the multiplexer, by detaching or quitting,
# and the script removes everything it made.
#
# outside spreads the sessions over zellij, tmux and herdr, and runs the
# dashboard in the terminal itself, outside any multiplexer, where it lists
# the sessions and agents of all three. It takes no --mux. larder, with the
# real pi, is the first tmux session. The scene ends when you quit the
# dashboard, or when you leave the multiplexer that the dashboard attached
# to.
#
# The multiplexers use your own configuration, so they have your theme,
# status bar and keys: ~/.tmux.conf or ~/.config/tmux/tmux.conf, zellij's
# config.kdl with its themes and layouts, and herdr's config.toml. --plain
# uses a small configuration of the script's own instead. The dashboard, pi
# and the stand-ins take the theme that matches the terminal's background,
# or the one --theme names.
#
# The scene runs with its own HOME, XDG directories, sockets and PATH, and
# without the variables that hold API keys or tokens, so it never reaches
# your own sessions or accounts. Set KEEP=1 to keep its temporary directory.
#
# The pi agents are the real pi, which opens a made-up session that
# scripts/showcase.py writes. claude, codex, opencode and agy are stand-ins
# that draw a still screen from scripts/showcase.py. Every agent reports a
# status with OSC 7501, which the dashboard shows in zellij. herdr finds the
# agents itself, and the script reports their statuses to it. tmux has no
# agent statuses, so in tmux the lists show the agents without one.

set -euo pipefail

usage() {
    echo "usage: scripts/showcase.sh [dashboard|sidebar|compact|outside] [--mux zellij|tmux] [--theme dark|light] [--plain]"
}
die() {
    echo "showcase: $*" >&2
    exit 1
}

view=dashboard mux=zellij mux_given="" theme="" plain=""
while (($#)); do
    case $1 in
    dashboard | sidebar | compact | outside) view=$1 ;;
    --mux)
        mux=${2:-} mux_given=1
        shift
        ;;
    --theme)
        theme=${2:-}
        shift
        ;;
    --plain) plain=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
    esac
    shift
done
[[ $mux == zellij || $mux == tmux ]] || die "--mux takes zellij or tmux"
[[ -z $theme || $theme == dark || $theme == light ]] || die "--theme takes dark or light"
[[ $view != outside || -z $mux_given ]] || die "outside runs zellij, tmux and herdr; it takes no --mux"

# The multiplexers that the scene runs. Outside, jq also reads herdr's
# answers.
muxes=$mux
[[ $view != outside ]] || muxes="zellij tmux herdr"

here=$(cd "$(dirname "$0")" && pwd)
dash="$here/../multiplexer-dashboard"
for m in $muxes; do
    command -v "$m" >/dev/null || die "$m is not installed; run inside nix develop"
done
[[ $view != outside ]] || command -v jq >/dev/null || die "jq is not installed; run inside nix develop"
command -v python3 >/dev/null || die "python3 is not installed"
realpi=$(command -v pi) || die "pi is not installed; see https://pi.dev"
[[ -t 0 && -t 1 ]] || die "run it in a terminal"
read -r rows cols < <(stty size)
[[ $view != outside ]] || ((cols >= 80 && rows >= 20)) ||
    die "outside needs a terminal of at least 80 columns and 20 rows"
[[ -n $theme ]] || theme=$(python3 "$here/showcase.py" background) || theme=dark

# The user's own configuration, found before HOME changes.
user_home=$HOME
user_tmux_conf="" user_zellij_dir="" user_herdr_conf=""
if [[ -z $plain ]]; then
    for f in "$HOME/.tmux.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" \
        "$HOME/.config/tmux/tmux.conf"; do
        if [[ -f $f ]]; then
            user_tmux_conf=$f
            break
        fi
    done
    for d in "${ZELLIJ_CONFIG_DIR:-}" "${XDG_CONFIG_HOME:-$HOME/.config}/zellij" \
        "$HOME/.config/zellij"; do
        if [[ -n $d && -f $d/config.kdl ]]; then
            user_zellij_dir=$d
            break
        fi
    done
    for f in "${HERDR_CONFIG_PATH:-}" "${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml" \
        "$HOME/.config/herdr/config.toml"; do
        if [[ -n $f && -f $f ]]; then
            user_herdr_conf=$f
            break
        fi
    done
fi

# Unix socket paths are limited to about 100 bytes, and the multiplexers
# put their sockets under this directory, so it stays short.
tmp=$(mktemp -d /tmp/mds.XXXXXX)

# Nothing that reaches the user's own multiplexers or accounts.
for v in $(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'); do
    case $v in
    TMUX* | ZELLIJ* | TERM_PROGRAM* | HERDR_* | MULTIPLEXER_DASHBOARD_* | AWS_* | *API_KEY* | *TOKEN* | *SECRET* | *PASSWORD*)
        unset "$v"
        ;;
    esac
done
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache" \
    XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state" XDG_RUNTIME_DIR="$tmp/run" \
    TMUX_TMPDIR="$tmp/tmux" ZELLIJ_CONFIG_DIR="$tmp/config/zellij" \
    PATH="$tmp/bin:$PATH" SHELL="$tmp/bin/showcase-shell" SHOWCASE_THEME="$theme" \
    COLORTERM="${COLORTERM:-truecolor}"
mkdir -p "$HOME/.pi/agent" "$ZELLIJ_CONFIG_DIR" "$XDG_CONFIG_HOME/herdr" "$XDG_CACHE_HOME" \
    "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$TMUX_TMPDIR" "$tmp/bin" "$tmp/pi" \
    "$tmp/layouts"
chmod 700 "$XDG_RUNTIME_DIR"

cleanup() {
    local m
    for m in $muxes; do
        case $m in
        tmux) tmux kill-server 2>/dev/null || true ;;
        zellij)
            zellij kill-all-sessions -y >/dev/null 2>&1 || true
            zellij delete-all-sessions -y >/dev/null 2>&1 || true
            ;;
        herdr) herdr server stop >/dev/null 2>&1 || true ;;
        esac
    done
    if [[ -z ${KEEP:-} ]]; then rm -rf "$tmp"; else echo "kept $tmp"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- the scene

# The sessions, in the order they are listed, one tab per line:
# SESSION TAB PROJECT COMMAND... A tab without a command runs a shell. The
# first session is the one the terminal shows.
scene="
larder       agent    larder       pi larder working
larder       review   larder       codex codex-review done
larder       server   larder       uvicorn
kilnworks    checkout kilnworks    claude claude-kilnworks working
kilnworks    shell    kilnworks
infra-live   staging  infra-live   claude claude-infra-live blocked
switchback   ios      switchback   opencode opencode-switchback idle
tributary    guide    tributary    agy agy-tributary working
photo-backup backup   photo-backup pi photo-backup done
dotfiles     shell    dotfiles
"
main=larder
sessions=$(awk 'NF && !seen[$1]++ { print $1 }' <<<"$scene")

# The multiplexer of each session in the outside view. larder runs in tmux,
# whose sessions take the preview's size. herdr shows "done" for an agent
# that finished while its workspace had no focus, and the first herdr
# workspace has the focus, so photo-backup comes second.
placement="
kilnworks    zellij
infra-live   zellij
tributary    zellij
larder       tmux
dotfiles     tmux
switchback   herdr
photo-backup herdr
"

# sessions_of MUX: the sessions that MUX runs, in the order of the scene.
sessions_of() {
    if [[ $view == outside ]]; then
        awk -v m="$1" 'NR == FNR { if ($2 == m) keep[$1] = 1; next } $1 in keep' \
            <(echo "$placement") <(echo "$sessions")
    elif [[ $1 == "$mux" ]]; then
        echo "$sessions"
    fi
}

# Each project is a git repository on a branch, which the shell prompt, pi
# and the dashboard show.
for p in larder:fix/orders-n-plus-one kilnworks:feat/one-column-checkout \
    infra-live:main switchback:release/2.4 tributary:docs/streaming-guide \
    photo-backup:fix/s3-retries \
    dotfiles:main; do
    mkdir -p "$HOME/code/${p%%:*}"
    git -C "$HOME/code/${p%%:*}" init -q -b "${p#*:}"
done

python3 "$here/showcase.py" pi-sessions "$tmp/pi" "$HOME"
printf '{"theme": "%s"}\n' "$theme" >"$HOME/.pi/agent/settings.json"

# The shell of every pane, with a short prompt.
cat >"$tmp/bashrc" <<'EOF'
PS1='\[\e[36m\]\w\[\e[0m\] \[\e[35m\]$(git branch --show-current 2>/dev/null)\[\e[0m\] \$ '
EOF
cat >"$tmp/bin/showcase-shell" <<EOF
#!/bin/sh
exec bash --rcfile "$tmp/bashrc" "\$@"
EOF
# pi PROJECT STATUS: the real pi on the project's made-up session, with
# made-up keys so that it loads the session's model without asking. pi
# reports "idle" once it starts, so the status follows a few seconds later.
cat >"$tmp/bin/pi" <<EOF
#!/usr/bin/env bash
( sleep 4; printf '\033]7501;state=%s\033\\\\' "\$2" >/dev/tty ) &
exec env ANTHROPIC_API_KEY=showcase OPENAI_API_KEY=showcase PI_OFFLINE=1 PI_TELEMETRY=0 \\
    "$realpi" --no-extensions --no-mcp --no-skills --no-context-files \\
    --no-prompt-templates --session "$tmp/pi/\$1.jsonl"
EOF
# The stand-ins run under the agent's name, which the dashboard detects.
for a in claude codex opencode agy; do
    cat >"$tmp/bin/$a" <<EOF
#!/usr/bin/env bash
exec -a $a python3 "$here/showcase.py" screen "\$@"
EOF
done
cat >"$tmp/bin/uvicorn" <<EOF
#!/bin/sh
exec python3 "$here/showcase.py" log
EOF
# Under both names, for the key bindings of the user's configuration.
ln -s "$dash" "$tmp/bin/multiplexer-sidebar"
ln -s "$dash" "$tmp/bin/multiplexer-dashboard"
chmod +x "$tmp/bin/"*

# zellij draws a border around each pane unless the configuration turns
# pane frames off.
frames=1
if [[ $mux == tmux ]] ||
    grep -Eq '^[[:space:]]*pane_frames[[:space:]]+false' "$user_zellij_dir/config.kdl" 2>/dev/null; then
    frames=0
fi
# The sidebar's width and its arguments.
case $view in
sidebar) side=$((30 + 2 * frames)) side_args="--sidebar" ;;
compact) side=$((3 + 2 * frames)) side_args="--compact" ;;
dashboard | outside) side=0 side_args="" ;;
esac

# The size of the tmux sessions. In the outside view, where the dashboard
# fills the terminal, their panes have the size of the dashboard's preview,
# which shows the last lines of a pane, cut to its width. tmux's status
# line takes a row.
tmux_cols=$cols tmux_rows=$rows
if [[ $view == outside ]]; then
    lw=$((cols * 2 / 5))
    ((lw < 34)) && lw=34
    ((lw > 46)) && lw=46
    tmux_cols=$((cols - lw - 3)) tmux_rows=$((rows - 5))
fi

# tabs SESSION: the session's lines of the scene.
tabs() { awk -v s="$1" '$1 == s' <<<"$scene"; }

# ---------------------------------------------------------------- zellij

zellij_layout() {
    local session=$1 first=1 _s tab project cmd args a
    echo "layout {"
    echo "    default_tab_template {"
    echo "        pane size=1 borderless=true {"
    echo "            plugin location=\"tab-bar\""
    echo "        }"
    if ((side)); then
        echo "        pane split_direction=\"vertical\" {"
        echo "            pane size=$side command=\"multiplexer-sidebar\" name=\"multiplexer-sidebar\" close_on_exit=true {"
        echo "                args \"--theme\" \"$theme\" \"$side_args\""
        echo "            }"
        echo "            children"
        echo "        }"
    else
        echo "        children"
    fi
    echo "        pane size=2 borderless=true {"
    echo "            plugin location=\"status-bar\""
    echo "        }"
    echo "    }"
    while read -r _s tab project cmd args; do
        echo "    tab name=\"$tab\" cwd=\"$HOME/code/$project\"$( ((first)) && echo " focus=true") {"
        if [[ -n $cmd ]]; then
            echo "        pane command=\"$cmd\" focus=true {"
            if [[ -n $args ]]; then
                printf '            args'
                for a in $args; do printf ' "%s"' "$a"; done
                echo
            fi
            echo "        }"
        else
            echo "        pane focus=true"
        fi
        if ((first)) && [[ $view == dashboard && $session == "$main" ]]; then
            echo "        floating_panes {"
            echo "            pane command=\"multiplexer-sidebar\" name=\"multiplexer-sidebar\" close_on_exit=true x=\"5%\" y=\"5%\" width=\"90%\" height=\"90%\" {"
            echo "                args \"--theme\" \"$theme\""
            echo "            }"
            echo "        }"
        fi
        echo "    }"
        first=0
    done < <(tabs "$session")
    echo "}"
}

# wait_until SECONDS COMMAND...: polls COMMAND until it succeeds.
wait_until() {
    local deadline=$((SECONDS + $1))
    shift
    until "$@" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || return 1
        sleep 0.2
    done
}

# zellij_config: the user's config.kdl, themes and layouts, or one with a
# key binding for the dashboard, then the options that the scene needs.
# zellij takes the last value of an option and merges blocks of the same
# name, so the options at the end override the user's. The sessions start
# without a client, so zellij would cover the main session with its card
# of what happened while no one was attached; the scene turns that card off.
zellij_config() {
    local conf="$ZELLIJ_CONFIG_DIR/config.kdl" d
    if [[ -n $user_zellij_dir ]]; then
        cp "$user_zellij_dir/config.kdl" "$conf"
        for d in themes layouts; do
            [[ -d $user_zellij_dir/$d ]] && ln -s "$user_zellij_dir/$d" "$ZELLIJ_CONFIG_DIR/$d"
        done
    else
        zellij_keys >"$conf"
    fi
    cat >>"$conf" <<EOF
show_startup_tips false
show_release_notes false
default_shell "$SHELL"
attention {
    startup_card "never"
}
EOF
}

# zellij_keys: Alt d opens the dashboard, for a scene without the user's
# configuration.
zellij_keys() {
    cat <<EOF
keybinds {
    shared_except "locked" {
        bind "Alt d" {
            Run "multiplexer-sidebar" "--theme" "$theme" {
                floating true
                close_on_exit true
                width "90%"
                height "90%"
                x "5%"
                y "5%"
            }
        }
    }
}
EOF
}

# Every session starts in the background, one after another and a second
# apart, since zellij gives their ages in whole seconds and the dashboard
# lists them by age. A session without a client is about 50 columns wide,
# so the dashboard's preview of another session is narrow until that
# session has a client of its own; the main session takes the terminal's
# size once the terminal attaches.
start_zellij() {
    zellij_config
    local s
    for s in $(sessions_of zellij); do
        zellij_layout "$s" >"$tmp/layouts/$s.kdl"
        zellij --layout "$tmp/layouts/$s.kdl" attach --create-background "$s"
        wait_until 30 zellij --session "$s" action list-panes -j ||
            die "zellij session $s did not start"
        sleep 1
    done
}

attach_zellij() { zellij attach "$main"; }

# ---------------------------------------------------------------- tmux

# tmux_config: the user's tmux.conf, or a small one with key bindings for
# the dashboard, then the options that the sidebar and pi need. The user's
# ~/.tmux and ~/.config/tmux are linked into HOME, where the configuration
# finds its plugins.
tmux_config() {
    local d
    echo "set -g default-shell \"$SHELL\""
    if [[ -n $user_tmux_conf ]]; then
        for d in .tmux .config/tmux; do
            if [[ -d $user_home/$d ]]; then
                mkdir -p "$(dirname "$HOME/$d")"
                ln -s "$user_home/$d" "$HOME/$d"
            fi
        done
        echo "source-file \"$user_tmux_conf\""
    else
        cat <<EOF
set -g mouse on
set -g status-style "bg=default"
set -g status-right "%H:%M "
set -g window-status-current-style "bold"
bind b split-window -hbf -l 32 "multiplexer-sidebar --theme $theme --sidebar"
bind Tab new-pane -O -x90% -y90% -X5% -Y5% -c '#{pane_current_path}' "multiplexer-sidebar --theme $theme"
EOF
    fi
    cat <<EOF
set -g focus-events on
set -g extended-keys on
set -g extended-keys-format csi-u
EOF
}

start_tmux() {
    tmux_config >"$tmp/tmux.conf"
    local s _s tab project cmd args target
    for s in $(sessions_of tmux); do
        target=""
        while read -r _s tab project cmd args; do
            set -- ${cmd:+"$cmd${args:+ $args}"}
            if [[ -z $target ]]; then
                tmux -f "$tmp/tmux.conf" new-session -d -s "$s" -n "$tab" \
                    -c "$HOME/code/$project" -x "$tmux_cols" -y "$tmux_rows" "$@"
            else
                tmux new-window -d -t "$s:" -n "$tab" -c "$HOME/code/$project" "$@"
            fi
            target="$s:$tab"
            if ((side)); then
                tmux split-window -d -hbf -l "$side" -t "$target" \
                    "multiplexer-sidebar --theme $theme $side_args"
            fi
        done < <(tabs "$s")
    done
    sleep 2
}

attach_tmux() {
    if [[ $view == dashboard ]]; then
        tmux attach -t "$main" \; new-pane -O -x90% -y90% -X5% -Y5% \
            "multiplexer-sidebar --theme $theme"
    else
        tmux attach -t "$main"
    fi
}

# ---------------------------------------------------------------- herdr

# herdr_config: the user's config.toml, or one with a key binding for the
# dashboard, with the first-run setup turned off. TOML takes each key once,
# so the user's own onboarding line is left out.
herdr_config() {
    local conf="$XDG_CONFIG_HOME/herdr/config.toml"
    echo "onboarding = false" >"$conf"
    if [[ -n $user_herdr_conf ]]; then
        grep -Ev '^[[:space:]]*onboarding[[:space:]]*=' "$user_herdr_conf" >>"$conf" || true
    else
        cat >>"$conf" <<EOF

[[keys.command]]
key = "prefix+alt+d"
type = "popup"
command = "multiplexer-sidebar --theme $theme"
width = "90%"
height = "90%"
EOF
    fi
}

# herdr_found N: whether herdr has found N agents and has given each a
# status of its own.
herdr_found() {
    [[ $(herdr agent list |
        jq '[.result.agents[] | select(.agent_status != "unknown")] | length') == "$1" ]]
}

# Each session is a workspace, and each of its tabs runs its command in the
# shell of the tab's pane. herdr shows "done" for an agent that went from
# working to idle while its workspace had no focus, so a "done" agent
# reports working and then idle. Until herdr has given an agent a status of
# its own, it takes a report of idle as idle, so the reports wait for that.
start_herdr() {
    herdr_config
    (cd "$tmp" && nohup herdr server >/dev/null 2>&1 &)
    wait_until 10 herdr workspace list || die "the herdr server did not start"
    local s _s tab project cmd args reply ws pane status a
    local -a agents=()
    for s in $(sessions_of herdr); do
        ws=""
        while read -r _s tab project cmd args; do
            if [[ -z $ws ]]; then
                reply=$(herdr workspace create --cwd "$HOME/code/$project" --label "$s" --no-focus)
                ws=$(jq -r .result.workspace.workspace_id <<<"$reply")
                herdr tab rename "$(jq -r .result.tab.tab_id <<<"$reply")" "$tab" >/dev/null
            else
                reply=$(herdr tab create --workspace "$ws" --cwd "$HOME/code/$project" \
                    --label "$tab" --no-focus)
            fi
            pane=$(jq -r .result.root_pane.pane_id <<<"$reply")
            if [[ -n $cmd ]]; then
                herdr pane run "$pane" "clear; exec $cmd${args:+ $args}" >/dev/null
                # The last argument of an agent is its status.
                [[ -z $args ]] || agents+=("$pane $cmd ${args##* }")
            fi
        done < <(tabs "$s")
    done
    wait_until 20 herdr_found "${#agents[@]}" ||
        die "herdr did not find the scene's agents"


    for a in "${agents[@]}"; do
        read -r pane cmd status <<<"$a"
        [[ $status != "done" ]] || status=working
        herdr pane report-agent --source showcase --agent "$cmd" --state "$status" "$pane" >/dev/null
    done
    sleep 1
    for a in "${agents[@]}"; do
        read -r pane cmd status <<<"$a"
        [[ $status != "done" ]] ||
            herdr pane report-agent --source showcase --agent "$cmd" --state idle "$pane" >/dev/null
    done
}

# ---------------------------------------------------------------- start

for m in $muxes; do "start_$m"; done
clear
if [[ $view == outside ]]; then
    multiplexer-dashboard --theme "$theme"
else
    "attach_$mux"
fi
