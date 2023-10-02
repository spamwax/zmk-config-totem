#!/usr/bin/env bash
# shellcheck disable=2059
if [ -t 1 ]; then
    # stdout is a terminal
    # shellcheck disable=2034
    GREEN=$'\e[0;32m'
    # shellcheck disable=2034
    RED=$'\e[0;31m'
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

        -m|--multithread)
            # shellcheck disable=2034
            MULTITHREAD="true"
            ;;

        -c|--clear-cache)
            CLEAR_CACHE="true"
            ;;

        # comma or space separated list of boards (use quotes if space separated)
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

[[ -z $OUTPUT_DIR ]] && OUTPUT_DIR="$HOME/Downloads"
[[ -z $LOG_DIR ]] && LOG_DIR="/tmp"

[[ -z $HOST_ZMK_DIR ]] && HOST_ZMK_DIR="$HOME/projects/zmk_firmwares/zmk"
[[ -z $HOST_CONFIG_DIR ]] && HOST_CONFIG_DIR="$HOME/projects/zmk_firmwares/zmk-config-totem"

[[ -z $DOCKER_ZMK_DIR ]] && DOCKER_ZMK_DIR="/workspace/zmk"
[[ -z $DOCKER_CONFIG_DIR ]] && DOCKER_CONFIG_DIR="/workspace/zmk-config"

[[ -z $BOARDS ]] && BOARDS="$(grep '^[[:space:]]*\-[[:space:]]*board:' "$HOST_CONFIG_DIR/build.yaml" | sed 's/^.*: *//')"

[[ -z $CLEAR_CACHE ]] && CLEAR_CACHE="false"

# Set env list to be used by Docker later
rm -f "$HOST_CONFIG_DIR/env.list"
# shellcheck disable=2129
echo "ZEPHYR_VERSION=$ZEPHYR_VERSION" >> "$HOST_CONFIG_DIR/env.list"
echo "OUTPUT_DIR=$OUTPUT_DIR" >> "$HOST_CONFIG_DIR/env.list"
echo "LOG_DIR=$LOG_DIR" >> "$HOST_CONFIG_DIR/env.list"
echo "HOST_ZMK_DIR=$HOST_ZMK_DIR" >> "$HOST_CONFIG_DIR/env.list"
echo "HOST_CONFIG_DIR=$HOST_CONFIG_DIR" >> "$HOST_CONFIG_DIR/env.list"
echo "DOCKER_ZMK_DIR=$DOCKER_ZMK_DIR" >> "$HOST_CONFIG_DIR/env.list"
echo "DOCKER_CONFIG_DIR=$DOCKER_CONFIG_DIR" >> "$HOST_CONFIG_DIR/env.list"
echo "OUTPUT_DIR=$OUTPUT_DIR" >> "$HOST_CONFIG_DIR/env.list"
echo "WEST_OPTS=$WEST_OPTS" >> "$HOST_CONFIG_DIR/env.list"
echo "CONFIG_DIR=$DOCKER_CONFIG_DIR/config" >> "$HOST_CONFIG_DIR/env.list"

zmk_type=dev
zmk_tag="3.2"

DOCKER_IMG="zmkfirmware/zmk-$zmk_type-arm:$zmk_tag"
DOCKER_IMG="private/zmk"
DOCKER_BIN="docker"

"$DOCKER_BIN" build --build-arg zmk_type=$zmk_type --build-arg zmk_tag="$zmk_tag" -t private/zmk . >/dev/null || exit

# +-------------------------+
# | AUTOMATE CONFIG OPTIONS |
# +-------------------------+

cd "$HOST_CONFIG_DIR" || exit

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


if [[ $RUNWITH_DOCKER = true ]]
then
    printf "\nBuild mode: docker\n"
    echo
    echo "📦 Building Dockerfile 📦"
    DOCKER_CMD="$DOCKER_BIN run --rm \
        --mount type=bind,source=$HOST_ZMK_DIR,target=$DOCKER_ZMK_DIR \
        --mount type=bind,source=$HOST_CONFIG_DIR,target=$DOCKER_CONFIG_DIR \
        --mount type=volume,source=zmk-root-user-$ZEPHYR_VERSION,target=/root \
        --mount type=volume,source=zmk-zephyr-$ZEPHYR_VERSION,target=$DOCKER_ZMK_DIR/zephyr \
        --mount type=volume,source=zmk-zephyr-modules-$ZEPHYR_VERSION,target=$DOCKER_ZMK_DIR/modules \
        --mount type=volume,source=zmk-zephyr-tools-$ZEPHYR_VERSION,target=$DOCKER_ZMK_DIR/tools"

    #
    # | Cleanup and shit |
    #

    # Reset volumes
    if [[ $CLEAR_CACHE = true ]]
    then
        printf "\n${CYAN}💀 Removing Docker volumes\n${NC}"
        # TODO: When there is no Docker volume, next line returns error
        # shellcheck disable=2046
        $DOCKER_BIN volume rm $($DOCKER_BIN volume ls -q | grep "^zmk-.*-$ZEPHYR_VERSION$")
        printf "${CYAN}💀 Deleting 'build' folder.\n${NC}"
        sudo rm -rf "$HOST_ZMK_DIR/app/build"
        sudo rm -rf "$HOST_ZMK_DIR/.west"
    fi

    # Build parameters
    SUFFIX="${ZEPHYR_VERSION}_docker"
    echo "SUFFIX=$SUFFIX" >> "$HOST_CONFIG_DIR/env.list"

    DOCKER_PREFIX="$DOCKER_CMD -w $DOCKER_ZMK_DIR/app --env-file $HOST_CONFIG_DIR/env.list $DOCKER_IMG"
    $DOCKER_PREFIX "$DOCKER_CONFIG_DIR/scripts/build_board_matrix.sh" || exit

    cd "$HOST_CONFIG_DIR" || exit
    firmware_files=$(find . -name '*.uf2' | tr '\n' ' ' | sed 's/.\///g' | sed 's/ $//' | sed 's/ /  /')
    scp ./*.uf2 10.42.0.2:~/Downloads >/dev/null && echo "🗄 Copied firmware(s) files to macOS"
    printf "╰┈┈┈┈┈┈➤ $firmware_files\n"

    echo
    printf "Done! 🎉 😎 🎉\n"

else
    echo "Build mode: local"
    SUFFIX="${ZEPHYR_VERSION}"
    CONFIG_DIR="$HOST_CONFIG_DIR/config"
    DOCKER_PREFIX=
    cd "$HOST_ZMK_DIR/app" || exit
fi


exit


















# . ./create_build_matrix.sh

# # usage: compile_board board shield
# compile_board () {
#     board="$1"
#     shield="$2"
#     # [ -n "$shield" ] && extra_args="-DSHIELD=\"$shield\"" || extra_args=
#     artifact_name=${shield:+$shield-}${board}-zmk
#     extra_args=${shield:+-DSHIELD=\"$shield\"}
#     BUILD_DIR="${1}_$SUFFIX"
#     LOGFILE="$LOG_DIR/zmk_build_$artifact_name.log"
#     [[ $MULTITHREAD = "true" ]] || echo -en "\n$(tput setaf 2)Building $1... $(tput sgr0)"
#     [[ $MULTITHREAD = "true" ]] && echo -e "$(tput setaf 2)Building $1... $(tput sgr0)"
#     $DOCKER_PREFIX west build -d "build/$BUILD_DIR" -b "$1" "$WEST_OPTS" \
#         -- -DZMK_CONFIG="$CONFIG_DIR" "$extra_args" -Wno-dev > "$LOGFILE" 2>&1
#     if [[ $? -eq 0 ]]
#     then
#         [[ $MULTITHREAD = "true" ]] || echo "$(tput setaf 2)done$(tput sgr0)"
#         echo "Build log saved to \"$LOGFILE\"."
#         if [[ -f $HOST_ZMK_DIR/app/build/$BUILD_DIR/zephyr/zmk.uf2 ]]
#         then
#             TYPE="uf2"
#         else
#             TYPE="bin"
#         fi
#         # OUTPUT="$OUTPUT_DIR/$1-zmk.$TYPE"
#         OUTPUT="$OUTPUT_DIR/$artifact_name.$TYPE"
#         [[ -f $OUTPUT ]] && [[ ! -L $OUTPUT ]] && mv "$OUTPUT" "$OUTPUT.bak"
#         cp "$HOST_ZMK_DIR/app/build/$BUILD_DIR/zephyr/zmk.$TYPE" "$HOST_ZMK_DIR/app/build/$BUILD_DIR/zephyr/$artifact_name.$TYPE"
#         cp "$HOST_ZMK_DIR/app/build/$BUILD_DIR/zephyr/zmk.$TYPE" "$OUTPUT"
#     else
#         echo
#         cat "$LOGFILE"
#         echo "$(tput setaf 1)Error: $1 failed$(tput sgr0)"
#     fi
# }

# cd "$HOST_ZMK_DIR/app" || exit
# if [[ $MULTITHREAD = "true" ]]; then
#     i=1
#     for board in $(echo "$BOARDS" | sed 's/,/ /g')
#     do
#         compile_board "$board" &
#         eval "T${i}=\${!}"
#         eval "B${i}=\$board"  # Store the board name in a corresponding variable
#         ((i++))
#     done

#     echo "Starting $(($i - 1)) background threads:"
#     for ((x=1; x<i; x++))
#     do
#         pid="T$x"
#         wait "${!pid}"
#         board="B$x"  # Retrieve the board name from the corresponding variable
#         echo -e "$(tput setaf 3)Thread $x with PID ${!pid} has finished: ${!board}$(tput sgr0)"
#     done
# else
#     readarray -t board_shields < <(yaml2json "$DOCKER_CONFIG_DIR"/build.yaml | jq -c -r '.include[]')

#     for line in "${board_shields[@]}"; do
#       echo; echo;
#       echo "Processing $line"
#       echo "-->> ${line//,/ }"
#       read -ra arr <<< "${line//,/ }"
#       board=$(echo "${arr[0]}" | cut -d ':' -f 2 | sed 's/["{}}]//g')
#       shield=$(echo "${arr[1]}" | cut -d ':' -f 2 | sed 's/["{}}]//g')
#       compile_board "$board" "$shield"
#     done
# fi
