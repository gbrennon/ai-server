#!/usr/bin/env python3
"""Run repeatable short and long llama.cpp measurements on the target host."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import threading
import time
import urllib.request
from statistics import mean


SHORT_PROMPT = (
    "Write a Rust function named add that returns the sum of two i32 values. "
    "Return only the function code."
)
LONG_PROMPT = "\n".join(
    f"module_{index:04d}: function_{index:04d} handles a deterministic ledger "
    "record with validated input, bounded output, and an explicit error path."
    for index in range(260)
) + "\nSummarize the module structure and validation flow."


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--endpoint", default="http://127.0.0.1:8080")
    parser.add_argument("--runs", type=int, default=3)
    return parser.parse_args()


def parse_rocm_power(csv_text: str) -> float | None:
    """Extract GPU package power (W) from the last rocm-smi CSV line."""
    lines = [line for line in csv_text.splitlines() if line.strip()]
    if not lines:
        return None
    header = lines[0].split(",")
    try:
        power_index = header.index("Current Socket Graphics Package Power (W)")
    except ValueError:
        return None
    values = []
    for line in lines[1:]:
        fields = line.split(",")
        if len(fields) > power_index:
            try:
                values.append(float(fields[power_index]))
            except ValueError:
                continue
    return mean(values) if values else None


def read_telemetry() -> dict[str, object]:
     rocm = subprocess.run(
         ["rocm-smi", "--showuse", "--showtemp", "--showpower", "--csv"],
         capture_output=True,
         text=True,
         timeout=3,
         check=False,
     ).stdout.strip()
     sensors = subprocess.run(
         ["bash", "-lc", "sensors 2>/dev/null"],
         capture_output=True,
         text=True,
         timeout=3,
         check=False,
     ).stdout
     edge_match = re.search(r"edge:\s*\+([0-9.]+)", sensors)
     acpi_match = re.search(r"acpitz.*?temp1:\s*\+([0-9.]+)", sensors, re.S)
     power_w = parse_rocm_power(rocm)
     return {
         "edge_c": float(edge_match.group(1)) if edge_match else None,
         "acpi_c": float(acpi_match.group(1)) if acpi_match else None,
         "power_w": power_w,
         "rocm": rocm.splitlines()[-1] if rocm else "",
     }


def monitor(stop: threading.Event, samples: list[dict[str, object]]) -> None:
    while not stop.is_set():
        try:
            samples.append(read_telemetry())
        except (OSError, subprocess.SubprocessError) as error:
            samples.append({"error": str(error)})
        stop.wait(1.0)


def request_sample(
    endpoint: str, model: str, case: str, prompt: str, run: int
) -> dict[str, object]:
    marked_prompt = f"{prompt}\nBenchmark run marker {run}; do not mention it."
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": marked_prompt}],
        "temperature": 0,
        "top_p": 1,
        "max_tokens": 128,
        "stream": False,
        "timings_per_token": True,
        "cache_prompt": False,
    }
    request = urllib.request.Request(
        f"{endpoint}/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=180) as response:
        result = json.load(response)
    elapsed = time.monotonic() - started
    timings = result.get("timings", {})
    usage = result.get("usage", {})
    prompt_tokens = timings.get("prompt_n", usage.get("prompt_tokens"))
    generated_tokens = timings.get("predicted_n", usage.get("completion_tokens"))
    sample = {
        "case": case,
        "run": run,
        "prompt_tokens": prompt_tokens,
        "generated_tokens": generated_tokens,
        "prompt_tps": timings.get("prompt_per_second"),
        "decode_tps": timings.get("predicted_per_second"),
        "end_to_end_tps": generated_tokens / elapsed if generated_tokens else None,
        "wall_s": round(elapsed, 4),
        "finish_reason": (result.get("choices") or [{}])[0].get("finish_reason"),
    }
    print(json.dumps(sample), flush=True)
    return sample


def select_case_samples(
    samples: list[dict[str, object]], case: str
) -> list[dict[str, object]]:
    return [sample for sample in samples if sample["case"] == case]


def print_case_summary(samples: list[dict[str, object]], case: str) -> None:
    selected = select_case_samples(samples, case)
    if not selected:
        return
    summary = {
        "summary_case": case,
        "runs": len(selected),
        "mean_prompt_tps": mean(float(sample["prompt_tps"]) for sample in selected),
        "mean_decode_tps": mean(float(sample["decode_tps"]) for sample in selected),
        "mean_end_to_end_tps": mean(
            float(sample["end_to_end_tps"]) for sample in selected
        ),
        "prompt_tokens": [sample["prompt_tokens"] for sample in selected],
        "generated_tokens": [sample["generated_tokens"] for sample in selected],
    }
    print(json.dumps(summary))


def print_telemetry_summary(telemetry: list[dict[str, object]]) -> None:
    edges = [float(item["edge_c"]) for item in telemetry if item.get("edge_c")]
    acpi = [float(item["acpi_c"]) for item in telemetry if item.get("acpi_c")]
    powers = [float(item["power_w"]) for item in telemetry if item.get("power_w") is not None]
    summary = {
        "summary_telemetry": True,
        "samples": len(telemetry),
        "max_edge_c": max(edges) if edges else None,
        "max_acpi_c": max(acpi) if acpi else None,
    }
    if powers:
        summary["min_power_w"] = min(powers)
        summary["mean_power_w"] = mean(powers)
        summary["max_power_w"] = max(powers)
    print(json.dumps(summary))


def summarize(samples: list[dict[str, object]], telemetry: list[dict[str, object]]) -> None:
    for case in ("short", "long"):
        print_case_summary(samples, case)
    print_telemetry_summary(telemetry)


def main() -> None:
    args = parse_args()
    if args.runs < 1:
        raise SystemExit("--runs must be positive")
    samples: list[dict[str, object]] = []
    telemetry: list[dict[str, object]] = []
    stop = threading.Event()
    thread = threading.Thread(target=monitor, args=(stop, telemetry), daemon=True)
    thread.start()
    try:
        for case, prompt in (("short", SHORT_PROMPT), ("long", LONG_PROMPT)):
            for run in range(1, args.runs + 1):
                samples.append(
                    request_sample(args.endpoint, args.model, case, prompt, run)
                )
    finally:
        stop.set()
        thread.join(timeout=3)
        summarize(samples, telemetry)


if __name__ == "__main__":
    main()
