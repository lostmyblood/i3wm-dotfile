#!/usr/bin/env bash
# Calendar popup: ISO week numbers, weekends dimmed, today highlighted.
#   Left / Right = previous / next month      Enter / Esc = close
# One rofi window in script mode: rofi re-runs this script on every key press (ROFI_RETV set)
# and the script just prints the next screen, so the popup never closes and reopens.
export LC_ALL=C.UTF-8

sp=$'\xc2\xa0'
dim="#666666" fg="#d0d0d0" bg="#0a0a0a" yel="#e5c07b" wkend="#8a8a8a"
months=(January February March April May June July August September October November December)
state=${XDG_CACHE_HOME:-$HOME/.cache}/polybar-calendar/offset   # months away from the current one

# --- date maths in pure bash (day numbers count from 1970-01-01; no `date` forks) ---
d2n() {   # y m d -> day number in REPLY
    local y=$1 m=$2 d=$3 era yoe doy
    (( m <= 2 )) && (( y-- ))
    era=$(( y / 400 )); yoe=$(( y - era * 400 ))
    doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 ))
    REPLY=$(( era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468 ))
}
n2d() {   # day number -> globals Y M D
    local z=$(( $1 + 719468 )) era doe yoe y doy mp
    era=$(( z / 146097 )); doe=$(( z - era * 146097 ))
    yoe=$(( (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 ))
    y=$(( yoe + era * 400 )); doy=$(( doe - (365 * yoe + yoe / 4 - yoe / 100) ))
    mp=$(( (5 * doy + 2) / 153 )); D=$(( doy - (153 * mp + 2) / 5 + 1 ))
    M=$(( mp < 10 ? mp + 3 : mp - 9 )); Y=$(( M <= 2 ? y + 1 : y ))
}
mlen() {  # y m -> days in month, in REPLY
    local a
    d2n "$1" "$2" 1; a=$REPLY
    d2n $(( $2 == 12 ? $1 + 1 : $1 )) $(( $2 == 12 ? 1 : $2 + 1 )) 1
    REPLY=$(( REPLY - a ))
}

# Render month $cy/$cm into $rows and $mesg; today is day number $tn.
render() {
    local n0 n1 wd0 start r c rs th wk w cell line dn N
    d2n "$cy" "$cm" 1; n0=$REPLY
    mlen "$cy" "$cm"; n1=$(( n0 + REPLY ))
    wd0=$(( (n0 + 3) % 7 + 1 )); start=$(( n0 - wd0 + 1 ))

    rows="<span foreground=\"$dim\">Wk${sp}${sp}Mo${sp}Tu${sp}We${sp}Th${sp}Fr${sp}Sa${sp}Su</span>"
    for (( r = 0; r < 6; r++ )); do
        rs=$(( start + 7 * r ))
        (( rs >= n1 )) && break   # no padding rows: popup height follows the month
        th=$(( rs + 3 )); n2d "$th"; d2n "$Y" 1 1; wk=$(( (th - REPLY) / 7 + 1 ))
        printf -v w '%2d' "$wk"
        line="<span foreground=\"$dim\">${w// /$sp}</span>${sp}${sp}"
        for (( c = 0; c < 7; c++ )); do
            N=$(( rs + c ))
            if (( N < n0 || N >= n1 )); then
                cell="${sp}${sp}"
            else
                dn=$(( N - n0 + 1 )); printf -v cell '%2d' "$dn"; cell=${cell// /$sp}
                if (( N == tn )); then cell="<span background=\"$yel\" foreground=\"$bg\">$cell</span>"
                elif (( c >= 5 )); then cell="<span foreground=\"$wkend\">$cell</span>"
                fi
            fi
            line+=$cell; (( c < 6 )) && line+=$sp
        done
        rows+=$'\n'"$line"
    done
    mesg="<b>${months[cm-1]} $cy</b>"
}

# ============================================================================
# Handler: rofi runs this on open (ROFI_RETV=0) and on every key press.
#   ROFI_RETV 10 = Left, 11 = Right, 1 = Enter
# ============================================================================
if [[ -n ${ROFI_RETV+x} ]]; then
    [[ $ROFI_RETV == 1 ]] && { pkill -x rofi; exit; }
    mkdir -p "${state%/*}"
    off=0
    [[ -r $state ]] && read -r off <"$state"
    [[ $off =~ ^-?[0-9]+$ ]] || off=0
    case $ROFI_RETV in 10) (( off-- )) ;; 11) (( off++ )) ;; esac
    printf '%s\n' "$off" >"$state"

    printf -v t '%(%Y %m %d)T' -1
    read -r ty tm td <<<"$t"
    ty=$((10#$ty)) tm=$((10#$tm)) td=$((10#$td))
    d2n "$ty" "$tm" "$td"; tn=$REPLY

    m=$(( ty * 12 + tm - 1 + off )); cy=$(( m / 12 )); cm=$(( m % 12 + 1 ))
    render
    printf '\0markup-rows\x1ftrue\n\0no-custom\x1ftrue\n\0selected\x1f0\n\0message\x1f%s\n%s\n' "$mesg" "$rows"
    exit
fi

# ============================================================================
# Launcher (what polybar runs)
# ============================================================================
pkill -x rofi && exit    # already open -> close it (toggle)
self=$(readlink -f "$0")
theme=${self%/*}/../popup.rasi
mkdir -p "${state%/*}"; printf '0\n' >"$state"

# Left/Right are freed from rofi's cursor-movement defaults so they can switch months.
exec rofi -show cal -modi "cal:$self" -markup-rows -no-custom -p "" -theme "$theme" \
    -theme-str 'window{width:30ch;} element{padding:1px 6px;} element selected.normal{background-color:transparent;}' \
    -kb-move-char-back "Control+b" -kb-move-char-forward "Control+f" \
    -kb-custom-1 "Left" -kb-custom-2 "Right"
