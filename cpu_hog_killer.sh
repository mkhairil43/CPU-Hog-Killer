#!/system/bin/sh
#
# CPU Hog Killer - Monitors and terminates processes with excessive CPU usage
# Designed for Android devices (Magisk/KernelSU module)
#

##########################################################################################
# Configuration
##########################################################################################

SAMPLE_INTERVAL=10                  # Interval between CPU usage samples in seconds
MONITOR_DURATION=60                 # Total duration to monitor each process (seconds)
CPU_THRESHOLD=30                    # CPU usage threshold (percent)
TOP_PROCESSES_COUNT=5               # Number of top processes to monitor
MEASUREMENTS_LIMIT=5                # Number of measurements before killing process
INITIAL_SLEEP_TIME=60               # Initial wait time when screen is off (seconds)
HIGH_PRIORITY_MULTIPLIER=3          # Multiplier for high-priority processes (e.g., system_server)
WHITE_LIST="toybox|android.system.suspend-service|audioserver|android.hardware.audio.service_64"
THRESHOLD_HIGH=$((CPU_THRESHOLD * HIGH_PRIORITY_MULTIPLIER))  # Pre-calculate high priority threshold

##########################################################################################
# Global Variables
##########################################################################################

ORIGINAL_SELINUX=""                 # Backup of original SELinux status
MONITORING_SKIPS=0                  # Number of times monitoring was skipped
REMAINING_MONITORING_SKIPS=0        # Remaining skips before next monitoring run
SYSTEM_INSTABILITY_REPORTED=0       # Flag indicating if system instability was reported
MONITOR_WAIT_TIME=$INITIAL_SLEEP_TIME  # Current wait time between monitoring cycles
SELINUX_DISABLED_BY_SCRIPT=0        # Flag to track if we disabled SELinux

# Arrays for tracking process measurements (using associative arrays)
declare -A pids                     # Process IDs being tracked
declare -A avg_cpu_usage            # Cumulative CPU usage per PID
declare -A measurements_count       # Number of measurements per PID

##########################################################################################
# Initialization
##########################################################################################

init_globals() {
    ORIGINAL_SELINUX=$(getenforce)
    MONITORING_SKIPS=0
    REMAINING_MONITORING_SKIPS=0
    SYSTEM_INSTABILITY_REPORTED=0
    MONITOR_WAIT_TIME=$INITIAL_SLEEP_TIME
    SELINUX_DISABLED_BY_SCRIPT=0
}

##########################################################################################
# Cleanup and Signal Handling
##########################################################################################

# Restore SELinux on script exit
restore_selinux_on_exit() {
    if [ "$SELINUX_DISABLED_BY_SCRIPT" -eq 1 ]; then
        setenforce "$ORIGINAL_SELINUX" 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') SELinux restored to $ORIGINAL_SELINUX"
    fi
}

# Set up trap to restore SELinux on exit
trap restore_selinux_on_exit EXIT INT TERM HUP

##########################################################################################
# Utility Functions
##########################################################################################

# Cleanup all process measurements
cleanup_measurements() {
    # Fast array reset without reallocating
    pids=()
    avg_cpu_usage=()
    measurements_count=()
    echo "$(date '+%Y-%m-%d %H:%M:%S') All previous measurements cleared."
}

# Trim whitespace and extract the first word from a string
trim_and_extract_command() {
    echo "$1" | awk '{print $1}'
}

# Send notification when a process is killed
send_notification() {
    local title="$1"
    local message="$2"
    local original_selinux

    # Only disable SELinux if not already disabled
    if [ "$(getenforce)" = "Enforcing" ]; then
        setenforce 0
        SELINUX_DISABLED_BY_SCRIPT=1
    fi

    # Validate and sanitize inputs - remove any potentially dangerous characters
    title=$(echo "$title" | tr -d "'\"\`\\$;&|")
    message=$(echo "$message" | tr -d "'\"\`\\$;&|")

    # Use shell PID 0 (shell itself) as fallback if UID 2000 doesn't exist
    su -lp 2000 -c "cmd notification post -S bigtext -t '${title}' 'Tag' '${message}'" 2>/dev/null || \
    su -c "cmd notification post -S bigtext -t '${title}' 'Tag' '${message}'" 2>/dev/null || \
    echo "$(date '+%Y-%m-%d %H:%M:%S') Failed to send notification: $title - $message"
}

##########################################################################################
# System State Functions
##########################################################################################

# Check if the system is idle (not charging and screen is locked)
should_monitor() {
    local device_idle_info screen_locked screen_on charging

    device_idle_info=$(dumpsys deviceidle | grep -E 'mScreenLocked|mScreenOn|mCharging')

    screen_locked=${device_idle_info#*mScreenLocked=}
    screen_locked=${screen_locked%% *}
    
    screen_on=${device_idle_info#*mScreenOn=}
    screen_on=${screen_on%% *}
    
    charging=${device_idle_info#*mCharging=}
    charging=${charging%% *}

    if [[ "$screen_on" == "false" && "$charging" == "false" && "$screen_locked" == "true" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') The system is idle."
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') System is either charging, unlocked, or the screen is on. Sleeping for $MONITOR_WAIT_TIME seconds…"
        if [ "$MONITORING_SKIPS" -ne 0 ] || [ "$REMAINING_MONITORING_SKIPS" -ne 0 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') Resetting the loop skips to 0…"
            MONITORING_SKIPS=0
            REMAINING_MONITORING_SKIPS=0
        fi
        return 1
    fi
}

# Get the package name of the app with playing media
get_playing_media_package_name() {
    local output previous_line playing_package line

    output=$(dumpsys media_session | grep -E "(PLAYING|package=)")
    playing_package=""
    previous_line=""

    while IFS= read -r line; do
        if [[ "$line" == *"state=PLAYING"* ]]; then
            playing_package=$(echo "$previous_line" | cut -d'=' -f2)
            break
        fi
        previous_line="$line"
    done <<< "$output"

    if [ -n "$playing_package" ]; then
        echo "$playing_package"
    else
        echo "No media playing."
    fi
}

# Check for ongoing or ringing calls
check_for_ongoing_calls() {
    local telephony_info state

    telephony_info=$(dumpsys telephony.registry | grep -E 'mForegroundCallState|mRingingCallState')

    # Extract all states in one pass using parameter expansion
    for state in ${telephony_info#*=} ${telephony_info#*=}; do
        state=${state%% *}
        [[ "$state" =~ ^[0-9]+$ ]] || continue
        if [[ "$state" -ne 0 ]]; then
            return 0  # True: There is an ongoing call or the phone is ringing
        fi
    done
    return 1  # False: No ongoing or ringing calls
}

##########################################################################################
# Process Management Functions
##########################################################################################

# Report system instability for critical processes
report_system_instability() {
    local cmd="$1"
    local formatted_avg_cpu="$2"

    echo "$(date '+%Y-%m-%d %H:%M:%S') Reporting the system as unstable… $cmd is using $formatted_avg_cpu% of the CPU on average."
    send_notification "High CPU Usage Detected" "The process $cmd is using a high amount of CPU (Average Usage: $formatted_avg_cpu%). It can not be killed without causing a reboot. To debug it, use \"top -H\" via ADB."
}

# Kill a process and send notification
kill_process_with_notification() {
    local pid="$1"
    local cmd="$2"
    local formatted_avg_cpu="$3"
    local pid_exists

    # Verify the process still exists and has the same command before killing (TOCTOU mitigation)
    if [ -d "/proc/$pid" ]; then
        pid_exists=$(ps -p "$pid" -o comm= 2>/dev/null)
        if [ -n "$pid_exists" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') Killing process $cmd (Average CPU usage: $formatted_avg_cpu%)"
            kill "$pid" 2>/dev/null
            send_notification "$cmd Killed" "Average CPU Usage: $formatted_avg_cpu%"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') Process $pid no longer exists, skipping kill"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') Process $pid not found in /proc, skipping kill"
    fi
}

# Display top processes with their statistics
display_top_processes() {
    local current_top=("$@")
    local entry pid cpu cmd avg_cpu

    echo "Top $TOP_PROCESSES_COUNT CPU-consuming processes:"
    for entry in "${current_top[@]}"; do
        read pid cpu cmd <<< "$entry"
        if [ "${measurements_count[$pid]}" -gt 0 ]; then
            avg_cpu=$(echo "${avg_cpu_usage[$pid]} / ${measurements_count[$pid]}" | bc -l)
            avg_cpu=$(printf "%.2f" "$avg_cpu")
            echo "PID: $pid, CPU%: $cpu, AVG-CPU%: $avg_cpu, Command: $cmd, Measurements: ${measurements_count[$pid]}"
        fi
    done
}

# Get command name from process info
get_command_name() {
    local pid="$1"
    local comm="$2"
    local args cmd

    if [[ "$comm" == "app_process64" ]]; then
        args=$(ps -f -eo args -p "$pid" | head -n 2 | tail -n +2)
        if [ -n "$args" ]; then
            cmd=$(trim_and_extract_command "$args")
            [ -z "$cmd" ] && cmd="app_process64 (no arguments)"
        else
            cmd="app_process64 (no ARGS)"
        fi
    else
        cmd=$comm
    fi

    echo "$cmd"
}

# Process a single CPU measurement for a PID
process_cpu_measurement() {
    local pid="$1"
    local cpu="$2"
    local cmd="$3"
    local avg_cpu formatted_avg_cpu playing_media_package

    # Initialize tracking for new PIDs
    if [[ -z "${pids[$pid]}" ]]; then
        pids[$pid]=$pid
        avg_cpu_usage[$pid]=0
        measurements_count[$pid]=0
    fi

    # Accumulate CPU usage and increment measurement count (use integer math when possible)
    avg_cpu_usage[$pid]=$(echo "${avg_cpu_usage[$pid]} + $cpu" | bc)
    measurements_count[$pid]=$((measurements_count[$pid] + 1))

    # Check if we have enough measurements to make a decision
    if (( measurements_count[$pid] >= MEASUREMENTS_LIMIT )); then
        avg_cpu=$(echo "${avg_cpu_usage[$pid]} / ${measurements_count[$pid]}" | bc -l)
        formatted_avg_cpu=$(printf "%.2f" "$avg_cpu")

        # Handle high-priority processes (system_server) differently
        if [[ "$cmd" == "system_server" ]]; then
            if (( $(echo "$avg_cpu > $THRESHOLD_HIGH" | bc -l) )) && \
               [ "$SYSTEM_INSTABILITY_REPORTED" -eq 0 ]; then
                report_system_instability "$cmd" "$formatted_avg_cpu"
                return 10  # Signal to add 10 seconds
            fi
        else
            # Regular process handling - use pre-calculated threshold
            if (( $(echo "$avg_cpu > $CPU_THRESHOLD" | bc -l) )); then
                playing_media_package=$(get_playing_media_package_name)
                if [[ "$cmd" == "$playing_media_package" ]]; then
                    echo "The package to be killed $cmd is playing media. Skipping…"
                else
                    kill_process_with_notification "$pid" "$cmd" "$formatted_avg_cpu"
                    return 10  # Signal to add 10 seconds
                fi
            fi
        fi
    fi
    return 0
}

##########################################################################################
# CPU Monitoring Functions
##########################################################################################

# Monitor CPU usage and analyze top processes
monitor_and_analyze() {
    local TIME_SPENT top_processes current_top pid user comm cpu cmd
    local avg_cpu formatted_avg_cpu entry time_adjustment

    # Check for ongoing calls - skip monitoring if calls are active
    if check_for_ongoing_calls; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') There is an ongoing call or the phone is ringing"
        return 1
    fi

    cleanup_measurements
    echo "$(date '+%Y-%m-%d %H:%M:%S') Monitoring CPU usage for $MONITOR_DURATION seconds..."
    TIME_SPENT=0

    while [ "$TIME_SPENT" -lt "$MONITOR_DURATION" ]; do
        # Check if system is still idle
        if ! should_monitor; then
            return 1
        fi

        echo "$(date '+%Y-%m-%d %H:%M:%S') Collecting CPU usage snapshot at $TIME_SPENT seconds..."

        # Get top CPU-consuming processes (excluding whitelisted ones)
        # Validate WHITE_LIST contains only safe characters before using in grep
        if echo "$WHITE_LIST" | grep -qE '^[a-zA-Z0-9._|:-]+$'; then
            top_processes=$(top -b -n 1 -o pid,user,comm,%cpu | tail -n +6 | grep -Ev "$WHITE_LIST" | head -n "$((TOP_PROCESSES_COUNT + 1))")
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: WHITE_LIST contains invalid characters, skipping whitelist filter"
            top_processes=$(top -b -n 1 -o pid,user,comm,%cpu | tail -n +6 | head -n "$((TOP_PROCESSES_COUNT + 1))")
        fi

        current_top=()

        # Process each line of top output
        while read -r pid user comm cpu; do
            # Skip empty entries and header
            if [ -z "$cpu" ] || [ "$pid" = "PID" ]; then
                continue
            fi

            # Get command name
            cmd=$(get_command_name "$pid" "$comm")

            current_top+=("$pid $cpu $cmd")

            # Process CPU measurement and get time adjustment
            process_cpu_measurement "$pid" "$cpu" "$cmd"
            time_adjustment=$?

            if [ $time_adjustment -eq 10 ]; then
                TIME_SPENT=$((TIME_SPENT - 10))
            fi
        done <<< "$top_processes"

        # Display current top processes
        display_top_processes "${current_top[@]}"

        sleep "$SAMPLE_INTERVAL"
        TIME_SPENT=$((TIME_SPENT + SAMPLE_INTERVAL))
    done
    return 0
}

##########################################################################################
# Main Loop
##########################################################################################

main_loop() {
    while true; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') Checking if the system is idle..."

        if should_monitor; then
            if [ "$REMAINING_MONITORING_SKIPS" -eq 0 ]; then
                monitor_and_analyze
                if [ $? -eq 0 ]; then
                    # Successfully completed monitoring - increase skips exponentially
                    if [ $MONITORING_SKIPS -eq 0 ]; then
                        MONITORING_SKIPS=1
                    else
                        MONITORING_SKIPS=$((MONITORING_SKIPS * 2))
                    fi
                    REMAINING_MONITORING_SKIPS=$MONITORING_SKIPS
                    echo "$(date '+%Y-%m-%d %H:%M:%S') Increasing the amount of loop skips to $MONITORING_SKIPS…"
                fi
            else
                REMAINING_MONITORING_SKIPS=$((REMAINING_MONITORING_SKIPS - 1))
                echo "$(date '+%Y-%m-%d %H:%M:%S') Skipping this loop. Remaining loop skips: $REMAINING_MONITORING_SKIPS"
            fi
            echo "$(date '+%Y-%m-%d %H:%M:%S') Next device idle check in $MONITOR_WAIT_TIME seconds."
        fi

        sleep "$MONITOR_WAIT_TIME"
    done
}

##########################################################################################
# Entry Point
##########################################################################################

init_globals
main_loop
