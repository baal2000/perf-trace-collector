## Perf Trace Collector

A specialized diagnostic tool for capturing and resolving .NET performance traces on Linux, specifically designed for high-CPU scenarios where standard .NET diagnostic tools (like dotnet-trace or dotnet-dump) fail.

### Overview

In extreme CPU saturation events, the .NET Diagnostics Server thread often becomes starved for cycles, making it impossible to establish an IPC connection for standard tracing.

This script implements a pull-based workflow:

- It uses native Linux perf to sample CPU cycles and scheduler events directly from the host.
- It extracts the unlinked JIT memory map from the target container.
- It uses an embedded Python script to mathematically resolve [unknown] managed frames by mapping sampled hex addresses to the C# method ranges found in the JIT map.
### Prerequisites

- Sudo access: Required for native perf sampling of kernel and process symbols.
- Linux perf: Must be installed on the host OS.
- Docker: The target process must be running in a Docker container.
- Python 3: Required for the symbol resolution phase.
- Zip: Required to package the final trace artifacts.

### Usage

Execute the script with the process name and the container name as arguments:

```
./collect_trace.sh <process_name> <container_name>
```

####Arguments:

- process_name: The name of the binary to trace (e.g., MyService).
- container_name: The name or ID of the Docker container.

#### Example:

```
sudo ./collect_trace.sh MyService production-api-container
```
### Output

The script generates a timestamped ZIP file: hostname_YYYYMMDD_HHMMSS.perf.trace.zip.

#### Contents of the ZIP:

- *.perf.data.txt: The processed trace with unmasked C# method names.
- readme.txt: Quick-start instructions for analysis.
- artifacts/: Subfolder containing the raw perf.data, perf.map, and the resolution script for debugging.

### Analysis Instructions

The generated trace is compatible with Windows-based analysis tools:

#### PerfView:

- Transfer the ZIP file to a Windows machine.
- Open the ZIP file directly in PerfView.exe.
- Navigate to CPU Stacks to see the resolved method names.
- Use the Filter box to isolate specific namespaces or methods.

### How it Works

- PID Discovery: Uses pidof on the host to find the real PID of the containerized process.
- Raw Capture: Runs perf record at 99 Hz for 10 seconds to capture stack samples without requiring cooperation from the .NET runtime.
- Map Extraction: Uses docker exec to copy /tmp/perf-1.map out of the container.
- Symbol Unmasking replaces the opaque hex addresses with human-readable C# signatures.
