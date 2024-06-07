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

        -l|--local)
            RUNWITH_DOCKER="false"
            ;;

        -r|--remote-docker)
            REMOTE_DOCKER="true"
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

        --host-config-dir)
            HOST_CONFIG_DIR="$2"
            shift
            ;;

        --host-zmk-dir)
            HOST_ZMK_DIR="$2"
            shift
            ;;

        --docker-config-dir)
            DOCKER_CONFIG_DIR="$2"
            shift
            ;;

        --docker-zmk-dir)
            DOCKER_ZMK_DIR="$2"
            shift
            ;;

        --)
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
[[ -z $ZEPHYR_VERSION ]] && ZEPHYR_VERSION="3.2.0"
[[ -z $RUNWITH_DOCKER ]] && RUNWITH_DOCKER="true"

[[ -z $HOST_ZMK_DIR ]] && HOST_ZMK_DIR="/tank/anbaar/projects/hobbies/zmk_firmwares/zmk"
[[ -z $HOST_CONFIG_DIR ]] && HOST_CONFIG_DIR="/tank/anbaar/projects/hobbies/zmk_firmwares/zmk-config-totem"

OUTPUT_DIR=${OUTPUT_DIR:-output}
[[ -z $LOG_DIR ]] && LOG_DIR="/tmp"

[[ -z $DOCKER_ZMK_DIR ]] && DOCKER_ZMK_DIR="/workspace/zmk"
[[ -z $DOCKER_CONFIG_DIR ]] && DOCKER_CONFIG_DIR="/workspace/zmk-config"

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
        if [[ " ${avails[*]} " =~ " ${item} " ]]; then
            echo "    ${GREEN}$item${NC} will be built."
        else
            echo "    ${RED}$item${NC} is not a valid board in build.yaml"
        fi
    done
    echo "------------------------"; echo
fi


[[ -z $CLEAR_CACHE ]] && CLEAR_CACHE="false"

if [[ -n $REMOTE_DOCKER ]]; then
  printf "\n%s\n" "${YELLOW}ATTENTION!${NC} Using remote Docker!"
  [[ -z $DOCKER_HOST ]] \
      && printf "\n%s\n" "DOCKER_HOST env. variable is NOT set." \
      && printf "\t%s\n" "Set it like ${CYAN}export DOCKER_HOST=ssh://khersak${NC}" \
      && printf "\t%s\n" "${RED}Aborting!${NC}" \
      && exit
  local_config="$SCRIPT_DIR"/.. 
  local_zmk="$local_config"/../zmk
  local_output="$local_config/output"
  USERNAME="hamid"
  USERUID="1000"
  USERGID="1000"
else
  printf "\n%s\n" "${YELLOW}ATTENTION!${NC} Using local Docker!"
  local_config="$HOST_CONFIG_DIR"
  local_zmk="$HOST_ZMK_DIR"
  local_output="$local_config/output"
  USERNAME=$(id -un)
  USERUID=$(id -u)
  USERGID=$(id -g)
fi

# Set env list to be used by Docker later
rm -f "$local_config/env.list"
rm -f "$local_config/.env"
# shellcheck disable=2129
echo "ZEPHYR_VERSION=$ZEPHYR_VERSION" >> "$local_config/env.list"
echo "OUTPUT_DIR=$OUTPUT_DIR" >> "$local_config/env.list"
echo "LOG_DIR=$LOG_DIR" >> "$local_config/env.list"
echo "HOST_ZMK_DIR=$HOST_ZMK_DIR" >> "$local_config/env.list"
echo "HOST_CONFIG_DIR=$HOST_CONFIG_DIR" >> "$local_config/env.list"
echo "DOCKER_ZMK_DIR=$DOCKER_ZMK_DIR" >> "$local_config/env.list"
echo "DOCKER_CONFIG_DIR=$DOCKER_CONFIG_DIR" >> "$local_config/env.list"
echo "WEST_OPTS=$WEST_OPTS" >> "$local_config/env.list"
echo "CONFIG_DIR=$DOCKER_CONFIG_DIR/config" >> "$local_config/env.list"

zmk_type=dev
zmk_tag="3.2"

DOCKER_IMG="zmkfirmware/zmk-$zmk_type-arm:$zmk_tag"
DOCKER_IMG="private/zmk"
DOCKER_BIN="docker"

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

if [[ $RUNWITH_DOCKER = true ]]; then
    printf "\nBuild mode: docker\n"
    SUFFIX="${ZEPHYR_VERSION}_docker"

    printf "\n📦 Building Dockerfile 📦\n"
    "$DOCKER_BIN" build --build-arg zmk_type=$zmk_type --build-arg zmk_tag="$zmk_tag" \
        --build-arg USERNAME="$USERNAME" --build-arg USERUID="$USERUID" --build-arg USERGID="$USERGID" \
        -t private/zmk . >/dev/null || exit

    printf "     Done.\n"
    #
    # | Cleanup and shit |
    #
    # Reset volumes
    if [[ $CLEAR_CACHE = true ]]; then
        printf "\n==-> Clearing cache and starting a fresh build <-==\n"
        printf "\n%s\n" "${CYAN}💀 Removing Docker volumes.${NC}"
        $DOCKER_BIN volume ls -q | grep "^zmk-.*-$ZEPHYR_VERSION$" | while read -r _v; do
            $DOCKER_BIN volume rm "$_v"
        done
        printf "%s\n" "${CYAN}💀 Deleting 'build' folder.${NC}"
        sudo rm -rf "$local_zmk/app/build"
        sudo rm -rf "$local_zmk/.west"
        sudo rm -rf "$local_output"/*
    fi
else
    printf "\nBuild mode: local\n"
    if [[ $CLEAR_CACHE = true ]]; then
        printf "\n==-> Clearing cache and starting a fresh build <-==\n"
        printf "%s\n" "${CYAN}💀 Deleting 'build' folder.${NC}"
        sudo rm -rf "$local_zmk/app/build"
        sudo rm -rf "$local_zmk/.west"
        sudo rm -rf "$local_output"/*
        sudo /usr/bin/rm -rf /tank/anbaar/projects/hobbies/zmk_firmwares/zmk-config-totem/output/*
    fi
    SUFFIX="${ZEPHYR_VERSION}"
    CONFIG_DIR="$HOST_CONFIG_DIR/config"
    DOCKER_PREFIX=
fi
echo
readarray -t board_shields < <(yaml2json "$local_config"/build.yaml | jq -c -r '.include[]')

for pair in "${board_shields[@]}"; do
    # Construct board/shield names
    read -ra arr <<< "${pair//,/ }"
    board=$(echo "${arr[0]}" | cut -d ':' -f 2 | sed 's/["{}}]//g')
    shield=$(echo "${arr[1]}" | cut -d ':' -f 2 | sed 's/["{}}]//g')
    if [ $build_all = "no" ]; then
        if [[ " ${BOARDS[*]} " =~ " ${board} " ]]; then
            echo "✅ ${GREEN}Found${NC} requested \"$board${shield:+" ($shield)"}\" board!"; echo
        else
            echo "📢 ${YELLOW}Skipping${NC} building \"$board${shield:+" ($shield)"}\"!"; echo
            continue
        fi
    fi
    echo "Starting the build process for \"$board${shield:+" ($shield)"}\"."; echo

    if [[ $RUNWITH_DOCKER = true ]]; then
        # shellcheck disable=2129
        echo "SUFFIX=$SUFFIX" >> "$local_config/env.list"
        echo "board=$board" >> "$local_config/env.list"
        echo "shield=$shield" >> "$local_config/env.list"
        echo "local_config=$local_config" >> "$local_config/env.list"
        # USER_ID=1000
        # GROUP_ID=1000
        echo "USER_ID=$USERUID" >> "$local_config/env.list"
        echo "GROUP_ID=$USERGID" >> "$local_config/env.list"
        cp "$local_config/env.list" "$local_config/.env"
        DOCKER_CMD="$DOCKER_BIN run --rm \
            --mount type=bind,source=$HOST_ZMK_DIR,target=$DOCKER_ZMK_DIR \
            --mount type=bind,source=$HOST_CONFIG_DIR,target=$DOCKER_CONFIG_DIR \
            --mount type=bind,source=$LOG_DIR,target=/tmp  \
            --mount type=volume,source=zmk-root-user-$ZEPHYR_VERSION,target=/root \
            --mount type=volume,source=zmk-zephyr-$ZEPHYR_VERSION,target=$DOCKER_ZMK_DIR/zephyr \
            --mount type=volume,source=zmk-zephyr-modules-$ZEPHYR_VERSION,target=$DOCKER_ZMK_DIR/modules \
            --mount type=volume,source=zmk-zephyr-tools-$ZEPHYR_VERSION,target=$DOCKER_ZMK_DIR/tools"

        # Run Docker to build firmware for board/shield combo
        printf "\n%s\n" "🚧 Run Docker to build \"$board MCU ${shield:+(${CYAN}$shield${NC} keyboard)}\""
        printf "╰┈┈➤"
        DOCKER_PREFIX="$DOCKER_CMD -w $DOCKER_ZMK_DIR/app --env-file $local_config/env.list $DOCKER_IMG"

        docker-compose --env-file "$local_config"/env.list run --workdir "$DOCKER_ZMK_DIR"/app --rm build || exit
        # docker-compose --env-file "$local_config"/env.list run --workdir "$DOCKER_ZMK_DIR"/app --rm change-vol-ownership || exit
        docker-compose rm --force

        printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n\n"
    else
        echo
        cd "$HOST_ZMK_DIR/app" || exit
    fi
done

# Copy firmware files to macOS
cd "$local_output" || exit
firmware_files=$(find . -name '*.uf2' | tr '\n' ' ' | sed 's/.\///g' | sed 's/ $//' | sed 's/ /  /')
if [[ -n $REMOTE_DOCKER ]]; then
  cp  ./*.uf2 ~/Downloads >/dev/null && echo "🗄 Copied all firmwares file to ${GREEN}Download${NC} folder."
else
  scp ./*.uf2 192.168.13.200:~/Downloads >/dev/null && echo "🗄 Sent all firmware files to ${GREEN}macOS${NC}."
fi
printf "%s" "╰┈┈┈┈┈┈➤ $firmware_files"
echo
printf "Done! 🎉 😎 🎉\n"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n\n"
