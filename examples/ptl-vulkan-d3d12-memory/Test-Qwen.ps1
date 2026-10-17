param([string]$Label = 'current', [int]$Port = 8090)
$ErrorActionPreference = 'Stop'
$address = "http://127.0.0.1:$Port"
$cases = @(
    @{ name='arithmetic'; prompt='只输出计算结果，不要解释：17乘以23等于多少？'; max_tokens=24 },
    @{ name='chinese'; prompt='请用中文解释什么是混合专家模型（MoE），它为什么每次只激活部分参数却仍需要存放完整模型权重？控制在180字以内。'; max_tokens=240 },
    @{ name='structured'; prompt='只输出一个合法JSON对象，不要使用Markdown。字段city为上海，字段sum为123加456的结果，字段items为包含苹果和香蕉的数组。'; max_tokens=100 }
)
$results = @()
foreach ($case in $cases) {
    $body = @{ model='Qwen3.5-35B-A3B'; messages=@(@{role='user';content=$case.prompt}); max_tokens=$case.max_tokens; temperature=0; stream=$false; chat_template_kwargs=@{enable_thinking=$false} } | ConvertTo-Json -Depth 6 -Compress
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod "$address/v1/chat/completions" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 240
    $record = [ordered]@{ name=$case.name; elapsedSeconds=[math]::Round($watch.Elapsed.TotalSeconds,2); content=$response.choices[0].message.content; reasoning=$response.choices[0].message.reasoning_content; finishReason=$response.choices[0].finish_reason; usage=$response.usage; timings=$response.timings }
    $results += $record
    $record | ConvertTo-Json -Depth 6
}
$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $logDir "test-$Label.json") -Encoding utf8
if ($results[0].content.Trim() -ne '391') { throw 'Arithmetic sanity check failed.' }
try { $structured = $results[2].content | ConvertFrom-Json } catch { throw 'JSON check failed.' }
if ($structured.city -ne '上海' -or $structured.sum -ne 579 -or $structured.items.Count -ne 2) { throw 'Structured output check failed.' }
Write-Output 'Arithmetic and structured-output sanity checks passed.'
