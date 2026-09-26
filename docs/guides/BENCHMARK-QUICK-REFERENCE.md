# Benchmark Quick Reference: Copy-Paste Commands
## TL;DR Version - Just Run These

**Updated:** 2026-09-18  
**Use this when:** You want quick results without reading full documentation

---

## One-Liner: Full Suite (45 minutes)

```bash
# Deploy parallel 2, run full verification (connectivity + benchmark + compilation)
cd /path/to/ai-server && make verify-omp-parallel
```

---

## Quick Benchmark Only (5 minutes)

### Benchmark Speedup for Current Configuration

```bash
python3 << 'EOF'
import urllib.request, json, time, threading

HOST = "192.168.0.2"
MODEL_ID = "/var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf"
PARALLEL = 2  # Change this to test different factors

def req(i, res):
    payload = {
        'model': MODEL_ID,
        'messages': [{'role': 'system', 'content': 'Answer in one sentence.'}, 
                     {'role': 'user', 'content': f'Count 1-5 with commas (req {i})'}],
        'max_tokens': 50, 'temperature': 0.1
    }
    t0 = time.time()
    r = urllib.request.Request(f'http://{HOST}:8080/v1/chat/completions', 
                               data=json.dumps(payload).encode(), 
                               headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(r, timeout=60) as resp:
        res[i] = time.time() - t0

# Sequential
seq, t0 = {}, time.time()
for i in range(PARALLEL): req(f's{i}', seq)
tseq = time.time() - t0

time.sleep(0.5)

# Parallel
par, t0 = {}, time.time()
ts = [threading.Thread(target=req, args=(f'p{i}', par)) for i in range(PARALLEL)]
for t in ts: t.start()
for t in ts: t.join()
tpar = time.time() - t0

print(f"Sequential: {tseq:.2f}s | Concurrent: {tpar:.2f}s | Speedup: {tseq/tpar:.2f}x")
EOF
```

---

## Deploy Different Parallel Factors

### Deploy Parallel 2
```bash
ssh gbrennon-local-ai@192.168.0.2 << 'EOF'
  sudo systemctl stop llama-server
  sudo sed -i 's/--parallel [0-9]\+/--parallel 2/g' /etc/systemd/system/llama-server.service
  sudo systemctl daemon-reload
  sudo systemctl start llama-server
  sleep 10
  echo "[OK] Deployed parallel 2"
EOF
```

### Deploy Parallel 3
```bash
ssh gbrennon-local-ai@192.168.0.2 << 'EOF'
  sudo systemctl stop llama-server
  sudo sed -i 's/--parallel [0-9]\+/--parallel 3/g' /etc/systemd/system/llama-server.service
  sudo systemctl daemon-reload
  sudo systemctl start llama-server
  sleep 10
  echo "[OK] Deployed parallel 3"
EOF
```

### Deploy Parallel 4 (Warning: May Crash)
```bash
ssh gbrennon-local-ai@192.168.0.2 << 'EOF'
  sudo systemctl stop llama-server
  sudo sed -i 's/--parallel [0-9]\+/--parallel 4/g' /etc/systemd/system/llama-server.service
  sudo systemctl daemon-reload
  sudo systemctl start llama-server
  sleep 10
  echo "[OK] Deployed parallel 4 (watch for crashes)"
EOF
```

---
## Inside SSH Session: Quick Tier Switch & CLI Execution

If you are **already logged into the machine via SSH**, do **NOT** re-run Ansible or deployment scripts. Use these local commands directly on the Evo X2:

### 1. Switch Parallel Tier in 5 Seconds (No Redeploy)

```bash
# Switch to Parallel 2 (Stable / Production default)
sudo sed -i 's/--parallel [0-9]\+/--parallel 2/g' /etc/systemd/system/llama-server.service
sudo systemctl daemon-reload && sudo systemctl restart llama-server

# Switch to Parallel 3 (Testing Tier)
sudo sed -i 's/--parallel [0-9]\+/--parallel 3/g' /etc/systemd/system/llama-server.service
sudo systemctl daemon-reload && sudo systemctl restart llama-server

# Verify active slots:
curl -s http://localhost:8080/slots | jq 'length'
```

---

### 2. Run Python Micro-Benchmark Locally on the Box

```bash
python3 - << 'EOF'
import urllib.request, json, time, threading

URL = "http://localhost:8080/v1/chat/completions"
MODEL = "/var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf"

with urllib.request.urlopen("http://localhost:8080/slots") as r:
    slots = json.loads(r.read())
parallel = len(slots)
print(f"--- Running Benchmark on {parallel} Slots (Localhost) ---")

def send(idx, out):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": f"Count 1 to 5 with commas ({idx})"}],
        "max_tokens": 50, "temperature": 0.1
    }).encode()
    t0 = time.time()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        out[idx] = time.time() - t0

# 1. Sequential
seq = {}; t0 = time.time()
for i in range(parallel): send(f"s{i}", seq)
t_seq = time.time() - t0

# 2. Parallel
par = {}; t0 = time.time()
threads = [threading.Thread(target=send, args=(f"p{i}", par)) for i in range(parallel)]
for t in threads: t.start()
for t in threads: t.join()
t_par = time.time() - t0

print(f"Sequential: {t_seq:.2f}s | Concurrent: {t_par:.2f}s | Speedup: {t_seq/t_par:.2f}x")
EOF
```

---

### 3. Run Interactive `llama-cli`

> [WARN] **IMPORTANT:** Stop `llama-server` first to release the 22–27 GB of VRAM. Running both concurrently will trigger a Vulkan out-of-memory crash.

```bash
# 1. Stop background server
sudo systemctl stop llama-server

# 2. Launch interactive conversation
/opt/llama.cpp/build/bin/llama-cli \
  -m /var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf \
  -ngl 99 \
  --flash-attn on \
  -ctk q8_0 \
  -ctv q8_0 \
  --threads 16 \
  -c 32768 \
  --temp 0.6 \
  -cnv

# (Type /exit or Ctrl+C to leave)

# 3. Restart server when done
sudo systemctl start llama-server
```

---

### 4. Run `llama-bench` (Raw Hardware Benchmark)

```bash
sudo systemctl stop llama-server

/opt/llama.cpp/build/bin/llama-bench \
  -m /var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf \
  -ngl 99 \
  --flash-attn on \
  -ctk q8_0 \
  -ctv q8_0 \
  -p 512,2048 \
  -n 128,256

sudo systemctl start llama-server
```

---

### 5. Run `omp` Agent CLI on Evo X2

```bash
omp --no-skills --no-extensions --no-rules \
    --tools bash,read,write \
    --auto-approve --approval-mode=yolo \
    --system-prompt "You are a concise programming assistant. Act directly." \
    --model "evo-x2-llamacpp//var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf" \
    -p "Write a hello-world Rust program in /tmp/test.rs and test it with rustc."
```

---


## Check Current Status

```bash
ssh gbrennon-local-ai@192.168.0.2 << 'EOF'
  echo "=== Parallel Factor ==="
  ps aux | grep llama-server | grep -v grep | grep -oE "\-\-parallel [0-9]+"
  
  echo ""
  echo "=== Service Status ==="
  systemctl status llama-server --no-pager | grep -E "Active|Restart"
  
  echo ""
  echo "=== Memory ==="
  free -h | awk 'NR==2 {printf "Used: %s / Total: %s\n", $3, $2}'
  
  echo ""
  echo "=== Thermals ==="
  sensors 2>/dev/null | grep -oE "Tctl|edge.*[0-9]+.*C" | head -2
  
  echo ""
  echo "=== Slots ==="
  curl -s http://localhost:8080/slots | python3 -c "import sys, json; slots = json.load(sys.stdin); print(f'{len(slots)} slots: {[s[\"id\"] for s in slots]}')" 2>/dev/null || echo "(error)"
EOF
```

---

## Run Full Agentic Test

### With OMP (Real Agents)
```bash
TEST_DIR="/tmp/benchmark-agentic-p2"
OMP_MODEL="evo-x2-llamacpp/Qwen3.8-27B-UD-Q4_K_M.gguf"

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/src"

echo "Starting OMP agents..."
T0=$(date +%s)

(
  omp --no-skills --no-extensions --no-rules --tools bash,write,read \
      --auto-approve --approval-mode=yolo --cwd="$TEST_DIR" \
      --system-prompt "Write Rust code concisely." \
      --model "$OMP_MODEL" \
      -p "Write Cargo.toml and src/main.rs for a simple binary saying 'Hello parallel!'" \
      > "$TEST_DIR/a1.log" 2>&1
) &
P1=$!

(
  omp --no-skills --no-extensions --no-rules --tools bash,write,read \
      --auto-approve --approval-mode=yolo --cwd="$TEST_DIR" \
      --system-prompt "Write Rust code concisely." \
      --model "$OMP_MODEL" \
      -p "Write src/main.rs that prints 'Parallel 2 Active'" \
      > "$TEST_DIR/a2.log" 2>&1
) &
P2=$!

wait $P1 $P2
T1=$(date +%s)

echo "Agents completed in $((T1-T0))s"
echo "Files: $(ls $TEST_DIR/src/ 2>/dev/null | wc -l) files"
```

---

## Monitor in Real-Time

### Watch Power & Thermals During Benchmark
```bash
# In one terminal
ssh gbrennon-local-ai@192.168.0.2 'watch -n 2 "echo === Power === && sudo check-pmode && echo && echo === Thermals === && sensors | grep -E Tctl|edge"'
```

### Watch Memory
```bash
ssh gbrennon-local-ai@192.168.0.2 'watch -n 2 "free -h && echo && systemctl status llama-server --no-pager | grep Memory"'
```

### Watch Service Logs
```bash
ssh gbrennon-local-ai@192.168.0.2 'journalctl -u llama-server -f --no-pager | grep -E "error|WARN|ABRT"'
```

---

## Record Results to File

```bash
# Benchmark with output captured
{
  echo "Parallel 2 Benchmark - $(date)"
  python3 << 'BENCHMARK'
import urllib.request, json, time, threading

HOST = "192.168.0.2"
MODEL_ID = "/var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf"

def req(i, res):
    payload = {'model': MODEL_ID, 'messages': [{'role': 'system', 'content': 'Concise.'}, {'role': 'user', 'content': f'Count 1-5 (req {i})'}], 'max_tokens': 50, 'temperature': 0.1}
    t0 = time.time()
    r = urllib.request.Request(f'http://{HOST}:8080/v1/chat/completions', data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(r, timeout=60) as resp: res[i] = time.time() - t0

seq, t0 = {}, time.time()
for i in range(2): req(f's{i}', seq)
tseq = time.time() - t0

time.sleep(0.5)

par, t0 = {}, time.time()
ts = [threading.Thread(target=req, args=(f'p{i}', par)) for i in range(2)]
for t in ts: t.start()
for t in ts: t.join()
tpar = time.time() - t0

print(f"T_SEQ={tseq:.2f}")
print(f"T_PAR={tpar:.2f}")
print(f"SPEEDUP={tseq/tpar:.2f}x")
BENCHMARK
} | tee benchmark-results.txt

# View results
cat benchmark-results.txt
```

---

## Troubleshoot Issues

### Check if Service is Responding
```bash
ssh gbrennon-local-ai@192.168.0.2 'curl -s http://localhost:8080/health && echo "(OK)" || echo "(FAILED)"'
```

### View Recent Errors
```bash
ssh gbrennon-local-ai@192.168.0.2 'journalctl -u llama-server -n 50 --no-pager | grep -i "error\|crash\|abrt\|fail"'
```

### Check Memory Pressure
```bash
ssh gbrennon-local-ai@192.168.0.2 << 'EOF'
  USED=$(free | awk 'NR==2 {print $3}')
  TOTAL=$(free | awk 'NR==2 {print $2}')
  PCT=$((USED * 100 / TOTAL))
  echo "Memory: $PCT% full ($USED / $TOTAL KB)"
  [ $PCT -gt 80 ] && echo "WARNING: High memory usage" || echo "OK"
EOF
```

### Force Restart Service
```bash
ssh gbrennon-local-ai@192.168.0.2 'sudo systemctl restart llama-server && sleep 10 && systemctl status llama-server --no-pager | head -10'
```

---

## Template: Benchmark Report

After running your benchmarks, fill in:

```markdown
# My Benchmark Results
**Date:** $(date)
**Hardware:** GMKtec Evo X2 (128GB, Ryzen AI Max+ 395)

## Parallel 2
- Speedup: [INSERT]
- Seq Time: [INSERT]
- Par Time: [INSERT]
- Status: [PASS/FAIL]

## Parallel 3
- Speedup: [INSERT]
- Seq Time: [INSERT]
- Par Time: [INSERT]
- Status: [PASS/FAIL]

## Parallel 4
- Status: [PASS/FAIL/NOT TESTED]
- Notes: [INSERT]

## Recommendations
[Your conclusions here]
```

---

## Common Workflows

### Workflow 1: Test All Factors Sequentially

```bash
#!/bin/bash
for parallel in 2 3 4; do
  echo "Testing parallel $parallel..."
  
  # Deploy
  ssh gbrennon-local-ai@192.168.0.2 "sudo sed -i 's/--parallel [0-9]\+/--parallel $parallel/g' /etc/systemd/system/llama-server.service && sudo systemctl restart llama-server && sleep 15"
  
  # Benchmark
  echo "Running benchmark..."
  python3 << EOF
import urllib.request, json, time, threading
HOST = "192.168.0.2"
MODEL_ID = "/var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf"
def req(i, res):
    payload = {'model': MODEL_ID, 'messages': [{'role': 'system', 'content': 'Concise.'}, {'role': 'user', 'content': f'Count 1-5 (req {i})'}], 'max_tokens': 50, 'temperature': 0.1}
    t0 = time.time()
    r = urllib.request.Request(f'http://{HOST}:8080/v1/chat/completions', data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(r, timeout=60) as resp: res[i] = time.time() - t0
    except: res[i] = None
seq, t0 = {}, time.time()
for i in range($parallel): req(f's{i}', seq)
tseq = time.time() - t0
time.sleep(0.5)
par, t0 = {}, time.time()
ts = [threading.Thread(target=req, args=(f'p{i}', par)) for i in range($parallel)]
for t in ts: t.start()
for t in ts: t.join()
tpar = time.time() - t0
print(f"Parallel $parallel: Speedup={tseq/tpar:.2f}x (seq={tseq:.2f}s, par={tpar:.2f}s)")
EOF
  
  sleep 5
done
```

### Workflow 2: Compare Specific Models

```bash
for model_name in "Qwen3.8-27B-UD-Q4_K_M" "llama-2-7b-Q4_K_M"; do
  echo "Testing model: $model_name..."
  MODEL_PATH="/var/lib/llama.cpp/models/${model_name}.gguf"
  
  # Check if model exists
  ssh gbrennon-local-ai@192.168.0.2 "test -f $MODEL_PATH" || { echo "Model not found"; continue; }
  
  # Update systemd to use model
  ssh gbrennon-local-ai@192.168.0.2 "sudo sed -i 's|--model.*gguf|--model $MODEL_PATH|g' /etc/systemd/system/llama-server.service && sudo systemctl restart llama-server && sleep 15"
  
  # Run benchmark
  python3 benchmark.py 192.168.0.2 "$MODEL_PATH" 2
done
```

---

## File Locations

```
Repository Structure:
├── scripts/
│   ├── verify-omp-parallel.sh          (Main verification script)
│   ├── verify-omp-parallel-n.sh        (Parameterized version)
│   └── [Other scripts]
├── profiles/
│   ├── gmktec-evo-x2-parallel-2.yml
│   ├── gmktec-evo-x2-parallel-3.yml
│   └── gmktec-evo-x2-parallel-4.yml
├── docs/verification/
│   ├── evo-x2-omp-parallel-benchmark.md
│   ├── evo-x2-omp-parallel-3-benchmark.md
│   ├── evo-x2-omp-parallel-4-failure-report.md
│   └── PARALLEL-SCALING-ANALYSIS.md
└── docs/guides/
    ├── PARALLEL-BENCHMARK-SELF-SERVICE.md (Full guide)
    └── BENCHMARK-QUICK-REFERENCE.md       (This file)
```

---

## Timing Guide

```
Parallel 2 Full Suite:      ~11 minutes (connectivity + benchmark + compilation)
Parallel 2 Benchmark Only:  ~5 minutes
Parallel 2 Agentic Only:    ~5-10 minutes

Parallel 3 Full Suite:      ~15 minutes (longer agent time)
Parallel 4 Test:            ~60 seconds (crashes)

Full Sweep (2+3+4):         ~45 minutes
```

---

## [PASS] Sanity Checks

Before running benchmarks:

```bash
# 1. SSH works
ssh gbrennon-local-ai@192.168.0.2 'echo OK'

# 2. Model exists
ssh gbrennon-local-ai@192.168.0.2 'ls /var/lib/llama.cpp/models/*.gguf'

# 3. Service is running
ssh gbrennon-local-ai@192.168.0.2 'systemctl is-active llama-server'

# 4. Service responds to HTTP
ssh gbrennon-local-ai@192.168.0.2 'curl -s http://localhost:8080/health'

# 5. Memory available
ssh gbrennon-local-ai@192.168.0.2 'free -h | awk "NR==2"'

# All OK?
echo "[OK] Ready to run benchmarks"
```

---

*Quick reference created: 2026-09-18*  
*For full details, see: PARALLEL-BENCHMARK-SELF-SERVICE.md*
