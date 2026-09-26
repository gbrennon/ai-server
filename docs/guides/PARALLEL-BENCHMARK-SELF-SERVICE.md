# Self-Service Guide: Parallel Benchmark & Agentic Tool Testing
## Run Your Own Verification on GMKtec Evo X2 (or Similar Hardware)

**Updated:** 2026-09-18  
**Audience:** Engineers wanting to reproduce parallel scaling benchmarks  
**Time Required:** 45 minutes (parallel 2) to 2 hours (parallel 2+3+4 full sweep)

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start (5 minutes)](#quick-start)
3. [Step-by-Step Deployment](#step-by-step-deployment)
4. [Running Benchmarks Manually](#running-benchmarks-manually)
5. [Interpreting Results](#interpreting-results)
6. [Extending the Benchmarks](#extending-the-benchmarks)
7. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Hardware Requirements

- **Minimum:** 64 GB unified memory (for parallel 2 testing)
- **Recommended:** 128 GB (for parallel 2+3 testing)
- **For parallel 4:** 192 GB+ (or reduce context window to 32K)

### Software Requirements

```bash
# On your local machine (from ai-server repo):
- Bash 4.0+
- Python 3.8+
- SSH access to remote llama.cpp server
- curl or Python urllib (for HTTP requests)

# On remote Evo X2 (or similar):
- llama.cpp built and installed (/opt/llama.cpp/build/bin/llama-server)
- Model downloaded (/var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf or similar)
- systemd service configured (llama-server.service)
- SSH server running and accessible
- OMP (Oh My Pi) CLI installed for agentic testing
```

### Verify Prerequisites

```bash
# Check local tools
bash --version | head -1
python3 --version
which ssh

# Check remote connectivity
ssh -o BatchMode=yes -o ConnectTimeout=5 gbrennon-local-ai@192.168.0.2 'echo "SSH OK"'

# Check remote llama.cpp
ssh gbrennon-local-ai@192.168.0.2 'ls -lh /opt/llama.cpp/build/bin/llama-server'

# Check remote model
ssh gbrennon-local-ai@192.168.0.2 'ls -lh /var/lib/llama.cpp/models/ | grep gguf'

# Check remote OMP (for agentic tasks)
ssh gbrennon-local-ai@192.168.0.2 'which omp'
```

---

## Quick Start

### Option A: Run Pre-Built Verification (Easiest)

```bash
cd /path/to/ai-server
make verify-omp-parallel
```

This runs the complete parallel 2 verification (connectivity, benchmark, compilation) in ~11 minutes.

### Option B: Just Run the Benchmark (Fastest)

```bash
python3 << 'EOF'
import urllib.request, json, time, threading

HOST = "192.168.0.2"
MODEL_ID = "/var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf"

def send_req(req_id, results):
    payload = {
        'model': MODEL_ID,
        'messages': [
            {'role': 'system', 'content': 'Answer in one sentence.'},
            {'role': 'user', 'content': f'Count 1 to 5 with commas, request {req_id}'}
        ],
        'max_tokens': 50,
        'temperature': 0.1
    }
    t0 = time.time()
    req = urllib.request.Request(
        f'http://{HOST}:8080/v1/chat/completions',
        data=json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json'}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        results[req_id] = time.time() - t0

# Sequential
seq_res = {}
t_seq = time.time()
for i in range(2): send_req(f'seq_{i}', seq_res)
t_seq = time.time() - t_seq

time.sleep(0.5)

# Concurrent
par_res = {}
t_par = time.time()
threads = [threading.Thread(target=send_req, args=(f'par_{i}', par_res)) for i in range(2)]
for t in threads: t.start()
for t in threads: t.join()
t_par = time.time() - t_par

print(f"Sequential: {t_seq:.2f}s")
print(f"Concurrent: {t_par:.2f}s")
print(f"Speedup: {t_seq/t_par:.2f}x")
EOF
```

---

## Step-by-Step Deployment

### Step 1: Verify Current Configuration

```bash
ssh gbrennon-local-ai@192.168.0.2 << 'EOF'
echo "=== Current llama-server Configuration ==="
ps aux | grep llama-server | grep -v grep | sed 's/.*build\/bin\/llama-server/llama-server/' | tr ' ' '\n' | grep -E "parallel|model|port|ctx"

echo ""
echo "=== Service Status ==="
systemctl status llama-server --no-pager | head -15

echo ""
echo "=== Slots Active ==="
curl -s http://localhost:8080/slots | python3 -m json.tool | grep -E "id|state" | head -10
EOF
```

**Output should show:** Current `--parallel` setting, service active, slot count

### Step 2: Update llama-server to Target Parallel Factor

```bash
# For Parallel 2
TARGET_PARALLEL=2

ssh gbrennon-local-ai@192.168.0.2 << EOF
  sudo systemctl stop llama-server
  sudo sed -i "s/--parallel [0-9]\+/--parallel ${TARGET_PARALLEL}/g" /etc/systemd/system/llama-server.service
  sudo systemctl daemon-reload
  sudo systemctl start llama-server
  sleep 5
  echo "[OK] Updated to --parallel ${TARGET_PARALLEL}"
EOF
```

### Step 3: Verify Deployment

```bash
ssh gbrennon-local-ai@192.168.0.2 << 'EOF'
echo "Checking deployment..."
sleep 2

# Verify process
if ps aux | grep llama-server | grep -v grep | grep -q "parallel [0-9]\+"; then
  echo "[OK] llama-server is running"
else
  echo "[ERROR] llama-server failed to start"
  journalctl -u llama-server -n 20 --no-pager
  exit 1
fi

# Check health
if curl -s http://localhost:8080/health | grep -q "ok"; then
  echo "[OK] Service health check passed"
else
  echo "[WARN] Health check not responding yet, waiting..."
  sleep 5
fi

# Verify slot count
SLOTS=$(curl -s http://localhost:8080/slots | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
echo "[OK] Active slots: $SLOTS"
EOF
```

---

## Running Benchmarks Manually

### Benchmark 1: Micro-Benchmark (5 minutes)

Tests sequential vs. concurrent request performance.

**Script:** `benchmark-micro.py`

```python
#!/usr/bin/env python3
"""
Micro-benchmark: Sequential vs. Concurrent inference
Measures throughput improvement from parallel slot utilization
"""

import urllib.request
import json
import time
import threading
import sys
from statistics import mean, stdev

def benchmark(host, model_id, parallel_factor, num_requests=None):
    if num_requests is None:
        num_requests = parallel_factor
    
    url = f'http://{host}:8080/v1/chat/completions'
    
    def send_request(req_id, results):
        payload = {
            'model': model_id,
            'messages': [
                {'role': 'system', 'content': 'Answer concisely in one sentence.'},
                {'role': 'user', 'content': f'Count from 1 to 5 separated by commas. Request {req_id}'}
            ],
            'max_tokens': 50,
            'temperature': 0.1
        }
        
        t0 = time.time()
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode(),
                headers={'Content-Type': 'application/json'}
            )
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read().decode())
                dt = time.time() - t0
                results[req_id] = dt
                print(f"  [{req_id}] {dt:.2f}s")
        except Exception as e:
            print(f"  [{req_id}] ERROR: {e}")
            results[req_id] = None
    
    print(f"\n{'='*70}")
    print(f"Micro-Benchmark: Parallel Factor {parallel_factor}")
    print(f"{'='*70}")
    print(f"Host: {host}")
    print(f"Model: {model_id.split('/')[-1]}")
    print(f"Requests: {num_requests}")
    print()
    
    # Sequential phase
    print("PHASE 1: Sequential (requests one-by-one)")
    print("-" * 70)
    seq_results = {}
    t_seq_start = time.time()
    for i in range(num_requests):
        send_request(f'seq_{i}', seq_results)
    t_seq_total = time.time() - t_seq_start
    
    time.sleep(1)
    
    # Concurrent phase
    print("\nPHASE 2: Concurrent ({}-way parallel)".format(num_requests))
    print("-" * 70)
    par_results = {}
    t_par_start = time.time()
    threads = []
    for i in range(num_requests):
        t = threading.Thread(target=send_request, args=(f'par_{i}', par_results))
        threads.append(t)
        t.start()
    for t in threads:
        t.join()
    t_par_total = time.time() - t_par_start
    
    # Results
    print("\n" + "="*70)
    print("RESULTS")
    print("="*70)
    
    seq_times = [v for v in seq_results.values() if v is not None]
    par_times = [v for v in par_results.values() if v is not None]
    
    if seq_times and par_times:
        speedup = t_seq_total / t_par_total
        print(f"Sequential total:     {t_seq_total:.2f}s")
        print(f"Concurrent total:     {t_par_total:.2f}s")
        print(f"Speedup:              {speedup:.2f}x")
        print(f"\nPer-request (seq):    {mean(seq_times):.2f}s ±{stdev(seq_times) if len(seq_times)>1 else 0:.2f}s")
        print(f"Per-request (par):    {mean(par_times):.2f}s ±{stdev(par_times) if len(par_times)>1 else 0:.2f}s")
        print(f"Aggregate throughput: {num_requests / t_par_total:.1f} req/s")
        
        return {
            'speedup': speedup,
            't_seq': t_seq_total,
            't_par': t_par_total,
            'per_req_seq': mean(seq_times),
            'per_req_par': mean(par_times)
        }
    else:
        print("ERROR: Failed to complete benchmark")
        return None

if __name__ == '__main__':
    HOST = sys.argv[1] if len(sys.argv) > 1 else '192.168.0.2'
    MODEL = sys.argv[2] if len(sys.argv) > 2 else '/var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf'
    PARALLEL = int(sys.argv[3]) if len(sys.argv) > 3 else 2
    
    benchmark(HOST, MODEL, PARALLEL)
```

**Usage:**

```bash
# For parallel 2
python3 benchmark-micro.py 192.168.0.2 /var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf 2

# For parallel 3
python3 benchmark-micro.py 192.168.0.2 /var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf 3
```

### Benchmark 2: Agentic Workload (10-20 minutes)

Delegates code generation to OMP agents running concurrently with inference slots.

**Script:** `benchmark-agentic.sh`

```bash
#!/usr/bin/env bash
# Agentic benchmark: Dual OMP agents generate Rust project while parallel slots run

set -euo pipefail

PARALLEL=${1:-2}
HOST=${2:-192.168.0.2}
SSH_USER=${3:-gbrennon-local-ai}
TEST_DIR="/tmp/benchmark-agentic-p${PARALLEL}"
OMP_MODEL="evo-x2-llamacpp/Qwen3.8-27B-UD-Q4_K_M.gguf"

echo "=========================================="
echo "Agentic Workload Benchmark"
echo "Parallel Factor: $PARALLEL"
echo "=========================================="
echo

# Verify connectivity
ping -c 1 -W 2 "$HOST" >/dev/null || { echo "Host unreachable"; exit 1; }
ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$HOST" 'echo SSH OK' >/dev/null || { echo "SSH failed"; exit 1; }

# Prepare test directory
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/src"

echo "Starting benchmark..."
echo "- Agent 1: Generate Cargo.toml and src/main.rs"
echo "- Agent 2: Generate src/app.rs"
echo

T_START=$(date +%s)

# Agent 1
(
  omp --no-skills --no-extensions --no-rules --tools bash,write,read \
      --auto-approve --approval-mode=yolo \
      --cwd="$TEST_DIR" \
      --system-prompt "You are a Rust coding assistant. Write files using write tool. Be concise." \
      --model "$OMP_MODEL" \
      -p "Write Cargo.toml and src/main.rs for a Ratatui TUI showing 'Parallel $PARALLEL Active'. Keep concise." \
      > "$TEST_DIR/agent1.log" 2>&1
) &
PID_1=$!

# Agent 2
(
  omp --no-skills --no-extensions --no-rules --tools bash,write,read \
      --auto-approve --approval-mode=yolo \
      --cwd="$TEST_DIR" \
      --system-prompt "You are a Rust coding assistant. Write files using write tool. Be concise." \
      --model "$OMP_MODEL" \
      -p "Write src/app.rs with pub fn render_banner() returning 'Parallel $PARALLEL Active'. Keep concise." \
      > "$TEST_DIR/agent2.log" 2>&1
) &
PID_2=$!

echo "Agents running (PIDs: $PID_1, $PID_2)..."
wait $PID_1 $PID_2 || echo "Warning: One or more agents exited with error"

T_END=$(date +%s)
T_ELAPSED=$((T_END - T_START))

echo
echo "Agents completed in $T_ELAPSED seconds"
echo

# Verify compilation
if [[ -f "$TEST_DIR/Cargo.toml" && -f "$TEST_DIR/src/main.rs" && -f "$TEST_DIR/src/app.rs" ]]; then
  echo "[OK] All files generated"
  
  # Fix module declaration if needed
  if ! grep -q "mod app" "$TEST_DIR/src/main.rs"; then
    sed -i '1s/^/mod app;\n/' "$TEST_DIR/src/main.rs"
  fi
  
  # Compile
  echo "Compiling..."
  if (cd "$TEST_DIR" && cargo build --release 2>&1 | tail -5); then
    echo "[OK] Build succeeded"
    echo "  Binary: $TEST_DIR/target/release/omp-parallel-demo"
  else
    echo "[ERROR] Build failed"
  fi
else
  echo "[ERROR] Some files missing"
  ls -la "$TEST_DIR/src/" || true
fi
```

**Usage:**

```bash
bash benchmark-agentic.sh 2 192.168.0.2 gbrennon-local-ai
```

### Benchmark 3: Hardware Telemetry (Real-time Monitoring)

Monitor power, thermals, and memory during benchmarks.

**Script:** `monitor-telemetry.sh`

```bash
#!/usr/bin/env bash
# Real-time telemetry monitoring during benchmark

HOST=${1:-192.168.0.2}
SSH_USER=${2:-gbrennon-local-ai}
INTERVAL=${3:-5}

echo "Telemetry Monitor (updating every ${INTERVAL}s)"
echo "Press Ctrl+C to stop"
echo

while true; do
  clear
  echo "=== $(date) ==="
  echo
  
  ssh -o ConnectTimeout=2 "$SSH_USER@$HOST" << 'REMOTE' 2>/dev/null || echo "(SSH timeout)"
echo "--- Memory ---"
free -h | awk 'NR==2 {print "Used: " $3 " / Total: " $2 " (Peak: check systemd)"}'

echo ""
echo "--- Thermals ---"
sensors 2>/dev/null | grep -E "Tctl|edge|temp" | head -3 || echo "(sensors unavailable)"

echo ""
echo "--- Service ---"
systemctl status llama-server --no-pager | grep -E "Active|CPU|Memory" | head -3

echo ""
echo "--- Network ---"
curl -s http://localhost:8080/health | python3 -m json.tool 2>/dev/null | head -3 || echo "Service down"
REMOTE
  
  sleep "$INTERVAL"
done
```

**Usage:**

```bash
# In separate terminal while running benchmark
bash monitor-telemetry.sh 192.168.0.2 gbrennon-local-ai 5
```

---

## Interpreting Results

### What the Numbers Mean

```
Speedup = T_seq / T_par

Speedup < 1.0:   Concurrent slower than sequential (bad—check for crashes)
Speedup = 1.0:   No parallelism benefit (slots not actually concurrent)
Speedup = 1.5x:  50% improvement (some contention)
Speedup = 2.0x:  2x improvement (linear scaling for 2 slots)
Speedup > 2.0x:  Super-linear (amortized overhead wins)
Speedup > 3.0x:  Excellent (very low contention)
```

### Memory Analysis

```
Peak Memory = Max RAM used during benchmark

Safe:     Peak < 80% of available allocation
Risky:    Peak 80–95% (okay for testing, not production)
Danger:   Peak > 95% (risk of OOM, swap thrashing)
```

### Thermal Analysis

```
Edge Temperature Ranges:
Normal:   <50°C (plenty of headroom)
Warm:     50–70°C (acceptable, monitor)
Hot:      70–85°C (watch for throttling)
Critical: >85°C (risk of PROCHOT throttling)
```

---

## Extending the Benchmarks

### Add Custom Prompt / Task

```python
# In benchmark-micro.py, modify the payload:

payload = {
    'model': model_id,
    'messages': [
        {'role': 'system', 'content': 'You are a JSON API. Respond with valid JSON only.'},
        {'role': 'user', 'content': 'Generate a sample user profile in JSON format with name, age, email, verified boolean.'}
    ],
    'max_tokens': 200,  # Increase for longer responses
    'temperature': 0.5   # Higher = more creative
}
```

### Test Different Parallel Factors

```bash
# Loop through parallel factors
for parallel in 1 2 3; do
  echo "Testing parallel $parallel..."
  
  # Deploy
  ssh gbrennon-local-ai@192.168.0.2 "sudo sed -i 's/--parallel [0-9]\+/--parallel $parallel/g' /etc/systemd/system/llama-server.service && sudo systemctl restart llama-server && sleep 10"
  
  # Run benchmark
  python3 benchmark-micro.py 192.168.0.2 /var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf $parallel
  
  echo "---"
  sleep 5
done
```

### Custom Model Testing

```bash
# Download a different model
ssh gbrennon-local-ai@192.168.0.2 << 'EOF'
  cd /var/lib/llama.cpp/models/
  wget https://huggingface.co/TheBloke/Llama-2-7B-GGUF/resolve/main/llama-2-7b.Q4_K_M.gguf
EOF

# Test with new model
python3 benchmark-micro.py 192.168.0.2 /var/lib/llama.cpp/models/llama-2-7b.Q4_K_M.gguf 2
```

---

## Troubleshooting

### Issue: "Remote end closed connection"

**Cause:** llama-server crashed or isn't responding

**Fix:**
```bash
ssh gbrennon-local-ai@192.168.0.2 << 'EOF'
systemctl status llama-server --no-pager
journalctl -u llama-server -n 50 --no-pager | tail -20
EOF
```

Look for: `ABRT`, `Segmentation fault`, memory exhaustion messages

### Issue: "Slot count is 0" or "/slots endpoint not responding"

**Cause:** Service not fully initialized

**Fix:**
```bash
# Wait longer for startup
ssh gbrennon-local-ai@192.168.0.2 'sleep 30 && curl http://localhost:8080/health'
```

### Issue: Memory spike / service OOM kill

**Cause:** Parallel factor too high for available RAM

**Fix:**
```bash
# Reduce parallel factor
ssh gbrennon-local-ai@192.168.0.2 "sudo sed -i 's/--parallel [0-9]\+/--parallel 2/g' /etc/systemd/system/llama-server.service && sudo systemctl restart llama-server"

# Check memory
ssh gbrennon-local-ai@192.168.0.2 'free -h'
```

### Issue: OMP agents timeout or produce no output

**Cause:** Local model too slow, context tokens high

**Fix:**
```bash
# Use shorter system prompt
omp --system-prompt "Write code concisely." ...

# Or increase timeout
timeout 600 omp ...
```

### Issue: "Speedup < 1.0x" (concurrent slower than sequential)

**Cause:** Single-threaded bottleneck, overhead dominates

**Investigate:**
```bash
# Check CPU utilization
ssh gbrennon-local-ai@192.168.0.2 'watch -n 1 "ps aux | grep llama-server"'

# Check if slots are actually concurrent
curl http://192.168.0.2:8080/slots | python3 -m json.tool
```

---

## Reference: Configuration Files

### systemd Service Configuration

```ini
# /etc/systemd/system/llama-server.service

[Unit]
Description=llama.cpp OpenAI-compatible LLM server
Documentation=https://github.com/ggml-org/llama.cpp

[Service]
Type=simple
User=llamacpp
WorkingDirectory=/var/lib/llama.cpp

ExecStart=/opt/llama.cpp/build/bin/llama-server \
  --model /var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf \
  --host 0.0.0.0 \
  --port 8080 \
  --ctx-size 0 \
  --threads 16 \
  -ngl 99 \
  --flash-attn on \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --split-mode layer \
  --parallel 2

Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### Deployment Script Template

```bash
#!/usr/bin/env bash
# deploy-parallel.sh - Deploy and test a specific parallel factor

PARALLEL=${1:-2}
HOST=${2:-192.168.0.2}
SSH_USER=${3:-gbrennon-local-ai}

set -euo pipefail

echo "Deploying --parallel $PARALLEL to $HOST..."

# Stop service
ssh "$SSH_USER@$HOST" "sudo systemctl stop llama-server"

# Update config
ssh "$SSH_USER@$HOST" "sudo sed -i 's/--parallel [0-9]\+/--parallel $PARALLEL/g' /etc/systemd/system/llama-server.service"

# Restart
ssh "$SSH_USER@$HOST" "sudo systemctl daemon-reload && sudo systemctl start llama-server"

# Wait for startup
sleep 15

# Verify
echo "Verifying deployment..."
ssh "$SSH_USER@$HOST" << EOF
  if curl -s http://localhost:8080/health | grep -q ok; then
    echo "[OK] Service healthy"
  else
    echo "[ERROR] Service not responding"
    exit 1
  fi
  
  SLOTS=\$(curl -s http://localhost:8080/slots | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")
  if [ "\$SLOTS" -ge "$PARALLEL" ]; then
    echo "[OK] $SLOTS slots active (expected ≥$PARALLEL)"
  else
    echo "[ERROR] Only \$SLOTS slots found"
    exit 1
  fi
EOF

echo "[OK] Deployment successful"
```

---

## Next Steps

1. **Start Simple:** Run `make verify-omp-parallel` (parallel 2 only)
2. **Understand Results:** Read the generated report
3. **Test Parallel 3:** Use deployment guide to set `--parallel 3`, re-run benchmarks
4. **Compare:** Use the comparison spreadsheet in `PARALLEL-SCALING-ANALYSIS.md`
5. **Extend:** Modify benchmarks for your workload

---

## Support & Questions

- **Benchmark failing?** Check [Troubleshooting](#troubleshooting)
- **Want different model?** See [Custom Model Testing](#custom-model-testing)
- **Need more detail?** Read source reports in `docs/verification/`
- **Found a bug?** File an issue with benchmark output attached

---

*Self-service guide created: 2026-09-18*  
*For the latest benchmark scripts, see: `scripts/verify-omp-parallel-n.sh`*
