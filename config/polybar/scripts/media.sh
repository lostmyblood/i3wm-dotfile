#!/usr/bin/env bash
# Polybar media module.  media.sh        -> bar label (follows the player, no polling)
#                        media.sh popup  -> cover / lyrics popup (click on the label)
export LC_ALL=C.UTF-8
dim="#666666"

if [[ $1 != popup ]]; then
    trap 'pkill -P $$' EXIT

    while IFS='|' read -r status artist title; do
        [[ $status == Playing || $status == Paused ]] || { echo; continue; }
        text=$title
        [[ -n $artist ]] && text="$artist - $title"
        text=${text//%/}
        (( ${#text} > 50 )) && text="${text:0:49}…"
        if [[ $status == Paused ]]; then
            echo "%{F$dim}$text%{F-}"
        else
            echo "$text"
        fi
    done < <(playerctl --follow metadata --format '{{status}}|{{artist}}|{{title}}' 2>/dev/null)
    exit
fi

# ---------------------------------------------------------------- popup
pkill -x rofi && exit    # already open -> close it (toggle)

self=$0; [[ -L $self ]] && self=$(readlink -f "$self")
theme=${self%/*}/../popup.rasi
cache=${XDG_CACHE_HOME:-$HOME/.cache}/polybar-media
[[ -d $cache ]] || mkdir -p "$cache"

sp=$'\xc2\xa0' fs=$'\x1f'
fmt="{{status}}$fs{{artist}}$fs{{title}}$fs{{mpris:artUrl}}$fs{{playerName}}$fs{{xesam:url}}"

# Background downloads send this script SIGUSR1 when something lands. The main loop is parked
# in `wait`, which a trapped signal interrupts at once, so there is no polling anywhere.
# rpid = running rofi (we only ever kill our own window, never somebody else's rofi).
rpid= redraw= loaded=
outf=${XDG_RUNTIME_DIR:-/tmp}/polybar-media.$$
trap 'redraw=1; [[ -n $rpid ]] && kill $rpid 2>/dev/null' USR1
trap 'rm -f "$outf"; [[ -n $rpid ]] && kill $rpid 2>/dev/null' EXIT

# Markup-escape into $REPLY (no subshell).
esc() { local s=$1; s=${s//&/"&amp;"}; s=${s//</"&lt;"}; REPLY=${s//>/"&gt;"}; }
note() { command -v notify-send >/dev/null && notify-send -t 2000 media "$1"; }

load() {
    IFS=$fs read -r status artist title art player url < <(timeout 2 playerctl metadata --format "$fmt" 2>/dev/null)
    [[ -n $title ]]
}

# After a control press: stream player changes (one short-lived playerctl, instead of polling it
# up to 8 times) and take the new state straight from the first line that differs from $1.
settle() {
    local line sfd spid
    exec {sfd}< <(exec timeout 1 playerctl --follow metadata --format "$fmt" 2>/dev/null)
    spid=$!
    while read -rt 0.9 -u $sfd line; do
        [[ $line == "$1$fs"* ]] && continue
        IFS=$fs read -r status artist title art player url <<<"$line"
        [[ -n $title ]] && loaded=1
        break
    done
    kill $spid 2>/dev/null
    exec {sfd}<&-
}

wants_lyrics() {
    case ${player,,} in
        *firefox*|*librewolf*|*chrom*|*brave*|*vivaldi*|*zen*|*waterfox*|*edge*) return 1 ;;
    esac
    [[ $url != *youtube.com* && $url != *youtu.be* ]]
}

# Image file -> $bw $bh (largest WxH that `file` reports).
imgdims() {
    local rest w h re='([0-9]+) ?x ?([0-9]+)'
    bw=0 bh=0
    rest=$(file -b "$1" 2>/dev/null) || return 1
    while [[ $rest =~ $re ]]; do
        w=${BASH_REMATCH[1]} h=${BASH_REMATCH[2]}
        (( w * h > bw * bh )) && { bw=$w bh=$h; }
        rest=${rest#*"${BASH_REMATCH[0]}"}
    done
}

# Download the cover for $art. "bg" = background job (signals the main loop when done);
# otherwise it runs inline with a shorter timeout and the caller waits for it.
fetch_cover() {
    local tmp=$cache/cover.tmp.$BASHPID want= mt=3
    [[ $1 == bg ]] && mt=5
    if curl -sfL --connect-timeout 1 --max-time "$mt" -o "$tmp" "$art"; then
        read -r want <"$cache/cover.want"
        if [[ $want == "$art" ]]; then
            mv -f "$tmp" "$cache/cover"
            imgdims "$cache/cover"
            printf '%s\n%s %s\n' "$art" "$bw" "$bh" >"$cache/cover.url"
            [[ $1 == bg ]] && kill -USR1 $$
            return 0
        fi
    fi
    rm -f "$tmp"
    return 1
}

# Only does work when the art URL changes (or while the download is still pending).
# cover.url = "<art url>\n<width> <height>": the size is measured once, in the download job,
# so opening the popup never has to run `file`.
get_cover() {
    local fresh=0 bw=0 bh=0 cached= tmp
    if [[ $art != "$cover_art" ]]; then fresh=1
    elif [[ -z $cover_pending ]]; then return; fi
    cover_art=$art cover= cover_pad=140 cover_card=0 cover_pending=
    [[ -n $art ]] || return
    case $art in
        file://*)
            cover=${art#file://}
            printf -v cover '%b' "${cover//%/\\x}"
            [[ -f $cover ]] && imgdims "$cover" ;;
        http*)
            cover=$cache/cover
            [[ -r $cache/cover.url ]] && { read -r cached; read -r bw bh; } <"$cache/cover.url"
            if [[ $cached != "$art" || ! -f $cover ]]; then
                if (( fresh )); then
                    # "want" lets a slow download of an earlier album lose to the latest one.
                    printf '%s' "$art" >"$cache/cover.want"
                    if [[ -n $first ]]; then
                        fetch_cover && cached=$art    # first open: album is ready before the window shows
                    else
                        fetch_cover bg >/dev/null 2>&1 &
                    fi
                fi
                [[ $cached == "$art" ]] || { cover= cover_pending=1; }
            fi
            if [[ -n $cover ]]; then
                bw=${bw:-0} bh=${bh:-0}
                (( bw > 0 )) || imgdims "$cover"
            fi ;;
    esac
    [[ -f $cover ]] || { cover=; return; }

    (( bw > 0 )) || return
    cover_pad=$(( 278 * bh / (2 * bw) ))
    (( cover_pad > 200 )) && cover_pad=200
    (( cover_pad < 20 )) && cover_pad=20
    # Popup shape follows the art's aspect ratio:
    #   wide  (>= 6:5, e.g. 16:9 video) -> wide card,  220px thumbnail left, 440px window
    #   tall  (<= 4:5, e.g. 9:16 short) -> narrow card, 140px thumbnail left, 340px window
    #   else  (square-ish album art)    -> thumbnail on top, 300px window
    # card_pad is the cover's "vertical horizontal" padding = half its height / half its width.
    local tw=0
    if (( bw * 10 >= bh * 12 )); then tw=220 card_win=440
    elif (( bw * 10 <= bh * 8 )); then tw=140 card_win=340
    fi
    if (( tw )); then
        cover_card=1
        card_pad="$(( tw * bh / (2 * bw) ))px $(( tw / 2 ))px"
    fi
}

# Only does work when the track changes (or while lyrics are still pending);
# result cached in $lrows (ready-made rofi rows).
get_lyrics() {
    local fresh=0 key file q resp l
    local -a lines
    if [[ $lyr_key != "$artist|$title" ]]; then fresh=1 lyr_key="$artist|$title"
    elif [[ -z $lyr_pending ]]; then return; fi
    lyr_pending= lrows=
    key=$(md5sum <<<"$lyr_key"); key=${key%% *}
    file=$cache/$key.fold
    if (( fresh )) && [[ ! -s $file && ! -e $file.none ]]; then
        if command -v jq >/dev/null; then
            q=${title%% - *}; q=${q%% \(*}
            # Fetch in the background; the popup refreshes itself when it lands.
            ( tmp=$file.tmp.$BASHPID
              if resp=$(curl -sfG --connect-timeout 1 --max-time 5 -H 'User-Agent: polybar-media' \
                    --data-urlencode "track_name=$q" --data-urlencode "artist_name=${artist%%,*}" \
                    https://lrclib.net/api/search); then
                  jq -r '[.[] | select((.plainLyrics // "") != "")][0].plainLyrics // empty' <<<"$resp" \
                      | fold -s -w 34 >"$tmp"
                  if [[ -s $tmp ]]; then mv -f "$tmp" "$file"
                  else rm -f "$tmp"; : >"$file.none"; fi
                  kill -USR1 $$
              fi ) >/dev/null 2>&1 &
        else
            : >"$file.none"
        fi
    fi
    if [[ -s $file ]]; then
        mapfile -t lines <"$file"
        for l in "${lines[@]}"; do
            esc "$l"; lrows+="<span foreground=\"$dim\">${REPLY:-$sp}</span>"$'\n'
        done
        lrows=${lrows%$'\n'}
    elif [[ -e $file.none ]]; then
        lrows="<span foreground=\"$dim\">no lyrics found</span>"
    else
        lrows="<span foreground=\"$dim\">loading lyrics…</span>"
        lyr_pending=1
    fi
}

ts_base='window{location:north;anchor:north;x-offset:0px;width:300px;padding:8px;}
mainbox{spacing:6px;} message{padding:0;} textbox{horizontal-align:0.5;}
element{padding:1px 6px;} element-text{horizontal-align:0.5;}
element selected.normal{background-color:transparent;}'

rofi_args=(
    -dmenu -markup-rows -no-custom -format i -p "" -theme "$theme"
    -kb-custom-1 "Left" -kb-custom-2 "space" -kb-custom-3 "Right"
    -kb-page-next "Down,Page_Down" -kb-page-prev "Up,Page_Up"
    -kb-row-down "Control+n" -kb-row-up "Control+p"
    -kb-move-char-back "Control+b" -kb-move-char-forward "Control+f"
)

# Row 4 = middle of the 8-line list. With centered scrolling (scroll-method:1) the
# selection sits mid-list and every Up/Down press scrolls the text one line.
# first = set until the first window is about to open: the cover is downloaded synchronously
# then (up to 3s), so the album is ready when the popup appears.
sel=4 first=1
while :; do
    redraw=
    [[ -n $loaded ]] || load || { note "nothing playing"; exit; }
    loaded=
    get_cover
    first=

    # rofi -no-custom quits on empty input, so always feed at least one row.
    ts=$ts_base rows=$sp list=
    if wants_lyrics; then
        get_lyrics
        rows=$lrows list=,listview ts+='listview{lines:8;fixed-height:false;scroll-method:1;cycle:false;}'
    else
        lyr_pending=
    fi
    if [[ -z $cover ]]; then
        kids=message
    elif (( cover_card )); then
        # Card: thumbnail on the left; title, channel and controls on the right.
        kids=box-card
        ts+="window{width:${card_win}px;} textbox{horizontal-align:0;vertical-align:0.5;} message{expand:true;padding:0 0 0 12px;}"
        ts+="cover{children:[];expand:false;padding:$card_pad;background-image:url(\"$cover\",width);}"
        ts+='box-card{orientation:horizontal;spacing:0;expand:false;children:[cover,message];}'
    else
        kids=cover,message
        ts+="cover{children:[];expand:false;padding:${cover_pad}px;background-image:url(\"$cover\",width);}"
    fi
    ts+="mainbox{children:[$kids$list];}"

    glyph="❚❚"; [[ $status == Playing ]] || glyph="▶"
    esc "$title"; mesg="<b>$REPLY</b>"
    [[ -n $artist ]] && { esc "$artist"; mesg+=$'\n'"<span foreground=\"$dim\">$REPLY</span>"; }
    mesg+=$'\n'"◀◀${sp}${sp}${sp}${sp}${glyph}${sp}${sp}${sp}${sp}▶▶"

    # rofi runs in the background so `wait` can be interrupted by the download jobs' SIGUSR1.
    rofi "${rofi_args[@]}" -theme-str "$ts" -mesg "$mesg" -selected-row "$sel" <<<"$rows" >"$outf" &
    rpid=$!
    [[ -n $redraw ]] && kill $rpid 2>/dev/null    # something landed while we were building
    wait $rpid; rc=$?
    if [[ -n $redraw ]] && (( rc < 10 || rc > 12 )); then    # window was closed for a redraw
        wait $rpid 2>/dev/null; rpid=; continue
    fi
    rpid=
    out=; read -r out <"$outf"
    case $rc in
        10) timeout 2 playerctl previous ;;
        11) timeout 2 playerctl play-pause ;;
        12) timeout 2 playerctl next ;;
        *) exit ;;
    esac
    [[ $out =~ ^[0-9]+$ ]] && sel=$out
    settle "$status$fs$artist$fs$title"
done
