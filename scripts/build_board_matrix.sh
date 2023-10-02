#!/usr/bin/env bash
# shellcheck disable=2059

if [ -t 1 ]; then
    # stdout is a terminal
    GREEN=$'\e[0;32m'
    RED=$'\e[0;31m'
    NC=$'\e[0m'
fi

# usage: compile_board board shield
compile_board () {
    board="$1"
    shield="$2"
    # [ -n "$shield" ] && extra_args="-DSHIELD=\"$shield\"" || extra_args=
    artifact_name=${shield:+$shield-}${board}-zmk
    extra_args=${shield:+-DSHIELD="$shield"}
    BUILD_DIR="${1}_$SUFFIX"
    LOGFILE="$LOG_DIR/zmk_build_$artifact_name.log"
    echo -en "\n${GREEN}Building $1... ${NC}"
    west build -s "$DOCKER_ZMK_DIR/app" -d "build/$BUILD_DIR" -b "$1" "$WEST_OPTS" \
        -- -DZMK_CONFIG="$CONFIG_DIR" "$extra_args" -Wno-dev > "$LOGFILE" 2>&1
    # shellcheck disable=2181
    if [[ $? -eq 0 ]]
    then
        echo
        echo "Build log saved to \"$LOGFILE\"."
        echo "💪 ${GREEN}$artifact_name was built succesfully!${NC}"
        if [[ -f $DOCKER_ZMK_DIR/app/build/$BUILD_DIR/zephyr/zmk.uf2 ]]
        then
            TYPE="uf2"
        else
            TYPE="bin"
        fi
        echo
        # OUTPUT="$OUTPUT_DIR/$1-zmk.$TYPE"
        OUTPUT="$DOCKER_CONFIG_DIR/$artifact_name.$TYPE"
        # TODO: Use git tags to create a better extension than .bak
        echo "💾 Renaming & backing up firmware file..."
        [[ -f $OUTPUT ]] && [[ ! -L $OUTPUT ]] && mv "$OUTPUT" "$OUTPUT.bak"
        cp "$DOCKER_ZMK_DIR/app/build/$BUILD_DIR/zephyr/zmk.$TYPE" "$DOCKER_ZMK_DIR/app/build/$BUILD_DIR/zephyr/$artifact_name.$TYPE"
        cp "$DOCKER_ZMK_DIR/app/build/$BUILD_DIR/zephyr/zmk.$TYPE" "$OUTPUT" \
            && echo "⚙️ Copied firmware file to host folder."
             printf "_______________________________________\n"

    else
        echo
        cat "$LOGFILE"
        echo "${RED}🔴 Error: $artifact_name failed${NC} ⛑️ "
    fi
}


# Update west if needed
cd .. || exit
# ls $(pwd)
# ls -la ./app/west.yml

# Always re-init, it seems needed for each side?
# rm -rf "${DOCKER_ZMK_DIR}"/.west

OLD_WEST="/root/west.yml.old"
if [[ ! -f "${DOCKER_ZMK_DIR}"/.west/config ]]; then
    printf "🚀 Initiating the app... 🚀\n"
    west init -l app/
    cd "${DOCKER_ZMK_DIR}/app" || exit
    west update
else
    printf "✅ app is already initializez!\n"
fi

cd "$DOCKER_ZMK_DIR/app" || exit

if [[ -f $OLD_WEST ]]; then
    md5_old=$(md5sum $OLD_WEST | cut -d' ' -f1)
fi
if [[ $md5_old != $(md5sum ./west.yml | cut -d' ' -f1) ]]; then
    printf "\n🚀 app/west.yml has changed, Running 'west update' 🚀\n"
    echo
    cp ./west.yml $OLD_WEST
    west update
else
    echo "✅ ${DOCKER_ZMK_DIR}/app/west.yml hasn't changed!"
fi

west zephyr-export


readarray -t board_shields < <(yaml2json "$DOCKER_CONFIG_DIR"/build.yaml | jq -c -r '.include[]')

for line in "${board_shields[@]}"; do
    read -ra arr <<< "${line//,/ }"
    board=$(echo "${arr[0]}" | cut -d ':' -f 2 | sed 's/["{}}]//g')
    shield=$(echo "${arr[1]}" | cut -d ':' -f 2 | sed 's/["{}}]//g')
    printf "\n🚧 Starting the build for \"$board MCU ${shield:+($shield keyboard)}\"\n"
    printf "╰┈┈➤"
    compile_board "$board" "$shield"
    printf "\n\n"
done
echo
# grep -v -e "^#" -e "^$" "$DOCKER_ZMK_DIR/app/build/$BUILD_DIR/zephyr/.config" | sort
