param(
  [string]$Root = (Get-Location).Path
)

$drop = Join-Path $Root 'runtime\\dropzone\\outbox'
New-Item -ItemType Directory -Force -Path $drop | Out-Null

$patterns = @('*.log','*.jsonl','*.tmp','*.bak')
foreach($pat in $patterns){
  Get-ChildItem -Path $Root -File -Filter $pat -ErrorAction SilentlyContinue | ForEach-Object {
    Move-Item -LiteralPath $_.FullName -Destination (Join-Path $drop $_.Name) -Force
  }
}

Write-Output "Root guard sweep complete -> $drop"
