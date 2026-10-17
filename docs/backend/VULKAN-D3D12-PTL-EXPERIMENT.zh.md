# Intel Xe3 上 Vulkan 计算与 D3D12 专用显存分配：初步实验报告

日期：2026-10-18。状态：实验性、未经独立人工代码审查，结果尚不全面。

## 作者与人工参与声明

本报告、补丁实现、构建和自动化测试由 **GPT-6.1 Sol（OpenAI Codex）** 完成，按用户要求明确标注 AI 贡献。用户没有编写代码、设计实现、逐行审查或操作编译测试；用户提出需求、提供硬件约束，并反馈短文本生成确实超过 20 token/秒。

用户明确表示自己不了解实现，也不承诺维护。本实验没有指定具备审查能力的人类维护者，不能把用户列为补丁开发者、审查者或技术支持人员。AI 署名也不代表存在能够承担长期维护的主体。本材料用于让其他开发者独立复核，不应当当作上游已审查或可直接合入的改动。

## 问题与初步结论

在一台 32GB Intel Panther Lake 设备上，BIOS 预留 8GB 作为专用显存；普通 Vulkan 路径的模型分配被 Windows 计入共享显存。D3D12 DEFAULT 资源可使用预留显存。因此尝试先创建可共享的 D3D12 缓冲资源，再用 Vulkan Win32 外部内存机制导入，同一 Vulkan 后端完成权重上传与推理。

本机已经观察到约 6GB 实际专用显存使用，含约 4.52GiB 专家张量；短文本生成约 23.6 token/秒。用户另行反馈达到了 20 token/秒以上。**这是可行性和短时功能验证，不是完整的正确性、性能、模型质量或可靠性认证。** 仅使用同一物理 LPDDR 内存的不同分配路径，不会增加物理带宽或凭空增加 RAM。

## 环境与可复现基线

| 项目 | 值 |
| --- | --- |
| CPU / GPU | Core Ultra X7 358H / Intel Arc B390（Xe3） |
| 物理 RAM | 32GB；BIOS 预留 8GB，Windows 可用约 23.5GiB |
| 图形驱动 | 32.0.101.9033 |
| Vulkan 可见内存堆 | 13728MiB；19.3GB 可选共享上限没有调整 |
| 上游基线 | llama.cpp b11714，c0fd78626405c6d9b934efef0ec7291fcc20e3d6 |
| 模型 | Qwen3.5-35B-A3B-UD-IQ4_XS.gguf，17486174848 字节 |
| 模型 SHA256 | 745def087c9ec34d12a94eb9b31eb52dba958b36def510b7e8f6f2e6bf1be123 |
| 初始补丁版服务 SHA256 | 896805016de2ed419b502c5f4b05ad9f14c2f6723f9343b1aac3c7372f09c75b |

模型包含 40 个 MoE 层，每层 256 个专家，每次选择 8 个。文件名 IQ4_XS 不能代表所有张量类型：down 专家使用 IQ4_XS，gate/up 专家使用 IQ3_S。因此同时测试了两类专家计算。

## 分配流程

1. 只在设置 `GGML_VK_D3D12_MEMORY_MIB` 后启用实验路径；设备扩展存在时开启 `VK_KHR_external_memory_win32`。
2. 根据 Vulkan 设备 LUID 在 DXGI 中匹配同一物理适配器，创建 D3D12 设备。
3. 在额度内，创建带 `D3D12_HEAP_FLAG_SHARED` 的 DEFAULT committed buffer，允许 UAV 使用；通过 `CreateSharedHandle` 获得 NT handle。
4. Vulkan buffer 声明 `D3D12_RESOURCE` 外部句柄类型；查询内存兼容位，使用 `VkImportMemoryWin32HandleInfoKHR` 与 dedicated-allocation 信息导入并绑定。
5. Vulkan 负责实际上传、复制和着色器计算。D3D12 不对该资源提交计算或图形命令。导入资源不暴露 CPU 映射地址，避免被 UMA 直接访问路径误用。
6. 保留 D3D12 COM 资源至 Vulkan 缓冲区释放；导入后关闭 NT handle；销毁时释放 Vulkan buffer、Vulkan memory 以及 D3D12 资源。失败时尝试普通 Vulkan 分配。

`GGML_VK_FORCE_MAX_BUFFER_SIZE=1073741824` 让权重分为较小缓冲区，便于在专用和共享分配路径间按额度选择。`--no-host` 避免 CPU 专家使用 GPU host buffer；`--load-mode none` 避免保留整份文件映射。这些选项与显存补丁共同构成当前配置，不能把所有速度变化都归因于专用显存。

该补丁没有实现按 token 预测专家或动态专家 LRU 缓存。它把部分完整专家张量固定分配到专用显存，其余专家仍按层放在 CPU 或 GPU 共享内存。

## 初始 4K 配置与观测

复现命令，路径须替换为本机模型和补丁引擎：

```powershell
$env:GGML_VK_D3D12_MEMORY_MIB='6144'
$env:GGML_VK_FORCE_MAX_BUFFER_SIZE='1073741824'
./llama-server.exe -m MODEL.gguf --alias Qwen3.5-35B-A3B --host 127.0.0.1 --port 8090 `
  -c 4096 -np 1 -b 512 -ub 128 -t 8 -tb 16 -ngl 99 --fit off `
  --n-cpu-moe 10 --device Vulkan0 --load-mode none --no-host `
  -fa on --cache-ram 256 --ctx-checkpoints 2 --reasoning off --jinja `
  --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 --presence-penalty 1.5
```

| 观测 | 初步结果 |
| --- | --- |
| 连续中文短文本生成 | 177 token，23.61 token/秒 |
| 适配器专用显存峰值 | 6088MiB |
| 模型进程共享显存峰值 | 7063MiB |
| 同次采样最低可用 RAM | 5248MiB；该次 PagesOutputPersec 为 0 |
| 专家驻留日志 | 39 个专家张量，4628MiB，层 10–22 |
| 专家放置 | 10 层 CPU，13 层专用 GPU，17 层共享 GPU |
| 停止服务后 | 适配器专用显存回落至约 41MiB |

同类短测试中，普通 Vulkan 调整 CPU 放置后也可约 23.08 token/秒，但后续可用内存曾低至约 369MiB。因此不能宣称显存补丁本身带来数倍算力加速；主要已观察收益是使用预留内存并改善部分配置的系统余量。

## 已做检查与覆盖边界

- IQ3/IQ4 `MUL_MAT_ID` 与 CPU 数值对照 23/23 通过；这不是所有 Vulkan 运算或所有真实形状的证明。
- 算术 391、JSON 的指定字段和值通过；中文输出可读。没有对中文说明的所有事实逐句评分，模型可产生内容错误。
- 1167 token 合成资料检索和切换后的口令恢复通过。这是检索功能检查，不是长文档理解评测。
- 从安装目录重新启动后基础检查通过。
- 用户反馈已实际观察到 20 token/秒以上；没有将这一反馈扩展为完整验证。
- 后续测试已在 16K 配置实际输入 12027 prompt token，三处锚点检索通过，提示处理 167.83 token/秒、末尾生成 22.16 token/秒。但最低可用 RAM 924MiB，发生页面写出，不能直接视作理想日常配置。
- 更长上下文、更多 GPU 层与 27B 的评估将在本报告实验附录更新，估算和实测分别标识。

## 未解决问题与独立复核要求

1. 本驱动把导入的 D3D12 资源也计入 Vulkan 可见额度；8GB 预留与 13.4GiB Vulkan heap 不能直接相加成可任意分配的 Vulkan 空间。全 GPU 尝试仍有分配失败。
2. 进程 GPU 专用计数可能对导入别名重复统计，出现约 12GB；应查看适配器整体计数，不可声称使用超过 8GB 物理预留。
3. 还需要 Vulkan 验证层检查、导入能力/usage 查询、错误注入、并发分配、边界额度、设备丢失与恢复、驱动版本及其他设备验证。当前运行测试没有覆盖这些。
4. 还需要审核跨 API 初始所有权、buffer-device-address 兼容条件、资源描述与 Vulkan 要求的一致性；不能仅因当前驱动正常运行就断言所有实现都有效。
5. Win32 类型和 DirectX 依赖仅在 Windows 路径启用；尚未构建验证其他平台，也没有完整 CI。
6. 没有完成困惑度/KL 比较、与未修改引擎的固定输入数值一致性、标准任务集合、数小时压力测试、睡眠唤醒、电源切换或游戏并发验证。
7. 没有证明该路径锁定物理驻留或阻止 WDDM 迁移、驱逐。"驻留"指本机运行中的分配和计数器观测。
8. 资源上限、缓存和可用 RAM 随后台程序变化；本报告中的约 5GB 余量不能作为任意上下文的保证。

## 补丁和来源

`vulkan-d3d12-memory.patch` 含四个 Vulkan 文件的最小修改；不是 LLAMA-DX 计算后端，也不是 Vulkan 转 D3D12 的 Mesa Dozen。此前社区混合版本出现乱码，已排除为日常引擎。

- [官方 b11714 基线](https://github.com/ggml-org/llama.cpp/tree/b11714)
- [Khronos 外部内存说明](https://docs.vulkan.org/guide/latest/extensions/external.html)
- [Vulkan 内存导入规则](https://docs.vulkan.org/spec/latest/chapters/memory.html)
- [Intel 共享显存设置说明](https://www.intel.com/content/www/us/en/support/articles/000101789/graphics.html)
- [上游贡献规则](https://github.com/ggml-org/llama.cpp/blob/master/CONTRIBUTING.md)

这是未指定维护者的独立实验材料；如其他开发者希望用于上游投稿，应自行理解、审核、补足测试并遵循上游规则，不能把本次用户声明成负责维护和逐行审查的贡献者。


## 本轮扩大验证与日常配置

| 配置 | 实际 prompt token | 提示处理 token/秒 | 生成 token/秒 | 初始长请求最低可用 RAM MiB |
| --- | ---: | ---: | ---: | ---: |
| 16K，CPU10，6GB额度，f16 KV，微批128 | 12027 | 167.83 | 22.16 | 924 |
| 32K，CPU11，7GB额度，f16 KV，微批128 | 24027 | 137.52 | 20.66 | 2231 |
| 32K，CPU9，7GB额度，q8 KV，微批64 | 24027 | 92.59 | 17.64 | 2594 |
| 32K，CPU11，7GB额度，f16 KV，微批128 | 30011 | 121.99 | 19.31 | 902 |

以上三处锚点均检索正确，但均不能替代广泛语义质量测试，长请求期间均观察到系统页面写出。30K 首轮预填充约246秒；后续追问复用30007个缓存token，约3.88秒返回，口令、乘法、排序检查通过。随后连续生成256token约19.21token/秒，因长度上限截断，没有对说明全文评分。内存采样覆盖最初长请求，没有对之后每次追问持续采样。

本轮选择32K、11层CPU专家、f16 KV、7GB导入额度作为日常候选；关闭跨会话提示缓存、保留1个检查点。当前会话仍能复用前缀。日志确认46个专家张量、5476MiB位于导入缓冲区；边界层可能被缓冲区分界拆开，不能说成16个完整专家层。

增加GPU层的q8 KV配置在长上下文反而更慢，因此没有采用。32K能够运行，但接近满上下文时系统余量会不足1GB，初次处理大文档要数分钟；这不是任意后台负载下的稳定性保证。保留原4K配置作为较小上下文回退入口。

新增18次混合任务检查通过15次、失败3次。失败均为同一个Python表达式 `[i*i for i in range(5) if i%2==0]`，返回 `[0,4]`，而正确结果是 `[0,4,16]`。presence penalty=1.5、0、0.5的对照均未纠正。另以未经修改的官方b11714 Vulkan、4K、CPU专家11层单独检查，也得到同一错误。因此此失败并非仅在显存补丁下出现；单例对照仍不能证明整体数值完全等价。

发布材料保留失败结果、未覆盖项和无人工审查声明。27B的22种GGUF容量判断见单独的QWEN27B-ESTIMATE.md；27B尚未下载运行，估算没有混写为实测。常规使用入口已保存32K候选配置，旧4K配置另行保留。
