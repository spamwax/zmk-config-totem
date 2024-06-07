#!/usr/bin/env bash

# shellcheck disable=2034
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck disable=2059
if [ -t 1 ]; then
    # stdout is a terminal
    # shellcheck disable=2034
    GREEN=$'\e[0;32m'
    # shellcheck disable=2034
    RED=$'\e[0;31m'
    YELLOW=$'\e[0;33m'
    CYAN=$'\e[1;34m'
    NC=$'\e[0m'
fi

# Parse input arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        # needed when user isn't in docker group
        -s|--su)
            # shellcheck disable=2034
            SUDO="sudo"
            ;;

        -m|--multithread)
            # shellcheck disable=2034
            MULTITHREAD="true"
            ;;

        -c|--clear-cache)
            CLEAR_CACHE="true"
            ;;

        # comma separated list of boards (use quotes if space separated)
        # if ommitted, will compile list of boards in build.yaml
        -b|--board)
            BOARDS="$2"
            shift
            ;;

        -v|--version)
            ZEPHYR_VERSION="$2"
            shift
            ;;

        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift
            ;;

        --log-dir)
            LOG_DIR="$2"
            shift
            ;;

        --docker-zmk-dir)
            DOCKER_ZMK_DIR="$2"
            shift
            ;;

        --)
            # shellcheck disable=2124
            WEST_OPTS="${@:2}"
            break
            ;;

        *)
            echo "Unknown option $1"
            exit 1
            ;;

    esac
    shift
done

# Set defaults
[[ -z $ZEPHYR_VERSION ]] && ZEPHYR_VERSION="3.5.0"

local_config="$SCRIPT_DIR"/.. 
local_zmk="$local_config"/../zmk
local_output="$local_config/output"

OUTPUT_DIR=${OUTPUT_DIR:-output}
[[ -z $LOG_DIR ]] && LOG_DIR="/tmp"

cd "$local_zmk" || exit
git config --global --add safe.directory /workspace/zmk
if ! git ls-files >/dev/null 2>&1; then
    printf "%s\n" "${RED}zmk repo is missing!"
    exit 2
else
    git pull origin main >/dev/null 2>&1
fi
cd - >/dev/null || exit

if [[ -z $BOARDS ]]; then
    # BOARDS="$(grep '^[[:space:]]*\-[[:space:]]*board:' "$HOST_CONFIG_DIR/build.yaml" | sed 's/^.*: *//')"
    build_all=yes
    printf "\n%s Will build all boards in build.yaml\n" "${YELLOW}WARNING!${NC}"
else
    build_all=no
    IFS=, read -ra BOARDS <<< "$BOARDS"
    echo; echo "${CYAN}Selected${NC} boards to build:" "${BOARDS[@]}"
    readarray -t avails < <(grep '^[[:space:]]*\-[[:space:]]*board:' build.yaml | sed 's/^.*: *//')
    for item  in "${BOARDS[@]}"; do
        # if [[ " ${avails[*]} " =~ " ${item} " ]]; then
        if [[ " ${avails[*]} " == *" ${item} "* ]]; then
            echo "    ${GREEN}$item${NC} will be built."
        else
            echo "    ${RED}$item${NC} is not a valid board in build.yaml"
        fi
    done
    echo "------------------------"; echo
fi


[[ -z $CLEAR_CACHE ]] && CLEAR_CACHE="false"

printf "\n%s\n\n" "${YELLOW}ATTENTION!${NC} Building locally!"
USERNAME=$(id -un)
USERUID=$(id -u)
USERGID=$(id -g)
USERNAME="hamid"
USERUID="1000"
USERGID="1000"

DOCKER_ZMK_DIR="$local_zmk"
DOCKER_CONFIG_DIR="$local_config"
CONFIG_DIR="$DOCKER_CONFIG_DIR/config"

# +-------------------------+
# | AUTOMATE CONFIG OPTIONS |
# +-------------------------+

cd "$local_config" || exit

if [[ -f config/combos.dtsi ]]
    # update maximum combos per key
    then
    count=$( \
        tail -n +10 config/combos.dtsi | \
        grep -Eo '[LR][TMBH][0-9]' | \
        sort | uniq -c | sort -nr | \
        awk 'NR==1{print $1}' \
    )
    sed -Ei "/CONFIG_ZMK_COMBO_MAX_COMBOS_PER_KEY/s/=.+/=$count/" config/*.conf
    echo "Setting MAX_COMBOS_PER_KEY to $count"

    # update maximum keys per combo
    count=$( \
        tail -n +10 config/combos.dtsi | \
        grep -o -n '[LR][TMBH][0-9]' | \
        cut -d : -f 1 | uniq -c | sort -nr | \
        awk 'NR==1{print $1}' \
    )
    sed -Ei "/CONFIG_ZMK_COMBO_MAX_KEYS_PER_COMBO/s/=.+/=$count/" config/*.conf
    echo "Setting MAX_KEYS_PER_COMBO to $count"
fi

# +--------------------+
# | BUILD THE FIRMWARE |
# +--------------------+

SUFFIX="${ZEPHYR_VERSION}_devcontainer"

# | Cleanup and shit |
#
# Reset volumes
if [[ $CLEAR_CACHE = true ]]; then
    printf "\n==-> Clearing cache and starting a fresh build <-==\n"
    printf "\n%s\n" "${CYAN}💀 Cleaning Docker volumes content.${NC}"
    rm -rf /root/west.yml*
    rm -rf "$local_zmk/app/build"
    rm -rf "$local_zmk/.west"
    rm -rf "${local_output:?}"/*
    for f in {zephyr,modules,tools}; do
        rm -rf "/workspace/zmk/$f" >/dev/null 2>&1
    done
fi

# Only run a multithread build if we are not doing a fresh/clean build.
MTHREAD=
MTHREAD=$([[ $CLEAR_CACHE == false ]] && [[ -n $MULTITHREAD ]] && echo yes)
readarray -t board_shields < <(yaml2json "$local_config"/build.yaml | jq -c -r '.include[]')

if [[ $MTHREAD == "yes" ]]; then
    counter=1
    for pair in "${board_shields[@]}"; do
        # Construct board/shield names
        read -ra arr <<< "${pair//,/ }"
        board=$(echo "${arr[0]}" | cut -d ':' -f 2 | sed 's/["{}}]//g')
        shield=$(echo "${arr[1]}" | cut -d ':' -f 2 | sed 's/["{}}]//g')
        if [ $build_all = "no" ]; then
            # if [[ " ${BOARDS[*]} " =~ " ${board} " ]]; then
            if [[ " ${BOARDS[*]} " == *" ${board} "* ]]; then
                echo "✅ ${GREEN}Found${NC} requested \"$board${shield:+" ($shield)"}\" board!"; echo
            else
                echo "📢 ${YELLOW}Skipping${NC} building \"$board${shield:+" ($shield)"}\"!"; echo
                continue
            fi
        fi
        # shellcheck source=build_board_matrix.sh
        . "$SCRIPT_DIR"/build_board_matrix.sh &
        sleep 0.75
        eval "T${counter}=\${!}"
        eval "B${counter}=\$board-\$shield"  # Store the board name in a corresponding variable
        ((counter++))
    done
    # shellcheck disable=2031,2004
    printf "%s\n" "${YELLOW}Started $(($counter - 1)) background threads${NC}"
    while :
    do
        for ((x=1; x<counter; x++))
        do
            pid="T$x"
            _board="B$x"
            if ps -p "${!pid}" >/dev/null 2>&1; then
                printf '%c' '.'
                # shellcheck disable=2004
                _DONE[$x]=0
            else
                # shellcheck disable=2031
                [[ ${_DONE[$x]} = 0 ]] && printf " %s " "${GREEN}${!_board}: done. 🏁${NC}"
                # shellcheck disable=2004
                _DONE[$x]=1
            fi
        done
        _r=1
        for ((x=1; x<counter; x++))
        do
            if [[ ${_DONE[$x]} = 0 ]]; then _r=0; fi
        done
        if [[ $_r = 1 ]]; then break; fi
        sleep 0.75
    done
else
    for pair in "${board_shields[@]}"; do
        # Construct board/shield names
        read -ra arr <<< "${pair//,/ }"
        board=$(echo "${arr[0]}" | cut -d ':' -f 2 | sed 's/["{}}]//g')
        shield=$(echo "${arr[1]}" | cut -d ':' -f 2 | sed 's/["{}}]//g')
        if [ $build_all = "no" ]; then
            # if [[ " ${BOARDS[*]} " =~ " ${board} " ]]; then
            if [[ " ${BOARDS[*]} " == *" ${board} "* ]]; then
                # shellcheck disable=2031
                echo "✅ ${GREEN}Found${NC} requested \"$board${shield:+" ($shield)"}\" board!"; echo
            else
                # shellcheck disable=2031
                echo "📢 ${YELLOW}Skipping${NC} building \"$board${shield:+" ($shield)"}\"!"; echo
                continue
            fi
        fi
        # shellcheck disable=2031
        printf "\n%s\n" "🚧 Run west to build \"$board MCU ${shield:+(${CYAN}$shield${NC} keyboard)}\""
        printf "╰┈┈➤"
        shield=$(echo "${arr[1]}" | cut -d ':' -f 2 | sed 's/["{}}]//g')
        # shellcheck source=build_board_matrix.sh
        . "$SCRIPT_DIR"/build_board_matrix.sh
        printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n\n"
    done
fi

    # printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n\n"
# done
echo
# Copy firmware files to macOS
cd "$local_output" || exit
firmware_files=$(find . -name '*.uf2' | tr '\n' ' ' | sed 's/.\///g' | sed 's/ $//' | sed 's/ /  /')

if scp ./*.uf2 192.168.13.200:~/Downloads >/dev/null; then
    echo "🗄 Sent all firmware files to ${GREEN}macOS${NC}."
    printf "Done! 🎉 😎 🎉\n"
else
    echo "${RED}🔴 Error: couldn't copy to remote computer!"
fi
printf "%s" "╰┈┈┈┈┈┈➤ $firmware_files"
echo
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n\n"
