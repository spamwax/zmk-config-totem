#!/usr/bin/env bash
# shellcheck disable=2059

if [ -t 1 ]; then
    # stdout is a terminal
    GREEN=$'\e[0;32m'
    RED=$'\e[0;31m'
    NC=$'\e[0m'
fi

# shellcheck disable=2295
function msg_() {
    if [[ $MTHREAD != "yes" ]]; then
        # string="$@"
        string="$*"
        del='\\n'
        while test "${string#*$del}" != "$string" ; do
          echo "${string%%$del*}"
          string="${string#*$del}"
        done
        echo "$string"
    fi
}

# usage: compile_board board shield
compile_board () {
    board="$1"
    shield="$2"
    LOGFILE="$LOG_DIR/zmk_build_$artifact_name.log"

    msg_ "west build -s $DOCKER_ZMK_DIR/app -d build/$BUILD_DIR -b $1 $WEST_OPTS -- -DZMK_CONFIG=$CONFIG_DIR $extra_args -Wno-dev > $LOGFILE 2>&1\n"
    msg_ "\n${GREEN}Building $1... ${NC}"
    west build -s "$DOCKER_ZMK_DIR/app" -d "build/$BUILD_DIR" -b "$1" "$WEST_OPTS" \
        -- -DZMK_CONFIG="$CONFIG_DIR" "$extra_args" -Wno-dev > "$LOGFILE" 2>&1
    # shellcheck disable=2181
    if [[ $? -eq 0 ]]
    then
        msg_ "\nBuild log saved to \"$LOGFILE\".\n\n"
        msg_ "💪 ${GREEN}$artifact_name was built succesfully!${NC}\n"
        if [[ -f $DOCKER_ZMK_DIR/app/build/$BUILD_DIR/zephyr/zmk.uf2 ]]
        then
            TYPE="uf2"
        else
            TYPE="bin"
        fi

        # OUTPUT="$OUTPUT_DIR/$1-zmk.$TYPE"
        [[ $artifact_name == *"_left"* ]] && artifact_name=LEFT-${artifact_name//_left/}
        [[ $artifact_name == *"_right"* ]] && artifact_name=RIGHT-${artifact_name//_right/}
        OUTPUT="$DOCKER_CONFIG_DIR/$OUTPUT_DIR/$artifact_name.$TYPE"
        # TODO: Use git tags to create a better extension than .bak
        msg_ "💾 Renaming & backing up firmware file & CONFIG_* file...\n"
        [[ -f $OUTPUT ]] && [[ ! -L $OUTPUT ]] && mv "$OUTPUT" "$OUTPUT.bak"

        # Also copy CONFIG_* settings for possible debugging purposes.
        CONFIG_OUTPUT="$DOCKER_CONFIG_DIR/$OUTPUT_DIR/CONFIG_$artifact_name.ini"
        [[ -f $CONFIG_OUTPUT ]] && [[ ! -L $CONFIG_OUTPUT ]] && mv "$CONFIG_OUTPUT" "$CONFIG_OUTPUT.bak"
        grep -v -e "^#" -e "^$" "$DOCKER_ZMK_DIR/app/build/$BUILD_DIR/zephyr/.config" | \
            sort > "$CONFIG_OUTPUT"

        cp "$DOCKER_ZMK_DIR/app/build/$BUILD_DIR/zephyr/zmk.$TYPE" \
            "$DOCKER_ZMK_DIR/app/build/$BUILD_DIR/zephyr/$artifact_name.$TYPE"

        cp "$DOCKER_ZMK_DIR/app/build/$BUILD_DIR/zephyr/zmk.$TYPE" "$OUTPUT" \
            && msg_ "⚙️ Copied firmware file to host folder:\n" && \
            echo "    -> $OUTPUT"
    else
        echo
        cat "$LOGFILE"
        printf "\n%s\n" "${RED}🔴 Error: $artifact_name failed${NC} ⛑️ "
        exit 1
    fi
}

prev_dir=$(pwd)

# Update west if needed
# echo "$DOCKER_ZMK_DIR"
cd "$DOCKER_ZMK_DIR" || exit

export ZEPHYR_VERSION="$ZEPHYR_VERSION"

# ls $(pwd)
# ls -la ./app/west.yml

# Always re-init, it seems needed for each side?
# rm -rf "${DOCKER_ZMK_DIR}"/.west

OLD_WEST="/root/west.yml.old"
if [[ ! -f "${DOCKER_ZMK_DIR}"/.west/config ]]; then
    msg_ "🚀 Initializing the app... 🚀\n\n"
    west init -l app/
    cd "${DOCKER_ZMK_DIR}" || exit
    west update
else
    msg_ "\n✅ app is already initialized!\n\n"
fi

cd "$DOCKER_ZMK_DIR/app" || exit

if [[ -f $OLD_WEST ]]; then
    md5_old=$(md5sum $OLD_WEST | cut -d' ' -f1)
fi
if [[ $md5_old != $(md5sum ./west.yml | cut -d' ' -f1) ]]; then
    msg_ "\n🚀 Found fresh app/west.yml, Running 'west update' 🚀\n\n"
    cp ./west.yml $OLD_WEST
    west update
else
    msg_ "✅ ${DOCKER_ZMK_DIR}/app/west.yml hasn't changed!\n\n"
fi

west zephyr-export >/dev/null


artifact_name=${shield:+$shield-}${board}-zmk
extra_args=${shield:+-DSHIELD="$shield"}
BUILD_DIR="${artifact_name}_$SUFFIX"
if [ -d "$DOCKER_ZMK_DIR"/app/build/"$BUILD_DIR" ]; then
    rm -rf "$DOCKER_ZMK_DIR/app/build/$BUILD_DIR"
    msg_ "♻ Removed old build directory before starting the build process.\n"
fi

compile_board "$board" "$shield"

cd "$prev_dir" || exit

