#!/usr/bin/env bash

set -u
set -o pipefail

TITLE="Systemd Manager v5.2 COLOR TAGS"
VERSION="5.2"

TMP_DIR="${TMPDIR:-/tmp}"
CACHE_FILE="$TMP_DIR/.systemd_manager_v52_cache.$$"
SELECTION_FILE="$TMP_DIR/.systemd_manager_v52_select.$$"
EDITOR_BIN="${EDITOR:-nano}"
UI_BIN=""

FILTER_STATE="all"
FILTER_TYPE="service"
SEARCH_TERM=""
SCOPE_MODE="system"
SORT_MODE="priority"
SHOW_CORE_SERVICES="no"

cleanup() {
    rm -f "$CACHE_FILE" "$SELECTION_FILE" 2>/dev/null
}
trap cleanup EXIT

need_cmd() { command -v "$1" >/dev/null 2>&1; }
is_root() { [ "$(id -u)" -eq 0 ]; }

sudo_cmd() {
    if is_root; then
        "$@"
    else
        sudo "$@"
    fi
}

detect_pkg_manager() {
    if need_cmd apt-get; then
        echo "apt"
    else
        echo "unknown"
    fi
}

install_missing_dependencies() {
    local missing=()
    local cmd

    for cmd in systemctl awk sed grep sort cut tr head wc journalctl mktemp; do
        need_cmd "$cmd" || missing+=("$cmd")
    done

    if ! need_cmd dialog && ! need_cmd whiptail; then
        missing+=("dialog")
    fi

    if ! need_cmd "$EDITOR_BIN"; then
        missing+=("nano")
        EDITOR_BIN="nano"
    fi

    [ "${#missing[@]}" -eq 0 ] && return 0

    echo "Не хватает зависимостей: ${missing[*]}"

    case "$(detect_pkg_manager)" in
        apt)
            sudo_cmd apt-get update || return 1
            sudo_cmd apt-get install -y dialog whiptail nano systemd coreutils grep sed mawk util-linux sudo || return 1
            ;;
        *)
            echo "Авто-установка поддерживается только для apt-based систем."
            return 1
            ;;
    esac
}

check_dependencies() {
    install_missing_dependencies || exit 1

    if need_cmd dialog; then
        UI_BIN="dialog"
    elif need_cmd whiptail; then
        UI_BIN="whiptail"
    else
        echo "Не найден ни dialog, ни whiptail"
        exit 1
    fi
}

supports_color_ui() {
    [ "$UI_BIN" = "dialog" ]
}

msg() {
    if [ "$UI_BIN" = "whiptail" ]; then
        whiptail --title "$TITLE" --msgbox "$1" 18 84
    else
        dialog --colors --title "$TITLE" --msgbox "$1" 18 84
    fi
}

err() {
    if [ "$UI_BIN" = "whiptail" ]; then
        whiptail --title "$TITLE - Ошибка" --msgbox "$1" 24 110
    else
        dialog --colors --title "$TITLE - Ошибка" --msgbox "$1" 24 110
    fi
}

yesno() {
    if [ "$UI_BIN" = "whiptail" ]; then
        whiptail --title "$TITLE" --yesno "$1" 12 78
    else
        dialog --colors --title "$TITLE" --yesno "$1" 12 78
    fi
}

inputbox() {
    if [ "$UI_BIN" = "whiptail" ]; then
        whiptail --title "$TITLE" --inputbox "$1" 12 78 "$2" 3>&1 1>&2 2>&3
    else
        dialog --colors --title "$TITLE" --inputbox "$1" 12 78 "$2" 3>&1 1>&2 2>&3
    fi
}

menu_box() {
    local title="$1" text="$2" h="$3" w="$4" mh="$5"
    shift 5
    if [ "$UI_BIN" = "whiptail" ]; then
        whiptail --title "$title" --menu "$text" "$h" "$w" "$mh" "$@" 3>&1 1>&2 2>&3
    else
        dialog --colors --title "$title" --menu "$text" "$h" "$w" "$mh" "$@" 3>&1 1>&2 2>&3
    fi
}

checklist_box() {
    local title="$1" text="$2" h="$3" w="$4" lh="$5"
    shift 5
    if [ "$UI_BIN" = "whiptail" ]; then
        whiptail --title "$title" --checklist "$text" "$h" "$w" "$lh" "$@" 3>&1 1>&2 2>&3
    else
        dialog --colors --title "$title" --checklist "$text" "$h" "$w" "$lh" "$@" 3>&1 1>&2 2>&3
    fi
}

scroll_box() {
    local title="$1" text="$2"
    if [ "$UI_BIN" = "whiptail" ]; then
        whiptail --title "$title" --scrolltext --msgbox "$text" 28 112
    else
        dialog --colors --title "$title" --msgbox "$text" 28 112
    fi
}

run_scoped_systemctl() {
    local scope="$1"
    shift
    case "$scope" in
        system)
            if is_root; then
                systemctl "$@"
            else
                sudo systemctl "$@"
            fi
            ;;
        user)
            systemctl --user "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

run_scoped_show_prop() {
    local scope="$1" unit="$2" prop="$3"
    if [ "$scope" = "system" ]; then
        systemctl show "$unit" --property="$prop" --value 2>/dev/null
    else
        systemctl --user show "$unit" --property="$prop" --value 2>/dev/null
    fi
}

unit_kind_from_name() {
    local unit="$1"
    printf "%s" "${unit##*.}"
}

type_matches_filter() {
    local kind="$1"
    if [ "$FILTER_TYPE" = "all" ]; then
        return 0
    fi
    [ "$kind" = "$FILTER_TYPE" ]
}

type_args() {
    if [ "$FILTER_TYPE" = "all" ]; then
        printf '%s\n' "--type=service --type=timer --type=socket --type=target --type=mount"
    else
        printf '%s\n' "--type=$FILTER_TYPE"
    fi
}

list_units_raw() {
    local scope="$1"
    local targs
    targs="$(type_args)"

    if [ "$scope" = "system" ]; then
        eval "systemctl list-units --all --plain --no-legend --no-pager $targs" 2>/dev/null
    else
        eval "systemctl --user list-units --all --plain --no-legend --no-pager $targs" 2>/dev/null
    fi
}

list_unit_files_raw() {
    local scope="$1"
    local targs
    targs="$(type_args)"

    if [ "$scope" = "system" ]; then
        eval "systemctl list-unit-files --no-legend --no-pager $targs" 2>/dev/null
    else
        eval "systemctl --user list-unit-files --no-legend --no-pager $targs" 2>/dev/null
    fi
}

build_cache_for_scope() {
    local scope="$1"
    local units_tmp files_tmp merged_tmp
    units_tmp="$(mktemp)"
    files_tmp="$(mktemp)"
    merged_tmp="$(mktemp)"

    list_units_raw "$scope" | awk '
        NF >= 4 {
            unit=$1
            load=$2
            active=$3
            substate=$4
            $1=""
            $2=""
            $3=""
            $4=""
            desc=$0
            gsub(/^[ \t]+/, "", desc)
            printf "%s|%s|%s|%s|%s\n", unit, load, active, substate, desc
        }
    ' | sort -t'|' -k1,1 > "$units_tmp"

    list_unit_files_raw "$scope" | awk '
        NF >= 2 {
            unit=$1
            state=$2
            printf "%s|%s\n", unit, state
        }
    ' | sort -t'|' -k1,1 > "$files_tmp"

    awk -F'|' '
        FNR==NR { files[$1]=$2; next }
        {
            unit=$1
            load=$2
            active=$3
            substate=$4
            desc=$5
            enabled=(unit in files ? files[unit] : "unknown")
            printf "%s|%s|%s|%s|%s|%s\n", unit, load, active, substate, enabled, desc
            seen[unit]=1
        }
        END {
            for (u in files) {
                if (!(u in seen)) {
                    printf "%s|unknown|inactive|dead|%s|\n", u, files[u]
                }
            }
        }
    ' "$files_tmp" "$units_tmp" \
    | sort -t'|' -k1,1 \
    | awk -F'|' -v s="$scope" '{printf "%s|%s|%s|%s|%s|%s|%s\n", s,$1,$2,$3,$4,$5,$6}' \
    > "$merged_tmp"

    cat "$merged_tmp"

    rm -f "$units_tmp" "$files_tmp" "$merged_tmp"
}

build_cache() {
    : > "$CACHE_FILE"
    case "$SCOPE_MODE" in
        system) build_cache_for_scope system >> "$CACHE_FILE" ;;
        user) build_cache_for_scope user >> "$CACHE_FILE" ;;
        all)
            build_cache_for_scope system >> "$CACHE_FILE"
            build_cache_for_scope user >> "$CACHE_FILE"
            ;;
    esac
}

is_priority_service() {
    local unit="$1"
    case "$unit" in
        nginx.service|apache2.service|caddy.service|httpd.service|lighttpd.service) return 0 ;;
        mysql.service|mysqld.service|mariadb.service|postgresql.service|postgresql@*.service|redis.service|redis-server.service|mongod.service) return 0 ;;
        docker.service|containerd.service|podman.service|crio.service) return 0 ;;
        xray.service|v2ray.service|trojan.service|sing-box.service|openvpn.service|wg-quick@*.service) return 0 ;;
        pm2*.service|node*.service|gunicorn*.service|uvicorn*.service|php*-fpm.service) return 0 ;;
        *) return 1 ;;
    esac
}

is_core_system_service() {
    local scope="$1"
    local unit="$2"

    [ "$scope" = "user" ] && return 1

    case "$unit" in
        systemd-*.service|systemd-*.socket|systemd-*.target|systemd-*.mount|systemd-*.timer) return 0 ;;
        dbus.service|dbus-*.service|dbus.socket) return 0 ;;
        getty*.service|serial-getty*.service|console-getty.service) return 0 ;;
        polkit.service|polkitd.service) return 0 ;;
        snapd.service|snapd.*.service|snapd.*.socket|snapd.*.timer) return 0 ;;
        apt-daily.service|apt-daily.timer|apt-daily-upgrade.service|apt-daily-upgrade.timer) return 0 ;;
        ufw.service) return 0 ;;
        accounts-daemon.service|udisks2.service|ModemManager.service|avahi-daemon.service|NetworkManager.service|networkd-dispatcher.service) return 0 ;;
        rsyslog.service|cron.service|whoopsie.service|thermald.service|irqbalance.service|bluetooth.service|cups.service) return 0 ;;
        systemd-resolved.service|systemd-timesyncd.service|systemd-logind.service|systemd-udevd.service) return 0 ;;
        user@*.service|user-runtime-dir@*.service) return 0 ;;
        *) return 1 ;;
    esac
}

should_display_unit() {
    local scope="$1"
    local unit="$2"

    [ "$SHOW_CORE_SERVICES" = "yes" ] && return 0
    [ "$scope" = "user" ] && return 0
    is_priority_service "$unit" && return 0

    local fragment
    fragment=$(run_scoped_show_prop "$scope" "$unit" "FragmentPath")
    case "$fragment" in
        /etc/systemd/system/*|/run/systemd/system/*) return 0 ;;
    esac

    is_core_system_service "$scope" "$unit" && return 1
    return 0
}

priority_rank() {
    local scope="$1"
    local unit="$2"
    local active="$3"
    local enabled="$4"
    local fragment

    [ "$scope" = "user" ] && { echo "0"; return; }
    is_priority_service "$unit" && { echo "1"; return; }

    fragment=$(run_scoped_show_prop "$scope" "$unit" "FragmentPath")
    case "$fragment" in
        /etc/systemd/system/*) echo "2"; return ;;
        /run/systemd/system/*) echo "3"; return ;;
    esac

    [ "$active" = "failed" ] && { echo "4"; return; }
    [ "$enabled" = "enabled" ] && { echo "5"; return; }
    is_core_system_service "$scope" "$unit" && { echo "9"; return; }
    echo "6"
}

color_active_text() {
    local active="$1"
    if supports_color_ui; then
        case "$active" in
            active) printf "\\Z2active\\Zn" ;;
            failed) printf "\\Z1failed\\Zn" ;;
            inactive|dead) printf "\\Z3inactive\\Zn" ;;
            activating) printf "\\Z6activating\\Zn" ;;
            deactivating) printf "\\Z5deactivating\\Zn" ;;
            *) printf "%s" "$active" ;;
        esac
    else
        printf "%s" "$active"
    fi
}

color_enabled_text() {
    local enabled="$1"
    if supports_color_ui; then
        case "$enabled" in
            enabled|enabled-runtime|linked|linked-runtime|alias) printf "\\Z4%s\\Zn" "$enabled" ;;
            disabled) printf "\\Z0disabled\\Zn" ;;
            static|indirect|generated|transient) printf "\\Z6%s\\Zn" "$enabled" ;;
            masked|masked-runtime) printf "\\Z5%s\\Zn" "$enabled" ;;
            *) printf "%s" "$enabled" ;;
        esac
    else
        printf "%s" "$enabled"
    fi
}

color_scope_text() {
    local scope="$1"
    if supports_color_ui; then
        case "$scope" in
            system) printf "\\Z7[system]\\Zn" ;;
            user) printf "\\Z2[user]\\Zn" ;;
            *) printf "[%s]" "$scope" ;;
        esac
    else
        printf "[%s]" "$scope"
    fi
}

color_unit_text() {
    local unit="$1"
    local active="$2"
    local enabled="$3"

    if supports_color_ui; then
        case "$enabled" in
            masked|masked-runtime)
                printf "\\Z5%s\\Zn" "$unit"
                return
                ;;
        esac

        case "$active" in
            active) printf "\\Z2%s\\Zn" "$unit" ;;
            failed) printf "\\Z1%s\\Zn" "$unit" ;;
            inactive|dead) printf "\\Z3%s\\Zn" "$unit" ;;
            *) printf "%s" "$unit" ;;
        esac
    else
        printf "%s" "$unit"
    fi
}

trim_desc() {
    local desc="$1"
    local maxlen="${2:-28}"
    if [ "${#desc}" -gt "$maxlen" ]; then
        printf "%s..." "${desc:0:$maxlen}"
    else
        printf "%s" "$desc"
    fi
}

refresh_one_unit() {
    local scope="$1"
    local unit="$2"
    local load active substate enabled desc tmp kind

    kind="$(unit_kind_from_name "$unit")"
    type_matches_filter "$kind" || return 0

    load=$(run_scoped_show_prop "$scope" "$unit" "LoadState")
    active=$(run_scoped_show_prop "$scope" "$unit" "ActiveState")
    substate=$(run_scoped_show_prop "$scope" "$unit" "SubState")
    desc=$(run_scoped_show_prop "$scope" "$unit" "Description")

    if [ "$scope" = "system" ]; then
        enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    else
        enabled=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
    fi

    [ -z "$load" ] && load="unknown"
    [ -z "$active" ] && active="inactive"
    [ -z "$substate" ] && substate="dead"
    [ -z "$enabled" ] && enabled="unknown"
    [ -z "$desc" ] && desc=""

    tmp="$(mktemp)"
    awk -F'|' -v s="$scope" -v u="$unit" '!($1==s && $2==u)' "$CACHE_FILE" > "$tmp"
    printf "%s|%s|%s|%s|%s|%s|%s\n" "$scope" "$unit" "$load" "$active" "$substate" "$enabled" "$desc" >> "$tmp"
    mv "$tmp" "$CACHE_FILE"
}

refresh_selected_units() {
    local item scope unit
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        unit="${item%%@@*}"
        scope="${item#*@@}"
        refresh_one_unit "$scope" "$unit"
    done < "$SELECTION_FILE"
}

match_state_filter() {
    local active="$1" enabled="$2"
    case "$FILTER_STATE" in
        all) return 0 ;;
        active) [ "$active" = "active" ] ;;
        failed) [ "$active" = "failed" ] ;;
        inactive) [ "$active" = "inactive" ] || [ "$active" = "dead" ] ;;
        enabled) [ "$enabled" = "enabled" ] ;;
        disabled) [ "$enabled" = "disabled" ] ;;
        static) [ "$enabled" = "static" ] ;;
        masked) [ "$enabled" = "masked" ] ;;
        *) return 0 ;;
    esac
}

match_search() {
    local unit="$1" desc="$2"
    [ -z "$SEARCH_TERM" ] && return 0
    local s u d
    s=$(printf "%s" "$SEARCH_TERM" | tr '[:upper:]' '[:lower:]')
    u=$(printf "%s" "$unit" | tr '[:upper:]' '[:lower:]')
    d=$(printf "%s" "$desc" | tr '[:upper:]' '[:lower:]')
    [[ "$u" == *"$s"* || "$d" == *"$s"* ]]
}

filtered_lines() {
    local scope unit load active substate enabled desc kind
    while IFS='|' read -r scope unit load active substate enabled desc; do
        should_display_unit "$scope" "$unit" || continue
        kind="$(unit_kind_from_name "$unit")"
        type_matches_filter "$kind" || continue
        match_state_filter "$active" "$enabled" || continue
        match_search "$unit" "$desc" || continue
        printf "%s|%s|%s|%s|%s|%s|%s\n" "$scope" "$unit" "$load" "$active" "$substate" "$enabled" "$desc"
    done < "$CACHE_FILE"
}

sorted_filtered_lines() {
    case "$SORT_MODE" in
        priority)
            while IFS='|' read -r scope unit load active substate enabled desc; do
                printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
                    "$(priority_rank "$scope" "$unit" "$active" "$enabled")" \
                    "$scope" "$unit" "$load" "$active" "$substate" "$enabled" "$desc"
            done < <(filtered_lines) | sort -t'|' -k1,1n -k3,3 | cut -d'|' -f2-8
            ;;
        name) filtered_lines | sort -t'|' -k2,2 ;;
        state) filtered_lines | sort -t'|' -k4,4 -k2,2 ;;
        enabled) filtered_lines | sort -t'|' -k6,6 -k2,2 ;;
        type)
            while IFS='|' read -r scope unit load active substate enabled desc; do
                printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
                    "$scope" "$unit" "$load" "$active" "$substate" "$enabled" "$desc" "$(unit_kind_from_name "$unit")"
            done < <(filtered_lines) | sort -t'|' -k8,8 -k2,2 | cut -d'|' -f1-7
            ;;
        scope) filtered_lines | sort -t'|' -k1,1 -k2,2 ;;
        *) filtered_lines | sort -t'|' -k2,2 ;;
    esac
}

show_unit_status() {
    local scope="$1" unit="$2" output
    output=$(run_scoped_systemctl "$scope" status "$unit" --no-pager 2>&1 | sed 's/\x1B\[[0-9;]*[[:alpha:]]//g')
    scroll_box "$TITLE - status: [$scope] $unit" "$output"
}

show_unit_logs() {
    local scope="$1" unit="$2" lines output
    lines=$(inputbox "Сколько строк журнала показать для $unit ?" "80") || return
    [[ "$lines" =~ ^[0-9]+$ ]] || lines=80

    if [ "$scope" = "system" ]; then
        output=$(journalctl -u "$unit" -n "$lines" --no-pager 2>&1 | sed 's/\x1B\[[0-9;]*[[:alpha:]]//g')
    else
        output=$(journalctl --user -u "$unit" -n "$lines" --no-pager 2>&1 | sed 's/\x1B\[[0-9;]*[[:alpha:]]//g')
    fi

    scroll_box "$TITLE - logs: [$scope] $unit" "$output"
}

show_unit_details() {
    local scope="$1" unit="$2"
    local load active substate enabled desc fragment file_state names

    load=$(run_scoped_show_prop "$scope" "$unit" "LoadState")
    active=$(run_scoped_show_prop "$scope" "$unit" "ActiveState")
    substate=$(run_scoped_show_prop "$scope" "$unit" "SubState")
    desc=$(run_scoped_show_prop "$scope" "$unit" "Description")
    fragment=$(run_scoped_show_prop "$scope" "$unit" "FragmentPath")
    file_state=$(run_scoped_show_prop "$scope" "$unit" "UnitFileState")
    names=$(run_scoped_show_prop "$scope" "$unit" "Names")

    if [ "$scope" = "system" ]; then
        enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    else
        enabled=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
    fi

    [ -z "$load" ] && load="unknown"
    [ -z "$active" ] && active="unknown"
    [ -z "$substate" ] && substate="unknown"
    [ -z "$enabled" ] && enabled="$file_state"
    [ -z "$enabled" ] && enabled="unknown"
    [ -z "$desc" ] && desc="-"
    [ -z "$fragment" ] && fragment="-"
    [ -z "$file_state" ] && file_state="unknown"
    [ -z "$names" ] && names="$unit"

    local active_text enabled_text scope_text unit_text
    active_text="$(color_active_text "$active")"
    enabled_text="$(color_enabled_text "$enabled")"
    scope_text="$(color_scope_text "$scope")"
    unit_text="$(color_unit_text "$unit" "$active" "$enabled")"

    msg "UNIT:       $unit_text
SCOPE:      $scope_text
DESC:       $desc

LOAD:       $load
ACTIVE:     $active_text
SUB:        $substate
ENABLED:    $enabled_text
FILE STATE: $file_state
ALIASES:    $names
FRAGMENT:   $fragment"
}

show_unit_cat() {
    local scope="$1" unit="$2" output
    output=$(run_scoped_systemctl "$scope" cat "$unit" 2>&1)
    scroll_box "$TITLE - cat: [$scope] $unit" "$output"
}

show_dependencies() {
    local scope="$1" unit="$2" output
    output=$(run_scoped_systemctl "$scope" list-dependencies "$unit" --no-pager 2>&1)
    scroll_box "$TITLE - deps: [$scope] $unit" "$output"
}

show_reverse_dependencies() {
    local scope="$1" unit="$2" output
    output=$(run_scoped_systemctl "$scope" list-dependencies --reverse "$unit" --no-pager 2>&1)
    scroll_box "$TITLE - reverse deps: [$scope] $unit" "$output"
}

edit_unit() {
    local scope="$1" unit="$2"
    msg "Сейчас откроется редактор для:
[$scope] $unit

После выхода обновится только этот unit."

    if [ "$scope" = "system" ]; then
        if is_root; then
            SYSTEMD_EDITOR="$EDITOR_BIN" systemctl edit "$unit"
        else
            sudo SYSTEMD_EDITOR="$EDITOR_BIN" systemctl edit "$unit"
        fi
    else
        SYSTEMD_EDITOR="$EDITOR_BIN" systemctl --user edit "$unit"
    fi

    refresh_one_unit "$scope" "$unit"
}

handle_unit_action() {
    local scope="$1" unit="$2" action="$3" out rc

    out=$(run_scoped_systemctl "$scope" "$action" "$unit" 2>&1)
    rc=$?

    if [ $rc -eq 0 ]; then
        refresh_one_unit "$scope" "$unit"
        msg "Успешно:
[$scope] systemctl $action $unit"
    else
        err "Не удалось выполнить:
[$scope] systemctl $action $unit

$out"
    fi
}

do_daemon_reload() {
    local out rc
    case "$SCOPE_MODE" in
        system) out=$(run_scoped_systemctl system daemon-reload 2>&1); rc=$? ;;
        user) out=$(run_scoped_systemctl user daemon-reload 2>&1); rc=$? ;;
        all)
            out=$(
                {
                    echo "[system]"
                    run_scoped_systemctl system daemon-reload
                    echo
                    echo "[user]"
                    run_scoped_systemctl user daemon-reload
                } 2>&1
            )
            rc=$?
            ;;
    esac

    if [ $rc -eq 0 ]; then
        msg "daemon-reload выполнен."
        build_cache
    else
        err "$out"
    fi
}

do_daemon_reexec() {
    yesno "daemon-reexec может быть чувствительной операцией.
Продолжить?" || return

    local out rc
    case "$SCOPE_MODE" in
        system) out=$(run_scoped_systemctl system daemon-reexec 2>&1); rc=$? ;;
        user) out=$(run_scoped_systemctl user daemon-reexec 2>&1); rc=$? ;;
        all)
            out=$(
                {
                    echo "[system]"
                    run_scoped_systemctl system daemon-reexec
                    echo
                    echo "[user]"
                    run_scoped_systemctl user daemon-reexec
                } 2>&1
            )
            rc=$?
            ;;
    esac

    if [ $rc -eq 0 ]; then
        msg "daemon-reexec выполнен."
        build_cache
    else
        err "$out"
    fi
}

build_checklist_array() {
    local arr=()
    local scope unit load active substate enabled desc
    local state_text short_desc a_text e_text s_text

    while IFS='|' read -r scope unit load active substate enabled desc; do
        short_desc="$(trim_desc "$desc" 24)"
        a_text="$(color_active_text "$active")"
        e_text="$(color_enabled_text "$enabled")"
        s_text="$(color_scope_text "$scope")"
        state_text="$s_text $a_text/$e_text $(unit_kind_from_name "$unit")"
        [ -n "$short_desc" ] && state_text="$state_text | $short_desc"
        arr+=("$unit@@$scope" "$state_text" "OFF")
    done < <(sorted_filtered_lines)

    printf '%s\0' "${arr[@]}"
}

mass_action_menu() {
    local raw selected_count action item scope unit result summary
    : > "$SELECTION_FILE"

    local items=()
    while IFS= read -r -d '' item; do
        items+=("$item")
    done < <(build_checklist_array)

    [ "${#items[@]}" -eq 0 ] && {
        msg "Нет units для выбора."
        return
    }

    raw=$(checklist_box \
        "$TITLE - Multi Select" \
        "Filter:$FILTER_STATE  Type:$FILTER_TYPE  Scope:$SCOPE_MODE  Core:$SHOW_CORE_SERVICES" \
        28 118 16 \
        "${items[@]}") || return

    raw=$(printf "%s" "$raw" | tr -d '"')
    [ -z "$raw" ] && return

    for item in $raw; do
        printf "%s\n" "$item" >> "$SELECTION_FILE"
    done

    selected_count=$(wc -l < "$SELECTION_FILE" | tr -d ' ')
    [ "$selected_count" -eq 0 ] && return

    action=$(menu_box \
        "$TITLE - Mass Action" \
        "Selected:$selected_count" \
        20 78 12 \
        "start" "Start" \
        "stop" "Stop" \
        "restart" "Restart" \
        "enable" "Enable" \
        "disable" "Disable" \
        "mask" "Mask" \
        "unmask" "Unmask" \
        "preset" "Preset" \
        "reset-failed" "Reset failed" \
        "cancel" "Отмена") || return

    [ "$action" = "cancel" ] && return
    yesno "Применить '$action' к $selected_count unit(s)?" || return

    summary=""
    while IFS= read -r item; do
        unit="${item%%@@*}"
        scope="${item#*@@}"

        result=$(run_scoped_systemctl "$scope" "$action" "$unit" 2>&1)
        if [ $? -eq 0 ]; then
            summary="${summary}OK   [$scope] $unit"$'\n'
        else
            summary="${summary}FAIL [$scope] $unit :: ${result//$'\n'/ }"$'\n'
        fi
    done < "$SELECTION_FILE"

    refresh_selected_units
    scroll_box "$TITLE - Mass Action Result" "$summary"
}

unit_action_menu() {
    local scope="$1" unit="$2" choice
    local active enabled active_text enabled_text

    while true; do
        active=$(run_scoped_show_prop "$scope" "$unit" "ActiveState")
        [ -z "$active" ] && active="unknown"
        if [ "$scope" = "system" ]; then
            enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
        else
            enabled=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
        fi
        [ -z "$enabled" ] && enabled="unknown"

        active_text="$(color_active_text "$active")"
        enabled_text="$(color_enabled_text "$enabled")"

        choice=$(menu_box \
            "$TITLE - $unit [$scope]" \
            "Status:$active_text  Boot:$enabled_text" \
            28 88 18 \
            "1" "Details" \
            "2" "Status" \
            "3" "Logs" \
            "4" "Start" \
            "5" "Stop" \
            "6" "Restart" \
            "7" "Enable" \
            "8" "Disable" \
            "9" "Mask" \
            "10" "Unmask" \
            "11" "Reset failed" \
            "12" "Preset" \
            "13" "Cat unit" \
            "14" "Edit unit" \
            "15" "Dependencies" \
            "16" "Reverse dependencies" \
            "17" "Back") || return

        case "$choice" in
            1) show_unit_details "$scope" "$unit" ;;
            2) show_unit_status "$scope" "$unit" ;;
            3) show_unit_logs "$scope" "$unit" ;;
            4) yesno "Запустить $unit ?" && handle_unit_action "$scope" "$unit" "start" ;;
            5) yesno "Остановить $unit ?" && handle_unit_action "$scope" "$unit" "stop" ;;
            6) yesno "Перезапустить $unit ?" && handle_unit_action "$scope" "$unit" "restart" ;;
            7) yesno "Включить автозагрузку для $unit ?" && handle_unit_action "$scope" "$unit" "enable" ;;
            8) yesno "Выключить автозагрузку для $unit ?" && handle_unit_action "$scope" "$unit" "disable" ;;
            9) yesno "Замаскировать $unit ?" && handle_unit_action "$scope" "$unit" "mask" ;;
            10) yesno "Снять mask с $unit ?" && handle_unit_action "$scope" "$unit" "unmask" ;;
            11) yesno "Сбросить failed-state для $unit ?" && handle_unit_action "$scope" "$unit" "reset-failed" ;;
            12) yesno "Применить preset для $unit ?" && handle_unit_action "$scope" "$unit" "preset" ;;
            13) show_unit_cat "$scope" "$unit" ;;
            14) edit_unit "$scope" "$unit" ;;
            15) show_dependencies "$scope" "$unit" ;;
            16) show_reverse_dependencies "$scope" "$unit" ;;
            17) return ;;
        esac
    done
}

browse_units() {
    local items=()
    local count=0
    local scope unit load active substate enabled desc short short_desc selected s u
    local a_text e_text s_text unit_text

    while IFS='|' read -r scope unit load active substate enabled desc; do
        short_desc="$(trim_desc "$desc" 28)"
        a_text="$(color_active_text "$active")"
        e_text="$(color_enabled_text "$enabled")"
        s_text="$(color_scope_text "$scope")"
        unit_text="$(color_unit_text "$unit" "$active" "$enabled")"

        short="$s_text $a_text/$e_text $(unit_kind_from_name "$unit")"
        [ -n "$short_desc" ] && short="$short | $short_desc"

        items+=("$unit@@$scope" "$short")
        count=$((count + 1))
    done < <(sorted_filtered_lines)

    if [ "$count" -eq 0 ]; then
        msg "Ничего не найдено.

Filter:$FILTER_STATE
Type:$FILTER_TYPE
Scope:$SCOPE_MODE
Sort:$SORT_MODE
Core:$SHOW_CORE_SERVICES
Search:${SEARCH_TERM:-<пусто>}"
        return
    fi

    selected=$(menu_box \
        "$TITLE - Units" \
        "Units:$count  F:$FILTER_STATE  T:$FILTER_TYPE  S:$SCOPE_MODE  Core:$SHOW_CORE_SERVICES" \
        24 116 16 \
        "${items[@]}") || return

    u="${selected%%@@*}"
    s="${selected#*@@}"
    unit_action_menu "$s" "$u"
}

quick_failed_menu() {
    local old="$FILTER_STATE"
    FILTER_STATE="failed"
    browse_units
    FILTER_STATE="$old"
}

set_search() {
    SEARCH_TERM=$(inputbox "Введи часть имени unit или description" "$SEARCH_TERM") || true
}

clear_search() {
    SEARCH_TERM=""
    msg "Поиск очищен."
}

toggle_core_services() {
    if [ "$SHOW_CORE_SERVICES" = "yes" ]; then
        SHOW_CORE_SERVICES="no"
        msg "Теперь скрываются типичные системные Ubuntu services."
    else
        SHOW_CORE_SERVICES="yes"
        msg "Теперь показываются все системные services."
    fi
}

pick_state_filter() {
    local choice
    choice=$(menu_box \
        "$TITLE - State Filter" \
        "Выбери фильтр состояния" \
        22 70 12 \
        "all" "Все" \
        "active" "Только active" \
        "failed" "Только failed" \
        "inactive" "Только inactive" \
        "enabled" "Только enabled" \
        "disabled" "Только disabled" \
        "static" "Только static" \
        "masked" "Только masked") || return
    FILTER_STATE="$choice"
}

pick_type_filter() {
    local choice old="$FILTER_TYPE"
    choice=$(menu_box \
        "$TITLE - Type Filter" \
        "Выбери тип unit" \
        20 70 10 \
        "service" "service" \
        "timer" "timer" \
        "socket" "socket" \
        "target" "target" \
        "mount" "mount" \
        "all" "все типы") || return
    FILTER_TYPE="$choice"
    [ "$old" != "$FILTER_TYPE" ] && build_cache
}

pick_scope_mode() {
    local choice old="$SCOPE_MODE"
    choice=$(menu_box \
        "$TITLE - Scope" \
        "Где смотреть units" \
        18 70 10 \
        "system" "Системные units" \
        "user" "Пользовательские units" \
        "all" "И system, и user") || return
    SCOPE_MODE="$choice"
    [ "$old" != "$SCOPE_MODE" ] && build_cache
}

pick_sort_mode() {
    local choice
    choice=$(menu_box \
        "$TITLE - Sort" \
        "Сортировка списка" \
        20 72 10 \
        "priority" "По полезности" \
        "name" "По имени" \
        "state" "По active state" \
        "enabled" "По enabled state" \
        "type" "По типу unit" \
        "scope" "По scope") || return
    SORT_MODE="$choice"
}

refresh_cache() {
    build_cache
    msg "Кеш обновлён."
}

header_text() {
    cat <<EOF
Color Tags UX TUI для systemd

F:$FILTER_STATE  T:$FILTER_TYPE  S:$SCOPE_MODE
Sort:$SORT_MODE  Core:$SHOW_CORE_SERVICES
Search:${SEARCH_TERM:-<пусто>}
UI:$UI_BIN  Editor:$EDITOR_BIN
EOF
}

advanced_menu() {
    local choice
    while true; do
        choice=$(menu_box \
            "$TITLE - Advanced" \
            "Дополнительные операции" \
            18 76 10 \
            "1" "daemon-reload" \
            "2" "daemon-reexec" \
            "3" "Назад") || return

        case "$choice" in
            1) yesno "Выполнить daemon-reload ?" && do_daemon_reload ;;
            2) do_daemon_reexec ;;
            3) return ;;
        esac
    done
}

main_menu() {
    local choice
    build_cache

    while true; do
        choice=$(menu_box \
            "$TITLE v$VERSION" \
            "$(header_text)" \
            24 86 14 \
            "1" "Открыть список units" \
            "2" "Поиск" \
            "3" "Сбросить поиск" \
            "4" "Фильтр по state" \
            "5" "Фильтр по type" \
            "6" "Scope system/user/all" \
            "7" "Сортировка" \
            "8" "Скрыть/показать core services" \
            "9" "Multi-select / mass actions" \
            "10" "Quick failed view" \
            "11" "Advanced operations" \
            "12" "Обновить кеш" \
            "13" "Выход") || exit 0

        case "$choice" in
            1) browse_units ;;
            2) set_search ;;
            3) clear_search ;;
            4) pick_state_filter ;;
            5) pick_type_filter ;;
            6) pick_scope_mode ;;
            7) pick_sort_mode ;;
            8) toggle_core_services ;;
            9) mass_action_menu ;;
            10) quick_failed_menu ;;
            11) advanced_menu ;;
            12) refresh_cache ;;
            13) exit 0 ;;
        esac
    done
}

check_dependencies
main_menu
