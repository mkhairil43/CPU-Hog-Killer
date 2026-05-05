#!/system/bin/sh
# set -x 

# Validate resetprop command exists before using it
if ! command -v resetprop >/dev/null 2>&1; then
    echo "Warning: resetprop not found, skipping boot_completed reset"
else
    if ! resetprop -w sys.boot_completed 0; then
        echo "Warning: Failed to set sys.boot_completed, continuing anyway"
    fi
fi

MODDIR=${0%/*}

# Wait until /sdcard/ exists and is accessible
until [ -d "/sdcard/" ]; do
    echo "/sdcard/ is not accessible yet. Waiting..."
    sleep 2
done
# Now that /sdcard/ is accessible, proceed
echo "/sdcard/ is accessible."

# Redirect output to a log file in a secure location
# Use /data/local/tmp as primary (more secure than /sdcard)
# Fall back to /sdcard only if necessary
if [ -d "/data/local/tmp" ] && [ -w "/data/local/tmp" ]; then
    LOGFILE="/data/local/tmp/cpu_hog_killer.log"
    rm -f "$LOGFILE"
else
    # Fallback to /sdcard with restricted permissions
    LOGFILE="/sdcard/cpu_hog_killer.log"
    rm -f "$LOGFILE"
fi

exec > "$LOGFILE" 2>&1

# Make the log file readable only by owner and group (more secure)
chmod 640 "$LOGFILE" 2>/dev/null || chmod 664 "$LOGFILE"

# Log that the script has started
echo "Service script started."

# Wait until /system/bin/sh exists and is accessible
until [ -x "/system/bin/sh" ]; do
    echo "/system/bin/sh is not accessible yet. Waiting..."
    sleep 2
done
echo "/system/bin/sh is now accessible."

# Check MODPATH with proper quoting
MODPATH="$MODDIR"
echo "MODPATH: $MODPATH"

# Validate the cpu_hog_killer.sh script exists before executing
if [ ! -f "$MODPATH/cpu_hog_killer.sh" ]; then
    echo "ERROR: cpu_hog_killer.sh not found at $MODPATH/cpu_hog_killer.sh"
    exit 1
fi

# Start the CPU hog killer script with an absolute path
chmod 755 "$MODPATH/cpu_hog_killer.sh"
/system/bin/sh "$MODPATH/cpu_hog_killer.sh"
