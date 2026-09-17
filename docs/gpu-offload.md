# Understanding llama.cpp GPU Layer Offload

## What `offloaded 49/49 layers to GPU` means

A llama.cpp model is divided into neural-network layers. The message:

```text
load_tensors: offloaded 49/49 layers to GPU
```

means llama.cpp assigned all 49 model layers to the Vulkan device instead of
keeping those layers in normal CPU memory. With the EVO X2 profile, this is
requested by:

```text
-ngl 99
```

`-ngl 99` means “offload up to 99 layers”; llama.cpp uses as many as the
selected device can support. It does not mean the model has 99 layers.

Full layer offload generally reduces CPU work and can increase generation
speed. The model still uses CPU memory for some metadata, host buffers, and
runtime operations. The KV cache also consumes memory and grows with context
length.

## Important: verify that the device is the real Radeon GPU

The phrase “offloaded to GPU” alone is not sufficient proof of hardware
acceleration. Vulkan can expose a software CPU renderer named `llvmpipe`.

Check the llama-server log:

```bash
ssh <user>@<evo-ip> \
  'grep -iE "ggml_vulkan:|using device|offloaded.*layers|/dev/dri" \
   /var/log/llama.cpp/llama-server.log | tail -30'
```

A working EVO X2 hardware setup should identify an AMD Radeon device, such as
the Radeon 8060S. This is **not** hardware acceleration:

```text
ggml_vulkan: 0 = llvmpipe (LLVM ...)
ggml_vulkan: Warning: Device type is CPU
MESA: error: Opening /dev/dri/card0 failed: Permission denied
```

The `llvmpipe` renderer is CPU software Vulkan. It can still report:

```text
offloaded 49/49 layers to GPU
```

but the layers are being processed by the CPU through the software renderer,
not by the Radeon 8060S. This usually explains unexpectedly low performance.

## Check GPU visibility and permissions

On the EVO X2:

```bash
vulkaninfo --summary
ls -l /dev/dri
id llamacpp
getent group render
getent group video
```

Look for an AMD Radeon device and a render node such as `/dev/dri/renderD128`.
The `llamacpp` service user must be able to access the render device. If the
user is not in the relevant device groups, add it and restart the service:

```bash
sudo usermod -aG render llamacpp
sudo usermod -aG video llamacpp
sudo systemctl restart llama-server
```

Then check the log again. A group change affects newly started processes, so a
service restart is required.

## Confirm the service is healthy

```bash
systemctl is-enabled llama-server
systemctl is-active llama-server
curl http://127.0.0.1:8080/health
```

Expected:

```text
enabled
active
{"status":"ok"}
```

Finally verify both the Vulkan device and layer offload:

```bash
grep -iE "ggml_vulkan: 0 =|using device|offloaded.*layers" \
  /var/log/llama.cpp/llama-server.log | tail -10
```

The strongest confirmation is an AMD Radeon device name together with
`offloaded 49/49 layers`, not `llvmpipe`.

## Relationship to model size and context

Full offload requires enough available unified memory for model weights,
working buffers, and the KV cache. Increasing context size increases KV-cache
usage. If a larger model does not fit, llama.cpp may keep some layers on the
CPU or fail during model loading.

For the current Qwen3-30B-A3B Q4 model, the expected evidence is:

```text
Vulkan0 model buffer size = ...
offloaded 49/49 layers to GPU
```

but the Vulkan device line must identify the actual Radeon 8060S rather than
`llvmpipe`.
