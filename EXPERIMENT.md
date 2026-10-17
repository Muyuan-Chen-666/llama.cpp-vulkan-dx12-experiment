# Experimental Vulkan compute with D3D12 memory allocation on Intel PTL

**AI implementation and report: GPT-6.1 Sol (OpenAI Codex). Preliminary, not independently human-reviewed, no designated maintainer.**

The account owner requested this experiment and supplied hardware constraints. They did not design, implement, compile, execute the automated tests, or review the code. They explicitly state that they do not understand the implementation and are not offering maintenance or technical support. They subsequently confirmed observing over 20 generated tokens/s. Do not attribute implementation or technical approval to the account owner. An AI byline is not a substitute for a responsible human reviewer or maintainer.

This branch is a reproducible research artifact for independent examination. It is not an upstream submission or an assertion that the patch meets upstream contribution requirements. Anyone proposing an upstream contribution should independently understand and review it, complete the missing validation, and follow upstream policy.

## Observation and mechanism

On one Windows device with a Core Ultra X7 358H, Arc B390 Xe3, 32GB physical RAM, an 8GB BIOS GPU reservation, and driver 32.0.101.9033, ordinary Vulkan allocations were reported as shared GPU memory. A D3D12 DEFAULT resource used reserved dedicated memory. The patch creates shared committed D3D12 buffer resources and imports their NT handles into Vulkan using `VK_KHR_external_memory_win32` and the `D3D12_RESOURCE` handle type.

Vulkan still executes uploads and inference kernels; D3D12 does not execute compute commands on the resource. Adapter LUID matching selects the same physical GPU. The D3D12 resource is retained alongside its Vulkan allocation. Imported buffers deliberately have no CPU mapping. A MiB limit controls the opt-in allocation path, and failed attempts fall back to ordinary Vulkan allocation.

The tested Vulkan device exposes a 13728MiB heap. Imported resources still count toward its effective allocation limit. The BIOS reservation cannot simply be added to the heap to promise a 21GB Vulkan addressable budget. This does not add physical RAM or bandwidth and does not guarantee protection from WDDM migration or eviction.

## Reproduction

Base: llama.cpp tag `b11714`, commit `c0fd78626405c6d9b934efef0ec7291fcc20e3d6`.

Build the static Windows Vulkan backend using a compatible C++ compiler, Windows SDK, Vulkan headers/loader, shader compiler and SPIR-V headers. The patch links Windows D3D12/DXGI libraries. The tested local build enabled AVX2, FMA/F16C and AVX-VNNI. Neither a system driver replacement nor a Vulkan ICD replacement was used.

Model: `Qwen3.5-35B-A3B-UD-IQ4_XS.gguf`, 17486174848 bytes, SHA256 `745def087c9ec34d12a94eb9b31eb52dba958b36def510b7e8f6f2e6bf1be123`. The expert tensors mix IQ4_XS down projections and IQ3_S gate/up projections.

```powershell
$env:GGML_VK_D3D12_MEMORY_MIB='6144'
$env:GGML_VK_FORCE_MAX_BUFFER_SIZE='1073741824'
./llama-server.exe -m MODEL.gguf --alias Qwen3.5-35B-A3B --host 127.0.0.1 --port 8090 `
  -c 4096 -np 1 -b 512 -ub 128 -t 8 -tb 16 -ngl 99 --fit off `
  --n-cpu-moe 10 --device Vulkan0 --load-mode none --no-host `
  -fa on --cache-ram 256 --ctx-checkpoints 2 --reasoning off --jinja `
  --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 --presence-penalty 1.5
```

The environment limit is an allocation preference, not a physical residency guarantee. The 1GiB buffer limit permits several allocations to fit inside the dedicated-memory preference. Ordinary CPU buffers and non-mapped loading are part of the tested configuration. No dynamic expert cache or per-token expert prediction was implemented.

## Initial measurements

| Measurement | Observation |
| --- | --- |
| Chinese generation | 177 tokens, 23.61 tokens/s |
| Dedicated memory, adapter counter | 6088MiB peak |
| Shared memory, model process | 7063MiB peak |
| Available system RAM in that short run | 5248MiB minimum; no page output sampled |
| Expert tensors in imported resources | 39 tensors, 4628MiB, layers 10 through 22 |
| Expert placement | 10 CPU layers, 13 dedicated GPU layers, 17 shared GPU layers |
| After stopping the model | Adapter dedicated usage returned to approximately 41MiB |

Process-level dedicated counters appeared to double-count imported aliases and could show approximately 12GB. Adapter-level counters were used for actual dedicated residency observations. This is not evidence of more than 8GB reserved memory.

Tuned stock Vulkan also reached approximately 23.08 tokens/s, while system RAM headroom later fell to approximately 369MiB. Therefore this experiment does not establish a multiple-fold compute-speed improvement from dedicated allocation itself.

## Checks and explicit limitations

- The IQ3/IQ4 `MUL_MAT_ID` operation cases tested against CPU passed 23/23. This does not cover all shapes, operations or graph optimizations.
- Arithmetic, specified JSON fields and readable Chinese generation passed short checks. Semantic truthfulness was not comprehensively scored.
- A 1167-token synthetic lookup and conversation restoration check passed.
- A subsequent 16K configuration processed 12027 actual prompt tokens, retrieved three anchors, and generated its answer at 22.16 tokens/s. Prefill was 167.83 tokens/s. Available RAM fell to 924MiB and page output occurred: this was not a sufficiently comfortable daily profile.
- Longer-context results and 27B capacity estimates are separate experimental follow-ups; an estimate must not be described as a measured model benchmark.
- No perplexity/KL equivalence, fixed-input stock-versus-patched numerical comparison, standard task suite, multi-hour endurance, sleep/wake, power-state, concurrent gaming, other GPU, or other driver validation has been completed.
- Validation-layer checks, external-buffer usage/capability queries, buffer-device-address compatibility, initial external ownership, resource-description matching, allocation-boundary/failure injection, concurrent allocation and device-loss behavior require independent review. Successful execution on this driver does not prove those cases correct.
- Non-Windows builds and complete CI have not been verified. No human approval or upstream readiness is claimed.

The [Chinese report](docs/backend/VULKAN-D3D12-PTL-EXPERIMENT.zh.md) includes the detailed experiment history. The existing upstream [license](LICENSE) applies to the derived code. Original upstream material and names are not claims of endorsement.

References: [Khronos external memory guide](https://docs.vulkan.org/guide/latest/extensions/external.html), [Vulkan memory specification](https://docs.vulkan.org/spec/latest/chapters/memory.html), [upstream contribution policy](https://github.com/ggml-org/llama.cpp/blob/master/CONTRIBUTING.md).

## Longer-context follow-up measurements

These synthetic tests place three lookup anchors near the beginning, middle and end of a larger prompt. They are useful correctness checks, not a broad context-understanding benchmark.

| Configured context | Actual prompt | CPU expert layers | Imported-resource limit | KV / microbatch | Prefill tokens/s | Answer tokens/s | Minimum available RAM MiB |
| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: |
| 16K | 12027 | 10 | 6144MiB | f16 / 128 | 167.83 | 22.16 | 924 |
| 32K | 24027 | 11 | 7168MiB | f16 / 128 | 137.52 | 20.66 | 2231 |
| 32K | 24027 | 9 | 7168MiB | q8_0 / 64 | 92.59 | 17.64 | 2594 |

All three anchor checks passed in these runs. Page output was observed in the long tests; background process residency, caching, power and thermals were not fully controlled. The latter two used `--cache-ram 0 --ctx-checkpoints 1`. In the q8 run, adding two GPU expert layers did not outweigh the cost of the changed KV format/microbatch on this device. This is a configuration comparison, not an isolated attribution to one setting.

The 32K f16 profile is the more balanced candidate. Near-limit input and subsequent conversation tests are documented in the accompanying evidence when available; successful allocation alone is not treated as validation.

A near-limit run processed 30011 actual prompt tokens in 246.02 seconds, retrieved all three anchors, and answered at 19.31 tokens/s. A follow-up reused 30007 cached tokens, checked the anchor plus arithmetic and sorting, and returned in 3.88 seconds. A subsequent 256-token generation ran at 19.21 tokens/s; it was capped at the token limit and its semantic quality was not scored. Initial long-request memory monitoring reached 902MiB available RAM and sampled page output. Near-full context is therefore possible but memory-tight, and the first large-document pass can take several minutes.

The candidate daily profile uses `-c 32768 --n-cpu-moe 11`, a 7168MiB imported-resource limit, f16 KV, microbatch 128, `--cache-ram 0 --ctx-checkpoints 1`. Disabling the cross-conversation prompt cache does not prevent current-slot prefix reuse. Residency logs identify 46 expert tensors totaling 5476MiB in imported buffers; allocation boundaries can split a layer, so this must not be described as 16 whole dedicated expert layers. The previous 4K/6144MiB profile remains a fallback.

An additional 18-request synthetic mixed-task run passed 15 and failed 3. All three failures were the same Python expression, `[i*i for i in range(5) if i%2==0]`: the answer was `[0,4]` instead of `[0,4,16]`. Presence penalties 1.5, 0 and 0.5 all retained the error. Unmodified official b11714 Vulkan, tested separately at 4K with the same 11 CPU expert layers, also produced `[0,4]`. This single failure is not unique to the allocation patch; it does not establish complete numerical equivalence or model quality. The failed answers are retained in the evidence.

See [sanitized measurements](docs/backend/ptl-memory-evidence/measurements.json), [expert placement](docs/backend/ptl-memory-evidence/resident-experts-32k.json), and the [synthetic check scripts](examples/ptl-vulkan-d3d12-memory/README.md). No chat history, credentials, user process listings, local usernames or raw server logs are part of the published evidence.

## 27B planning estimate, not an executed benchmark

The [separate capacity estimate](docs/backend/QWEN35-27B-PTL-ESTIMATE.zh.md) covers 22 published GGUF weight formats. Representative actual file sizes are 10.72GiB for UD-IQ3_XXS, 13.95GiB for IQ4_XS, 15.59GiB for Q4_K_M, 18.26GiB for Q5_K_M, 20.91GiB for Q6_K, and 26.63GiB for Q8_0. The 27B dense model has 16 full-attention layers, so its f16 KV alone is approximately 2GiB at 32K context. The remaining state/workspace and OS requirements still apply.

IQ3 is the first capacity-oriented candidate; IQ4/Q4 normally need some CPU placement under this Vulkan heap limit. Q5 is tight, Q6 is marginal, and Q8/BF16 are not practical daily choices on this machine. No 27B model was downloaded or run. Dense 27B must not inherit the sparse 35B-A3B speed claim; single-digit tokens/s is a planning expectation only, pending a real benchmark.
