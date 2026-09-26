# Parallel Benchmark & Agentic Testing Guide
## Complete Reference for Self-Service Verification

**Created:** 2026-09-18  
**Status:** Ready to use  
**Audience:** Engineers running their own parallel scaling benchmarks

---

## Where to Start

### Option 1: Just Run It (Fastest)
- **Time:** 11 minutes
- **Complexity:** Low
- **Result:** Full parallel 2 benchmark with verification

```bash
cd /path/to/ai-server
make verify-omp-parallel
```

[PASS] This is the recommended approach for most users.

### Option 2: Quick Benchmark Only (Fastest Data)
- **Time:** 5 minutes
- **Complexity:** Very low
- **Result:** Speedup numbers for current configuration

See: **[BENCHMARK-QUICK-REFERENCE.md](BENCHMARK-QUICK-REFERENCE.md)** → Section "Quick Benchmark Only"

### Option 3: Full Self-Service (Most Control)
- **Time:** 45 minutes for all factors
- **Complexity:** Medium
- **Result:** Custom testing, extended benchmarks, full control

See: **[PARALLEL-BENCHMARK-SELF-SERVICE.md](PARALLEL-BENCHMARK-SELF-SERVICE.md)**

### Option 4: Just Study the Results
- **Time:** 15 minutes
- **Complexity:** None (reading only)
- **Result:** Understand what we learned

See: **[docs/verification/PARALLEL-SCALING-ANALYSIS.md](../verification/PARALLEL-SCALING-ANALYSIS.md)**

---
### Quick References & CLI Guides

1. **`SSH-BENCHMARK-AND-CLI-GUIDE.md`** — **Start here if you are in SSH!**
   - Changing parallel factor without redeployment
   - Running the benchmark directly against `localhost:8080`
   - Running `llama-cli` interactively (with required VRAM safeguards)
   - Running `llama-bench` for raw Vulkan compute measurements
   - Running `omp` agent CLI locally

2. **`BENCHMARK-QUICK-REFERENCE.md`** — Copy-paste commands from either workstation or SSH.

3. **`PARALLEL-BENCHMARK-SELF-SERVICE.md`** — Full end-to-end background, theory, and scripts.
- Copy-paste commands
- Deployment scripts
- Quick status checks
- Troubleshooting
- Template reports

**Best for:** Quick iterations, experienced engineers

---

### Full Self-Service Guide (Step-by-Step)

**File:** `PARALLEL-BENCHMARK-SELF-SERVICE.md`

Use this when you want:
- Detailed explanations
- Understanding prerequisites
- Custom scripts
- How to interpret results
- How to extend benchmarks

**Best for:** Learning, customization, reproducibility

---

### Benchmark Results & Analysis

**Files in `../verification/`:**

| Report | Focus | Status | When to Read |
|--------|-------|--------|--------------|
| `evo-x2-omp-parallel-benchmark.md` | Parallel 2 (optimized) | PASS | Understand production baseline |
| `evo-x2-omp-parallel-3-benchmark.md` | Parallel 3 (testing) | PASS (diminished) | Understand scaling limits |
| `evo-x2-omp-parallel-4-failure-report.md` | Parallel 4 (hardware limit) | FAIL | Understand why parallel 4 crashes |
| `PARALLEL-SCALING-ANALYSIS.md` | All factors compared | COMPLETE | Make production decisions |

---

## Quick Start by Use Case

### I Want to Verify My Hardware

```bash
cd /path/to/ai-server
make verify-omp-parallel
```

### I Want to Test Different Parallel Factors (2, 3, 4)

See: `BENCHMARK-QUICK-REFERENCE.md` → "Deploy Different Parallel Factors"

### I Want to Test My Own Workload

See: `PARALLEL-BENCHMARK-SELF-SERVICE.md` → "Extending the Benchmarks"

### I Want to Understand the Results

Read: `PARALLEL-SCALING-ANALYSIS.md` (start here for overview)

---

## Key Findings

| Configuration | Speedup | Memory | Thermals | Production Ready? |
|---------------|---------|--------|----------|-------------------|
| **Parallel 2** | 4.35x | 27 GB peak | 52°C | YES |
| **Parallel 3** | 1.99x | 5.4 GB peak | 47°C | [WARN] NO |
| **Parallel 4** | CRASH | 1 GB (crash) | N/A | NO |

---

## Files Included

```
docs/guides/
├── README.md                           (This file)
├── BENCHMARK-QUICK-REFERENCE.md        (Copy-paste commands)
└── PARALLEL-BENCHMARK-SELF-SERVICE.md  (Full step-by-step guide)

docs/verification/
├── evo-x2-omp-parallel-benchmark.md
├── evo-x2-omp-parallel-3-benchmark.md
├── evo-x2-omp-parallel-4-failure-report.md
└── PARALLEL-SCALING-ANALYSIS.md
```

---

## Tools Needed

- SSH (to remote host)
- Python 3.8+
- Bash 4.0+
- `make` (for convenience)
- OMP CLI (for agentic tasks)

---

## [PASS] Start Here

1. **Read this file** (you're reading it now)
2. **Run:** `make verify-omp-parallel`
3. **Review:** Generated report in `docs/verification/`
4. **Experiment:** Use `BENCHMARK-QUICK-REFERENCE.md` for custom tests
5. **Extend:** Use `PARALLEL-BENCHMARK-SELF-SERVICE.md` for advanced testing

---

*Created: 2026-09-18*
