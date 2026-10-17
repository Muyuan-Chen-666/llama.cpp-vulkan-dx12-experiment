param([int]$TargetTokens=12000,[string]$Label='long-context',[switch]$ContinueChat)
$ErrorActionPreference='Stop'
$state=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'server-state.json') -Raw | ConvertFrom-Json
$address=$state.address
function Build-Prompt([int]$Rows) {
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('请阅读合成资料，只输出一个JSON对象，字段begin、middle、end分别填写三条指定锚点的口令。不要解释，不要把普通条目的编号当作口令。')
    for($i=0;$i -lt $Rows;$i++) {
        if($i -eq [int]($Rows*0.05)){$lines.Add('指定锚点 BEGIN：口令 cedar-7284。')}
        if($i -eq [int]($Rows*0.5)){$lines.Add('指定锚点 MIDDLE：口令 maple-3591。')}
        if($i -eq [int]($Rows*0.95)){$lines.Add('指定锚点 END：口令 birch-6417。')}
        $lines.Add("普通条目 $i | 设备运行资料：本段用于观察长文档处理，普通条目不含测试口令，状态为待复核。")
    }
    $lines.Add('现在只返回这三条锚点口令的JSON对象。')
    return $lines -join "`n"
}
$rows=[math]::Max(3,[int]($TargetTokens/36))
for($attempt=0;$attempt -lt 4;$attempt++) {
    $prompt=Build-Prompt $rows
    $tokenBody=@{content=$prompt;add_special=$false} | ConvertTo-Json -Compress
    $tokenized=Invoke-RestMethod "$address/tokenize" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($tokenBody)) -TimeoutSec 60
    $count=$tokenized.tokens.Count
    if([math]::Abs($count-$TargetTokens) -lt 60){break}
    $rows=[math]::Max(3,[int]($rows*$TargetTokens/$count))
}
if($count+256 -gt $state.context){throw "Prompt $count is too close to configured context $($state.context)."}
Write-Output "Testing $count content tokens in $($state.context) context."
$body=@{model='Qwen3.5-35B-A3B';messages=@(@{role='user';content=$prompt});max_tokens=160;temperature=0;stream=$false;chat_template_kwargs=@{enable_thinking=$false}} | ConvertTo-Json -Depth 6 -Compress
$client=[Net.Http.HttpClient]::new()
$client.Timeout=[TimeSpan]::FromMinutes(20)
$content=[Net.Http.StringContent]::new($body,[Text.Encoding]::UTF8,'application/json')
$watch=[Diagnostics.Stopwatch]::StartNew()
$request=$client.PostAsync("$address/v1/chat/completions",$content)
$samples=[Collections.Generic.List[object]]::new()
$lowMemorySamples=0
try {
    while(-not $request.IsCompleted) {
        $adapter=Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory
        $mem=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
        $samples.Add([ordered]@{seconds=[math]::Round($watch.Elapsed.TotalSeconds,1);adapterDedicatedMiB=($adapter | Measure-Object DedicatedUsage -Sum).Sum/1MB;adapterSharedMiB=($adapter | Measure-Object SharedUsage -Sum).Sum/1MB;availableMiB=$mem.AvailableMBytes;pagesOut=$mem.PagesOutputPersec})
        if($mem.AvailableMBytes -lt 384){$lowMemorySamples++}else{$lowMemorySamples=0}
        if($lowMemorySamples -ge 3) {
            $client.CancelPendingRequests()
            [ordered]@{label=$Label;context=$state.context;contentTokens=$count;status='stopped-for-low-memory';samples=@($samples)} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $PSScriptRoot "logs\context-$Label.json") -Encoding utf8
            throw 'Stopped long-context test after three low-memory samples.'
        }
        Start-Sleep -Seconds 1
    }
    $response=$request.GetAwaiter().GetResult()
    $raw=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $result=$raw | ConvertFrom-Json
    $response.EnsureSuccessStatusCode() | Out-Null
    $answer=$result.choices[0].message.content
    $checks=@{begin=$false;middle=$false;end=$false;json=$false}
    try {
        $parsed=$answer | ConvertFrom-Json
        $checks.json=$true
        $checks.begin=$parsed.begin -eq 'cedar-7284'
        $checks.middle=$parsed.middle -eq 'maple-3591'
        $checks.end=$parsed.end -eq 'birch-6417'
    } catch {}
    $record=[ordered]@{label=$Label;context=$state.context;cpuMoeLayers=$state.cpuMoeLayers;importMiB=$state.vulkanD3D12MiB;contentTokens=$count;elapsedSeconds=[math]::Round($watch.Elapsed.TotalSeconds,2);answer=$answer;checks=$checks;timings=$result.timings;usage=$result.usage;minAvailableMiB=($samples | ForEach-Object {$_.availableMiB} | Measure-Object -Minimum).Minimum;peakAdapterDedicatedMiB=($samples | ForEach-Object {$_.adapterDedicatedMiB} | Measure-Object -Maximum).Maximum;peakAdapterSharedMiB=($samples | ForEach-Object {$_.adapterSharedMiB} | Measure-Object -Maximum).Maximum;maxPagesOutputPersec=($samples | ForEach-Object {$_.pagesOut} | Measure-Object -Maximum).Maximum;samples=@($samples)}
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $PSScriptRoot "logs\context-$Label.json") -Encoding utf8
    $record.Remove('samples')
    $record | ConvertTo-Json -Depth 6
    if(-not ($checks.json -and $checks.begin -and $checks.middle -and $checks.end)){throw 'Long-context retrieval check failed; output saved.'}
    if($ContinueChat) {
        $messages=@(@{role='user';content=$prompt},@{role='assistant';content=$answer},@{role='user';content='只输出JSON：begin填写刚才BEGIN口令，product填写97乘89，sorted填写数组[3,1,2,1]去重排序的结果。'})
        $nextBody=@{model='Qwen3.5-35B-A3B';messages=$messages;max_tokens=120;temperature=0;stream=$false;chat_template_kwargs=@{enable_thinking=$false}} | ConvertTo-Json -Depth 8 -Compress
        $followWatch=[Diagnostics.Stopwatch]::StartNew()
        $next=Invoke-RestMethod "$address/v1/chat/completions" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($nextBody)) -TimeoutSec 600
        $obj=$next.choices[0].message.content | ConvertFrom-Json
        $ok=$obj.begin -eq 'cedar-7284' -and $obj.product -eq 8633 -and ($obj.sorted -join ',') -eq '1,2,3'
        $record.followup=@{passed=$ok;answer=$next.choices[0].message.content;elapsedSeconds=$followWatch.Elapsed.TotalSeconds;timings=$next.timings;usage=$next.usage}
        $record | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $PSScriptRoot "logs\context-$Label.json") -Encoding utf8
        $record.followup | ConvertTo-Json -Depth 7
        if(-not $ok){throw 'Long conversation follow-up failed.'}
        $messages+=@{role='assistant';content=$next.choices[0].message.content}
        $messages+=@{role='user';content='请用中文写一篇至少450字的说明，解释刚才合成资料检索试验的目的、能证明的事情、无法证明的事情，以及如何进一步验证。分成四段，不要重复资料条目。'}
        $generationBody=@{model='Qwen3.5-35B-A3B';messages=$messages;max_tokens=256;temperature=0;stream=$false;chat_template_kwargs=@{enable_thinking=$false}} | ConvertTo-Json -Depth 8 -Compress
        $gen=Invoke-RestMethod "$address/v1/chat/completions" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($generationBody)) -TimeoutSec 600
        $record.longGeneration=@{answer=$gen.choices[0].message.content;finishReason=$gen.choices[0].finish_reason;timings=$gen.timings;usage=$gen.usage;semanticQualityScored=$false}
        $record | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $PSScriptRoot "logs\context-$Label.json") -Encoding utf8
        $record.longGeneration | ConvertTo-Json -Depth 6
    }
} finally {$content.Dispose();$client.Dispose()}
