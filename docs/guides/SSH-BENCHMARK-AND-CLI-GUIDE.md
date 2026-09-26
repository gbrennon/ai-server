# GMKtec Evo X2: SSH Session Benchmark & CLI Guide

**Audience:** Operators currently logged into `gbrennon-local-ai@192.168.0.2` via SSH.

---

## 1. Do You Need to Redeploy for Each Parallel Tier?

**NO.** You do not need to re-run Ansible, `make deploy-gmktec`, or any deployment scripts.

Since you are already inside the target machine, switching tiers is a single-line command editing the systemd service file:

```bash
# Switch to Parallel 2 (Recommended production baseline)
sudo sed -i 's/--parallel [0-9]\+/--parallel 2/g' /etc/systemd/system/llama-server.service
sudo systemctl daemon-reload && sudo systemctl restart llama-server

# Switch to Parallel 3 (Testing tier)
sudo sed -i 's/--parallel [0-9]\+/--parallel 3/g' /etc/systemd/system/llama-server.service
sudo systemctl daemon-reload && sudo systemctl restart llama-server

# Verify the new slot count after ~5-10 seconds
curl -s http://localhost:8080/slots | jq 'length'
```

---

## 2. Running the Micro-Benchmark Inside SSH

Run this directly in your SSH terminal to measure sequential vs. concurrent inference across all active slots:

```bash
python3 - << 'EOF'
import urllib.request, json, time, threading

URL = "http://localhost:8080/v1/chat/completions"
MODEL = "/var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf"

# Auto-detect active slots
with urllib.request.urlopen("http://localhost:8080/slots") as r:
    parallel = len(json.loads(r.read()))
print(f"=== Running Benchmark with {parallel} Parallel Slots on Localhost ===")

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

# 1. Sequential Run
seq = {}; t0 = time.time()
for i in range(parallel): send(f"s{i}", seq)
t_seq = time.time() - t0

# 2. Concurrent Run
par = {}; t0 = time.time()
threads = [threading.Thread(target=send, args=(f"p{i}", par)) for i in range(parallel)]
for t in threads: t.start()
for t in threads: t.join()
t_par = time.time() - t0

print(f"Sequential Total Time: {t_seq:.2f}s")
print(f"Concurrent Total Time: {t_par:.2f}s")
print(f"Measured Speedup:      {t_seq/t_par:.2f}x")
EOF
```

---

## 3. Running `llama-cli` (Interactive Chat)

> [WARN] **CRITICAL MEMORY CAUTION:** `llama-server` currently holds ~22–27 GB of VRAM. If you launch `llama-cli` while the server is running, loading a second copy of Qwen 27B will exceed available memory and crash the Vulkan driver.

### Step 1: Stop the background service
```bash
sudo systemctl stop llama-server
```

### Step 2: Run `llama-cli` interactively
```bash
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
```

*Commands inside `llama-cli`:*
- Type your prompt and press `Enter`.
- Type `/exit` or press `Ctrl+C` to quit.

### Step 3: Restart the server when done
```bash
sudo systemctl start llama-server
```

---

## 4. Running `llama-bench` (Hardware Throughput Benchmark)

To test raw Vulkan prompt processing ($t_{\text{pp}}$) and token generation ($t_{\text{tg}}$) speed:

```bash
# Stop server to free VRAM
sudo systemctl stop llama-server

/opt/llama.cpp/build/bin/llama-bench \
  -m /var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf \
  -ngl 99 \
  --flash-attn on \
  -ctk q8_0 \
  -ctv q8_0 \
  -p 512,2048 \
  -n 128,256

# Restart server
sudo systemctl start llama-server
```

---

## 5. Running `omp` (Oh My Pi) Against Local Model

```bash
omp --no-skills --no-extensions --no-rules \
    --tools bash,read,write \
    --auto-approve --approval-mode=yolo \
    --system-prompt "You are a concise programming assistant. Act directly." \
    --model "evo-x2-llamacpp//var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf" \
    -p "Write a hello-world Rust program in /tmp/test.rs and test it with rustc."
```

---

## 6. Live Hardware Monitoring in a Second SSH Pane

Open a second SSH terminal or tmux split and run:

```bash
# Monitor Power (Package Watts)
watch -n 1 "sudo check-pmode"

# Monitor Thermals
watch -n 1 "sensors | grep -E 'Tctl|edge'"

# Monitor Memory and Swap
watch -n 1 "free -h"
```
