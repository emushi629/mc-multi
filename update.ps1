# MC Multi 更新ツール
# 今入っている MC Multi を、変わったMODだけダウンロードして最新にする（設定・ミニマップのマークはそのまま）
# MCMulti-update.bat から呼ばれる。テスト用に -InstanceDir / -BaseUrl を指定できる
param(
    [string]$InstanceDir = "",
    [string]$BaseUrl = "https://emushi629.github.io/mc-multi/"
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$StateName = "mcmulti-update.json"

function Get-Bytes([string]$url) {
    if ($url -notmatch '^https?://') { return [IO.File]::ReadAllBytes($url) }
    $wc = New-Object Net.WebClient
    $wc.Headers.Add("User-Agent", "MCMulti-updater")
    try { return $wc.DownloadData($url) } finally { $wc.Dispose() }
}
function Get-Sha1([byte[]]$b) {
    $h = [Security.Cryptography.SHA1]::Create()
    return ([BitConverter]::ToString($h.ComputeHash($b)) -replace '-', '').ToLower()
}
function Get-FileSha1([string]$path) { return Get-Sha1 ([IO.File]::ReadAllBytes($path)) }
function Join-Url([string]$base, [string]$rel) {
    if ($rel -match '^https?://') { return $rel }
    if ($base -match '^https?://') { return $base.TrimEnd('/') + '/' + $rel }
    return Join-Path $base $rel
}
function Stop-WithMessage([string]$msg) {
    Write-Host ""
    Write-Host $msg -ForegroundColor Red
    exit 1
}

Write-Host "=== MC Multi 更新ツール ===" -ForegroundColor Green
Write-Host ""

# 1. 最新の一覧を取ってくる
try {
    $indexUrl = Join-Url $BaseUrl "pack-index.json"
    if ($indexUrl -match '^https?://') { $indexUrl += "?t=" + [DateTime]::Now.Ticks }   # 古いキャッシュを避ける
    $json = [Text.Encoding]::UTF8.GetString((Get-Bytes $indexUrl))
} catch {
    Stop-WithMessage "最新のMOD一覧を取れませんでした。ネットにつながっているか確かめてね。`n($($_.Exception.Message))"
}
$index = ($json.TrimStart([char]0xFEFF)) | ConvertFrom-Json
Write-Host "最新のパック: $($index.name)（MOD $($index.mods.Count)個）"

# 2. 更新する MC Multi を探す（mods に黄昏の森が入っているもの）
if ($InstanceDir -eq "") {
    $root = Join-Path $env:USERPROFILE "curseforge\minecraft\Instances"
    $found = @()
    if (Test-Path $root) {
        $found = @(Get-ChildItem $root -Directory | Where-Object {
            Test-Path (Join-Path $_.FullName "mods\twilightforest-*.jar")
        } | Sort-Object LastWriteTime -Descending)
    }
    if ($found.Count -eq 0) {
        Write-Host "MC Multi のフォルダが見つかりませんでした。"
        Write-Host "CurseForge で MC Multi を右クリック → フォルダを開く で出たフォルダの場所を貼り付けてね。"
        $InstanceDir = (Read-Host "フォルダの場所").Trim('"', ' ')
    } elseif ($found.Count -eq 1) {
        $InstanceDir = $found[0].FullName
    } else {
        Write-Host ""
        Write-Host "MC Multi が $($found.Count) 個あります。更新するものの番号を入れてね（いつも遊んでいる方）"
        for ($i = 0; $i -lt $found.Count; $i++) {
            Write-Host ("  {0}. {1}（最後に使った日: {2}）" -f ($i + 1), $found[$i].Name, $found[$i].LastWriteTime.ToString("M/d HH:mm"))
        }
        $n = [int](Read-Host "番号")
        if ($n -lt 1 -or $n -gt $found.Count) { Stop-WithMessage "番号がちがいます。もう一度やり直してね。" }
        $InstanceDir = $found[$n - 1].FullName
    }
}
$mods = Join-Path $InstanceDir "mods"
if (-not (Test-Path $mods)) { Stop-WithMessage "mods フォルダがありません: $InstanceDir" }
Write-Host "更新するフォルダ: $InstanceDir"

# 3. ゲームが起動中なら止める（MODファイルを入れ替えられないため）
$running = @(Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($InstanceDir) })
if ($running.Count -gt 0) { Stop-WithMessage "Minecraft が起動中です。ゲームを閉じてからもう一度実行してね。" }

# 4. パックのMODとして入っているファイルの名前（外されたMOD・古い版を片付けるのに使う）
#    自分で足したMODは片付けないよう、パックのMOD（今のもの＋外したもの）の projectID に当たるものだけ数える
$packIds = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($m in $index.mods) { [void]$packIds.Add([int]$m.projectID) }
foreach ($id in @($index.retiredProjectIDs)) { if ($id) { [void]$packIds.Add([int]$id) } }
$managed = New-Object 'System.Collections.Generic.HashSet[string]'
$cfJson = Join-Path $InstanceDir "minecraftinstance.json"
if (Test-Path $cfJson) {
    try {
        $cf = [IO.File]::ReadAllText($cfJson, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($a in $cf.installedAddons) {
            if ($a.fileNameOnDisk -and $packIds.Contains([int]$a.addonID)) { [void]$managed.Add($a.fileNameOnDisk) }
        }
    } catch { }
}
$statePath = Join-Path $InstanceDir $StateName
if (Test-Path $statePath) {
    $state = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($f in $state.mods) { [void]$managed.Add($f) }
}

# 5. 足りないMOD・変わったMODだけダウンロード
$want = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($m in $index.mods) { [void]$want.Add($m.fileName) }
$todo = @($index.mods | Where-Object {
    $p = Join-Path $mods $_.fileName
    -not (Test-Path -LiteralPath $p) -or (Get-FileSha1 $p) -ne $_.sha1
})
$total = ($todo | Measure-Object -Property size -Sum).Sum
Write-Host ""
if ($todo.Count -eq 0) {
    Write-Host "MODはぜんぶ最新です。"
} else {
    Write-Host ("ダウンロードするMOD: {0}個（{1:N1}MB）" -f $todo.Count, ($total / 1MB))
    $k = 0
    foreach ($m in $todo) {
        $k++
        Write-Host ("  [{0}/{1}] {2}" -f $k, $todo.Count, $m.name)
        try { $b = Get-Bytes $m.url } catch { Stop-WithMessage "$($m.name) のダウンロードに失敗しました。少し待ってからもう一度やってね。" }
        if ((Get-Sha1 $b) -ne $m.sha1) { Stop-WithMessage "$($m.name) のファイルが壊れていました。もう一度やってね。" }
        $tmp = Join-Path $mods ($m.fileName + ".download")
        [IO.File]::WriteAllBytes($tmp, $b)
        Move-Item -LiteralPath $tmp -Destination (Join-Path $mods $m.fileName) -Force
    }
}

# 6. パックから外れたMODを片付ける（消さずに mods_old フォルダへ移す）
$old = @(Get-ChildItem -LiteralPath $mods -Filter *.jar | Where-Object { $managed.Contains($_.Name) -and -not $want.Contains($_.Name) })
if ($old.Count -gt 0) {
    $bak = Join-Path $InstanceDir "mods_old"
    New-Item -ItemType Directory -Force -Path $bak | Out-Null
    Write-Host ""
    Write-Host "使わなくなったMOD（mods_old フォルダへ移動）:"
    foreach ($f in $old) {
        Write-Host "  - $($f.Name)"
        Move-Item -LiteralPath $f.FullName -Destination (Join-Path $bak $f.Name) -Force
    }
}

# 7. 日本語化パックなどの追加ファイル
foreach ($o in $index.overrides) {
    $p = Join-Path $InstanceDir $o.path
    if ((Test-Path -LiteralPath $p) -and (Get-FileSha1 $p) -eq $o.sha1) { continue }
    $u = Join-Url $BaseUrl $o.url
    if ($u -match '^https?://') { $u += "?t=" + [DateTime]::Now.Ticks }   # 更新直後の古いキャッシュを避ける
    $b = Get-Bytes $u
    if ((Get-Sha1 $b) -ne $o.sha1) { Stop-WithMessage "$($o.path) のファイルが壊れていました。もう一度やってね。" }
    New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
    [IO.File]::WriteAllBytes($p, $b)
    Write-Host "更新: $($o.path)"
}

# 8. 次回のために、入れたMODの一覧を残す
$newState = @{ version = $index.version; updated = (Get-Date).ToString("s"); mods = @($index.mods | ForEach-Object { $_.fileName }) }
[IO.File]::WriteAllText($statePath, ($newState | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))

Write-Host ""
Write-Host "完了！ $($index.name) になりました。いつも通り CurseForge から Play してね。" -ForegroundColor Green
Write-Host "（CurseForge の画面のMOD一覧は古いまま表示されるけど、ゲームには関係ないよ）"
