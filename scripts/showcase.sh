#!/usr/bin/env bash
# Opens a made-up scene of coding agents at work, in a zellij or tmux of its
# own, for screenshots of the dashboard, the sidebar or the compact sidebar.
#
#   nix develop -c scripts/showcase.sh [dashboard|sidebar|compact]
#       [--mux zellij|tmux] [--theme dark|light] [--plain]
#
# The default is the dashboard in zellij. Run it in a terminal outside any
# multiplexer, at the size the screenshot should have. The scene fills the
# terminal; leave it as you leave the multiplexer, by detaching or quitting,
# and the script removes everything it made.
#
# The multiplexer uses your own configuration, so it has your theme, status
# bar and keys: ~/.tmux.conf or ~/.config/tmux/tmux.conf, and zellij's
# config.kdl with its themes and layouts. --plain uses a small configuration
# of the script's own instead. The dashboard, pi and the stand-ins take the
# theme that matches the terminal's background, or the one --theme names.
#
# The scene runs with its own HOME, XDG directories, sockets and PATH, and
# without the variables that hold API keys or tokens, so it never reaches
# your own sessions or accounts. Set KEEP=1 to keep its temporary directory.
#
# The pi agents are the real pi, which opens a made-up session that
# scripts/showcase.py writes. claude, codex, opencode and agy are stand-ins
# that draw a still screen from scripts/showcase.py. Every agent reports a
# status with OSC 7501, which the dashboard shows in zellij. tmux has no
# agent statuses, so in tmux the lists show the agents without one.

set -euo pipefail

usage() {
    echo "usage: scripts/showcase.sh [dashboard|sidebar|compact] [--mux zellij|tmux] [--theme dark|light] [--plain]"
}
die() {
    echo "showcase: $*" >&2
    exit 1
}

view=dashboard mux=zellij theme="" plain=""
while (($#)); do
    case $1 in
    dashboard | sidebar | compact) view=$1 ;;
    --mux)
        mux=${2:-}
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

here=$(cd "$(dirname "$0")" && pwd)
dash="$here/../multiplexer-dashboard"
command -v "$mux" >/dev/null || die "$mux is not installed; run inside nix develop"
command -v tmux >/dev/null || die "tmux is not installed; run inside nix develop"
command -v python3 >/dev/null || die "python3 is not installed"
realpi=$(command -v pi) || die "pi is not installed; see https://pi.dev"
[[ -t 0 && -t 1 ]] || die "run it in a terminal"
read -r rows cols < <(stty size)
[[ -n $theme ]] || theme=$(python3 "$here/showcase.py" background) || theme=dark

# The user's own configuration, found before HOME changes.
user_home=$HOME
user_tmux_conf="" user_zellij_dir=""
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
mkdir -p "$HOME/.pi/agent" "$ZELLIJ_CONFIG_DIR" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" \
    "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$TMUX_TMPDIR" "$tmp/bin" "$tmp/pi" "$tmp/layouts"
chmod 700 "$XDG_RUNTIME_DIR"

# The harness is a hidden tmux server whose windows play the terminal of
# each zellij session while the scene starts. Its variables stay out of
# zellij, or the panes would think that they run in tmux.
th() { tmux -L harness -f /dev/null "$@"; }
outside_harness="env -u TMUX -u TMUX_PANE -u TERM_PROGRAM -u TERM_PROGRAM_VERSION TERM=$TERM"
cleanup() {
    th kill-server 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
    if [[ $mux == zellij ]]; then
        zellij kill-all-sessions -y >/dev/null 2>&1 || true
        zellij delete-all-sessions -y >/dev/null 2>&1 || true
    fi
    if [[ -z ${KEEP:-} ]]; then rm -rf "$tmp"; else echo "kept $tmp"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- the scene

# The sessions, in the order they are listed, one tab per line:
# SESSION TAB PROJECT COMMAND... A tab without a command runs a shell. The
# first session is the one the terminal shows.
scene="
shop-api      agent    shop-api       pi shop-api working
shop-api      review   shop-api       codex codex-review done
shop-api      server   shop-api       uvicorn
web           checkout web            claude claude-web working
web           shell    web
infra         staging  infra          claude claude-infra blocked
mobile        ios      mobile         opencode opencode-mobile idle
docs          guide    docs           agy agy-docs working
data-pipeline export   data-pipeline  pi data-pipeline done
dotfiles      shell    dotfiles
"
main=shop-api
sessions=$(awk 'NF && !seen[$1]++ { print $1 }' <<<"$scene")

# Each project is a git repository on a branch, which the shell prompt, pi
# and the dashboard show.
for p in shop-api:fix/orders-n-plus-one web:feat/one-column-checkout infra:main \
    mobile:release/2.4 docs:docs/streaming-guide data-pipeline:fix/s3-retries \
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
dashboard) side=0 side_args="" ;;
esac

# The size of the other sessions. The preview of the dashboard shows the
# last lines of a pane, cut to its width, so in the dashboard view their
# panes have the size of the preview of a dashboard that covers 90% of the
# terminal, as the multiplexer's key binding opens it. The sessions keep
# the rows of zellij's tab bar and status bar, or of tmux's status line.
other_cols=$cols other_rows=$rows
if [[ $view == dashboard ]]; then
    dc=$((cols * 9 / 10 - 2)) dr=$((rows * 9 / 10 - 2))
    lw=$((dc * 2 / 5))
    ((lw < 34)) && lw=34
    ((lw > 46)) && lw=46
    other_cols=$((dc - lw - 3)) other_rows=$((dr - 6))
    if [[ $mux == zellij ]]; then
        other_rows=$((other_rows + 3))
    else
        other_rows=$((other_rows + 1))
    fi
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

# zellij_config: the user's config.kdl, themes and layouts, with the options
# that the scene needs and the configuration leaves out. Without a
# configuration of the user's, one with a key binding for the dashboard.
zellij_config() {
    local conf="$ZELLIJ_CONFIG_DIR/config.kdl" d
    if [[ -n $user_zellij_dir ]]; then
        cp "$user_zellij_dir/config.kdl" "$conf"
        for d in themes layouts; do
            [[ -d $user_zellij_dir/$d ]] && ln -s "$user_zellij_dir/$d" "$ZELLIJ_CONFIG_DIR/$d"
        done
        grep -Eq '^[[:space:]]*show_startup_tips[[:space:]]' "$conf" ||
            echo "show_startup_tips false" >>"$conf"
        grep -Eq '^[[:space:]]*show_release_notes[[:space:]]' "$conf" ||
            echo "show_release_notes false" >>"$conf"
        grep -Eq '^[[:space:]]*default_shell[[:space:]]' "$conf" ||
            echo "default_shell \"$SHELL\"" >>"$conf"
        return
    fi
    cat >"$conf" <<EOF
show_startup_tips false
show_release_notes false
default_shell "$SHELL"
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

start_zellij() {
    zellij_config
    local s w h
    # One session after another and a second apart, since zellij gives
    # their ages in whole seconds and the dashboard lists them by age.
    for s in $sessions; do
        zellij_layout "$s" >"$tmp/layouts/$s.kdl"
        w=$other_cols h=$other_rows
        [[ $s == "$main" ]] && w=$cols h=$rows
        th new-session -d -s "$s" -x "$w" -y "$h" \
            "$outside_harness zellij --layout '$tmp/layouts/$s.kdl' attach --create '$s'"
        wait_until 30 zellij --session "$s" action list-panes -j ||
            die "zellij session $s did not start"
        sleep 1
    done
    # The last pi reports its status 4 seconds after it starts. Then the
    # hidden clients go away and the sessions stay.
    sleep 5
    th kill-server
    clear
    zellij attach "$main"
}

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
    local s w h _s tab project cmd args target
    for s in $sessions; do
        w=$other_cols h=$other_rows
        [[ $s == "$main" ]] && w=$cols h=$rows
        target=""
        while read -r _s tab project cmd args; do
            set -- ${cmd:+"$cmd${args:+ $args}"}
            if [[ -z $target ]]; then
                tmux -f "$tmp/tmux.conf" new-session -d -s "$s" -n "$tab" \
                    -c "$HOME/code/$project" -x "$w" -y "$h" "$@"
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
    clear
    if [[ $view == dashboard ]]; then
        tmux attach -t "$main" \; new-pane -O -x90% -y90% -X5% -Y5% \
            "multiplexer-sidebar --theme $theme"
    else
        tmux attach -t "$main"
    fi
}

"start_$mux"
