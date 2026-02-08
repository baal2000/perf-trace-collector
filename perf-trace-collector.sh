#!/bin/bash

# --- CONFIGURATION ---
# Container name from first argument
CONTAINER_NAME="${1}"
DURATION=10
SAMPLESPERSECOND=99
# ---------------------

# 1. Setup Filenames
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname)

# Intermediate files (Deleted at the end)
DATA_FILE="${HOSTNAME}_${TIMESTAMP}.perf.data"
MAP_FILE="${HOSTNAME}_${TIMESTAMP}.perf.map"
RAW_TEXT_FILE="${HOSTNAME}_${TIMESTAMP}.raw.txt"
PYTHON_SCRIPT="fix_trace_embedded.py"
README_FILE="readme.txt"

# Final Output files
FIXED_TEXT_FILE="${HOSTNAME}_${TIMESTAMP}.perf.data.txt"
# Zip name format: hostname_timestamp.perf.trace.zip
ZIP_FILE="${HOSTNAME}_${TIMESTAMP}.perf.trace.zip"
DEBUG_DIR="artifacts"

# Help / Validation
show_help() {
    echo "Usage: $0 [container_name]"
    echo ""
    echo "Arguments:"
    echo "  container_name  The Docker container name where the process is running"
    echo ""
    echo "Example:"
    echo "  $0 production-api-container"
    echo ""
}

if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_help
    exit 0
fi

if [ -z "$CONTAINER_NAME" ]; then
    echo "Error: Missing container_name argument."
    show_help
    exit 1
fi

echo "=========================================="
echo "Step 1: Finding PID for container '$CONTAINER_NAME'..."
echo "=========================================="

TARGET_PID=$(sudo docker inspect -f '{{.State.Pid}}' "$CONTAINER_NAME")

if [ -z "$TARGET_PID" ] || [ "$TARGET_PID" = "0" ]; then
    echo "Error: Could not retrieve PID for container '$CONTAINER_NAME'."
    echo "Ensure the container is running and accessible."
    exit 1
fi

echo "Target PID: $TARGET_PID"
echo "Container:  $CONTAINER_NAME"

echo ""
echo "=========================================="
echo "Step 2: Recording Trace (${DURATION}s)..."
echo "=========================================="

sudo perf record -p "$TARGET_PID" -g \
    -e cycles -e sched:sched_switch \
    -F "$SAMPLESPERSECOND" \
    -o "$DATA_FILE" \
    -- sleep "$DURATION" && \
sudo docker exec "$CONTAINER_NAME" cat /tmp/perf-1.map > "$MAP_FILE"

if [ ! -f "$DATA_FILE" ] || [ ! -s "$MAP_FILE" ]; then
    echo "Error: Capture failed. Check permissions or container state."
    exit 1
fi

echo "Capture complete."

echo ""
echo "=========================================="
echo "Step 3: Resolving Symbols (Embedded Python)..."
echo "=========================================="

# 3a. Generate Raw Text (Requires sudo for kernel symbols)
echo "   -> converting binary to raw text..."
sudo chmod 666 "$DATA_FILE" "$MAP_FILE"
sudo perf script -i "$DATA_FILE" \
    -F comm,pid,tid,time,period,event,ip,sym,dso \
    -f > "$RAW_TEXT_FILE"
sudo chmod 666 "$RAW_TEXT_FILE"

# 3b. Check for Python 3 availability
echo "   -> checking for python3..."
if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is not installed. Cannot resolve symbols."
    exit 1
fi

# 3c. Create the Python Script on the fly
echo "   -> generating resolver script..."
cat << 'EOF' > "$PYTHON_SCRIPT"
import sys, bisect, datetime, re

def process_trace(map_file, trace_file):
    # Load Map with Sizes
    map_entries = []
    try:
        with open(map_file, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                p = line.split(maxsplit=2)
                if len(p) >= 3:
                    try:
                        start = int(p[0], 16)
                        size = int(p[1], 16)
                        name = p[2].strip()
                        map_entries.append((start, size, name))
                    except ValueError: continue
    except FileNotFoundError: sys.exit(1)
    
    # Sort by start address for binary search
    map_entries.sort(key=lambda x: x[0])
    starts = [x[0] for x in map_entries]

    # Print Headers
    now = datetime.datetime.now().strftime("%c")
    print(f"# started on {now}\n# header: captured on {now}")
    print(f"# header: cmdline : /usr/bin/perf script\n# header: nrcpus available : 1")
    print(f"# header: event : cycles")

    header_regex = re.compile(r"^(.*?)\s+(\d+/\d+)\s+.*?(\d+\.\d+):")
    
    # Process Trace
    with open(trace_file, 'r', encoding='utf-8', errors='ignore') as infile:
        for line in infile:
            if line.startswith("#"): continue
            
            # Normalize Header
            m = header_regex.match(line)
            if m:
                line = f"{m.group(1).strip()} {m.group(2)} [000] {m.group(3)}: 1 cycles:\n"
            
            # Resolve Symbols with Bounds Check
            elif "[unknown]" in line:
                tokens = line.split()
                try:
                    idx = tokens.index("[unknown]")
                    addr = int(tokens[idx-1].strip(":"), 16)
                    
                    if addr < 0x7fffffffffff: # Ignore Kernel Space
                        # Find insertion point
                        map_idx = bisect.bisect_right(starts, addr) - 1
                        
                        if map_idx >= 0:
                            entry = map_entries[map_idx]
                            start_addr = entry[0]
                            size = entry[1]
                            name = entry[2]
                            
                            # CRITICAL: Check if address is actually inside the method
                            if addr < (start_addr + size):
                                line = line.replace("[unknown]", name)
                                line = line.replace("(/memfd:doublemapper (deleted))", "(/jit)")
                            # Else: It falls in a gap (e.g. Native Runtime), leave as unknown
                            
                except (ValueError, IndexError): pass
            sys.stdout.write(line)

if __name__ == "__main__":
    process_trace(sys.argv[1], sys.argv[2])
EOF

# 3d. Run the Python Script to create the final fixed file
echo "   -> resolving symbols..."
python3 "$PYTHON_SCRIPT" "$MAP_FILE" "$RAW_TEXT_FILE" > "$FIXED_TEXT_FILE"

# 3e. Create Readme
echo "   -> creating instructions..."
cat << EOF > "$README_FILE"
TRACE ANALYSIS INSTRUCTIONS
===========================

This zip file contains a .NET performance trace captured from Linux.
The symbols have been pre-resolved using the captured JIT map.

FILE TO USE:
------------
$FIXED_TEXT_FILE
(This file contains the stack traces with resolved method names)

HOW TO VIEW (Recommended):
--------------------------
1. Open PerfView.exe (Windows).
2. Open the ZIP file directly: '$ZIP_FILE'.
3. Double-click 'CPU Stacks'.
4. Use the 'Filter' box to find your method names and aggregate threads.

DEBUGGING:
----------
If the trace looks wrong, the raw original files are preserved in the '$DEBUG_DIR' folder.
You can re-run the resolution logic manually using the included python script.
EOF

echo ""
echo "=========================================="
echo "Step 4: Packaging..."
echo "=========================================="

# Prepare Debug Artifacts
mkdir -p "$DEBUG_DIR"
cp "$RAW_TEXT_FILE" "$PYTHON_SCRIPT" "$MAP_FILE" "$DEBUG_DIR/"

# Zip: Fixed Trace + Readme at Root, Raw files in subfolder
zip -q -r "$ZIP_FILE" "$FIXED_TEXT_FILE" "$README_FILE" "$DEBUG_DIR"

# Cleanup everything except the final zip
rm "$DATA_FILE" "$MAP_FILE" "$RAW_TEXT_FILE" "$PYTHON_SCRIPT" "$FIXED_TEXT_FILE" "$README_FILE"
rm -rf "$DEBUG_DIR"

echo "SUCCESS! Download and unzip this file:"
echo "$PWD/$ZIP_FILE"
echo "=========================================="