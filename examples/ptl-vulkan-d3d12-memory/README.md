# Synthetic experiment checks (Windows)

Generated and run by GPT-6.1 Sol. No independent human review or designated maintainer. These scripts are a small synthetic test set, not a standard quality benchmark or a reliability certification. Failures must be retained in any report.

Start the patched server using the command in [EXPERIMENT.md](../../EXPERIMENT.md), changing the context/CPU/import settings to the profile being examined. Use the alias `Qwen3.5-35B-A3B`. The scripts send synthetic prompts to the local server and read Windows GPU/system counters. They do not install a driver, edit BIOS settings or download a model.

From this directory, create a local manifest matching the running server and a log directory:

```powershell
New-Item -ItemType Directory -Path logs -Force
@'
{"address":"http://127.0.0.1:8090","context":32768,"cpuMoeLayers":11,"vulkanD3D12MiB":7168,"cacheType":"f16"}
'@ | Set-Content server-state.json -Encoding utf8
./Test-Qwen.ps1 -Label local-short
./Test-LongContext.ps1 -TargetTokens 24000 -Label local-long -ContinueChat
./Test-MixedTasks.ps1 -Label local-mixed -Rounds 3
```

`Test-LongContext` uses tokenization to build an approximately sized prompt and checks three lookup anchors. `-ContinueChat` additionally checks a follow-up and measures up to 256 generated tokens; the latter's semantic quality is not scored. It stops the initial long request after three samples with less than 384MiB available RAM. It does not exercise every possible resource failure.

The mixed task set includes a Python list-comprehension case which failed in this experiment. The report must not turn 15/18 passes into a claim of comprehensive correctness. Serialized answers and failure counts are retained in local logs.

GPU adapter counters are used for dedicated memory because imported resources may be double-counted at process level. Background activity and power/thermal state can affect both performance and available RAM. Local `server-state.json` and raw logs may contain machine-specific information; inspect them before publishing.
