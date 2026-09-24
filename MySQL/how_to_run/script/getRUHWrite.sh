#!/bin/bash

# Check arguments
if [ $# -eq 0 ]; then
    echo "Usage: $0 <nvme_device_path> [MAX_RUAMW]"
    echo "Example: $0 /dev/nvme6n1"
    echo "Example: $0 /dev/nvme6n1 4349952"
    exit 1
fi

# NVMe device path (from command line argument)
DEVICE="$1"

# MAX Reclaim Unit Available Media Writes (RUAMW)
# Can be passed as second parameter, default is 4349952
MAX_RUAMW="${2:-4349952}"

# cur_time
get_timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

# nvme fdp status to extract RUAMW 
parse_ruamw() {
    sudo nvme fdp status "$DEVICE" | grep -E "Placement Identifier|Reclaim Unit Available Media Writes" | \
    awk '
    /Placement Identifier/ {
        match($0, /Placement Identifier ([0-9]+)/, arr)
        pid = arr[1]
    }
    /Reclaim Unit Available Media Writes/ {
        match($0, /: ([0-9]+)/, arr)
        print pid, arr[1]
    }
    '
}

echo "begin NVMe FDP monitoring..."
echo "device: $DEVICE"
echo "MAX RUAMW: $MAX_RUAMW"
#echo "Press Ctrl+C to stop"
echo ""

# Print header
echo "Timestamp, PID_0_Writes, PID_1_Writes, PID_2_Writes, PID_3_Writes, PID_4_Writes, PID_5_Writes, PID_6_Writes, PID_7_Writes, PID_0_Resets, PID_1_Resets, PID_2_Resets, PID_3_Resets, PID_4_Resets, PID_5_Resets, PID_6_Resets, PID_7_Resets"

declare -A prev_ruamw
declare -A reset_counts  # cumulative reset count per PID

# Initialize reset counters
for pid in {0..7}; do
    reset_counts[$pid]=0
done

while read -r pid value; do
    prev_ruamw[$pid]=$value
done < <(parse_ruamw)

while true; do
    sleep 5
    
    # cur_time
    timestamp=$(get_timestamp)
    
    # get current RUAMW value
    declare -A curr_ruamw
    while read -r pid value; do
        curr_ruamw[$pid]=$value
    done < <(parse_ruamw)
    
    # calculate 
    declare -A writes
    output="$timestamp"
    
    # Iterate over Placement Identifiers (0-7)
    for pid in {0..7}; do
        if [[ -n "${prev_ruamw[$pid]}" ]] && [[ -n "${curr_ruamw[$pid]}" ]]; then
            prev_val=${prev_ruamw[$pid]}
            curr_val=${curr_ruamw[$pid]}
            
            # check if reset (cur_val > prev_val)
            if [[ $curr_val -gt $prev_val ]]; then
                # if reset: written = prev_value + (MAX - current_value)
                write_count=$((prev_val + MAX_RUAMW - curr_val))
                reset_counts[$pid]=$((reset_counts[$pid] + 1))  # increment reset count for this PID
               # echo "[PID $pid] Reset detected: prev=$prev_val, curr=$curr_val, writes=$write_count, total_resets=${reset_counts[$pid]}" >&2
            else
                # normal case: written = prev_value - current_value
                write_count=$((prev_val - curr_val))
            fi
            
            writes[$pid]=$write_count
            output="$output, $write_count"
        else
            # if no PID, write 0
            writes[$pid]=0
            output="$output, 0"
        fi
    done
    
    # Add reset counts for each PID
    for pid in {0..7}; do
        output="$output, ${reset_counts[$pid]}"
    done
    
    # to terminal
    echo "$output"
    
    # update prev_ruamw to current value
    for pid in "${!curr_ruamw[@]}"; do
        prev_ruamw[$pid]=${curr_ruamw[$pid]}
    done
done
