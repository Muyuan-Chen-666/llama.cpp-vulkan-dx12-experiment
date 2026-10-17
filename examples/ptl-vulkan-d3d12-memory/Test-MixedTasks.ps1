param([string]$Label='mixed',[int]$Rounds=3)
$ErrorActionPreference='Stop'
$state=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'server-state.json') -Raw | ConvertFrom-Json
$cases=@(
    @{name='arithmetic';prompt='只输出JSON对象：product为97乘89，difference为1000减387。';check={param($v) $v.product -eq 8633 -and $v.difference -eq 613}},
    @{name='sort-and-count';prompt='只输出JSON对象：把[3,1,2,1]去重升序排列放在values字段，原始数组长度放在length字段。';check={param($v) ($v.values -join ',') -eq '1,2,3' -and $v.length -eq 4}},
    @{name='python-trace';prompt='Python表达式 [i*i for i in range(5) if i%2==0] 的结果是什么？只输出JSON对象，结果数组放在result字段。';check={param($v) ($v.result -join ',') -eq '0,4,16'}},
    @{name='english-extraction';prompt='Extract from: "Ada is 37 years old and lives in York." Return only a JSON object with name, age (integer), and city.';check={param($v) $v.name -eq 'Ada' -and $v.age -eq 37 -and $v.city -eq 'York'}},
    @{name='unicode-json';prompt='只输出合法JSON对象：city为上海，items为苹果和香蕉组成的数组，enabled为布尔值true。';check={param($v) $v.city -eq '上海' -and ($v.items -join ',') -eq '苹果,香蕉' -and $v.enabled -is [bool] -and $v.enabled -eq $true}},
    @{name='letter-count';prompt='字符串abca中各字母出现几次？只输出JSON对象，a、b、c为字段，值为出现次数。';check={param($v) $v.a -eq 2 -and $v.b -eq 1 -and $v.c -eq 1}}
)
$records=[Collections.Generic.List[object]]::new()
for($round=1;$round -le $Rounds;$round++) {
    foreach($case in $cases) {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $answer=$null
        $r=$null
        try {
            $body=@{model='Qwen3.5-35B-A3B';messages=@(@{role='user';content="第 $round 轮功能检查。$($case.prompt)"});max_tokens=96;temperature=0;stream=$false;chat_template_kwargs=@{enable_thinking=$false}} | ConvertTo-Json -Depth 6 -Compress
            $r=Invoke-RestMethod "$($state.address)/v1/chat/completions" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
            $answer=$r.choices[0].message.content
            $v=$answer | ConvertFrom-Json
            $ok=[bool](& $case.check $v)
            $errorText=$null
        }catch{$ok=$false;$errorText=$_.Exception.Message}
        $mem=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
        $records.Add([ordered]@{round=$round;case=$case.name;passed=$ok;elapsedSeconds=$watch.Elapsed.TotalSeconds;answer=$answer;error=$errorText;timings=$r.timings;availableMiB=$mem.AvailableMBytes})
        Write-Output "$round / $($case.name): $ok"
    }
}
$passed=@($records | Where-Object {$_.passed}).Count
$summary=[ordered]@{label=$Label;count=$records.Count;passed=$passed;failed=$records.Count-$passed;context=$state.context;cacheType=$state.cacheType;cpuMoeLayers=$state.cpuMoeLayers;cases=@($records);coverage='Small synthetic task set; not a standard quality benchmark or endurance test.'}
$summary | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $PSScriptRoot "logs\mixed-$Label.json") -Encoding utf8
Write-Output "$passed / $($records.Count) passed."
if($passed -ne $records.Count){throw 'Some mixed task checks failed; see saved results.'}
