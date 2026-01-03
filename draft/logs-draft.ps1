# backup-system v.13 - split-backup-7zip-3d-only.ps1
# Изменения:
# • 3D Objects → исключительно 7-Zip (store mode, многопоточно)
# • Основные папки → встроенный ZIP (без изменений)
# • Убрана папка Downloads
# • Убрана двойная проверка хешей → только один проход
# • Потоки хеширования = все доступные ядра процессора
# • Компактный вывод сохранён

# ---------------- CONFIG ----------------
$UserPath        = $env:USERPROFILE
$HashAlgorithm   = "SHA512"           # или SHA256, если хотите быстрее

# Основные папки (Downloads убрана)
$MainFolders     = @(
    "$UserPath\Videos",
    "$UserPath\Documents",
    "$UserPath\Music",
    "$UserPath\Pictures",
    "$UserPath\Desktop"
)

# Отдельная папка для 3D Objects — будет архивироваться через 7-Zip
$ThreeDFolders   = @("$UserPath\3D Objects")

$DestinationRoot = "G:\Backups"
$DateTimeFormat  = "dd-MM-yyyy-HH_mm"
$FileExtension   = "zip"

# Максимальное количество потоков = все ядра процессора
$MaxThreads      = [Environment]::ProcessorCount

$ZipCompressionLevel = [System.IO.Compression.CompressionLevel]::NoCompression
$BufferSize      = 16MB
$CheckpointFile  = "$env:TEMP\backup-checkpoint.json"

# Путь к 7-Zip (обязательно должен существовать для 3D Objects)
$SevenZipPath    = "C:\Program Files\7-Zip\7z.exe"

$CompactMode     = $true

# ----------------------------------------

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------------- ФУНКЦИИ ----------------

function Write-Status {
    param(
        [string]$MessageRu,
        [string]$MessageEn,
        [string]$Level = "INFO",
        [switch]$Compact
    )
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    
    "[$timestamp] [$Level] $MessageEn" | Out-File -FilePath "$env:TEMP\backup-temp.log" -Encoding UTF8 -Append -Force
    
    if ($CompactMode -and $Compact) {
        $color = switch($Level){
            "ERROR"   { "Red"    }
            "WARN"    { "Yellow" }
            "INFO"    { "Gray"   }
            "SUCCESS" { "Green"  }
            default   { "White"  }
        }
        
        $symbol = switch($Level){
            "ERROR"   { "✗" }
            "WARN"    { "!" }
            "INFO"    { ">" }
            "SUCCESS" { "✓" }
            default   { "·" }
        }
        
        Write-Host "$symbol $MessageRu" -ForegroundColor $color
    } else {
        $color = switch($Level){
            "ERROR"   { "Red"    }
            "WARN"    { "Yellow" }
            "INFO"    { "Cyan"   }
            "SUCCESS" { "Green"  }
            default   { "White"  }
        }
        
        Write-Host "[$timestamp] [$Level] $MessageEn" -ForegroundColor $color
        if ($MessageRu -ne $MessageEn) {
            Write-Host "[$timestamp] [$Level] $MessageRu" -ForegroundColor $color
        }
    }
}

function Write-ProgressStatus {
    param(
        [string]$ActivityRu,
        [string]$ActivityEn,
        [string]$StatusRu,
        [string]$StatusEn,
        [int]$Percent = -1
    )
    
    if (-not $CompactMode) {
        if ($Percent -ge 0) {
            Write-Progress -Activity $ActivityEn -Status $StatusEn -PercentComplete $Percent
        } else {
            Write-Progress -Activity $ActivityEn -Status $StatusEn
        }
    } else {
        Write-Host "↳ ${ActivityRu}: $StatusRu" -ForegroundColor DarkGray
    }
}

function Get-FileSizeHuman {
    param([long]$Bytes)
    $units = @('B','KB','MB','GB','TB')
    $index = 0
    while ($Bytes -ge 1024 -and $index -lt $units.Length - 1) {
        $Bytes /= 1024
        $index++
    }
    return "{0:N2} {1}" -f $Bytes, $units[$index]
}

function Test-FreeSpace {
    param([string]$Path, [long]$RequiredBytes)
    try {
        $drive = (Get-Item $Path).PSDrive.Root
        $driveInfo = Get-PSDrive -Name $drive[0]
        $free = $driveInfo.Free
        
        Write-Status -MessageEn "Free on ${drive}: $(Get-FileSizeHuman $free)" `
                     -MessageRu "Свободно на ${drive}: $(Get-FileSizeHuman $free)" -Level "INFO" -Compact
        Write-Status -MessageEn "Needed ≈ $(Get-FileSizeHuman $RequiredBytes)" `
                     -MessageRu "Нужно ≈ $(Get-FileSizeHuman $RequiredBytes)" -Level "INFO" -Compact
        
        return $free -gt ($RequiredBytes * 1.15)  # 15% запас
    } catch {
        Write-Status -MessageEn "Cannot check free space" -MessageRu "Не удалось проверить место" -Level "WARN" -Compact
        return $true
    }
}

function Get-FilesBatch {
    param([string[]]$Folders, [string]$BackupName)
    
    Write-Status -MessageEn "Scanning $BackupName..." -MessageRu "Сканирую $BackupName..." -Level "INFO"
    
    $allFiles = [System.Collections.Generic.List[string]]::new()
    $totalSize = 0L
    
    foreach ($folder in $Folders) {
        if (-not (Test-Path -LiteralPath $folder)) {
            Write-Status -MessageEn "Not found: $folder" -MessageRu "Не найдена: $folder" -Level "WARN" -Compact
            continue
        }
        
        Write-ProgressStatus -ActivityRu "Сканирование" -ActivityEn "Scanning" `
                            -StatusRu (Split-Path $folder -Leaf) -StatusEn (Split-Path $folder -Leaf)
        
        Get-ChildItem -LiteralPath $folder -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object {
                $allFiles.Add($_.FullName)
                $totalSize += $_.Length
            }
    }
    
    Write-Progress -Activity "Scanning" -Completed
    
    if ($allFiles.Count -eq 0) {
        Write-Status -MessageEn "No files found" -MessageRu "Файлы не найдены" -Level "WARN"
        return $null
    }
    
    Write-Status -MessageEn "Found $($allFiles.Count) files ($(Get-FileSizeHuman $totalSize))" `
                 -MessageRu "Найдено $($allFiles.Count) файлов ($(Get-FileSizeHuman $totalSize))" -Level "SUCCESS"
    
    return @{
        Files     = $allFiles.ToArray()
        TotalSize = $totalSize
        Count     = $allFiles.Count
    }
}

function Get-FileHashesParallel {
    param(
        [string[]]$Files,
        [string]$BasePath,
        [string]$BackupName
    )
    
    if ($Files.Count -eq 0) { return @{Hashes = @{}; SuccessCount = 0} }
    
    Write-Status -MessageEn "Hashing $($Files.Count) files..." -MessageRu "Считаю хеши..." -Level "INFO"
    
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $runspacePool.Open()
    
    $results = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new()
    $queue   = [System.Collections.Concurrent.ConcurrentQueue[string]]::new($Files)
    $done    = [System.Collections.Concurrent.ConcurrentQueue[int]]::new()
    
    $script = {
        param($q, $res, $cnt, $base, $alg)
        
        $hasher = if ($alg -eq "SHA512") { [System.Security.Cryptography.SHA512]::Create() }
                  else { [System.Security.Cryptography.SHA256]::Create() }
        
        $buf = New-Object byte[] 1MB
        
        $file = $null
        while ($q.TryDequeue([ref]$file)) {
            try {
                $fs = [IO.File]::OpenRead($file)
                while ($fs.Read($buf,0,$buf.Length) -gt 0) { $hasher.TransformBlock($buf,0,$buf.Length,$buf,0) | Out-Null }
                $hasher.TransformFinalBlock($buf,0,0) | Out-Null
                
                $rel = $file.Substring($base.Length + 1)
                $hash = [BitConverter]::ToString($hasher.Hash).Replace("-","").ToLower()
                $res[$rel] = $hash
                
                $cnt.Enqueue(1)
            } catch {
                $res[$file] = "ERROR"
            } finally {
                if ($fs) { $fs.Dispose() }
            }
            $hasher.Initialize()
        }
        $hasher.Dispose()
    }
    
    $jobs = @()
    1..$MaxThreads | ForEach-Object {
        $ps = [powershell]::Create().AddScript($script)
        $ps.AddArgument($queue); $ps.AddArgument($results); $ps.AddArgument($done)
        $ps.AddArgument($BasePath); $ps.AddArgument($HashAlgorithm)
        $ps.RunspacePool = $runspacePool
        $jobs += @{ ps = $ps; ar = $ps.BeginInvoke() }
    }
    
    $last = Get-Date
    while (-not ($jobs.ar.IsCompleted -notcontains $false)) {
        $c = $done.Count
        $p = if ($Files.Count) { [math]::Min(100, [math]::Round($c * 100 / $Files.Count)) } else {0}
        
        if ((Get-Date) - $last -gt [TimeSpan]::FromSeconds(3)) {
            Write-ProgressStatus -ActivityRu "Хеширование" -ActivityEn "Hashing" `
                                -StatusRu "$c/$($Files.Count)" -StatusEn "$c/$($Files.Count)" -Percent $p
            $last = Get-Date
        }
        Start-Sleep -Milliseconds 300
    }
    
    foreach ($job in $jobs) { $job.ps.EndInvoke($job.ar); $job.ps.Dispose() }
    $runspacePool.Close(); $runspacePool.Dispose()
    
    $hashes = @{}
    foreach ($kv in $results.GetEnumerator()) {
        if ($kv.Value -ne "ERROR") { $hashes[$kv.Key] = $kv.Value }
    }
    
    Write-Status -MessageEn "Hashes ready: $($hashes.Count) files" -MessageRu "Хеши готовы: $($hashes.Count)" -Level "SUCCESS"
    return @{ Hashes = $hashes }
}

function Create-Archive-Main {
    # Встроенный ZIP — для основных папок
    param(
        [string[]]$Files,
        [string]$BasePath,
        [hashtable]$Hashes,
        [string]$OutputPath,
        [string]$HashFileName,
        [string]$BackupName
    )
    
    Write-Status -MessageEn "Creating ZIP (native) → $BackupName" -MessageRu "Создаю ZIP → $BackupName" -Level "INFO"
    
    $hashContent = "# Hashes`n# Algo: $HashAlgorithm`n# Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n"
    $Hashes.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $hashContent += "$($_.Value) *$($_.Key)`n"
    }
    
    $dir = Split-Path $OutputPath -Parent
    if (!(Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    
    $fs = [IO.File]::Open($OutputPath, [IO.FileMode]::Create)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create, $false)
        $buf = New-Object byte[] $BufferSize
        
        $cnt = 0
        foreach ($file in $Files) {
            $rel = $file.Substring($BasePath.Length + 1)
            if (!$Hashes.ContainsKey($rel)) { continue }
            
            $entry = $zip.CreateEntry($rel.Replace('\','/'), $ZipCompressionLevel)
            $es = $entry.Open()
            $fsIn = [IO.File]::OpenRead($file)
            
            $read = 0
            while (($read = $fsIn.Read($buf, 0, $buf.Length)) -gt 0) {
                $es.Write($buf, 0, $read)
            }
            
            $fsIn.Close()
            $es.Close()
            $cnt++
        }
        
        # Хеш-файл внутрь
        $he = $zip.CreateEntry($HashFileName, $ZipCompressionLevel)
        $hes = $he.Open()
        $bytes = [Text.Encoding]::UTF8.GetBytes($hashContent)
        $hes.Write($bytes, 0, $bytes.Length)
        $hes.Close()
        
        $zip.Dispose()
    }
    finally { $fs.Close() }
    
    $size = (Get-Item $OutputPath).Length
    Write-Status -MessageEn "Done: $(Get-FileSizeHuman $size)" -MessageRu "Готово: $(Get-FileSizeHuman $size)" -Level "SUCCESS"
    
    return @{ Success = $true; Size = $size; Files = $cnt }
}

function Create-Archive-3D {
    # Только 7-Zip — для 3D Objects
    param(
        [string[]]$Files,
        [string]$BasePath,
        [hashtable]$Hashes,
        [string]$OutputPath,
        [string]$HashFileName,
        [string]$BackupName
    )
    
    if (!(Test-Path $SevenZipPath)) {
        Write-Status -MessageEn "7-Zip not found at $SevenZipPath" -MessageRu "7-Zip не найден" -Level "ERROR"
        return @{ Success = $false; Reason = "7-Zip missing" }
    }
    
    Write-Status -MessageEn "Creating 7-Zip archive → $BackupName" -MessageRu "Создаю 7z архив → $BackupName" -Level "INFO"
    
    # Список относительных путей
    $listPath = "$env:TEMP\3d-files-$((Get-Date).Ticks).txt"
    $Files | ForEach-Object { $_.Substring($BasePath.Length + 1) } | Out-File $listPath -Encoding utf8
    
    # Файл хешей
    $hashPath = "$env:TEMP\$HashFileName"
    $hashContent = "# Hashes`n# Algo: $HashAlgorithm`n# Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n"
    $Hashes.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $hashContent += "$($_.Value) *$($_.Key)`n"
    }
    $hashContent | Out-File $hashPath -Encoding utf8
    
    # Запуск 7-Zip
    $args = "a -tzip -mx=0 -mmt=on `"$OutputPath`" -ir@`"$listPath`" `"$hashPath`""
    $p = Start-Process $SevenZipPath -ArgumentList $args -NoNewWindow -Wait -PassThru
    
    Remove-Item $listPath, $hashPath -Force -ErrorAction SilentlyContinue
    
    if ($p.ExitCode -ne 0) {
        Write-Status -MessageEn "7-Zip failed (code $($p.ExitCode))" -MessageRu "7-Zip завершился с ошибкой $($p.ExitCode)" -Level "ERROR"
        return @{ Success = $false; Reason = "7-Zip error $($p.ExitCode)" }
    }
    
    $size = (Get-Item $OutputPath).Length
    Write-Status -MessageEn "7-Zip done: $(Get-FileSizeHuman $size)" -MessageRu "7-Zip готов: $(Get-FileSizeHuman $size)" -Level "SUCCESS"
    
    return @{ Success = $true; Size = $size; Files = $Files.Count }
}

function Test-ArchiveIntegrity {
    param([string]$Path)
    
    Write-Status -MessageEn "Integrity check..." -MessageRu "Проверка целостности..." -Level "INFO" -Compact
    
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        foreach ($e in $zip.Entries) {
            $s = $e.Open()
            $s.ReadByte() | Out-Null
            $s.Close()
        }
        $zip.Dispose()
        Write-Status -MessageEn "Integrity OK" -MessageRu "Целостность OK" -Level "SUCCESS" -Compact
        return $true
    } catch {
        Write-Status -MessageEn "Integrity FAILED" -MessageRu "Целостность НЕ ПРОЙДЕНА" -Level "ERROR" -Compact
        return $false
    }
}

function Process-Backup {
    param(
        [string[]]$Folders,
        [string]$Name,
        [string]$TempPath,
        [string]$FinalPath,
        [string]$HashFileName,
        [switch]$Use7Zip
    )
    
    Write-Host "`n$('═'*60)" -ForegroundColor $(if($Name -eq "3D"){"Magenta"}else{"Cyan"})
    Write-Host " $Name БЭКАП " -ForegroundColor $(if($Name -eq "3D"){"Magenta"}else{"Cyan"})
    Write-Host $('═'*60) -ForegroundColor $(if($Name -eq "3D"){"Magenta"}else{"Cyan"})
    
    $scan = Get-FilesBatch -Folders $Folders -BackupName $Name
    if (!$scan) {
        Write-Host " ✓ $Name : нет файлов" -ForegroundColor Gray
        return @{Success=$false; Reason="No files"}
    }
    
    if (!(Test-FreeSpace $DestinationRoot $scan.TotalSize)) {
        Write-Status -MessageEn "Not enough space" -MessageRu "Мало места" -Level "ERROR"
        return @{Success=$false; Reason="No space"}
    }
    
    $hashes = Get-FileHashesParallel -Files $scan.Files -BasePath $UserPath -BackupName $Name
    
    $archiveFn = if ($Use7Zip) { "Create-Archive-3D" } else { "Create-Archive-Main" }
    
    $result = & $archiveFn -Files $scan.Files -BasePath $UserPath -Hashes $hashes.Hashes `
                           -OutputPath $TempPath -HashFileName $HashFileName -BackupName $Name
    
    if (!$result.Success) {
        return @{Success=$false; Reason=$result.Reason}
    }
    
    $ok = Test-ArchiveIntegrity $TempPath
    
    # Перенос
    $finalName = Split-Path $FinalPath -Leaf
    $tempDest = Join-Path (Split-Path $FinalPath -Parent) (Split-Path $TempPath -Leaf)
    Move-Item $TempPath $tempDest -Force
    Rename-Item $tempDest $finalName -Force
    
    if ($ok) {
        Write-Host " ✓ $Name : Успешно  |  $(Get-FileSizeHuman $result.Size)" -ForegroundColor Green
        return @{Success=$true; Size=$result.Size; Files=$scan.Count}
    } else {
        Write-Host " ! $Name : целостность под вопросом" -ForegroundColor Yellow
        return @{Success=$false; Size=$result.Size; Files=$scan.Count; IntegrityOK=$false}
    }
}

# ---------------- MAIN ----------------

Clear-Host

Write-Host "`nBACKUP SYSTEM v.13 — 3D Objects → 7-Zip only" -ForegroundColor Cyan
Write-Host "Основные папки (без Downloads) → встроенный ZIP"
Write-Host "Хеши — один проход | Потоки: $MaxThreads`n"

$choice = Read-Host "1 = Основной`n2 = 3D Objects`n3 = Оба`n→ "

$dt = Get-Date -Format $DateTimeFormat
$destFolder = Join-Path $DestinationRoot "Backup-$dt"
$logPath = Join-Path $destFolder "log-$dt.txt"

if (!(Test-Path $destFolder)) { New-Item -ItemType Directory $destFolder -Force | Out-Null }

$results = @{}

switch ($choice) {
    "1" {
        $mainTemp = Join-Path $env:TEMP "Main-$dt.partial.zip"
        $mainFinal = Join-Path $destFolder "Main-$dt.zip"
        $results.Main = Process-Backup -Folders $MainFolders -Name "Основной" `
                                       -TempPath $mainTemp -FinalPath $mainFinal `
                                       -HashFileName "hashes-main.sha512" -Use7Zip:$false
    }
    "2" {
        $3dTemp = Join-Path $env:TEMP "3D-$dt.partial.zip"
        $3dFinal = Join-Path $destFolder "3D-$dt.zip"
        $results.ThreeD = Process-Backup -Folders $ThreeDFolders -Name "3D Objects" `
                                         -TempPath $3dTemp -FinalPath $3dFinal `
                                         -HashFileName "hashes-3d.sha512" -Use7Zip
    }
    "3" {
        # Основной
        $mainTemp = Join-Path $env:TEMP "Main-$dt.partial.zip"
        $mainFinal = Join-Path $destFolder "Main-$dt.zip"
        $results.Main = Process-Backup -Folders $MainFolders -Name "Основной" `
                                       -TempPath $mainTemp -FinalPath $mainFinal `
                                       -HashFileName "hashes-main.sha512" -Use7Zip:$false
        
        # 3D
        $3dTemp = Join-Path $env:TEMP "3D-$dt.partial.zip"
        $3dFinal = Join-Path $destFolder "3D-$dt.zip"
        $results.ThreeD = Process-Backup -Folders $ThreeDFolders -Name "3D Objects" `
                                         -TempPath $3dTemp -FinalPath $3dFinal `
                                         -HashFileName "hashes-3d.sha512" -Use7Zip
    }
    default { exit }
}

# Лог
if (Test-Path "$env:TEMP\backup-temp.log") {
    Move-Item "$env:TEMP\backup-temp.log" $logPath -Force
}

Write-Host "`nГотово. Папка:" -ForegroundColor Cyan
Write-Host "  $destFolder" -ForegroundColor White
Write-Host "Лог: $logPath`n"

Read-Host "Enter для выхода"
