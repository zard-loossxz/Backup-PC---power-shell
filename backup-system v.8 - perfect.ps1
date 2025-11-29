# improved-backup.ps1 (v.8 - Fixed Wildcard Path Issue)
# ⭐️ ИСПРАВЛЕНИЕ: Добавлен -LiteralPath для корректной обработки путей с [ ]
# ⭐️ Исправлен Hash Error ($BufferSize scope)
# ⭐️ Надежность: Двойной проход хеширования файлов
# ⭐️ Оптимизация: 1MB Buffer, Runspace Reuse, Единое сканирование

# ---------------- CONFIG ----------------

$UserPath        = $env:USERPROFILE
$HashAlgorithm   = "SHA512"
# Список папок, которые нужно архивировать
$SourceFolders   = @(
    "$UserPath\Videos",
    "$UserPath\Documents",
    "$UserPath\Downloads",
    "$UserPath\Music",
    "$UserPath\Pictures",
    "$UserPath\Desktop",
    "$UserPath\3D Objects"
)
$DestinationRoot = "G:\Backups"    # <-- КОРНЕВАЯ папка для всех бэкапов
$DateTimeFormat  = "dd-MM-yyyy-HH_mm"
$FilePrefix      = "Backup"
$FileExtension   = "zip"
$MaxThreads      = 10              # <-- Максимальное количество потоков для хеширования
# Уровень сжатия: NoCompression для МАКСИМАЛЬНОЙ СКОРОСТИ
$ZipCompressionLevel = [System.IO.Compression.CompressionLevel]::NoCompression 
# ⭐️ Оптимизированный размер буфера чтения/записи (1MB)
$BufferSize = 1MB 
# ----------------------------------------

# --- Загрузка необходимых сборок ---
Add-Type -AssemblyName System.Management.Automation
Add-Type -AssemblyName System.Collections.Concurrent
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Prepare names
$CurrentDateTime = Get-Date -Format $DateTimeFormat
$BackupFolderName = "$FilePrefix-$CurrentDateTime"
$DestinationPath = Join-Path $DestinationRoot $BackupFolderName

$ArchiveFileName = "$FilePrefix-$CurrentDateTime.$FileExtension"
$ArchivePartialName = "$FilePrefix-$CurrentDateTime.partial.$FileExtension"
$ArchiveTempPath = Join-Path $env:TEMP $ArchivePartialName
$tempDestPartial = Join-Path $DestinationPath $ArchivePartialName 
$FinalArchivePath = Join-Path $DestinationPath $ArchiveFileName

$InternalHashFileName = "Backup-Files.$($HashAlgorithm.ToLower())"
$InternalHashTempPath = Join-Path $env:TEMP $InternalHashFileName

$LogFileName = "$ArchiveFileName.log"
$LogTempPath = Join-Path $env:TEMP $LogFileName
$LogDestPath = Join-Path $DestinationPath $LogFileName

# ---------------- FUNCTIONS ----------------

function Log {
    param([string]$msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    $line | Out-File -FilePath $LogTempPath -Encoding UTF8 -Append -Force
}

function Add-FileToZipEntry {
    param(
        [System.IO.Compression.ZipArchive]$ZipArchive,
        [string]$FilePath,
        [string]$EntryName,
        [System.IO.Compression.CompressionLevel]$CompressionLevel
    )
    
    $fileStream = $null
    $entryStream = $null
    try {
        $entry = $ZipArchive.CreateEntry($EntryName, $CompressionLevel)
        
        $fileStream = [System.IO.File]::OpenRead($FilePath)
        $entryStream = $entry.Open()
        
        # Manual copy 
        $buffer = New-Object byte[] $BufferSize
        $read = 0
        while (($read = $fileStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $entryStream.Write($buffer, 0, $read)
        }
        
    } catch {
        throw
    } finally {
        if ($entryStream -ne $null) { $entryStream.Close(); $entryStream.Dispose() }
        if ($fileStream -ne $null) { $fileStream.Close(); $fileStream.Dispose() }
    }
}


function Create-ZipInMemory {
    param(
        [string[]]$allFiles,
        [string]$basePath,
        [string]$zipPath,
        [string]$internalHashContent,  # ⭐️ Теперь принимаем строку вместо пути к файлу
        [System.IO.Compression.CompressionLevel]$CompressionLevel
    )
    
    Log "ARCHIVE: Создание архива в памяти: $zipPath"
    
    $zipDir = [System.IO.Path]::GetDirectoryName($zipPath)
    if (-not (Test-Path $zipDir)) { 
        New-Item -ItemType Directory -Path $zipDir -Force | Out-Null 
    }

    $mode = [System.IO.Compression.ZipArchiveMode]::Create
    # ⭐️ Прямая запись на диск - только ОДНА операция записи
    $fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create)
    
    try {
        $za = New-Object System.IO.Compression.ZipArchive($fs, $mode, $false)
        
        foreach ($file in $allFiles) {
            
            # ⭐️ ИСПРАВЛЕНИЕ: Использование -LiteralPath для Test-Path
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or $file.Length -le $basePath.Length) {
                Log "WARN: Пропускаем файл (не найден или путь некорректен): $file"
                continue
            }

            $relative = $file.Substring($basePath.Length + 1)
            $entryName = $relative -replace '\\','/'
            
            try {
                # ⭐️ Прямое добавление файла в архив (без временных файлов)
                $entry = $za.CreateEntry($entryName, $CompressionLevel)
                $entryStream = $entry.Open()
                $fileStream = [System.IO.File]::OpenRead($file)
                
                # ⭐️ Оптимизированное копирование с буфером
                $buffer = New-Object byte[] $BufferSize
                $read = 0
                while (($read = $fileStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $entryStream.Write($buffer, 0, $read)
                }
                
                $fileStream.Close()
                $entryStream.Close()
                
            } catch {
                Log "ERROR: Не удалось добавить в архив: $file -> $($_.Exception.Message)"
            }
        }
        
        # ⭐️ Добавляем хеш-файл ИЗ ПАМЯТИ (без записи на диск)
        if ($internalHashContent) {
            $entryName = $InternalHashFileName
            try {
                $hashEntry = $za.CreateEntry($entryName, $CompressionLevel)
                $hashStream = $hashEntry.Open()
                $hashBytes = [System.Text.Encoding]::UTF8.GetBytes($internalHashContent)
                $hashStream.Write($hashBytes, 0, $hashBytes.Length)
                $hashStream.Close()
                Log "INTERNAL: Хеш-файл добавлен в архив из памяти"
            } catch {
                Log "ERROR: Не удалось добавить внутренний файл хешей в архив: $($_.Exception.Message)"
            }
        } else {
            Log "WARN: Внутренний файл хешей пуст - не будет включён в архив."
        }
        
        $za.Dispose()
    } finally {
        $fs.Close()
    }
}

function Get-AllFileHashesParallel {
    param(
        [string[]]$allFiles,
        [string]$basePath,
        [System.Management.Automation.Runspaces.RunspacePool]$runspacePool
    )

    Log "Найдено файлов для хеширования: $($allFiles.Length)"
    
    $concurrentHashes = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new()
    $processedCount = [System.Collections.Concurrent.ConcurrentQueue[int]]::new()

    # Сортируем файлы по размеру (большие вперед) для балансировки нагрузки
    $fileQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $allFiles | ForEach-Object { $fileQueue.Enqueue($_) }

    $scriptBlock = {
        param($queue, $results, $counter, $basePath, $hashAlgorithm)
        
        # Создание объекта хеширования
        if ($hashAlgorithm -eq "SHA512") {
            $sha = [System.Security.Cryptography.SHA512]::Create()
        } else {
            $sha = [System.Security.Cryptography.SHA256]::Create()
        }
        
        $buffer = New-Object byte[] (128KB)
        $path = $null
        
        while ($queue.TryDequeue([ref]$path)) {
            try {
                $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                
                # Хеширование
                while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $sha.TransformBlock($buffer, 0, $read, $buffer, 0) | Out-Null
                }
                $sha.TransformFinalBlock($buffer, 0, 0) | Out-Null
                $hex = [System.BitConverter]::ToString($sha.Hash).Replace("-", "").ToLower()

                $relative = $path.Substring($basePath.Length + 1)
                $results.TryAdd($relative, $hex) | Out-Null
                $fs.Close()
                $sha.Initialize() # Сброс для следующего файла
                $counter.Enqueue(1)
                
            } catch {
                $results.TryAdd($path, "ERROR: $($_.Exception.Message)") | Out-Null
                $counter.Enqueue(1)
            } finally {
                if ($fs -ne $null) { $fs.Dispose() }
            }
        }
        $sha.Dispose()
    }

    $jobs = @()
    for ($i=0; $i -lt $MaxThreads; $i++) {
        $powerShell = [powershell]::Create().AddScript($scriptBlock).AddArgument($fileQueue).AddArgument($concurrentHashes).AddArgument($processedCount).AddArgument($basePath).AddArgument($HashAlgorithm)
        $powerShell.RunspacePool = $runspacePool
        $job = $powerShell.BeginInvoke()
        $jobs += [PSCustomObject]@{
            Job = $job
            PowerShell = $powerShell
        }
    }

    # Прогресс-бар во время хеширования
    Log "Ожидание завершения многопоточного хеширования..."
    while (($fileQueue.Count -gt 0) -or ($jobs.Job.IsCompleted -contains $false)) {
        $done = $processedCount.Count
        if ($allFiles.Length -gt 0) {
            Write-Progress -Activity "Хеширование файлов" -Status "$done / $($allFiles.Length)" -PercentComplete (($done / $allFiles.Length) * 100)
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Progress -Activity "Хеширование файлов" -Completed

    $jobs | ForEach-Object {
        $_.PowerShell.EndInvoke($_.Job) | Out-Null
        $_.PowerShell.Dispose()
    }
    
    Log "Многопоточное хеширование завершено."

    # Разделение результатов на успешные хеши и ошибки
    $results = [System.Collections.Hashtable]::new()
    $errors = @()
    
    $concurrentHashes.GetEnumerator() | ForEach-Object { 
        if ($_.Value -like "ERROR:*") {
            $errors += "$($_.Key)`t$($_.Value)"
        } else {
            $results.Add($_.Key, $_.Value)
        }
    }
    
    return @{
        Hashes = $results;
        Errors = $errors;
        Count = $allFiles.Length
    }
}
# ---------------- MAIN FLOW ----------------

$runspacePool = $null 
$allFilesList = $null 

try {
    # 0) Создание папок и очистка лога
    if (-not (Test-Path -Path $DestinationRoot)) {
        New-Item -Path $DestinationRoot -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -Path $DestinationPath)) {
        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
        Write-Host "`nСоздана папка для файлов бэкапа: $DestinationPath" -ForegroundColor Yellow
    }
    
    if (Test-Path $LogTempPath) { Remove-Item $LogTempPath -Force -ErrorAction SilentlyContinue }
    "`n=== START BACKUP ===`n" | Out-File -FilePath $LogTempPath -Encoding UTF8 -Force

    # 1) Единое сканирование файлов
    Log "SCAN: Сканирование исходных папок..."
    $allFilesList = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $SourceFolders) {
        if (-not (Test-Path $r)) {
            Log "WARN: Исходная папка не найдена и будет пропущена: $r"
            continue
        }
        try {
            Get-ChildItem -Path $r -File -Recurse -ErrorAction Stop |
                ForEach-Object { $allFilesList.Add($_.FullName) }
        } catch {
            Log "ERROR: Ошибка сканирования $r : $($_.Exception.Message)"
        }
    }
    $allFiles = $allFilesList.ToArray()
    Log "SCAN: Всего найдено файлов: $($allFiles.Length)"

    # 2) Создание и открытие пула потоков ОДИН РАЗ
    Log "SETUP: Создание пула потоков ($MaxThreads) для хеширования..."
    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads, $sessionState, $Host)
    $runspacePool.Open()
    
    Log "START: Создание внутреннего файла хешей ($InternalHashFileName) в $MaxThreads потоках (Проход 1)..."

	# 3) Считаем хеши (одним проходом)
	Log "START: Создание внутреннего файла хешей ($InternalHashFileName) в $MaxThreads потоках..."
	$hashResult = Get-AllFileHashesParallel -allFiles $allFiles -basePath $UserPath -runspacePool $runspacePool
	$hashDict = $hashResult.Hashes
	$errorsDuringHashing = $hashResult.Errors


	if ($errorsDuringHashing.Count -gt 0) {
		Log "WARN: Были ошибки при хешировании: $($errorsDuringHashing.Count) файлов."
		foreach ($e in $errorsDuringHashing) { Log "HASH-ERROR: $e" }
	} else {
		Log "Хеширование прошло без ошибок."
	}
    # 4) Валидация — пересчёт хешей и сравнение (Проход 2 - Валидация)
    Log "VALIDATION: Повторный расчёт хешей (Проход 2) для валидации..."
    # Используем ТОТ ЖЕ пул потоков
    $second = Get-AllFileHashesParallel -allFiles $allFiles -basePath $UserPath -runspacePool $runspacePool
    $hashDict2 = $second.Hashes
    $errorsDuringSecond = $second.Errors

    # Сравнение результатов
    $mismatches = @()
    foreach ($key in $hashDict.Keys) {
        $h1 = $hashDict[$key]
        if (-not $hashDict2.ContainsKey($key)) {
            $mismatches += "MISSING_IN_SECOND`t$key"
        } else {
            $h2 = $hashDict2[$key]
            if ($h1 -ne $h2) {
                $mismatches += "HASH_MISMATCH`t$key`t$h1`t$h2"
            }
        }
    }

    if ($mismatches.Count -gt 0 -or $errorsDuringSecond.Count -gt 0) {
        Log "VALIDATION: !!! НАЙДЕНЫ ПРОБЛЕМЫ: $($mismatches.Count) несовпадений хешей, $($errorsDuringSecond.Count) ошибок повторного чтения."
        foreach ($mm in $mismatches) { Log "PROBLEM: $mm" }
        foreach ($e in $errorsDuringSecond) { Log "RE-READ-ERROR: $e" }
        Log "ВНИМАНИЕ: Продолжаем архивацию, но рекомендуется проверить файлы."
    } else {
        Log "VALIDATION: Хеши совпадают (повторная проверка пройдена)."
    }

    # 5) Создаём архив .partial.zip ИЗ ПАМЯТИ
    Log "ARCHIVE: Создание архива (временный): $ArchiveTempPath"
    if (Test-Path $ArchiveTempPath) { Remove-Item $ArchiveTempPath -Force -ErrorAction SilentlyContinue }

    # ⭐️ Создаем хеш-контент в памяти вместо временного файла
    $hashContentBuilder = [System.Text.StringBuilder]::new()
    $hashDict.Keys | Sort-Object | ForEach-Object {
        $key = $_
        $value = $hashDict[$key]
        $hashContentBuilder.AppendLine("$value *$key") | Out-Null
    }
    $hashContent = $hashContentBuilder.ToString()

    # ⭐️ Вызываем новую функцию с передачей хеш-контента как строки
    Create-ZipInMemory -allFiles $allFiles -basePath $UserPath -zipPath $ArchiveTempPath -internalHashContent $hashContent -CompressionLevel $ZipCompressionLevel

    # 6) Перенос .partial.zip и лога в финальную папку
    Log "MOVE: Перемещение файлов в целевую папку: $DestinationPath"
    
    # Перенос архива
    Move-Item -Path $ArchiveTempPath -Destination $tempDestPartial -Force
    # Перенос лога
    Move-Item -Path $LogTempPath -Destination $LogDestPath -Force
    
    Log "MOVE: Файлы перемещены. Финализация..."

    # 7) Переименовать .partial.zip -> .zip (финальное имя)
    $finalPath = Join-Path $DestinationPath $ArchiveFileName
    try {
        Rename-Item -Path $tempDestPartial -NewName $ArchiveFileName -Force
        Log "FINALIZE: Переименован $tempDestPartial -> $finalPath"
        Write-Host "`n✅ Успешно! Файл: $FinalArchivePath" -ForegroundColor Green
    } catch {
        Log "ERROR: Не удалось переименовать частичный архив. Остался как .partial.zip: $($_.Exception.Message)"
        Write-Host "`n⚠️ ВНИМАНИЕ: Не удалось переименовать. Файл остался как $tempDestPartial" -ForegroundColor Yellow
    }


    Log "SUCCESS: Архивация завершена."
    
} catch {
    Log "FATAL ERROR (Общий блок): $($_.Exception.Message)"
    Log "STACK: $($_.Exception.StackTrace)"
    if (Test-Path $LogTempPath) {
        Move-Item -Path $LogTempPath -Destination $LogDestPath -Force -ErrorAction SilentlyContinue
    }
    Write-Error "`nКРИТИЧЕСКАЯ ОШИБКА. См. лог файл: $LogDestPath"
    throw
} finally {
    # Очистка Runspace Pool
    if ($runspacePool -ne $null) {
        Log "CLEANUP: Закрытие пула потоков."
        $runspacePool.Close()
        $runspacePool.Dispose()
    }
    
    Write-Host "`nНажмите Enter для выхода..."
    Read-Host | Out-Null
}