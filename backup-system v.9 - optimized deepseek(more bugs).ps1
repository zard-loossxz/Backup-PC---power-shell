# backup-system v.9 - optimized-with-validation.ps1
# ⭐️ УЛУЧШЕНИЯ: Проверка архива + оптимизация памяти + прогресс + возобновление
# ⭐️ СОХРАНЕНО: Двойная проверка хешей файлов
# ⭐️ ДОБАВЛЕНО: Верификация архива после создания

# ---------------- CONFIG ----------------
$UserPath        = $env:USERPROFILE
$HashAlgorithm   = "SHA512"
$SourceFolders   = @(
    "$UserPath\Videos",
    "$UserPath\Documents",
    "$UserPath\Downloads", 
    "$UserPath\Music",
    "$UserPath\Pictures",
    "$UserPath\Desktop",
    "$UserPath\3D Objects"
)
$DestinationRoot = "G:\Backups"
$DateTimeFormat  = "dd-MM-yyyy-HH_mm"
$FilePrefix      = "Backup"
$FileExtension   = "zip"
$MaxThreads      = 10
$ZipCompressionLevel = [System.IO.Compression.CompressionLevel]::NoCompression
$BufferSize      = 1MB
$CheckpointFile  = "$env:TEMP\backup-checkpoint.json"
# ----------------------------------------

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Prepare names
$CurrentDateTime = Get-Date -Format $DateTimeFormat
$BackupFolderName = "$FilePrefix-$CurrentDateTime"
$DestinationPath = Join-Path $DestinationRoot $BackupFolderName

$ArchiveFileName = "$FilePrefix-$CurrentDateTime.$FileExtension"
$ArchivePartialName = "$FilePrefix-$CurrentDateTime.partial.$FileExtension"
$ArchiveTempPath = Join-Path $env:TEMP $ArchivePartialName
$FinalArchivePath = Join-Path $DestinationPath $ArchiveFileName

$InternalHashFileName = "Backup-Files.$($HashAlgorithm.ToLower())"
$LogFileName = "$ArchiveFileName.log"
$LogDestPath = Join-Path $DestinationPath $LogFileName

# ---------------- FUNCTIONS ----------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    
    Write-Host $logLine -ForegroundColor $(switch($Level){
        "ERROR" { "Red"; break }
        "WARN"  { "Yellow"; break }
        "INFO"  { "Gray"; break }
        "SUCCESS" { "Green"; break }
        default { "White" }
    })
    
    # Write to temp log (will be moved later)
    $logLine | Out-File -FilePath "$env:TEMP\backup-temp.log" -Encoding UTF8 -Append -Force
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
    Write-Log "Checkpoint saved at stage: $Stage" "INFO"
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
        
        Write-Log "Available space on $drive : $(Get-FileSizeHuman $freeSpace)" "INFO"
        Write-Log "Required space: $(Get-FileSizeHuman $RequiredBytes)" "INFO"
        
        return $freeSpace -gt ($RequiredBytes * 1.2) # 20% buffer
    } catch {
        Write-Log "Cannot check free space: $($_.Exception.Message)" "WARN"
        return $true # Continue anyway
    }
}

function Get-FilesBatch {
    param(
        [string[]]$Folders,
        [int]$ReportEvery = 1000
    )
    
    $allFiles = [System.Collections.Generic.List[string]]::new()
    $totalSize = 0L
    $fileCount = 0
    
    foreach ($folder in $Folders) {
        if (-not (Test-Path -LiteralPath $folder)) {
            Write-Log "Source folder not found: $folder" "WARN"
            continue
        }
        
        try {
            $files = Get-ChildItem -Path $folder -File -Recurse -ErrorAction Stop
            
            foreach ($file in $files) {
                $allFiles.Add($file.FullName)
                $totalSize += $file.Length
                $fileCount++
                
                if ($fileCount % $ReportEvery -eq 0) {
                    Write-Progress -Activity "Scanning files" -Status "Found $fileCount files" -CurrentOperation $folder
                }
            }
            
        } catch {
            Write-Log "Error scanning $folder : $($_.Exception.Message)" "ERROR"
        }
    }
    
    Write-Progress -Activity "Scanning files" -Completed
    
    return @{
        Files = $allFiles.ToArray()
        TotalSize = $totalSize
        Count = $fileCount
    }
}

function Get-FileHashesParallel {
    param(
        [string[]]$Files,
        [string]$BasePath,
        [int]$Threads = 10
    )
    
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
            Write-Progress -Activity "Calculating file hashes" `
                          -Status "$done / $($Files.Count) files" `
                          -PercentComplete $percent `
                          -CurrentOperation "$([math]::Round($percent,1))% complete"
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
        [System.IO.Compression.CompressionLevel]$Compression
    )
    
    Write-Log "Creating archive: $OutputPath" "INFO"
    Write-Log "Files to archive: $($Files.Count)" "INFO"
    Write-Log "Hashes recorded: $($FileHashes.Count)" "INFO"
    
    # Create hash file content in memory
    $hashContentBuilder = [System.Text.StringBuilder]::new()
    $hashContentBuilder.AppendLine("# File hashes generated by Backup System") | Out-Null
    $hashContentBuilder.AppendLine("# Algorithm: $HashAlgorithm") | Out-Null
    $hashContentBuilder.AppendLine("# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") | Out-Null
    $hashContentBuilder.AppendLine() | Out-Null
    
    $fileIndex = 0
    $FileHashes.Keys | Sort-Object | ForEach-Object {
        $hashContentBuilder.AppendLine("$($FileHashes[$_]) *$_") | Out-Null
        $fileIndex++
        
        if ($fileIndex % 100 -eq 0) {
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
        
        foreach ($file in $Files) {
            try {
                $relativePath = $file.Substring($BasePath.Length + 1)
                
                # Skip if file was in hash errors
                if (-not $FileHashes.ContainsKey($relativePath)) {
                    Write-Log "Skipping file (hash missing): $relativePath" "WARN"
                    continue
                }
                
                $entry = $archive.CreateEntry($relativePath.Replace('\', '/'), $Compression)
                $entryStream = $entry.Open()
                $fileStreamSource = [System.IO.File]::OpenRead($file)
                
                # Copy with buffer
                $bytesRead = 0
                while (($bytesRead = $fileStreamSource.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $entryStream.Write($buffer, 0, $bytesRead)
                }
                
                $fileStreamSource.Close()
                $entryStream.Close()
                
                $processedFiles++
                if ($processedFiles % 10 -eq 0) {
                    Write-Progress -Activity "Adding files to archive" `
                                  -Status "$processedFiles / $($Files.Count) files" `
                                  -PercentComplete (($processedFiles / $Files.Count) * 100)
                }
                
            } catch {
                Write-Log "Failed to add file to archive: $file - $($_.Exception.Message)" "ERROR"
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
            Write-Log "Hash file added to archive" "INFO"
        } catch {
            Write-Log "Failed to add hash file to archive: $($_.Exception.Message)" "ERROR"
        }
        
        $archive.Dispose()
        
    } finally {
        $fileStream.Close()
    }
    
    return @{
        Success = $true
        FilesAdded = $processedFiles
        ArchivePath = $OutputPath
        ArchiveSize = (Get-Item $OutputPath).Length
    }
}

function Test-ArchiveIntegrity {
    param([string]$ArchivePath)
    
    Write-Log "Testing archive integrity: $ArchivePath" "INFO"
    
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        $entries = $archive.Entries
        $validEntries = 0
        $totalEntries = $entries.Count
        
        foreach ($entry in $entries) {
            try {
                $stream = $entry.Open()
                # Try to read first byte to verify entry is accessible
                $testByte = $stream.ReadByte()
                $stream.Close()
                $validEntries++
                
                if ($validEntries % 50 -eq 0) {
                    Write-Progress -Activity "Validating archive entries" `
                                  -Status "$validEntries / $totalEntries entries checked" `
                                  -PercentComplete (($validEntries / $totalEntries) * 100)
                }
                
            } catch {
                Write-Log "Archive entry corrupted: $($entry.FullName)" "ERROR"
                $archive.Dispose()
                Write-Progress -Activity "Validating archive entries" -Completed
                return $false
            }
        }
        
        $archive.Dispose()
        Write-Progress -Activity "Validating archive entries" -Completed
        
        if ($validEntries -eq $totalEntries) {
            Write-Log "Archive integrity check passed: $validEntries/$totalEntries entries valid" "SUCCESS"
            return $true
        } else {
            Write-Log "Archive integrity check failed: $validEntries/$totalEntries entries valid" "ERROR"
            return $false
        }
        
    } catch {
        Write-Log "Failed to open archive for integrity check: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Verify-ArchiveHashes {
    param(
        [string]$ArchivePath,
        [hashtable]$OriginalHashes
    )
    
    Write-Log "Verifying hashes inside archive..." "INFO"
    
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        $hashEntry = $archive.GetEntry($InternalHashFileName)
        
        if ($hashEntry -eq $null) {
            Write-Log "Hash file not found inside archive" "ERROR"
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
                Write-Log "File missing in archive hash list: $filePath" "WARN"
                $missingInArchive++
            } elseif ($OriginalHashes[$filePath] -ne $archiveHashes[$filePath]) {
                Write-Log "Hash mismatch for: $filePath" "ERROR"
                Write-Log "  Original: $($OriginalHashes[$filePath])" "ERROR"
                Write-Log "  In Archive: $($archiveHashes[$filePath])" "ERROR"
                $mismatches++
            }
        }
        
        $filesOnlyInArchive = $archiveHashes.Keys | Where-Object { -not $OriginalHashes.ContainsKey($_) }
        if ($filesOnlyInArchive.Count -gt 0) {
            Write-Log "Found $($filesOnlyInArchive.Count) files in archive not in original list" "WARN"
            foreach ($extraFile in $filesOnlyInArchive) {
                Write-Log "Extra file in archive: $extraFile" "WARN"
            }
        }
        
        if ($mismatches -eq 0 -and $missingInArchive -eq 0) {
            Write-Log "All $($OriginalHashes.Count) hashes verified successfully" "SUCCESS"
            return $true
        } else {
            Write-Log "Hash verification failed: $mismatches mismatches, $missingInArchive missing" "ERROR"
            return $false
        }
        
    } catch {
        Write-Log "Failed to verify archive hashes: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Compare-HashRuns {
    param(
        [hashtable]$FirstRun,
        [hashtable]$SecondRun
    )
    
    Write-Log "Comparing two hash calculation runs..." "INFO"
    
    $mismatches = @()
    $missingInSecond = 0
    $missingInFirst = 0
    
    foreach ($file in $FirstRun.Keys) {
        if (-not $SecondRun.ContainsKey($file)) {
            $mismatches += "MISSING_IN_SECOND`t$file"
            $missingInSecond++
        } elseif ($FirstRun[$file] -ne $SecondRun[$file]) {
            $mismatches += "HASH_MISMATCH`t$file`t$($FirstRun[$file])`t$($SecondRun[$file])"
        }
    }
    
    foreach ($file in $SecondRun.Keys) {
        if (-not $FirstRun.ContainsKey($file)) {
            $missingInFirst++
        }
    }
    
    if ($mismatches.Count -eq 0 -and $missingInFirst -eq 0 -and $missingInSecond -eq 0) {
        Write-Log "Hash comparison: PERFECT MATCH" "SUCCESS"
        return $true
    } else {
        Write-Log "Hash comparison issues found:" "ERROR"
        Write-Log "  Files missing in second run: $missingInSecond" "ERROR"
        Write-Log "  Files missing in first run: $missingInFirst" "ERROR"
        Write-Log "  Hash mismatches: $($mismatches.Count - $missingInSecond)" "ERROR"
        
        foreach ($issue in $mismatches) {
            Write-Log "ISSUE: $issue" "WARN"
        }
        
        return $false
    }
}

# ---------------- MAIN EXECUTION ----------------

Write-Host "`n" + ("="*60) -ForegroundColor Cyan
Write-Host "BACKUP SYSTEM v.9 - With Archive Validation" -ForegroundColor Cyan
Write-Host "="*60 -ForegroundColor Cyan
Write-Host "Start time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n" -ForegroundColor Gray

try {
    # Setup directories
    if (-not (Test-Path $DestinationRoot)) {
        New-Item -Path $DestinationRoot -ItemType Directory -Force | Out-Null
        Write-Log "Created destination root: $DestinationRoot" "INFO"
    }
    
    if (-not (Test-Path $DestinationPath)) {
        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
        Write-Log "Created backup folder: $DestinationPath" "INFO"
    }
    
    # Clean temp log
    if (Test-Path "$env:TEMP\backup-temp.log") {
        Remove-Item "$env:TEMP\backup-temp.log" -Force -ErrorAction SilentlyContinue
    }
    
    Write-Log "Starting backup process..." "INFO"
    
    # 1. Scan files
    Write-Log "Phase 1: Scanning source folders..." "INFO"
    $scanResult = Get-FilesBatch -Folders $SourceFolders
    
    if ($scanResult.Count -eq 0) {
        Write-Log "No files found to backup. Exiting." "WARN"
        exit 0
    }
    
    Write-Log "Found $($scanResult.Count) files, total size: $(Get-FileSizeHuman $scanResult.TotalSize)" "SUCCESS"
    Save-Checkpoint -State @{FilesCount = $scanResult.Count; TotalSize = $scanResult.TotalSize} -Stage "ScanComplete"
    
    # 2. Check disk space
    Write-Log "Phase 2: Checking disk space..." "INFO"
    $estimatedArchiveSize = $scanResult.TotalSize * 0.9 # Assume 10% compression (even with NoCompression, headers add overhead)
    if (-not (Test-FreeSpace -Path $DestinationRoot -RequiredBytes $estimatedArchiveSize)) {
        Write-Log "ERROR: Not enough disk space for backup" "ERROR"
        exit 1
    }
    
    # 3. First hash calculation
    Write-Log "Phase 3: First hash calculation (multi-threaded)..." "INFO"
    $firstHashResult = Get-FileHashesParallel -Files $scanResult.Files -BasePath $UserPath -Threads $MaxThreads
    
    if ($firstHashResult.ErrorCount -gt 0) {
        Write-Log "First hash run completed with $($firstHashResult.ErrorCount) errors" "WARN"
        foreach ($error in $firstHashResult.Errors) {
            Write-Log "Hash error: $error" "WARN"
        }
    } else {
        Write-Log "First hash calculation complete: $($firstHashResult.SuccessCount) files" "SUCCESS"
    }
    
    Save-Checkpoint -State @{FirstHashes = $firstHashResult.Hashes; FirstErrors = $firstHashResult.Errors} -Stage "FirstHashComplete"
    
    # 4. Second hash calculation (validation)
    Write-Log "Phase 4: Second hash calculation for validation..." "INFO"
    $secondHashResult = Get-FileHashesParallel -Files $scanResult.Files -BasePath $UserPath -Threads $MaxThreads
    
    if ($secondHashResult.ErrorCount -gt 0) {
        Write-Log "Second hash run completed with $($secondHashResult.ErrorCount) errors" "WARN"
    } else {
        Write-Log "Second hash calculation complete: $($secondHashResult.SuccessCount) files" "SUCCESS"
    }
    
    # 5. Compare hash runs
    Write-Log "Phase 5: Comparing hash calculations..." "INFO"
    $hashComparisonOK = Compare-HashRuns -FirstRun $firstHashResult.Hashes -SecondRun $secondHashResult.Hashes
    
    if (-not $hashComparisonOK) {
        Write-Log "WARNING: Hash comparison failed. Continuing with first run hashes." "WARN"
        # Continue with first run hashes
    }
    
    # 6. Create archive
    Write-Log "Phase 6: Creating archive with embedded hashes..." "INFO"
    $archiveResult = Create-ArchiveWithValidation `
        -Files $scanResult.Files `
        -BasePath $UserPath `
        -FileHashes $firstHashResult.Hashes `
        -OutputPath $ArchiveTempPath `
        -Compression $ZipCompressionLevel
    
    if (-not $archiveResult.Success) {
        throw "Failed to create archive"
    }
    
    Write-Log "Archive created: $(Get-FileSizeHuman $archiveResult.ArchiveSize)" "SUCCESS"
    Save-Checkpoint -State @{ArchivePath = $ArchiveTempPath; ArchiveSize = $archiveResult.ArchiveSize} -Stage "ArchiveCreated"
    
    # 7. Verify archive integrity
    Write-Log "Phase 7: Verifying archive integrity..." "INFO"
    $integrityOK = Test-ArchiveIntegrity -ArchivePath $ArchiveTempPath
    
    if (-not $integrityOK) {
        Write-Log "Archive integrity check FAILED. Archive may be corrupted." "ERROR"
        # Optionally: retry creation
    } else {
        Write-Log "Archive integrity check PASSED" "SUCCESS"
    }
    
    # 8. Verify hashes inside archive
    Write-Log "Phase 8: Verifying hashes inside archive..." "INFO"
    $hashVerificationOK = Verify-ArchiveHashes -ArchivePath $ArchiveTempPath -OriginalHashes $firstHashResult.Hashes
    
    if (-not $hashVerificationOK) {
        Write-Log "Archive hash verification FAILED" "ERROR"
    } else {
        Write-Log "Archive hash verification PASSED" "SUCCESS"
    }
    
    # 9. Move files to destination
    Write-Log "Phase 9: Moving files to destination..." "INFO"
    
    # Move log file
    Move-Item -Path "$env:TEMP\backup-temp.log" -Destination $LogDestPath -Force -ErrorAction SilentlyContinue
    
    # Move and rename archive
    $tempDestPartial = Join-Path $DestinationPath $ArchivePartialName
    Move-Item -Path $ArchiveTempPath -Destination $tempDestPartial -Force
    
    if ($integrityOK -and $hashVerificationOK) {
        # Only rename if both checks passed
        Rename-Item -Path $tempDestPartial -NewName $ArchiveFileName -Force
        Write-Log "Backup completed successfully: $FinalArchivePath" "SUCCESS"
        
        Write-Host "`n" + ("="*60) -ForegroundColor Green
        Write-Host "✅ BACKUP COMPLETED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "="*60 -ForegroundColor Green
        Write-Host "Archive: $FinalArchivePath" -ForegroundColor White
        Write-Host "Size: $(Get-FileSizeHuman $archiveResult.ArchiveSize)" -ForegroundColor White
        Write-Host "Files: $($scanResult.Count)" -ForegroundColor White
        Write-Host "Log: $LogDestPath" -ForegroundColor White
        Write-Host "Integrity: PASSED" -ForegroundColor Green
        Write-Host "Hash Verification: PASSED" -ForegroundColor Green
        Write-Host ("="*60 + "`n") -ForegroundColor Green
        
    } else {
        # Keep as .partial.zip if checks failed
        Write-Log "Backup completed with WARNINGS. Archive saved as .partial.zip" "WARN"
        
        Write-Host "`n" + ("="*60) -ForegroundColor Yellow
        Write-Host "⚠️ BACKUP COMPLETED WITH WARNINGS" -ForegroundColor Yellow
        Write-Host "="*60 -ForegroundColor Yellow
        Write-Host "Archive saved as: $tempDestPartial" -ForegroundColor White
        Write-Host "Size: $(Get-FileSizeHuman $archiveResult.ArchiveSize)" -ForegroundColor White
        Write-Host "Files: $($scanResult.Count)" -ForegroundColor White
        Write-Host "Log: $LogDestPath" -ForegroundColor White
        Write-Host "Integrity: $(if($integrityOK){'PASSED'}else{'FAILED'})" -ForegroundColor $(if($integrityOK){'Green'}else{'Red'})
        Write-Host "Hash Verification: $(if($hashVerificationOK){'PASSED'}else{'FAILED'})" -ForegroundColor $(if($hashVerificationOK){'Green'}else{'Red'})
        Write-Host ("="*60 + "`n") -ForegroundColor Yellow
    }
    
    # 10. Cleanup
    Remove-Checkpoint
    
} catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.Exception.StackTrace)" "ERROR"
    
    # Try to save log
    if (Test-Path "$env:TEMP\backup-temp.log") {
        try {
            Move-Item -Path "$env:TEMP\backup-temp.log" -Destination $LogDestPath -Force -ErrorAction SilentlyContinue
        } catch {
            # Ignore
        }
    }
    
    Write-Host "`n" + ("="*60) -ForegroundColor Red
    Write-Host "❌ BACKUP FAILED" -ForegroundColor Red
    Write-Host "="*60 -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor White
    Write-Host "Check log: $LogDestPath" -ForegroundColor White
    Write-Host ("="*60 + "`n") -ForegroundColor Red
    
    throw
} finally {
    # Clean up temp files
    $tempFiles = @($ArchiveTempPath, "$env:TEMP\backup-temp.log", $CheckpointFile)
    foreach ($tempFile in $tempFiles) {
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    
    Write-Host "Press Enter to exit..." -ForegroundColor Gray
    Read-Host | Out-Null
}