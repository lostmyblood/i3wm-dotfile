#!/usr/bin/env bash
# One process for the whole right-hand status: cpu %, ram (GiB used) and wifi.
# Everything is read from /proc and /sys with bash builtins; nmcli runs only when the wifi
# link changes (and once a minute as a safety net), and every nmcli call is time-limited.
export LC_ALL=C.UTF-8
fg="#d0d0d0" dim="#666666" yel="#e5c07b" red="#e06c6c"
self=$(readlink -f "$0"); click=${self%/*}/wifi.sh
exec {fd}<> <(:)    # private fd that never gets data: `read -t` on it is the sleep

# cpu/ram: normal, yellow at $2, red at $3.   wifi (inverted): yellow below 50%, red below 20%.
color() { c=$fg; (( $1 >= $2 )) && c=$yel; (( $1 >= $3 )) && c=$red; }

dev=
for d in /sys/class/net/*/wireless; do
    [[ -d $d ]] && { dev=${d%/wireless}; dev=${dev##*/}; break; }
done

read -r _ u n s i w q sq _ </proc/stat
pt=$((u+n+s+i+w+q+sq)); pi=$((i+w))
while read -r k v _; do [[ $k == MemTotal: ]] && { mt=$v; break; }; done </proc/meminfo

tick=0 prev= last= ssid= radio= retry=0 tries=0
while :; do
    read -r _ u n s i w q sq _ </proc/stat
    t=$((u+n+s+i+w+q+sq)); idle=$((i+w))
    dt=$((t-pt)); di=$((idle-pi)); pt=$t; pi=$idle
    cpu=0; (( dt > 0 )) && cpu=$((100*(dt-di)/dt))

    while read -r k v _; do [[ $k == MemAvailable: ]] && { ma=$v; break; }; done </proc/meminfo
    used=$((mt-ma)); ram=$((100*used/mt))                  # ram: % for the colour, GiB for display
    g=$(( (used * 10 + 524288) / 1048576 )); ramv="$((g/10)).$((g%10))GiB"

    color $cpu 50 80; cc=$c
    color $ram 60 85; rcol=$c

    wifi="no wifi"
    if [[ -n $dev ]]; then
        read -r op <"/sys/class/net/$dev/operstate"
        if [[ $op != "$prev" ]] || (( tick == 0 )) || (( retry == 1 )); then
            prev=$op ssid= radio=
            if [[ $op == up ]]; then
                while IFS=: read -r a name; do
                    [[ $a == yes ]] && { ssid=${name:-hidden}; break; }
                done < <(timeout 2 nmcli -t -e no -f ACTIVE,SSID dev wifi list --rescan no 2>/dev/null)
                if [[ -n $ssid ]]; then
                    retry=0 tries=0
                elif (( tries < 3 )); then
                    (( tries++ ))
                    retry=4                    # AP not listed yet: retry in ~8s
                else
                    retry=0 tries=0            # back off to the 60s safety net
                fi
            else
                radio=$(timeout 2 nmcli radio wifi 2>/dev/null)
                retry=0 tries=0
            fi
        fi
        (( retry > 0 )) && (( retry-- ))
        tick=$(( (tick + 1) % 30 ))

        if [[ $op == up && -n $ssid ]]; then
            lvl= q=
            while read -r name _ q lvl _; do
                [[ $name == "$dev:" ]] && break
                lvl= q=
            done </proc/net/wireless
            lvl=${lvl%.} q=${q%.}
            if [[ $lvl == -* ]]; then sig=$(( 2 * (lvl + 100) ))   # dBm -> percent
            else sig=$(( ${q:-0} * 100 / 70 )); fi                  # fallback: link quality /70
            (( sig > 100 )) && sig=100; (( sig < 0 )) && sig=0
            c=$fg; (( sig < 50 )) && c=$yel; (( sig < 20 )) && c=$red
            ssid_d=${ssid//%/}; wifi="%{F$c}${ssid_d:0:16}%{F-}"    # polybar treats % specially
        elif [[ $radio == disabled ]]; then
            wifi="%{F$dim}wifi off%{F-}"
        fi
    fi

    printf -v out '%%{F%s}%02d%% %%{F-} %%{F%s}%s%%{F-}  %%{A1:%s:}%s%%{A}' \
        "$cc" "$cpu" "$rcol" "$ramv" "$click" "$wifi"
    [[ $out == "$last" ]] || { printf '%s\n' "$out"; last=$out; }   # only redraw on change
    read -rt 2 -u $fd
done
