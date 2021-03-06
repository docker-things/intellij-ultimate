#!/bin/bash

# WhereAmI function
function get_script_dir() {
     SOURCE="${BASH_SOURCE[0]}"
     while [ -h "$SOURCE" ]; do
          DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
          SOURCE="$( readlink "$SOURCE" )"
          [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
     done
     DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
     echo "$DIR"
}
cd "$(get_script_dir)"

# Load the config
. config.sh

# Make sure there's a tag
if [[ $PROJECT_NAME != *":"* ]]; then
    PROJECT_NAME="${PROJECT_NAME}:latest"
fi

# Output functions
function showNormal() { echo -e "\033[00m$@"; }
function showGreen() { echo -e "\033[01;32m$@\033[00m"; }
function showYellow() { echo -e "\033[01;33m$@\033[00m"; }
function showRed() { echo -e "\033[01;31m$@\033[00m"; }

# Launch the required action
function scriptRun() {
    case "$1" in
        "build")       scriptBuild $@      ;;
        "start")       scriptStart $@      ;;
        "logs")        scriptLogs $@       ;;
        "status")      scriptStatus $@     ;;
        "connect")     scriptConnect $@    ;;
        "stop")        scriptStop $@       ;;
        "kill")        scriptKill $@       ;;
        "restart")     scriptRestart $@    ;;
        "backup")      scriptBackup $@     ;;
        "remove")      scriptRemove $@     ;;
        "restore")     scriptRestore $@    ;;
        "install")     scriptInstall $@    ;;
        "clear-data")  scriptClearData $@  ;;
        "set-default") scriptSetDefault $@ ;;
        *)             showUsage $@        ;;
    esac
}

# Show script usage
function showUsage() {
    showNormal "\nUsage: bash $0 [build|start|logs|status|connect|stop|kill|restart|backup|remove|restore|install|clear-data|set-default]\n"
    exit 1
}

# Build the docker image, pull the GIT repository and pull the DB from master
function scriptBuild() {

    # Check if DOCKER is installed
    command -v docker >/dev/null 2>&1 || {
        showRed "\n[ERROR] You need docker installed to run this. Here's how to install it:" \
                "\n        https://docs.docker.com/install/\n"
        exit 1
    }

    # Mark start time
    startTime="`date +"%Y-%m-%d %H:%M:%S"`"

    # Build the image
    showGreen "\n > Building image..."
    $DOCKER_CMD build ${BUILD_ARGS[@]} -t "$PROJECT_NAME" .

    # Exit if the bulid failed
    if [ $? -eq 1 ]; then
        showRed "\n[ERROR] Build failed!\n"
        exit 1
    fi

    # Get the images list
    imagesList="`$DOCKER_CMD images`"

    # Exit if the image doesn't exist
    TMP_NAME="`echo "$PROJECT_NAME" | awk -F':' '{print $1}'`"
    TMP_TAG="`echo "$PROJECT_NAME" | awk -F':' '{print $2}'`"
    if [ "`echo -e "$imagesList" | grep "$TMP_NAME" | grep "$TMP_TAG"`" == "" ]; then
        showRed "\n[ERROR] Build failed! Available images:\n"
        showNormal "$imagesList"
        exit 1
    fi

    # Remove unused parts
    showGreen "\n > Removing unused parts..."
    $DOCKER_CMD system prune -f

    # Show result
    showGreen "\n > Built image:"
    showNormal "$imagesList" | grep "REPOSITORY"

    TMP_NAME="`echo "$PROJECT_NAME" | awk -F':' '{print $1}'`"
    TMP_TAG="`echo "$PROJECT_NAME" | awk -F':' '{print $2}'`"
    showNormal "$imagesList" | grep "$TMP_NAME" | grep "$TMP_TAG"

    # Show duration
    showGreen "\n > Build time:"
    showNormal "Start: $startTime"
    showNormal "End:   `date +"%Y-%m-%d %H:%M:%S"`"

    # Create backup
    if [ "$2" != "no-backup" ]; then
        scriptBackup
    fi

    # Done
    showGreen "\n > Done. Run the following command to start the image:\n"
    showNormal "bash $0 start\n"
    exit 0

}

function buildRuntimeVolumeDirs() {
    nextIsVolume=0

    # Go through args
    for runArg in ${RUN_ARGS[@]}; do

        # If found '-v' the next arg contains the path
        if [ "$runArg" == "-v" ]; then
            nextIsVolume=1
            continue
        fi

        # If we've got a path
        if [ $nextIsVolume -eq 1 ]; then
            nextIsVolume=0

            # Host path
            hostPath="`echo $runArg | awk -F':' '{print $1}'`"

            # If the path doesn't exist
            if [ ! -f "$hostPath" -a ! -d "$hostPath" ]; then
                showYellow "Creating dir: $hostPath"
                mkdir -p "$hostPath"
            fi
        fi
    done
}

function buildRuntimeFifo() {

    # Which binaries should have fifo listeners
    FIFO_LIST=(
        notify-send
        xdg-open
        )

    # Make sure the fifo dir exists
    mkdir -p "$FIFO_PATH"

    # For each pipe
    for FIFO_NAME in ${FIFO_LIST[@]}; do
        # If path is not a pipe
        if [ ! -p "$FIFO_PATH/$FIFO_NAME" ]; then

            # Remove existing thing if there's something
            rm -rf "$FIFO_PATH/$FIFO_NAME"

            # Create pipe
            mkfifo "$FIFO_PATH/$FIFO_NAME"
        fi
    done
}

# Start the docker image
function scriptStart() {
    showGreen "\nStarting $PROJECT_NAME..."
    buildRuntimeVolumeDirs
    buildRuntimeFifo
    TMP_NAME="`echo "$PROJECT_NAME" | awk -F':' '{print $1}'`"
    CONTAINER_ID="`$DOCKER_CMD ps -a | grep "$TMP_NAME" | awk '{print $1}'`"
    # If NOT running
    if [ "$CONTAINER_ID" == "" ]; then
        $DOCKER_CMD run ${RUN_ARGS[@]} -v $FIFO_PATH:/tmp/fifo --name="$TMP_NAME" "$TMP_NAME" ${@:3}
    # If running
    else
        $DOCKER_CMD exec "$CONTAINER_ID" ${@:2}
    fi
    exit $?
}

# Show image logs
function scriptLogs() {
    showGreen "\nShowing logs for $PROJECT_NAME:"
    TMP_NAME="`echo "$PROJECT_NAME" | awk -F':' '{print $1}'`"
    CONTAINER_ID="`$DOCKER_CMD ps -a | grep "$TMP_NAME" | awk '{print $1}'`"
    if [ "$CONTAINER_ID" == "" ]; then
        showRed "\nCouldn't find container id! Image status: `scriptStatus`\n"
        exit 1
    else
        $DOCKER_CMD logs "$CONTAINER_ID"
        exit $?
    fi
}

# Show image status running/stopped
function scriptStatus() {
    TMP_NAME="`echo "$PROJECT_NAME" | awk -F':' '{print $1}'`"
    if [ "`$DOCKER_CMD ps -a | grep "$TMP_NAME" | awk '{print $1}'`" == "" ]; then
        echo 'stopped'
        exit 1
    else
        echo 'running'
        exit 0
    fi
}

# Connect to the container and launch bash
function scriptConnect() {
    CMD='/bin/bash'
    if [ "`grep 'FROM alpine' Dockerfile`" != "" ]; then
        CMD="/bin/ash"
    fi
    showGreen "\nLaunching $CMD in $PROJECT_NAME:"
    TMP_NAME="`echo "$PROJECT_NAME" | awk -F':' '{print $1}'`"
    CONTAINER_ID="`$DOCKER_CMD ps -a | grep "$TMP_NAME" | awk '{print $1}'`"
    if [ "$CONTAINER_ID" == "" ]; then
        showRed "\nCouldn't find container id! Image status: `scriptStatus`\n"
        exit 1
    else
        $DOCKER_CMD exec -it --user root "$CONTAINER_ID" $CMD
        exit $?
    fi
}

# Gracefully stop the running docker image
function scriptStop() {
    showYellow "\nStop $PROJECT_NAME image..."
    TMP_NAME="`echo "$PROJECT_NAME" | awk -F':' '{print $1}'`"
    CONTAINER_ID="`$DOCKER_CMD ps -a | grep "$TMP_NAME" | awk '{print $1}'`"
    if [ "$CONTAINER_ID" == "" ]; then
        showRed "\nCouldn't find container id! Image status: `scriptStatus`\n"
        [ "$1" != 'no-exit' ] && exit 1
    else
        $DOCKER_CMD stop "$CONTAINER_ID"
        CODE=$? && [ "$1" != 'no-exit' ] && exit $CODE
    fi
}

# Kill the running docker image
function scriptKill() {
    showYellow "\nKill $PROJECT_NAME image..."
    TMP_NAME="`echo "$PROJECT_NAME" | awk -F':' '{print $1}'`"
    CONTAINER_ID="`$DOCKER_CMD ps -a | grep "$TMP_NAME" | awk '{print $1}'`"
    if [ "$CONTAINER_ID" == "" ]; then
        showRed "\nCouldn't find container id! Image status: `scriptStatus`\n"
        exit 1
    else
        $DOCKER_CMD kill "$CONTAINER_ID"
        exit $?
    fi
}

# Restart the running docker image
function scriptRestart() {
    scriptStop 'no-exit'
    sleep 1s
    scriptStart
}

# backup the docker image
function scriptBackup() {

    if [ "$BACKUP_PATH" == "" ]; then
        showYellow "\n > Backup dir not set."
    else
        safeProjectName="`echo "$PROJECT_NAME" | sed -e 's/[^a-zA-Z0-9\-]/_/g'`"

        backupPath="${BACKUP_PATH}/${safeProjectName}.tar"

        if [ ! -d "${BACKUP_PATH}" ]; then
            showGreen "\n > Creating backup dir..."
            mkdir -p "${BACKUP_PATH}"
        fi

        showYellow "\n > Creating backup..."
        $DOCKER_CMD save --output "${backupPath}" "${PROJECT_NAME}"

        showGreen "\n > DONE"
    fi

    echo
    exit 0
}

# Remove the docker image
function scriptRemove() {

    # Remove docker image
    showRed "\n[WARN] Remove the \"$PROJECT_NAME\" docker image from your system?\n"
    read -p "[y/n] " -n 1 -r
    echo

    # Remove the image
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        showYellow "\n > Removing existing image..."
        $DOCKER_CMD rmi "$PROJECT_NAME"

        showYellow "\n > Removing unused parts..."
        $DOCKER_CMD system prune -f

        showGreen "\n > DONE"
    fi

    echo
    exit 0
}

# Restore a backup image
function scriptRestore() {

    safeProjectName="`echo "$PROJECT_NAME" | sed -e 's/[^a-zA-Z0-9\-]/_/g'`"

    backupPath="${BACKUP_PATH}/${safeProjectName}.tar"

    if [ ! -f "${backupPath}" ]; then
        showRed "\n > There is no backup for this image!"
        echo
        exit 1
    fi

    showYellow "\n > Restoring backup..."
    $DOCKER_CMD load --input "${backupPath}"

    showGreen "\n > DONE"

    echo
    exit 0
}

# Check if the image is built
function imageBuilt() {
    TMP_NAME="`echo "$PROJECT_NAME" | awk -F':' '{print $1}'`"
    TMP_TAG="`echo "$PROJECT_NAME" | awk -F':' '{print $2}'`"
    if [ "`$DOCKER_CMD images | grep "$TMP_NAME" | grep "$TMP_TAG"`" == "" ]; then
        echo "n"
    else
        echo "y"
    fi
}

# Set application as default
function scriptSetDefault() {
    safeProjectName="`echo "$PROJECT_NAME" | awk -F':' '{print $1}' | sed -e 's/[^a-zA-Z0-9\-]/_/g'`"
    if [ "$APP_GENERIC_NAME" == "Web Browser" ]; then
        xdg-settings set default-web-browser "${safeProjectName}.desktop"
    elif [ "$APP_GENERIC_NAME" == "Mail Client" ]; then
        xdg-settings set default-url-scheme-handler mailto "${safeProjectName}.desktop"
    elif [ "$APP_GENERIC_NAME" == "Text Editor" ]; then
        xdg-mime default "${safeProjectName}.desktop" text/plain
    else
        showYellow "[WARN] App of \"$APP_GENERIC_NAME\" type can't be set as default! Functionality not implemented!"
    fi
}

# Remove any data stored by the application
function scriptClearData() {
    showGreen "\nRemoving data for $PROJECT_NAME stored at `pwd`/data..."
    rm -rf ./data
    showGreen "\nRebuilding runtime dirs..."
    buildRuntimeVolumeDirs
}

# Make the app runnable from the host system
function scriptInstall() {
    showGreen "\nInstalling $PROJECT_NAME..."

    buildRuntimeVolumeDirs

    safeProjectName="`echo "$PROJECT_NAME" | awk -F':' '{print $1}' | sed -e 's/[^a-zA-Z0-9\-]/_/g'`"
    COMMAND="bash `pwd`/docker.sh start $safeProjectName"

    BIN_FILE="/usr/bin/$safeProjectName"
    sudo sh -c "
        echo '#!/bin/bash' > $BIN_FILE \
     && echo \"$COMMAND \\\$@\" >> $BIN_FILE \
     "
    sudo chmod +x "$BIN_FILE"
    showGreen "\nInstalled @ $BIN_FILE"

    if [ -f "`pwd`/icon.png" ]; then
        # Default app categories
        APP_CATEGORIES="${APP_CATEGORIES:=GNOME;GTK;Utility;}"

        # Open in terminal
        if [ "$APP_TERMINAL" == "true" ]; then
            BIN_FILE="x-terminal-emulator -e $BIN_FILE"
        fi

        # Where to add the entry
        DESKTOP_FILE="/usr/share/applications/$safeProjectName.desktop"

        # Add
        sudo sh -c "
            echo \"[Desktop Entry]\" > $DESKTOP_FILE \
         && echo \"Encoding=UTF-8\" >> $DESKTOP_FILE \
         && echo \"Name=${safeProjectName^}\" >> $DESKTOP_FILE \
         && echo \"GenericName=$APP_GENERIC_NAME\" >> $DESKTOP_FILE \
         && echo \"Comment=${safeProjectName^}\" >> $DESKTOP_FILE \
         && echo \"Icon=`pwd`/icon.png\" >> $DESKTOP_FILE \
         && echo \"Exec=$BIN_FILE $APP_PARAM\" >> $DESKTOP_FILE \
         && echo \"Categories=$APP_CATEGORIES\" >> $DESKTOP_FILE \
         && echo \"MimeType=$APP_MIME_TYPE\" >> $DESKTOP_FILE \
         && echo \"Terminal=false\" >> $DESKTOP_FILE \
         && echo \"Type=Application\" >> $DESKTOP_FILE \
         && echo \"StartupNotify=true\" >> $DESKTOP_FILE \
         "

        # Done
        showGreen "\nAdded menu entry @ $DESKTOP_FILE"
    fi
}

# Actually do stuff
scriptRun $@

