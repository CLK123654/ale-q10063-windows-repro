[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$RepositoryRoot,
  [Parameter(Mandatory = $true)]
  [string]$EvidenceRoot
)

$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$ArtifactsRoot = Join-Path $RepositoryRoot 'artifacts'
$Manifest = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'manifest.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null

[ordered]@{
  result = 'STARTED'
  runner = $env:RUNNER_OS
  runner_image = 'windows-2025'
  commit_sha = $env:GITHUB_SHA
  workflow_run_id = $env:GITHUB_RUN_ID
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'preflight.json') -Encoding utf8NoBOM

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-Sha256 {
  param([string]$PathValue)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $PathValue).Hash.ToLowerInvariant()
}

function Assert-SequenceEqual {
  param([object[]]$Actual, [object[]]$Expected, [string]$Label)
  $actualValues = @($Actual | ForEach-Object { [string]$_ } | Sort-Object)
  $expectedValues = @($Expected | ForEach-Object { [string]$_ } | Sort-Object)
  Assert-True ($actualValues.Count -eq $expectedValues.Count) "$Label count mismatch"
  for ($index = 0; $index -lt $expectedValues.Count; $index += 1) {
    Assert-True ($actualValues[$index] -ceq $expectedValues[$index]) "$Label mismatch at index $index"
  }
}

function Get-ZipEntries {
  param([string]$ArchivePath)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    return @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
  } finally {
    $archive.Dispose()
  }
}

function Assert-ZipSafeForWindows {
  param([string]$ArchivePath)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $bannedExtensions = @('.sh', '.bash', '.zsh', '.so', '.elf', '.deb', '.rpm', '.appimage')
  $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    foreach ($entry in $archive.Entries) {
      $normalized = $entry.FullName.Replace('\', '/')
      Assert-True (-not $normalized.StartsWith('/')) "absolute archive path found: $normalized"
      Assert-True (-not $normalized.Split('/').Contains('..')) "archive traversal found: $normalized"
      if ([string]::IsNullOrEmpty($entry.Name)) { continue }
      $extension = [System.IO.Path]::GetExtension($entry.Name).ToLowerInvariant()
      Assert-True (-not $bannedExtensions.Contains($extension)) "Linux artifact found in $normalized"
      $stream = $entry.Open()
      try {
        if ($entry.Length -ge 4) {
          $bytes = [byte[]]::new(4)
          [void]$stream.Read($bytes, 0, 4)
          $isElf = $bytes[0] -eq 0x7f -and $bytes[1] -eq 0x45 -and $bytes[2] -eq 0x4c -and $bytes[3] -eq 0x46
          Assert-True (-not $isElf) "ELF binary found in $normalized"
        }
      } finally {
        $stream.Dispose()
      }
    }
  } finally {
    $archive.Dispose()
  }
}

function Get-WorkbookSheetNames {
  param([string]$WorkbookPath)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($WorkbookPath)
  try {
    $entry = $archive.GetEntry('xl/workbook.xml')
    Assert-True ($null -ne $entry) 'workbook.xml missing'
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try { [xml]$xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
    return @($xml.SelectNodes("//*[local-name()='sheet']") | ForEach-Object { $_.GetAttribute('name') })
  } finally {
    $archive.Dispose()
  }
}

function Assert-SpecificationShape {
  param([string]$WorkbookPath)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($WorkbookPath)
  try {
    $entry = $archive.GetEntry('xl/worksheets/sheet1.xml')
    Assert-True ($null -ne $entry) 'specification worksheet missing'
    $reader = [System.IO.StreamReader]::new($entry.Open())
    try { [xml]$xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
    foreach ($cell in $xml.SelectNodes("//*[local-name()='c']")) {
      $reference = $cell.GetAttribute('r')
      Assert-True ($reference -match '^[AB]\d+$') "specification contains data outside two columns: $reference"
    }
  } finally {
    $archive.Dispose()
  }
}

function Assert-NaturalText {
  param([string[]]$Texts, [string]$Label)
  $quoteCharacters = @(
    [char]34, [char]39, [char]96, '“', '”', '‘', '’', '＂', '＇',
    '「', '」', '『', '』', '«', '»', '‹', '›', '〝', '〞', '〟', '《', '》', '〈', '〉'
  )
  $space = '[\t \u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+'
  $han = '[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]'
  $boundary = "(?:$han$space[A-Za-z0-9]|[A-Za-z0-9]$space$han|[A-Za-z]$space[0-9]|[0-9]$space[A-Za-z])"
  $riskTerms = @('此外', '至关重要', '深入探讨', '彰显', '赋能', '无缝', '不断演变的格局', '不仅', '不只是', '值得注意的是', '专家认为', '行业报告显示', '观察者指出', '未来展望', '挑战与未来', '——')
  $processTerms = @('制题返修', '去AI', '修改题目', '规则调整', 'Windows复现', 'Windows验证', 'GitHub Actions', 'CI门禁', '双干净目录', '动态变化', '负例', '附件哈希', '飞书回读', 'Reference控制', 'validation自证', '控制量', '不变量', '连续执行', '重复执行', '连续运行', '重复运行', '复跑')
  foreach ($text in $Texts) {
    foreach ($character in $quoteCharacters) {
      Assert-True (-not $text.Contains([string]$character)) "$Label contains a forbidden quote"
    }
    Assert-True (-not [regex]::IsMatch($text, $boundary)) "$Label contains a mixed boundary space"
    foreach ($term in ($riskTerms + $processTerms)) {
      Assert-True (-not $text.Contains($term)) "$Label contains forbidden term $term"
    }
  }
}

function Assert-NoPublicMetadata {
  $sensitiveTerms = @(
    ('record' + '_id'), ('file' + '_token'), ('app' + '_token'), ('table' + '_id'),
    ('tmp' + '_url'), ('open.feishu.cn/' + 'open-apis/drive')
  )
  $textExtensions = @('.txt', '.md', '.json', '.mjs', '.js', '.ps1', '.yml', '.yaml', '.csv', '.html', '.sql')
  foreach ($file in Get-ChildItem -LiteralPath $RepositoryRoot -File -Recurse) {
    if ($file.FullName.Contains("$([System.IO.Path]::DirectorySeparatorChar).git$([System.IO.Path]::DirectorySeparatorChar)")) { continue }
    if (-not $textExtensions.Contains($file.Extension.ToLowerInvariant())) { continue }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($term in $sensitiveTerms) {
      Assert-True (-not $text.Contains($term)) "public metadata found in $($file.Name)"
    }
  }
}

$artifactHashes = [ordered]@{}
foreach ($property in $Manifest.attachments.PSObject.Properties) {
  $filePath = Join-Path $ArtifactsRoot $property.Name
  Assert-True (Test-Path -LiteralPath $filePath -PathType Leaf) "missing artifact $($property.Name)"
  $actualHash = Get-Sha256 $filePath
  Assert-True ($actualHash -ceq [string]$property.Value) "artifact hash mismatch for $($property.Name)"
  $artifactHashes[$property.Name] = $actualHash
}

$inputArchive = Join-Path $ArtifactsRoot '输入数据包.zip'
$referenceArchive = Join-Path $ArtifactsRoot 'reference.zip'
Assert-SequenceEqual (Get-ZipEntries $inputArchive) @($Manifest.input_members) 'input archive members'
Assert-SequenceEqual (Get-ZipEntries $referenceArchive) @($Manifest.reference_members) 'reference archive members'
Assert-ZipSafeForWindows $inputArchive
Assert-ZipSafeForWindows $referenceArchive
Assert-SequenceEqual (Get-WorkbookSheetNames (Join-Path $ArtifactsRoot '关键标准答案.xlsx')) @($Manifest.answer_sheets) 'answer workbook sheets'
Assert-SequenceEqual (Get-WorkbookSheetNames (Join-Path $ArtifactsRoot '任务规格转化.xlsx')) @($Manifest.specification_sheets) 'specification workbook sheets'
Assert-SpecificationShape (Join-Path $ArtifactsRoot '任务规格转化.xlsx')

$taskTexts = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'task') -File -Filter '*.txt' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw })
Assert-NaturalText $taskTexts 'task text'
$staticReview = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'qa/static_gate.json') -Raw | ConvertFrom-Json
Assert-True ($staticReview.result -ceq 'PASS') 'local static review failed'
Assert-True (@($staticReview.violations).Count -eq 0) 'natural text violations found'
Assert-True (@($staticReview.archive_and_member_name_violations).Count -eq 0) 'answer control terms found in workbook or member names'
Assert-NoPublicMetadata

$nodeScript = Join-Path $RepositoryRoot 'scripts/windows_reproduce.mjs'
& node $nodeScript --repository-root $RepositoryRoot --evidence-root $EvidenceRoot
$nodeExit = $LASTEXITCODE
Assert-True ($nodeExit -eq 0) "Windows reproduction failed with exit code $nodeExit"

[ordered]@{
  result = 'PASS'
  runner_image = 'windows-2025'
  runner_os = $env:RUNNER_OS
  commit_sha = $env:GITHUB_SHA
  workflow_run_id = $env:GITHUB_RUN_ID
  repository = $env:GITHUB_REPOSITORY
  artifact_hashes = $artifactHashes
  input_members = @($Manifest.input_members)
  reference_members = @($Manifest.reference_members)
  linux_artifact_scan = 'PASS'
  natural_text_gate = 'PASS'
  answer_sheets = @($Manifest.answer_sheets)
  specification_sheets = @($Manifest.specification_sheets)
  specification_columns = 2
} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'windows-audit.json') -Encoding utf8NoBOM

Write-Host 'Windows SQLite gate: PASS'
