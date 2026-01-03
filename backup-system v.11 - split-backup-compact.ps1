﻿# backup-system v.11 - split-backup-compact.ps1
# ⭐️ УЛУЧШЕНИЯ: Компактный вывод + русские логи + выбор бэкапа
# ⭐️ ФОРМАТ: ZIP без сжатия (Store)
# ⭐️ ДОБАВЛЕНО: Пояснения действий + прогресс-статус

# ---------------- CONFIG ----------------
$UserPath        = $env:USERPROFILE
$HashAlgorithm   = "SHA512"

# Основные папки (без 3D Objects)
$MainFolders     = @(
    "$UserPath\Videos",
    "$UserPath\Documents",
    "$UserPath\Downloads", 
    "$UserPath\Music",
    "$UserPath\Pictures",
    "$UserPath\Desktop"
)

# Отдельная папка для 3D Objects
$ThreeDFolders   = @("$UserPath\3D Objects")

$DestinationRoot = "G:\Backups"
$DateTimeFormat  = "dd-MM-yyyy-HH_mm"
$FileExtension   = "zip"
$MaxThreads      = 10
$ZipCompressionLevel = [System.IO.Compression.CompressionLevel]::NoCompression
$BufferSize      = 1MB
$CheckpointFile  = "$env:TEMP\backup-checkpoint.json"

# Настройка компактного вывода
$CompactMode = $true  # true = компактный вывод, false = подробный
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
    
    # Записываем в лог-файл (полная версия)
    "[$timestamp] [$Level] $MessageEn" | Out-File -FilePath "$env:TEMP\backup-temp.log" -Encoding UTF8 -Append -Force
    
    # Выводим в консоль в зависимости от режима
    if ($CompactMode -and $Compact) {
        # Компактный режим: только русский и статус
        $color = switch($Level){
            "ERROR"   { "Red"; break }
            "WARN"    { "Yellow"; break }
            "INFO"    { "Gray"; break }
            "SUCCESS" { "Green"; break }
            default   { "White" }
        }
        
        $statusSymbol = switch($Level){
            "ERROR"   { "✗" }
            "WARN"    { "!" }
            "INFO"    { ">" }
            "SUCCESS" { "✓" }
            default   { "·" }
        }
        
        Write-Host "$statusSymbol $MessageRu" -ForegroundColor $color
    } else {
        # Подробный режим: оба языка
        $color = switch($Level){
            "ERROR"   { "Red"; break }
            "WARN"    { "Yellow"; break }
            "INFO"    { "Cyan"; break }
            "SUCCESS" { "Green"; break }
            default   { "White" }
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
        # В компактном режиме показываем только текст
        Write-Host "↳ ${ActivityRu}: $StatusRu" -ForegroundColor DarkGray
    }
}

function Save-Checkpoint {
    param(
        [hashtable]$State,
        [string]$Stage
    )
    
    $checkpointData = @{
        Stage = $Stage
        State = $State
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    $checkpointData | ConvertTo-Json -Depth 5 | Out-File $CheckpointFile -Encoding UTF8 -Force
    Write-Status -MessageEn "Checkpoint saved: $Stage" -MessageRu "Контр. точка: $Stage" -Level "INFO" -Compact
}

function Remove-Checkpoint {
    if (Test-Path $CheckpointFile) {
        Remove-Item $CheckpointFile -Force -ErrorAction SilentlyContinue
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
    param(
        [string]$Path,
        [long]$RequiredBytes
    )
    
    try {
        $drive = (Get-Item $Path).Root
        $driveInfo = [System.IO.DriveInfo]::new($drive)
        $freeSpace = $driveInfo.AvailableFreeSpace
        
        Write-Status -MessageEn "Free space on ${drive}: $(Get-FileSizeHuman $freeSpace)" `
                     -MessageRu "Место на ${drive}: $(Get-FileSizeHuman $freeSpace)" -Level "INFO" -Compact
        Write-Status -MessageEn "Required: $(Get-FileSizeHuman $RequiredBytes)" `
                     -MessageRu "Требуется: $(Get-FileSizeHuman $RequiredBytes)" -Level "INFO" -Compact
        
        return $freeSpace -gt ($RequiredBytes * 1.2) # 20% buffer
    } catch {
        Write-Status -MessageEn "Cannot check free space: $($_.Exception.Message)" `
                     -MessageRu "Ошибка проверки места: $($_.Exception.Message)" -Level "WARN" -Compact
        return $true # Continue anyway
    }
}

function Get-FilesBatch {
    param(
        [string[]]$Folders,
        [string]$BackupName,
        [int]$ReportEvery = 1000
    )
    
    Write-Status -MessageEn "Scanning folders for $BackupName..." `
                 -MessageRu "Сканирование папок для $BackupName..." -Level "INFO"
    
    $allFiles = [System.Collections.Generic.List[string]]::new()
    $totalSize = 0L
    $fileCount = 0
    $foundFolders = 0
    
    foreach ($folder in $Folders) {
        if (-not (Test-Path -LiteralPath $folder)) {
            Write-Status -MessageEn "Folder not found: $folder" `
                         -MessageRu "Папка не найдена: $folder" -Level "WARN" -Compact
            continue
        }
        
        try {
            Write-ProgressStatus -ActivityEn "Scanning folders" -ActivityRu "Сканирование папок" `
                                -StatusEn $folder -StatusRu $(Split-Path $folder -Leaf)
            
            $files = Get-ChildItem -Path $folder -File -Recurse -ErrorAction Stop
            
            $folderFileCount = 0
            foreach ($file in $files) {
                $allFiles.Add($file.FullName)
                $totalSize += $file.Length
                $fileCount++
                $folderFileCount++
                
                if (-not $CompactMode -and $fileCount % $ReportEvery -eq 0) {
                    Write-Progress -Activity "Scanning files" -Status "Found $fileCount files" -CurrentOperation $folder
                }
            }
            
            if ($folderFileCount -gt 0) {
                Write-Status -MessageEn "Found $folderFileCount files in $(Split-Path $folder -Leaf)" `
                             -MessageRu "Найдено $folderFileCount файлов в $(Split-Path $folder -Leaf)" -Level "INFO" -Compact
            }
            $foundFolders++
            
        } catch {
            Write-Status -MessageEn "Error scanning ${folder}: $($_.Exception.Message)" `
                         -MessageRu "Ошибка сканирования ${folder}: $($_.Exception.Message)" -Level "ERROR" -Compact
        }
    }
    
    Write-Progress -Activity "Scanning files" -Completed
    
    if ($fileCount -eq 0) {
        Write-Status -MessageEn "No files found for $BackupName" `
                     -MessageRu "Файлы не найдены для $BackupName" -Level "WARN"
        return $null
    }
    
    Write-Status -MessageEn "Found $fileCount files ($(Get-FileSizeHuman $totalSize))" `
                 -MessageRu "Найдено $fileCount файлов ($(Get-FileSizeHuman $totalSize))" -Level "SUCCESS"
    
    return @{
        Files = $allFiles.ToArray()
        TotalSize = $totalSize
        Count = $fileCount
        FoldersScanned = $foundFolders
    }
}

function Get-FileHashesParallel {
    param(
        [string[]]$Files,
        [string]$BasePath,
        [int]$Threads = 10,
        [string]$BackupName
    )
    
    if ($Files -eq $null -or $Files.Count -eq 0) {
        return @{
            Hashes = @{}
            Errors = @()
            SuccessCount = 0
            ErrorCount = 0
        }
    }
    
    Write-Status -MessageEn "Calculating hashes for $($Files.Count) files..." `
                 -MessageRu "Вычисление хешей для $($Files.Count) файлов..." -Level "INFO"
    
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $Threads)
    $runspacePool.Open()
    
    $concurrentResults = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new()
    $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new($Files)
    $processed = [System.Collections.Concurrent.ConcurrentQueue[int]]::new()
    
    $scriptBlock = {
        param($queue, $results, $counter, $basePath, $hashAlg)
        
        $hashAlgo = if ($hashAlg -eq "SHA512") {
            [System.Security.Cryptography.SHA512]::Create()
        } else {
            [System.Security.Cryptography.SHA256]::Create()
        }
        
        $buffer = New-Object byte[] (128KB)
        $currentFile = $null
        
        while ($queue.TryDequeue([ref]$currentFile)) {
            try {
                $fs = [System.IO.File]::OpenRead($currentFile)
                
                # Streaming hash calculation
                while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $hashAlgo.TransformBlock($buffer, 0, $read, $buffer, 0) | Out-Null
                }
                $hashAlgo.TransformFinalBlock($buffer, 0, 0) | Out-Null
                $hashHex = [System.BitConverter]::ToString($hashAlgo.Hash).Replace("-", "").ToLower()
                
                $relativePath = $currentFile.Substring($basePath.Length + 1)
                $results.TryAdd($relativePath, $hashHex) | Out-Null
                
                $fs.Close()
                $hashAlgo.Initialize() # Reset for next file
                $counter.Enqueue(1)
                
            } catch {
                $results.TryAdd($currentFile, "ERROR:$($_.Exception.Message)") | Out-Null
                $counter.Enqueue(1)
            } finally {
                if ($fs -ne $null) { $fs.Dispose() }
            }
        }
        
        $hashAlgo.Dispose()
    }
    
    $jobs = @()
    for ($i = 0; $i -lt $Threads; $i++) {
        $ps = [powershell]::Create().AddScript($scriptBlock)
        $ps.AddArgument($queue) | Out-Null
        $ps.AddArgument($concurrentResults) | Out-Null
        $ps.AddArgument($processed) | Out-Null
        $ps.AddArgument($BasePath) | Out-Null
        $ps.AddArgument($HashAlgorithm) | Out-Null
        $ps.RunspacePool = $runspacePool
        
        $jobs += @{
            PowerShell = $ps
            AsyncResult = $ps.BeginInvoke()
        }
    }
    
    # Progress monitoring
    $lastUpdate = Get-Date
    while ($jobs.AsyncResult.IsCompleted -contains $false -or $queue.Count -gt 0) {
        $done = $processed.Count
        $percent = if ($Files.Count -gt 0) { ($done / $Files.Count) * 100 } else { 0 }
        
        if ((Get-Date) - $lastUpdate -gt [TimeSpan]::FromSeconds(2)) {
            Write-ProgressStatus -ActivityEn "Calculating hashes" -ActivityRu "Вычисление хешей" `
                                -StatusEn "$done/$($Files.Count) files" -StatusRu "$done/$($Files.Count) файлов" `
                                -Percent $percent
            $lastUpdate = Get-Date
        }
        Start-Sleep -Milliseconds 100
    }
    
    Write-Progress -Activity "Calculating file hashes" -Completed
    
    # Collect results
    foreach ($job in $jobs) {
        $job.PowerShell.EndInvoke($job.AsyncResult) | Out-Null
        $job.PowerShell.Dispose()
    }
    
    $runspacePool.Close()
    $runspacePool.Dispose()
    
    # Separate hashes and errors
    $hashes = @{}
    $errors = @()
    
    foreach ($entry in $concurrentResults.GetEnumerator()) {
        if ($entry.Value -like "ERROR:*") {
            $errors += "$($entry.Key): $($entry.Value.Substring(6))"
        } else {
            $hashes[$entry.Key] = $entry.Value
        }
    }
    
    return @{
        Hashes = $hashes
        Errors = $errors
        SuccessCount = $hashes.Count
        ErrorCount = $errors.Count
    }
}

function Create-ArchiveWithValidation {
    param(
        [string[]]$Files,
        [string]$BasePath,
        [hashtable]$FileHashes,
        [string]$OutputPath,
        [System.IO.Compression.CompressionLevel]$Compression,
        [string]$InternalHashFileName,
        [string]$BackupName
    )
    
    $archiveName = Split-Path $OutputPath -Leaf
    Write-Status -MessageEn "Creating archive: $archiveName" `
                 -MessageRu "Создание архива: $archiveName" -Level "INFO"
    
    # Create hash file content in memory
    $hashContentBuilder = [System.Text.StringBuilder]::new()
    $hashContentBuilder.AppendLine("# File hashes generated by Backup System") | Out-Null
    $hashContentBuilder.AppendLine("# Algorithm: $HashAlgorithm") | Out-Null
    
    $backupName = (Split-Path $OutputPath -Leaf) -replace '\.partial\.zip$', '.zip'
    $hashContentBuilder.AppendLine("# Backup: $backupName") | Out-Null
    
    $hashContentBuilder.AppendLine("# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
    $hashContentBuilder.AppendLine() | Out-Null
    
    $fileIndex = 0
    $FileHashes.Keys | Sort-Object | ForEach-Object {
        $hashContentBuilder.AppendLine("$($FileHashes[$_]) *$_") | Out-Null
        $fileIndex++
        
        if (-not $CompactMode -and $fileIndex % 100 -eq 0) {
            Write-Progress -Activity "Preparing hash file" `
                          -Status "Processed $fileIndex / $($FileHashes.Count) entries" `
                          -PercentComplete (($fileIndex / $FileHashes.Count) * 100)
        }
    }
    
    Write-Progress -Activity "Preparing hash file" -Completed
    $hashContent = $hashContentBuilder.ToString()
    
    # Create archive directory if needed
    $archiveDir = [System.IO.Path]::GetDirectoryName($OutputPath)
    if (-not (Test-Path $archiveDir)) {
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    }
    
    # Create archive
    $archiveMode = [System.IO.Compression.ZipArchiveMode]::Create
    $fileStream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create)
    
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($fileStream, $archiveMode, $false)
        $buffer = New-Object byte[] $BufferSize
        $processedFiles = 0
        
        Write-Status -MessageEn "Adding files to archive..." `
                     -MessageRu "Добавление файлов в архив..." -Level "INFO" -Compact
        
        foreach ($file in $Files) {
            try {
                $relativePath = $file.Substring($BasePath.Length + 1)
                
                # Skip if file was in hash errors
                if (-not $FileHashes.ContainsKey($relativePath)) {
                    continue
                }
                
                $entry = $archive.CreateEntry($relativePath.Replace('\', '/'), $Compression)
                $entryStream = $entry.Open()
                $fileStreamSource = [System.IO.File]::OpenRead($file)
                
                # Copy with buffer (Store mode - no compression)
                $bytesRead = 0
                while (($bytesRead = $fileStreamSource.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $entryStream.Write($buffer, 0, $bytesRead)
                }
                
                $fileStreamSource.Close()
                $entryStream.Close()
                
                $processedFiles++
                if (-not $CompactMode -and $processedFiles % 10 -eq 0) {
                    Write-Progress -Activity "Adding files to archive" `
                                  -Status "$processedFiles / $($Files.Count) files" `
                                  -PercentComplete (($processedFiles / $Files.Count) * 100)
                }
                
            } catch {
                # Silent error in compact mode
                if (-not $CompactMode) {
                    Write-Status -MessageEn "Failed to add file: $(Split-Path $file -Leaf)" `
                                 -MessageRu "Ошибка добавления файла: $(Split-Path $file -Leaf)" -Level "ERROR" -Compact
                }
            }
        }
        
        Write-Progress -Activity "Adding files to archive" -Completed
        
        # Add hash file to archive
        try {
            $hashEntry = $archive.CreateEntry($InternalHashFileName, $Compression)
            $hashStream = $hashEntry.Open()
            $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($hashContent)
            $hashStream.Write($hashBytes, 0, $hashBytes.Length)
            $hashStream.Close()
        } catch {
            Write-Status -MessageEn "Failed to add hash file" `
                         -MessageRu "Ошибка добавления файла хешей" -Level "ERROR" -Compact
        }
        
        $archive.Dispose()
        
    } finally {
        $fileStream.Close()
    }
    
    $archiveSize = (Get-Item $OutputPath).Length
    Write-Status -MessageEn "Archive created: $(Get-FileSizeHuman $archiveSize)" `
                 -MessageRu "Архив создан: $(Get-FileSizeHuman $archiveSize)" -Level "SUCCESS"
    
    return @{
        Success = $true
        FilesAdded = $processedFiles
        ArchivePath = $OutputPath
        ArchiveSize = $archiveSize
    }
}

function Test-ArchiveIntegrity {
    param([string]$ArchivePath, [string]$BackupName)
    
    Write-Status -MessageEn "Checking archive integrity..." `
                 -MessageRu "Проверка целостности архива..." -Level "INFO" -Compact
    
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        $entries = $archive.Entries
        $validEntries = 0
        $totalEntries = $entries.Count
        
        foreach ($entry in $entries) {
            try {
                $stream = $entry.Open()
                $testByte = $stream.ReadByte()
                $stream.Close()
                $validEntries++
                
                if (-not $CompactMode -and $validEntries % 50 -eq 0) {
                    Write-Progress -Activity "Validating archive entries" `
                                  -Status "$validEntries / $totalEntries entries checked" `
                                  -PercentComplete (($validEntries / $totalEntries) * 100)
                }
                
            } catch {
                $archive.Dispose()
                Write-Progress -Activity "Validating archive entries" -Completed
                return $false
            }
        }
        
        $archive.Dispose()
        Write-Progress -Activity "Validating archive entries" -Completed
        
        if ($validEntries -eq $totalEntries) {
            Write-Status -MessageEn "Integrity check passed" `
                         -MessageRu "Проверка целостности пройдена" -Level "SUCCESS" -Compact
            return $true
        } else {
            Write-Status -MessageEn "Integrity check failed: $validEntries/$totalEntries" `
                         -MessageRu "Проверка целостности не пройдена: $validEntries/$totalEntries" -Level "ERROR" -Compact
            return $false
        }
        
    } catch {
        Write-Status -MessageEn "Failed to open archive" `
                     -MessageRu "Не удалось открыть архив" -Level "ERROR" -Compact
        return $false
    }
}

function Verify-ArchiveHashes {
    param(
        [string]$ArchivePath,
        [hashtable]$OriginalHashes,
        [string]$InternalHashFileName,
        [string]$BackupName
    )
    
    Write-Status -MessageEn "Verifying hashes..." `
                 -MessageRu "Проверка хешей..." -Level "INFO" -Compact
    
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        $hashEntry = $archive.GetEntry($InternalHashFileName)
        
        if ($hashEntry -eq $null) {
            $archive.Dispose()
            return $false
        }
        
        $stream = $hashEntry.Open()
        $reader = New-Object System.IO.StreamReader($stream)
        $archiveHashes = @{}
        
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line -match "^([a-f0-9]{64,128})\s+\*(.+)$") {
                $archiveHashes[$matches[2]] = $matches[1]
            }
        }
        
        $reader.Close()
        $stream.Close()
        $archive.Dispose()
        
        # Compare hashes
        $mismatches = 0
        $missingInArchive = 0
        
        foreach ($filePath in $OriginalHashes.Keys) {
            if (-not $archiveHashes.ContainsKey($filePath)) {
                $missingInArchive++
            } elseif ($OriginalHashes[$filePath] -ne $archiveHashes[$filePath]) {
                $mismatches++
            }
        }
        
        if ($mismatches -eq 0 -and $missingInArchive -eq 0) {
            Write-Status -MessageEn "Hash verification passed" `
                         -MessageRu "Проверка хешей пройдена" -Level "SUCCESS" -Compact
            return $true
        } else {
            Write-Status -MessageEn "Hash verification failed: $mismatches mismatches" `
                         -MessageRu "Проверка хешей не пройдена: $mismatches несовпадений" -Level "ERROR" -Compact
            return $false
        }
        
    } catch {
        Write-Status -MessageEn "Failed to verify hashes" `
                     -MessageRu "Не удалось проверить хеши" -Level "ERROR" -Compact
        return $false
    }
}

function Compare-HashRuns {
    param(
        [hashtable]$FirstRun,
        [hashtable]$SecondRun,
        [string]$BackupName
    )
    
    Write-Status -MessageEn "Comparing hash calculations..." `
                 -MessageRu "Сравнение вычислений хешей..." -Level "INFO" -Compact
    
    $mismatches = 0
    $missingInSecond = 0
    $missingInFirst = 0
    
    foreach ($file in $FirstRun.Keys) {
        if (-not $SecondRun.ContainsKey($file)) {
            $missingInSecond++
        } elseif ($FirstRun[$file] -ne $SecondRun[$file]) {
            $mismatches++
        }
    }
    
    foreach ($file in $SecondRun.Keys) {
        if (-not $FirstRun.ContainsKey($file)) {
            $missingInFirst++
        }
    }
    
    if ($mismatches -eq 0 -and $missingInFirst -eq 0 -and $missingInSecond -eq 0) {
        Write-Status -MessageEn "Hash comparison: Perfect match" `
                     -MessageRu "Сравнение хешей: Полное соответствие" -Level "SUCCESS" -Compact
        return $true
    } else {
        if ($CompactMode) {
            Write-Status -MessageEn "Hash comparison: Issues found ($mismatches mismatches)" `
                         -MessageRu "Сравнение хешей: Найдены проблемы ($mismatches несовпадений)" -Level "WARN" -Compact
        }
        return $false
    }
}

function Process-Backup {
    param(
        [string[]]$SourceFolders,
        [string]$BackupName,
        [string]$TempArchivePath,
        [string]$FinalArchivePath,
        [string]$InternalHashFileName
    )
    
    Write-Host "`n" + ("─"*50) -ForegroundColor $(switch($BackupName){
        "Main" { "Cyan"; break }
        "3D"   { "Magenta"; break }
        default { "White" }
    })
    Write-Host "▶ $BackupName БЭКАП / $BackupName BACKUP" -ForegroundColor $(switch($BackupName){
        "Main" { "Cyan"; break }
        "3D"   { "Magenta"; break }
        default { "White" }
    })
    Write-Host ("─"*50) -ForegroundColor $(switch($BackupName){
        "Main" { "Cyan"; break }
        "3D"   { "Magenta"; break }
        default { "White" }
    })
    
    Write-Status -MessageEn "Starting $BackupName backup..." `
                 -MessageRu "Начало $BackupName бэкапа..." -Level "INFO"
    
    # 1. Scan files
    $scanResult = Get-FilesBatch -Folders $SourceFolders -BackupName $BackupName
    
    if ($scanResult -eq $null -or $scanResult.Count -eq 0) {
        Write-Status -MessageEn "No files found. Skipping." `
                     -MessageRu "Файлы не найдены. Пропуск." -Level "WARN"
        Write-Host "✓ ${BackupName}: Нет файлов / No files" -ForegroundColor Gray
        return @{ 
            Success = $false 
            Reason = "No files" 
            FileCount = 0
            TotalSize = 0
            ArchiveSize = 0
            IntegrityOK = $false
            HashVerificationOK = $false
        }
    }
    
    # 2. Check disk space
    Write-Status -MessageEn "Checking disk space..." `
                 -MessageRu "Проверка места на диске..." -Level "INFO" -Compact
    $estimatedArchiveSize = $scanResult.TotalSize * 0.95
    if (-not (Test-FreeSpace -Path $DestinationRoot -RequiredBytes $estimatedArchiveSize)) {
        Write-Status -MessageEn "Not enough disk space" `
                     -MessageRu "Недостаточно места на диске" -Level "ERROR"
        return @{ 
            Success = $false 
            Reason = "Insufficient space" 
            FileCount = $scanResult.Count
            TotalSize = $scanResult.TotalSize
            ArchiveSize = 0
            IntegrityOK = $false
            HashVerificationOK = $false
        }
    }
    
    # 3. First hash calculation
    Write-Status -MessageEn "Calculating hashes (first pass)..." `
                 -MessageRu "Вычисление хешей (первый проход)..." -Level "INFO" -Compact
    $firstHashResult = Get-FileHashesParallel -Files $scanResult.Files -BasePath $UserPath -Threads $MaxThreads -BackupName $BackupName
    
    if ($firstHashResult.ErrorCount -gt 0 -and -not $CompactMode) {
        Write-Status -MessageEn "First hash run: $($firstHashResult.ErrorCount) errors" `
                     -MessageRu "Первый прогон хешей: $($firstHashResult.ErrorCount) ошибок" -Level "WARN" -Compact
    }
    
    # 4. Second hash calculation (validation)
    Write-Status -MessageEn "Calculating hashes (second pass)..." `
                 -MessageRu "Вычисление хешей (второй проход)..." -Level "INFO" -Compact
    $secondHashResult = Get-FileHashesParallel -Files $scanResult.Files -BasePath $UserPath -Threads $MaxThreads -BackupName $BackupName
    
    # 5. Compare hash runs
    Write-Status -MessageEn "Comparing hash runs..." `
                 -MessageRu "Сравнение прогонов хешей..." -Level "INFO" -Compact
    $hashComparisonOK = Compare-HashRuns -FirstRun $firstHashResult.Hashes -SecondRun $secondHashResult.Hashes -BackupName $BackupName
    
    if (-not $hashComparisonOK) {
        Write-Status -MessageEn "Hash comparison failed" `
                     -MessageRu "Сравнение хешей не удалось" -Level "WARN" -Compact
    }
    
    # 6. Create archive
    Write-Status -MessageEn "Creating archive..." `
                 -MessageRu "Создание архива..." -Level "INFO" -Compact
    $archiveResult = Create-ArchiveWithValidation `
        -Files $scanResult.Files `
        -BasePath $UserPath `
        -FileHashes $firstHashResult.Hashes `
        -OutputPath $TempArchivePath `
        -Compression $ZipCompressionLevel `
        -InternalHashFileName $InternalHashFileName `
        -BackupName $BackupName
    
    if (-not $archiveResult.Success) {
        Write-Status -MessageEn "Failed to create archive" `
                     -MessageRu "Не удалось создать архив" -Level "ERROR"
        return @{ 
            Success = $false 
            Reason = "Archive creation failed" 
            FileCount = $scanResult.Count
            TotalSize = $scanResult.TotalSize
            ArchiveSize = 0
            IntegrityOK = $false
            HashVerificationOK = $false
        }
    }
    
    # 7. Verify archive integrity
    Write-Status -MessageEn "Verifying archive integrity..." `
                 -MessageRu "Проверка целостности архива..." -Level "INFO" -Compact
    $integrityOK = Test-ArchiveIntegrity -ArchivePath $TempArchivePath -BackupName $BackupName
    
    # 8. Verify hashes inside archive
    Write-Status -MessageEn "Verifying archive hashes..." `
                 -MessageRu "Проверка хешей архива..." -Level "INFO" -Compact
    $hashVerificationOK = Verify-ArchiveHashes -ArchivePath $TempArchivePath `
        -OriginalHashes $firstHashResult.Hashes `
        -InternalHashFileName $InternalHashFileName `
        -BackupName $BackupName
    
    # 9. Move archive to destination
    $tempDestPartial = Join-Path $DestinationPath "$([System.IO.Path]::GetFileName($TempArchivePath))"
    Move-Item -Path $TempArchivePath -Destination $tempDestPartial -Force -ErrorAction SilentlyContinue
    
    if ($integrityOK -and $hashVerificationOK) {
        # Only rename if both checks passed
        $finalName = [System.IO.Path]::GetFileName($FinalArchivePath)
        Rename-Item -Path $tempDestPartial -NewName $finalName -Force
        
        Write-Host "✓ ${BackupName}: Успешно / Success" -ForegroundColor Green
        Write-Host "  Файлов: $($scanResult.Count) | Размер: $(Get-FileSizeHuman $archiveResult.ArchiveSize)" -ForegroundColor Gray
        
        return @{
            Success = $true
            ArchivePath = $FinalArchivePath
            ArchiveSize = $archiveResult.ArchiveSize
            FileCount = $scanResult.Count
            TotalSize = $scanResult.TotalSize
            IntegrityOK = $integrityOK
            HashVerificationOK = $hashVerificationOK
        }
    } else {
        Write-Host "! ${BackupName}: С предупреждениями / With warnings" -ForegroundColor Yellow
        Write-Host "  Файлов: $($scanResult.Count) | Размер: $(Get-FileSizeHuman $archiveResult.ArchiveSize)" -ForegroundColor Gray
        
        return @{
            Success = $false
            ArchivePath = $tempDestPartial
            ArchiveSize = $archiveResult.ArchiveSize
            FileCount = $scanResult.Count
            TotalSize = $scanResult.TotalSize
            IntegrityOK = $integrityOK
            HashVerificationOK = $hashVerificationOK
            Reason = "Validation failed"
        }
    }
}

function Show-BackupMenu {
    Write-Host "`n" + ("═"*60) -ForegroundColor Cyan
    Write-Host "ВЫБЕРИТЕ ТИП БЭКАПА / SELECT BACKUP TYPE" -ForegroundColor Cyan
    Write-Host "═"*60 -ForegroundColor Cyan
    Write-Host "1. Основной бэкап (без 3D Objects)" -ForegroundColor Green
    Write-Host "   Main backup (without 3D Objects)" -ForegroundColor Gray
    Write-Host "2. 3D Objects бэкап" -ForegroundColor Magenta
    Write-Host "   3D Objects backup" -ForegroundColor Gray
    Write-Host "3. Полный бэкап (оба архива)" -ForegroundColor Yellow
    Write-Host "   Full backup (both archives)" -ForegroundColor Gray
    Write-Host "4. Отмена / Cancel" -ForegroundColor Red
    Write-Host "═"*60 -ForegroundColor Cyan
    
    $choice = Read-Host "Введите номер (1-4) / Enter number (1-4)"
    
    switch ($choice) {
        "1" { return "Main" }
        "2" { return "3D" }
        "3" { return "Both" }
        "4" { exit }
        default {
            Write-Host "Неверный выбор / Invalid choice" -ForegroundColor Red
            return Show-BackupMenu
        }
    }
}

# ---------------- ОСНОВНОЕ ВЫПОЛНЕНИЕ ----------------

# Clear screen
Clear-Host

# Show menu
$backupType = Show-BackupMenu

# Prepare names
$CurrentDateTime = Get-Date -Format $DateTimeFormat

# Общая папка для обоих бэкапов
$BackupFolderName = "Backup-$CurrentDateTime"
$DestinationPath = Join-Path $DestinationRoot $BackupFolderName

# Основной бэкап
$MainArchiveFileName = "Main-Backup-$CurrentDateTime.$FileExtension"
$MainArchivePartialName = "Main-Backup-$CurrentDateTime.partial.$FileExtension"
$MainArchiveTempPath = Join-Path $env:TEMP $MainArchivePartialName
$MainFinalArchivePath = Join-Path $DestinationPath $MainArchiveFileName
$MainHashFileName = "Main-Backup-Files.$($HashAlgorithm.ToLower())"

# 3D Objects бэкап
$ThreeDArchiveFileName = "3D-Backup-$CurrentDateTime.$FileExtension"
$ThreeDArchivePartialName = "3D-Backup-$CurrentDateTime.partial.$FileExtension"
$ThreeDArchiveTempPath = Join-Path $env:TEMP $ThreeDArchivePartialName
$ThreeDFinalArchivePath = Join-Path $DestinationPath $ThreeDArchiveFileName
$ThreeDHashFileName = "3D-Backup-Files.$($HashAlgorithm.ToLower())"

$LogFileName = "Backup-$CurrentDateTime.log"
$LogDestPath = Join-Path $DestinationPath $LogFileName

Write-Host "`n" + ("╔" + ("═"*68) + "╗") -ForegroundColor Cyan
Write-Host "║ BACKUP SYSTEM v.11 - Split Archive (Store Mode)" -ForegroundColor Cyan
Write-Host "║ " -NoNewline -ForegroundColor Cyan
Write-Host "Выбранный тип: " -NoNewline -ForegroundColor White
Write-Host "$backupType" -ForegroundColor $(switch($backupType){
    "Main" { "Green"; break }
    "3D" { "Magenta"; break }
    "Both" { "Yellow"; break }
}) -NoNewline
Write-Host " | " -NoNewline -ForegroundColor Cyan
Write-Host "Selected type: $backupType" -ForegroundColor White
Write-Host "║ " -NoNewline -ForegroundColor Cyan
Write-Host "Время начала: " -NoNewline -ForegroundColor White
Write-Host "$(Get-Date -Format 'HH:mm:ss')" -NoNewline -ForegroundColor Gray
Write-Host " | " -NoNewline -ForegroundColor Cyan
Write-Host "Start time: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor White
Write-Host ("╚" + ("═"*68) + "╝") -ForegroundColor Cyan

try {
    # Setup directories
    if (-not (Test-Path $DestinationRoot)) {
        New-Item -Path $DestinationRoot -ItemType Directory -Force | Out-Null
        Write-Status -MessageEn "Created destination root" `
                     -MessageRu "Создана корневая папка" -Level "INFO"
    }
    
    if (-not (Test-Path $DestinationPath)) {
        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
        Write-Status -MessageEn "Created backup folder" `
                     -MessageRu "Создана папка бэкапа" -Level "INFO"
    }
    
    # Clean temp log
    if (Test-Path "$env:TEMP\backup-temp.log") {
        Remove-Item "$env:TEMP\backup-temp.log" -Force -ErrorAction SilentlyContinue
    }
    
    Write-Status -MessageEn "Starting backup process..." `
                 -MessageRu "Начало процесса бэкапа..." -Level "INFO"
    
    # Результаты для итоговой сводки
    $backupResults = @{}
    
    # Обработка в зависимости от выбора
    switch ($backupType) {
        "Main" {
            if ($MainFolders.Count -gt 0) {
                $mainResult = Process-Backup -SourceFolders $MainFolders `
                    -BackupName "Main" `
                    -TempArchivePath $MainArchiveTempPath `
                    -FinalArchivePath $MainFinalArchivePath `
                    -InternalHashFileName $MainHashFileName
                
                $backupResults.Main = $mainResult
            }
        }
        
        "3D" {
            if ($ThreeDFolders.Count -gt 0) {
                $threeDResult = Process-Backup -SourceFolders $ThreeDFolders `
                    -BackupName "3D" `
                    -TempArchivePath $ThreeDArchiveTempPath `
                    -FinalArchivePath $ThreeDFinalArchivePath `
                    -InternalHashFileName $ThreeDHashFileName
                
                $backupResults.ThreeD = $threeDResult
            }
        }
        
        "Both" {
            # Обработка основного бэкапа
            if ($MainFolders.Count -gt 0) {
                $mainResult = Process-Backup -SourceFolders $MainFolders `
                    -BackupName "Main" `
                    -TempArchivePath $MainArchiveTempPath `
                    -FinalArchivePath $MainFinalArchivePath `
                    -InternalHashFileName $MainHashFileName
                
                $backupResults.Main = $mainResult
            }
            
            # Обработка 3D бэкапа
            if ($ThreeDFolders.Count -gt 0) {
                $threeDResult = Process-Backup -SourceFolders $ThreeDFolders `
                    -BackupName "3D" `
                    -TempArchivePath $ThreeDArchiveTempPath `
                    -FinalArchivePath $ThreeDFinalArchivePath `
                    -InternalHashFileName $ThreeDHashFileName
                
                $backupResults.ThreeD = $threeDResult
            }
        }
    }
    
    # Move log file
    if (Test-Path "$env:TEMP\backup-temp.log") {
        Move-Item -Path "$env:TEMP\backup-temp.log" -Destination $LogDestPath -Force -ErrorAction SilentlyContinue
    }
    
    # Display summary
    Write-Host "`n" + ("╔" + ("═"*68) + "╗") -ForegroundColor White
    Write-Host "║ ИТОГИ БЭКАПА / BACKUP SUMMARY" -ForegroundColor White
    Write-Host ("╠" + ("═"*68) + "╣") -ForegroundColor White
    
    $totalSize = 0
    $totalFiles = 0
    $successfulBackups = 0
    $totalBackups = 0
    
    if ($backupResults.Main -ne $null) {
        $totalBackups++
        if ($backupResults.Main.Success) {
            $successfulBackups++
            $totalSize += $backupResults.Main.ArchiveSize
            $totalFiles += $backupResults.Main.FileCount
        }
    }
    
    if ($backupResults.ThreeD -ne $null) {
        $totalBackups++
        if ($backupResults.ThreeD.Success) {
            $successfulBackups++
            $totalSize += $backupResults.ThreeD.ArchiveSize
            $totalFiles += $backupResults.ThreeD.FileCount
        }
    }
    
    # Итоговый статус
    Write-Host "║ " -NoNewline -ForegroundColor White
    if ($successfulBackups -eq 0) {
        Write-Host "Статус: " -NoNewline -ForegroundColor Gray
        Write-Host "Бэкапы не созданы" -ForegroundColor Yellow -NoNewline
        Write-Host " | " -NoNewline -ForegroundColor White
        Write-Host "Status: " -NoNewline -ForegroundColor Gray
        Write-Host "No backups created" -ForegroundColor Yellow
    } elseif ($successfulBackups -eq $totalBackups) {
        Write-Host "Статус: " -NoNewline -ForegroundColor Gray
        Write-Host "Все бэкапы успешны" -ForegroundColor Green -NoNewline
        Write-Host " | " -NoNewline -ForegroundColor White
        Write-Host "Status: " -NoNewline -ForegroundColor Gray
        Write-Host "All backups successful" -ForegroundColor Green
    } else {
        Write-Host "Статус: " -NoNewline -ForegroundColor Gray
        Write-Host "Бэкапы с предупреждениями" -ForegroundColor Yellow -NoNewline
        Write-Host " | " -NoNewline -ForegroundColor White
        Write-Host "Status: " -NoNewline -ForegroundColor Gray
        Write-Host "Backups with warnings" -ForegroundColor Yellow
    }
    
    Write-Host "║ " -NoNewline -ForegroundColor White
    Write-Host "Успешно: " -NoNewline -ForegroundColor Gray
    Write-Host "$successfulBackups/$totalBackups" -ForegroundColor $(if($successfulBackups -eq $totalBackups){'Green'}else{'Yellow'}) -NoNewline
    Write-Host " | " -NoNewline -ForegroundColor White
    Write-Host "Successful: " -NoNewline -ForegroundColor Gray
    Write-Host "$successfulBackups/$totalBackups" -ForegroundColor $(if($successfulBackups -eq $totalBackups){'Green'}else{'Yellow'})
    
    if ($totalSize -gt 0) {
        Write-Host "║ " -NoNewline -ForegroundColor White
        Write-Host "Общий размер: " -NoNewline -ForegroundColor Gray
        Write-Host "$(Get-FileSizeHuman $totalSize)" -ForegroundColor White -NoNewline
        Write-Host " | " -NoNewline -ForegroundColor White
        Write-Host "Total size: " -NoNewline -ForegroundColor Gray
        Write-Host "$(Get-FileSizeHuman $totalSize)" -ForegroundColor White
    }
    
    if ($totalFiles -gt 0) {
        Write-Host "║ " -NoNewline -ForegroundColor White
        Write-Host "Всего файлов: " -NoNewline -ForegroundColor Gray
        Write-Host "$totalFiles" -ForegroundColor White -NoNewline
        Write-Host " | " -NoNewline -ForegroundColor White
        Write-Host "Total files: " -NoNewline -ForegroundColor Gray
        Write-Host "$totalFiles" -ForegroundColor White
    }
    
    Write-Host "║ " -NoNewline -ForegroundColor White
    Write-Host "Папка: " -NoNewline -ForegroundColor Gray
    Write-Host "$DestinationPath" -ForegroundColor Cyan -NoNewline
    Write-Host " | " -NoNewline -ForegroundColor White
    Write-Host "Folder: " -NoNewline -ForegroundColor Gray
    Write-Host "$DestinationPath" -ForegroundColor Cyan
    
    Write-Host "║ " -NoNewline -ForegroundColor White
    Write-Host "Лог: " -NoNewline -ForegroundColor Gray
    Write-Host "$LogDestPath" -ForegroundColor Cyan -NoNewline
    Write-Host " | " -NoNewline -ForegroundColor White
    Write-Host "Log: " -NoNewline -ForegroundColor Gray
    Write-Host "$LogDestPath" -ForegroundColor Cyan
    
    Write-Host ("╚" + ("═"*68) + "╝") -ForegroundColor White
    
    # Cleanup
    Remove-Checkpoint
    
} catch {
    Write-Status -MessageEn "FATAL ERROR: $($_.Exception.Message)" `
                 -MessageRu "ФАТАЛЬНАЯ ОШИБКА: $($_.Exception.Message)" -Level "ERROR"
    
    # Try to save log
    if (Test-Path "$env:TEMP\backup-temp.log") {
        try {
            Move-Item -Path "$env:TEMP\backup-temp.log" -Destination $LogDestPath -Force -ErrorAction SilentlyContinue
        } catch { }
    }
    
    Write-Host "`n" + ("╔" + ("═"*68) + "╗") -ForegroundColor Red
    Write-Host "║ ❌ БЭКАП НЕ УДАЛСЯ / BACKUP FAILED" -ForegroundColor Red
    Write-Host ("╠" + ("═"*68) + "╣") -ForegroundColor Red
    Write-Host "║ Ошибка: $($_.Exception.Message)" -ForegroundColor White
    Write-Host "║ Лог: $LogDestPath" -ForegroundColor White
    Write-Host ("╚" + ("═"*68) + "╝") -ForegroundColor Red
    
    throw
} finally {
    # Clean up temp files
    $tempFiles = @($MainArchiveTempPath, $ThreeDArchiveTempPath, 
                   "$env:TEMP\backup-temp.log", $CheckpointFile)
    foreach ($tempFile in $tempFiles) {
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    
    Write-Host "`nНажмите Enter для выхода..." -ForegroundColor Gray
    Write-Host "Press Enter to exit..." -ForegroundColor Gray
    Read-Host | Out-Null
}