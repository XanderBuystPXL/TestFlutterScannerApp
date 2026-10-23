param(
    [Parameter(Mandatory = $true)][string]$Data,
    [string]$Out,
    [string]$PocRoot = '',
    [int]$Steps = 3000,
    [int]$Factor = 2,
    [switch]$CheckOnly,
    [switch]$AlignmentReviewed,
    [switch]$AllowCoverageWarnings
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PocRoot)) { $PocRoot = Join-Path $PSScriptRoot '../../Research/PoC-Android' }
$testRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$researchRoot = [IO.Path]::GetFullPath($PocRoot)
$runtimePython = Join-Path $researchRoot '.venv/Scripts/python.exe'
$sharedPackages = Join-Path (Split-Path $researchRoot -Parent) 'PoC/.venv/Lib/site-packages'
if (!(Test-Path -LiteralPath $runtimePython) -or !(Test-Path -LiteralPath $sharedPackages)) {
    throw 'The existing Windows CUDA research runtime was not found. Supply -PocRoot; no runtime is installed or modified by this helper.'
}
if (!$CheckOnly -and (!$Out -or !$AlignmentReviewed)) {
    throw 'Training needs -Out and -AlignmentReviewed after reviewing the dataset geometry and images.'
}
$environmentNames = @('PYTHONPATH', 'PYTHONDONTWRITEBYTECODE', 'TEMP', 'TMP', 'TORCH_EXTENSIONS_DIR', 'MPLCONFIGDIR', 'HF_HUB_OFFLINE', 'TRANSFORMERS_OFFLINE')
$originalEnvironment = @{}
foreach ($name in $environmentNames) { $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $cache = Join-Path $testRoot '.tools/tmp'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $env:PYTHONPATH = (@($sharedPackages, (Join-Path $researchRoot '.venv/Lib/site-packages'),
        (Join-Path $researchRoot '.tools/gsplat_cuda')) + @($env:PYTHONPATH)) -join ';'
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $env:TEMP = $cache; $env:TMP = $cache
    $env:TORCH_EXTENSIONS_DIR = Join-Path $cache 'torch'
    $env:MPLCONFIGDIR = Join-Path $cache 'mpl'
    $env:HF_HUB_OFFLINE = '1'; $env:TRANSFORMERS_OFFLINE = '1'
    $runner = Join-Path $PSScriptRoot 'run_poc.py'
    $arguments = @($Data, '--poc-root', $researchRoot, '--steps', "$Steps", '--factor', "$Factor")
    if ($CheckOnly) { $arguments += '--check-only' }
    if ($Out) { $arguments += @('--out', $Out) }
    if ($AlignmentReviewed) { $arguments += '--alignment-reviewed' }
    if ($AllowCoverageWarnings) { $arguments += '--allow-coverage-warnings' }
    # Resolve the relocated read-only runtime for this process. No .pth/venv/research edits.
    $bootstrap = @'
import sys, runpy
from pathlib import Path
sys.dont_write_bytecode = True
import torch, gsplat_cuda
sys.modules['gsplat.csrc'] = gsplat_cuda
sys.argv = sys.argv[1:]
sys.path.insert(0, str(Path(sys.argv[0]).resolve().parent))
runpy.run_path(sys.argv[0], run_name='__main__')
'@
    & $runtimePython -u -c $bootstrap $runner @arguments
    if ($LASTEXITCODE -ne 0) { throw "Reconstruction runner failed with exit code $LASTEXITCODE." }
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
    }
}
