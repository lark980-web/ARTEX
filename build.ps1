# ARTEX Windows 本地构建脚本
#
# 做的事和 build.sh 一致：从 git 取版本号 -> 复用已导出的前端 -> go build（带 embedui 标签）。
#
# 为什么必须带 -tags embedui：
#   server/webui_embed.go 受 //go:build embedui 约束，它才把 server/webui/dist 里的
#   前端资源编译进二进制。不带这个标签会走 server/webui_stub.go 的桩实现，跑起来页面
#   只显示「前端未内嵌到此二进制（开发用 next dev；发布用 -tags embedui 构建）」，
#   而且产物比正式版小约 7 MB。别用裸 go build。
#
# 用法：
#   .\build.ps1                     构建 artex.exe（复用 server/webui/dist）
#   .\build.ps1 -RebuildFrontend    先 npm run build:static 再同步前端，然后构建
#   .\build.ps1 -OutputPath x.exe   指定输出路径
#   .\build.ps1 -Version v0.3.13    指定版本号（默认取 git describe）
#
# 关于前端：默认复用 server/webui/dist（已在仓库里）。只有改了前端源码才需要
# -RebuildFrontend，它需要 Node.js 和 npm。

[CmdletBinding()]
param(
    [string]$OutputPath = "artex.exe",
    [string]$Version = "",
    [switch]$RebuildFrontend
)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Write-Info($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "[!] $msg" -ForegroundColor Yellow }
function Die($msg)        { Write-Host "[x] $msg" -ForegroundColor Red; exit 1 }

# ---- 版本号：与 build.sh 保持一致（git describe，去掉 v 前缀）----
if (-not $Version) {
    $Version = "dev"
    if (Get-Command git -ErrorAction SilentlyContinue) {
        # E:\ 根目录属于其他仓库时会报 dubious ownership，这里显式放行本项目
        $projRoot = (Get-Location).Path
        $describe = & git -c "safe.directory=$projRoot" describe --tags --always --dirty 2>$null
        if ($LASTEXITCODE -eq 0 -and $describe) { $Version = $describe }
    }
}
$Version = $Version -replace "^v", ""

# ---- 前端资源 ----
if ($RebuildFrontend) {
    Write-Info "重建前端静态资源"
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { Die "未检测到 npm（重建前端需要 Node.js）" }
    Push-Location web
    try {
        & npm run build:static
        if ($LASTEXITCODE -ne 0) { Die "前端构建失败" }
    } finally { Pop-Location }

    Write-Info "同步前端资源到 server/webui/dist"
    $src = Join-Path "web" "out"
    if (-not (Test-Path $src)) { Die "未找到 web/out，前端构建可能未成功" }
    Remove-Item "server/webui/dist" -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path "server/webui/dist" -Force | Out-Null
    Copy-Item "$src\*" "server/webui/dist" -Recurse -Force
} else {
    if (-not (Test-Path "server/webui/dist")) {
        Die "server/webui/dist 不存在。请先加 -RebuildFrontend 构建前端（需要 Node.js），或从正式发布包中恢复该目录。"
    }
    Write-Info "复用 server/webui/dist（未重建前端）"
}

# ---- Go 环境检查 ----
if (-not (Get-Command go -ErrorAction SilentlyContinue)) { Die "未检测到 Go（项目需要 Go 1.26 或更高版本）" }
Write-Info ((& go version) -join "")

# go 需要 GOMODCACHE / GOCACHE 才能解析依赖与缓存编译产物。在某些精简环境
# （比如从服务/计划任务拉起、或没设过 GOPATH）里这两个变量是空的，go build 会直接
# 报 "module cache not found"。这里按 go 的默认位置兜底，不改变已有设置。
$homeDir = $env:USERPROFILE
if (-not $homeDir) { $homeDir = [Environment]::GetFolderPath("UserProfile") }
if (-not $homeDir) { $homeDir = $env:HOMEDRIVE + $env:HOMEPATH }

if (-not $env:GOPATH) {
    if (-not $homeDir) { Die "无法确定用户目录，请手动设置 GOPATH 环境变量后再运行" }
    $env:GOPATH = Join-Path $homeDir "go"
    Write-Info "未设置 GOPATH，使用默认：$env:GOPATH"
}
if (-not $env:GOCACHE) {
    $localApp = $env:LOCALAPPDATA
    if (-not $localApp -and $homeDir) { $localApp = Join-Path $homeDir "AppData\Local" }
    if ($localApp) {
        $env:GOCACHE = Join-Path $localApp "go-build"
        Write-Info "未设置 GOCACHE，使用默认：$env:GOCACHE"
    } else {
        Write-Warn2 "未设置 GOCACHE，交给 go 自行决定"
    }
}

# ---- 编译 ----
Write-Info "编译，版本 $Version（-tags embedui 已启用前端嵌入）"
$ldflags = "-s -w -buildid= -X main.version=$Version"

$env:CGO_ENABLED = "0"
& go build -tags embedui -trimpath -ldflags $ldflags -o $OutputPath ./cmd/artex

if ($LASTEXITCODE -ne 0) { Die "编译失败" }

# ---- 结果 ----
$out = Get-Item $OutputPath
$sizeMB = [math]::Round($out.Length / 1MB, 1)
Write-Ok "$($out.FullName)  $sizeMB MB"

# 内嵌校验：不带 -tags embedui 时走的是前端桩实现，产物里不会有 _next/static 这类
# 前端资源标记。用体积判断并不可靠（-ldflags "-s -w" 会去掉符号表，正式产物也会
# 掉到 37 MB 左右），所以直接扫产物内容。
$marker = [Text.Encoding]::ASCII.GetBytes("_next/static")
$bytes = [IO.File]::ReadAllBytes($out.FullName)
$found = $false
for ($i = 0; $i -le $bytes.Length - $marker.Length; $i++) {
    if ($bytes[$i] -eq $marker[0]) {
        $hit = $true
        for ($j = 1; $j -lt $marker.Length; $j++) {
            if ($bytes[$i + $j] -ne $marker[$j]) { $hit = $false; break }
        }
        if ($hit) { $found = $true; break }
    }
}
if ($found) {
    Write-Ok "已确认前端资源内嵌（检测到 _next/static）"
} else {
    Write-Warn2 "未在产物中找到前端资源标记，页面可能会显示「前端未内嵌」。请确认构建用了 -tags embedui。"
}
