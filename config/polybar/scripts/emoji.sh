#!/usr/bin/env bash
# Emoji picker, built as a rofi script mode so it can sit in the launcher's mode list.
#   Inside the launcher:  rofi -modi "drun,window,emoji:~/.config/polybar/scripts/emoji.sh"
#   Standalone (i3 key, polybar click): emoji.sh  -> opens the launcher theme on just the emoji list
# Enter copies the emoji; set EMOJI_TYPE=1 to also type it into the focused window (needs xdotool).
# The list comes from Unicode's emoji-test.txt (local copy, else downloaded once) and is cached.
export LC_ALL=C.UTF-8
cache=${XDG_CACHE_HOME:-$HOME/.cache}/polybar-emoji
rows=$cache/rows

note() { command -v notify-send >/dev/null && notify-send -t 2000 emoji "$1"; }

# One row per emoji:  😀  grinning face  [face-smiling]   (subgroup dimmed, like the launcher's {generic})
build() {
    local src= f
    mkdir -p "$cache"
    for f in /usr/share/unicode/emoji/emoji-test.txt /usr/share/unicode/emoji-test.txt "$cache/emoji-test.txt"; do
        [[ -s $f ]] && { src=$f; break; }
    done
    if [[ -z $src ]]; then
        src=$cache/emoji-test.txt
        curl -sfL --max-time 30 -o "$src" https://unicode.org/Public/emoji/latest/emoji-test.txt \
            || { rm -f "$src"; note "couldn't download the emoji list"; exit 1; }
    fi
    awk '
        /^# subgroup:/ { sg = $3; next }
        /; fully-qualified/ && !/skin tone/ {
            rest = substr($0, index($0, "# ") + 2)
            emoji = rest; sub(/ .*/, "", emoji)
            sub(/^[^ ]+ [^ ]+ /, "", rest)
            gsub(/&/, "\\&amp;", rest); gsub(/</, "\\&lt;", rest); gsub(/>/, "\\&gt;", rest)
            print emoji "  " rest "  [<span alpha=\"55%\">" sg "</span>]"
        }' "$src" >"$rows.tmp"
    [[ -s $rows.tmp ]] || { rm -f "$rows.tmp"; note "no emoji found in the list"; exit 1; }
    mv -f "$rows.tmp" "$rows"
}

# ---- script mode: rofi runs us to get the list (ROFI_RETV=0) and again with the chosen row ($1, RETV=1)
if [[ -n ${ROFI_RETV+x} ]]; then
    if [[ $ROFI_RETV == 1 ]]; then
        emoji=${1%% *}
        # Output goes to /dev/null so the clipboard owner can't keep rofi's pipe (and window) open.
        if command -v xclip >/dev/null; then printf '%s' "$emoji" | xclip -selection clipboard >/dev/null 2>&1
        elif command -v wl-copy >/dev/null; then printf '%s' "$emoji" | wl-copy >/dev/null 2>&1
        else note "install xclip to copy"; exit 1; fi
        if [[ $EMOJI_TYPE == 1 ]] && command -v xdotool >/dev/null; then
            setsid -f bash -c 'sleep 0.15; xdotool type --clearmodifiers --delay 0 "$1"' _ "$emoji" >/dev/null 2>&1
        else
            note "copied $emoji"
        fi
        exit
    fi
    [[ -s $rows ]] || build
    printf '\0markup-rows\x1ftrue\n\0no-custom\x1ftrue\n'
    cat "$rows"
    exit
fi

# ---- standalone launcher
pkill -x rofi && exit    # already open -> close it (toggle)
self=$(readlink -f "$0")
exec rofi -show emoji -modi "emoji:$self" -theme "${self%/*}/../../rofi/launcher.rasi"
