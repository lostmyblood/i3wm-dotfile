#!/usr/bin/env bash
export LC_ALL=C.UTF-8
dir=$(dirname "$(readlink -f "$0")")
theme=$dir/../popup.rasi
pkill -x rofi && exit    # already open -> close it (toggle)

dim="#666666" chipbg="#1c1c1c" fg="#d0d0d0"
yel="#e5c07b" red="#e06c6c"   # same health colours as stats.sh

# Markup-escape into $REPLY (no subshell).
esc() { local s=$1; s=${s//&/"&amp;"}; s=${s//</"&lt;"}; REPLY=${s//>/"&gt;"}; }
# Notifications share one tag so "connecting…" is replaced by the result.
note() {
    command -v notify-send >/dev/null || return 0
    notify-send -t 3000 -h string:x-dunst-stack-tag:wifi \
        -h string:x-canonical-private-synchronous:wifi wifi "$1"
}

command -v nmcli >/dev/null || { note "nmcli not found"; exit 1; }

W=24    # popup width in characters; set below from the content
PAD=6   # extra characters for window padding and row padding (raise if text is still cut)
L=10    # visible list lines; set below from the number of rows

# Action "buttons" are single keys: r rescan, w wifi off, d disconnect (exit codes 10-12).
# Custom key bindings win over typing, so these letters never reach the (unused) filter box.
pop() {
    rofi -dmenu -markup-rows -no-custom -format i -p "" -theme "$theme" \
        -theme-str "window{width:$(( W + PAD ))ch;} listview{lines:${L};} element-text{horizontal-align:0;} textbox{horizontal-align:0;}" \
        -kb-custom-1 "r" -kb-custom-2 "w" -kb-custom-3 "d" \
        -mesg "$1"
}

# Signal health colour into $c, like cpu/ram in stats.sh but inverted (low signal is bad):
# normal at 50% and above, yellow below 50%, red below 20%.
sigcol() { c=$fg; (( $1 < 50 )) && c=$yel; (( $1 < 20 )) && c=$red; }

# Find the saved profile whose SSID matches $1 (profile names often differ from SSIDs).
# Result in REPLY (a UUID); returns 1 if there is none.
find_profile() {
    local u t n s
    local -a cands=()
    while IFS=: read -r u t n; do
        [[ $t == 802-11-wireless ]] || continue
        # Check the profile whose name matches the SSID first.
        if [[ $n == "$1" ]]; then cands=("$u" "${cands[@]}")
        else cands+=("$u"); fi
    done < <(timeout 3 nmcli -t -e no -f UUID,TYPE,NAME connection show)
    for u in "${cands[@]}"; do
        s=$(timeout 3 nmcli -e no -g 802-11-wireless.ssid connection show uuid "$u" 2>/dev/null </dev/null)
        [[ $s == "$1" ]] && { REPLY=$u; return 0; }
    done
    return 1
}

# Security marker: lock for secured networks, blank for open ones.
lock='*' nolock=' '

dev=
while IFS=: read -r d t; do
    [[ $t == wifi ]] && { dev=$d; break; }
done < <(timeout 3 nmcli -t -e no -f DEVICE,TYPE dev)
[[ -n $dev ]] || { note "no wifi device found"; exit 1; }

if [[ $(timeout 3 nmcli radio wifi) != enabled ]]; then
    [[ $(printf 'turn wifi on\n' | pop "wifi is off") == 0 ]] && timeout 3 nmcli radio wifi on
    exit
fi

# Show the cached list immediately; refresh it in the background for next time.
timeout 5 nmcli dev wifi rescan >/dev/null 2>&1 &

state= conn=
while IFS=: read -r t st cn; do
    [[ $t == wifi ]] && { state=$st conn=$cn; break; }
done < <(timeout 3 nmcli -t -e no -f TYPE,STATE,CONNECTION dev)

# Header: connection info, then the action "chips" with their keys.
# The first letter is highlighted: pressing it runs the action.
chip() { printf '<span background="%s" foreground="%s"> <span foreground="%s"><b>%s</b></span>%s </span>' "$chipbg" "$fg" "$yel" "${1:0:1}" "${1:1}"; }
chips_plain=" rescan   wifi off "
chips="$(chip "rescan")  $(chip "wifi off")"
if [[ $state == connected ]]; then
    ip=$(timeout 3 nmcli -g IP4.ADDRESS dev show "$dev" 2>/dev/null)
    ip=${ip%%$'\n'*}
    esc "$conn"
    mesg="<b>$REPLY</b>"$'\n'"<span foreground=\"$dim\">${ip:-no ip}</span>"
    chips+="  $(chip "disconnect")"; chips_plain+="  disconnect "
else
    mesg="<span foreground=\"$dim\">not connected</span>"
fi
mesg+=$'\n'"$chips"

list=$(timeout 3 nmcli -t -e no -f IN-USE,SIGNAL,SECURITY,SSID dev wifi list --rescan no | sort -t: -k2,2 -nr)

# The connected SSID can have several APs; tag the SSID, not whichever AP sorts first.
# Also find the longest SSID, so the name column fits the networks around you (8-32 chars).
active= sw=8
while IFS=: read -r inuse _ _ ssid; do
    [[ $inuse == "*" ]] && active=$ssid
    (( ${#ssid} > sw )) && sw=${#ssid}
done <<<"$list"
(( sw > 32 )) && sw=32

declare -A seen
ssids=(); secs=(); rows=(); plain=()
while IFS=: read -r _ signal sec ssid; do
    [[ -z $ssid || -n ${seen[$ssid]} ]] && continue
    seen[$ssid]=1; ssids+=("$ssid"); secs+=("$sec")
    tag=; [[ -n $active && $ssid == "$active" ]] && tag=connected
    icon=$nolock; [[ -n $sec ]] && icon=$lock
    printf -v name '%-*.*s' "$sw" "$sw" "$ssid"
    printf -v pct '%3s%%' "${signal:-0}"
    sigcol "${signal:-0}"
    plain+=("$name $pct $icon $tag")
    esc "$name"
    row="$REPLY <span foreground=\"$c\">$pct</span> <span foreground=\"$dim\">$icon</span> $tag"
    [[ -n $tag ]] && row="<span background=\"$chipbg\">$row</span>"
    rows+=("$row")
done <<<"$list"

# rofi -no-custom quits on empty input, so always feed at least one row.
if (( ${#rows[@]} == 0 )); then
    rows=("<span foreground=\"$dim\">no networks found</span>"); plain=("no networks found")
fi

# Size the popup to its widest line (clamped), instead of a fixed pixel width.
for s in "${plain[@]}" "$chips_plain" "$conn" "$ip"; do
    (( ${#s} > W )) && W=${#s}
done
(( W > 60 )) && W=60

# Height follows the list too, up to 15 lines (then it scrolls).
L=${#rows[@]}
(( L > 15 )) && L=15
(( L < 1 )) && L=1

sel=$(printf '%s\n' "${rows[@]}" | pop "$mesg")
rc=$?
case $rc in
    10) note "scanning…"; exec "$0" ;;
    11) timeout 3 nmcli radio wifi off; exit ;;
    12) [[ $state == connected ]] && timeout 5 nmcli dev disconnect "$dev"; exit ;;
    0)  ;;
    *)  exit ;;
esac
[[ -n $sel && -n ${ssids[sel]} ]] || exit

ssid=${ssids[sel]}; sec=${secs[sel]}

# Connect. A profile created by a failed attempt is deleted again, so a wrong
# password can't leave a broken saved profile that later skips the password prompt.
fresh=0
if find_profile "$ssid"; then
    note "connecting to $ssid…"
    out=$(timeout 25 nmcli connection up uuid "$REPLY" 2>&1)
elif [[ -z $sec ]]; then
    fresh=1
    note "connecting to $ssid…"
    out=$(timeout 25 nmcli dev wifi connect "$ssid" 2>&1)
else
    fresh=1
    W=30
    pw=$(rofi -dmenu -password -p password -theme "$theme" \
        -theme-str "window{width:$(( W + PAD ))ch;} mainbox{children:[inputbar];}" </dev/null)
    [[ -z $pw ]] && exit
    note "connecting to $ssid…"
    # Password goes in on stdin (--ask), not on the command line where `ps` would show it.
    out=$(printf '%s\n' "$pw" | timeout 25 nmcli --ask dev wifi connect "$ssid" 2>&1)
fi
rc=$?
unset pw

if (( rc == 0 )); then
    note "connected to $ssid"
else
    (( fresh )) && find_profile "$ssid" && timeout 5 nmcli connection delete uuid "$REPLY" >/dev/null 2>&1
    note "failed: ${out##*$'\n'}"
fi
