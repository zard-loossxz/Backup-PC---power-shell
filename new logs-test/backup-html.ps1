# backup-system v.17 — HTML-логи, настраиваемая папка логов
# Логи в формате как у FreeFileSync

param (
    [switch]$NoPause
)

# ---------------- CONFIG ----------------
$UserPath          = $env:USERPROFILE
$HashAlgorithm     = "SHA256"

$MainFolders       = @(

    "$UserPath\Desktop"
)

# 👉 МЕНЯЕШЬ ТОЛЬКО ЭТИ СТРОКИ
$DestinationRoot   = "G:\Backups"
$ArchiveFolder     = "G:\Backups\Archive"
$MaxBackups        = 2
$LogFolder         = "G:\Backups\Logs"  # Папка для HTML-логов

$DateTimeFormat    = "yyyy-MM-dd_HH-mm"
$ZipCompression    = [System.IO.Compression.CompressionLevel]::NoCompression
$BufferSize        = 1MB
$InternalHashFile  = "FILES.sha256"
$TempArchiveSuffix = ".tmp-writing"

$SkipPatterns = @(
    'thumbs\.db$', 'desktop\.ini$', '\.DS_Store$',
    '~\$.*\.(doc|docx|xls|xlsx|ppt|pptx)$',
    '\.tmp$', '\.temp$', '\.bak$', '\.old$', '\.lock$'
)

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------------- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ----------------

function ConvertTo-HtmlSafe {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    return $Text -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'",'&#39;'
}

# ---------------- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ----------------
$Global:LogEntries = @()
$Global:StartTime = Get-Date
$Global:HasErrors = $false
$Global:HasWarnings = $false
$Global:ProcessedFiles = 0
$Global:TotalSize = 0

# ---------------- ФУНКЦИИ ЛОГИРОВАНИЯ ----------------

function Add-LogEntry {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Type = "Info"
    )
    
    $Global:LogEntries += [PSCustomObject]@{
        Time = Get-Date -Format "HH:mm:ss"
        Type = $Type
        Message = $Message
    }
    
    if ($Type -eq "Error") { $Global:HasErrors = $true }
    if ($Type -eq "Warning") { $Global:HasWarnings = $true }
}

function Get-LogIcon {
    param([string]$Type)
    
    switch ($Type) {
        "Info"    { "https://freefilesync.org/images/log/msg-info.png" }
        "Success" { "https://freefilesync.org/images/log/result-succes.png" }
        "Warning" { "https://freefilesync.org/images/log/msg-warning.png" }
        "Error"   { "https://freefilesync.org/images/log/msg-error.png" }
    }
}

function Save-HtmlLog {
    param(
        [string]$LogPath,
        [string]$ArchiveName,
        [int]$FileCount,
        [long]$TotalBytes,
        [timespan]$Duration,
        [bool]$HasErrors,
        [bool]$HasWarnings
    )
    
    $dt = Get-Date -Format "dd.MM.yyyy"
    $time = Get-Date -Format "HH:mm:ss"
    $durationStr = "{0:D2}:{1:D2}:{2:D2}" -f $Duration.Hours, $Duration.Minutes, $Duration.Seconds
    
    $sizeKB = [math]::Round($TotalBytes / 1KB, 0)
    $sizeMB = [math]::Round($TotalBytes / 1MB, 2)
    $sizeGB = [math]::Round($TotalBytes / 1GB, 2)
    
    $sizeStr = if ($sizeGB -ge 1) { "$sizeGB ГБ" }
               elseif ($sizeMB -ge 1) { "$sizeMB МБ" }
               else { "$sizeKB КБ" }
    
    # Определяем статус
    if ($HasErrors) {
        $statusText = "Выполнено с ошибками"
        $statusIcon = "https://freefilesync.org/images/log/result-error.png"
        $statusColor = "#ff4444"
    }
    elseif ($HasWarnings) {
        $statusText = "Выполнено с предупреждениями"
        $statusIcon = "https://freefilesync.org/images/log/result-warning.png"
        $statusColor = "#ff9800"
    }
    else {
        $statusText = "Выполнено успешно"
        $statusIcon = "https://freefilesync.org/images/log/result-succes.png"
        $statusColor = "#4CAF50"
    }
    
    # Формируем строки лога
    $logRows = ""
    foreach ($entry in $Global:LogEntries) {
        $icon = Get-LogIcon -Type $entry.Type
        $msg = ConvertTo-HtmlSafe -Text $entry.Message
        $logRows += @"
        <tr>
            <td valign="top">$($entry.Time)</td>
            <td valign="top"><img src="$icon" width="16" height="16" alt="$($entry.Type)"></td>
            <td>$msg</td>
        </tr>

"@
    }
    
    $html = @"
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>[Backup System] $ArchiveName</title>
    <style>
        body {
            font-family: -apple-system, 'Segoe UI', Arial, Tahoma, Helvetica, sans-serif;
            margin: 20px;
            background: #f5f5f5;
        }
        .header {
            margin-bottom: 20px;
        }
        .job-name {
            font-weight: 600;
            color: gray;
            font-size: 1.1em;
        }
        .summary-box {
            margin: 20px 0;
            display: inline-block;
            border-radius: 7px;
            background: #f8f8f8;
            box-shadow: 1px 1px 4px #888;
            overflow: hidden;
        }
        .summary-header {
            background-color: white;
            border-bottom: 1px solid #AAA;
            font-size: larger;
            padding: 10px;
        }
        .summary-header img {
            vertical-align: middle;
        }
        .summary-header span {
            font-weight: 600;
            vertical-align: middle;
            color: $statusColor;
        }
        .summary-table {
            border-spacing: 0;
            margin-left: 10px;
            padding: 5px 10px;
        }
        .summary-table td:nth-child(1) {
            padding-right: 10px;
        }
        .summary-table td:nth-child(2) {
            padding-right: 5px;
        }
        .summary-table img {
            display: block;
        }
        .log-items {
            line-height: 1em;
            border-spacing: 0;
            margin-top: 20px;
            background: white;
            padding: 10px;
            border-radius: 5px;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        }
        .log-items img {
            display: block;
        }
        .log-items td {
            padding-bottom: 0.5em;
            padding-top: 0.3em;
        }
        .log-items td:nth-child(1) {
            padding-right: 10px;
            white-space: nowrap;
            color: #666;
            font-family: 'Consolas', monospace;
        }
        .log-items td:nth-child(2) {
            padding-right: 10px;
        }
        .log-items td:nth-child(3) {
            width: 100%;
        }
        .footer {
            border-top: 1px solid #AAA;
            margin-top: 20px;
            padding-top: 10px;
            font-size: smaller;
            color: #666;
        }
        .footer img {
            vertical-align: middle;
        }
    </style>
</head>
<body>
    <div class="header">
        <span class="job-name">Backup System</span>
        &nbsp;<span style="white-space:nowrap">$dt &nbsp;$time</span>
    </div>

    <div class="summary-box">
        <div class="summary-header">
            <img src="$statusIcon" width="32" height="32" alt="">
            <span>$statusText</span>
        </div>
        <table role="presentation" class="summary-table">
            <tr>
                <td>Архив:</td>
                <td><img src="https://freefilesync.org/images/log/file.png" width="24" height="24" alt=""></td>
                <td><span style="font-weight:600;">$ArchiveName</span></td>
            </tr>
            <tr>
                <td>Элементов обработано:</td>
                <td><img src="https://freefilesync.org/images/log/file.png" width="24" height="24" alt=""></td>
                <td><span style="font-weight:600;">$FileCount</span> ($sizeStr)</td>
            </tr>
            <tr>
                <td>Общее время:</td>
                <td><img src="https://freefilesync.org/images/log/clock.png" width="24" height="24" alt=""></td>
                <td><span style="font-weight:600;">$durationStr</span></td>
            </tr>
        </table>
    </div>

    <table class="log-items">
$logRows
    </table>

    <div class="footer">
        <img src="https://freefilesync.org/images/log/os-windows.png" width="24" height="24" alt="">
        <span>Windows – $env:USERNAME ($env:COMPUTERNAME)</span>
    </div>
</body>
</html>
"@

    $html | Out-File -LiteralPath $LogPath -Encoding UTF8
}

# ---------------- ОСНОВНЫЕ ФУНКЦИИ ----------------

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $symbol = switch ($Level) { "ERROR" {"✗"} "WARN" {"!"} "SUCCESS" {"✓"} default {"·"} }
    $color  = switch ($Level) { "ERROR" {"Red"} "WARN" {"Yellow"} "SUCCESS" {"Green"} default {"Gray"} }
    Write-Host "$symbol $Message" -ForegroundColor $color
}

function Skip-File {
    param([string]$Path)
    foreach ($pattern in $SkipPatterns) {
        if ($Path -match $pattern) { return $true }
    }
    return $false
}

function Get-FilesToBackup {
    param([string[]]$Folders)
    $files = @()
    foreach ($folder in $Folders) {
        if (-not (Test-Path -LiteralPath $folder)) { 
            Add-LogEntry "Папка не найдена: $folder" "Warning"
            continue 
        }
        Get-ChildItem -LiteralPath $folder -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not (Skip-File $_.FullName) } |
            ForEach-Object { $files += $_.FullName }
    }
    return $files
}

function Get-FileHashes {
    param([string[]]$Files, [string]$BasePath)
    
    Write-Status "Вычисляю хеши ($($Files.Count) файлов)..."
    Add-LogEntry "$($Files.Count) файлов найдено для резервного копирования" "Info"
    
    $hashes = @{}
    $i = 0
    $total = $Files.Count
    
    foreach ($file in $Files) {
        $i++
        
        if ($i % 50 -eq 0 -or $i -eq $total) {
            $percent = [math]::Round(($i / $total) * 100, 1)
            Write-Progress -Activity "Вычисление хешей" -Status "Файл $i из $total" -PercentComplete $percent
        }
        
        try {
            $hashObj = Get-FileHash -LiteralPath $file -Algorithm $HashAlgorithm -ErrorAction Stop
            $relPath = $file.Substring($BasePath.Length + 1).Replace('\','/')
            $hashes[$relPath] = $hashObj.Hash.ToLower()
            
            $fileSize = (Get-Item -LiteralPath $file).Length
            $Global:TotalSize += $fileSize
        }
        catch {
            Add-LogEntry "Не удалось вычислить хеш: $file - $($_.Exception.Message)" "Error"
        }
    }
    
    Write-Progress -Activity "Вычисление хешей" -Completed
    Add-LogEntry "Хеширование завершено | Время прошло: $("{0:mm}:{0:ss}" -f (New-TimeSpan -Start $Global:StartTime))" "Info"
    
    return $hashes
}

function Create-Archive {
    param([string[]]$Files, [string]$BasePath, [hashtable]$Hashes, [string]$OutputPath)

    Add-LogEntry "Создание архива: $OutputPath" "Info"
    
    $fs = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        $buffer = New-Object byte[] $BufferSize
        $i = 0
        $total = $Files.Count

        foreach ($file in $Files) {
            $i++
            
            if ($i % 10 -eq 0 -or $i -eq $total) {
                $percent = [math]::Round(($i / $total) * 100, 1)
                Write-Progress -Activity "Создание архива" -Status "Файл $i из $total" -PercentComplete $percent
            }
            
            $relPath = $file.Substring($BasePath.Length + 1).Replace('\','/')
            if (-not $Hashes.ContainsKey($relPath)) { continue }
            
            try {
                $entry = $archive.CreateEntry($relPath, $ZipCompression)
                $es = $entry.Open()
                $fsrc = [System.IO.File]::OpenRead($file)
                while (($read = $fsrc.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $es.Write($buffer, 0, $read)
                }
                $fsrc.Dispose()
                $es.Dispose()
                $Global:ProcessedFiles++
            }
            catch {
                Add-LogEntry "Ошибка добавления в архив: $file - $($_.Exception.Message)" "Error"
            }
        }

        Write-Progress -Activity "Создание архива" -Completed

        # Файл с хешами
        $hashEntry = $archive.CreateEntry($InternalHashFile, $ZipCompression)
        $hs = $hashEntry.Open()
        $text = ($Hashes.Keys | Sort-Object | ForEach-Object { "$($Hashes[$_])  $_" }) -join "`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        $hs.Write($bytes, 0, $bytes.Length)
        $hs.Dispose()

        $archive.Dispose()
        Add-LogEntry "Архив создан успешно: $Global:ProcessedFiles файлов" "Success"
    }
    catch {
        Add-LogEntry "Критическая ошибка создания архива: $($_.Exception.Message)" "Error"
    }
    finally {
        $fs.Dispose()
    }
}

function Test-ArchiveHashes {
    param([string]$ArchivePath, [hashtable]$ExpectedHashes)

    if (-not (Test-Path $ArchivePath)) { return $false }

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        $hashEntry = $zip.GetEntry($InternalHashFile)
        if ($null -eq $hashEntry) {
            $zip.Dispose()
            return $false
        }

        $reader = New-Object System.IO.StreamReader($hashEntry.Open())
        $content = $reader.ReadToEnd()
        $reader.Dispose()
        $zip.Dispose()

        $actual = @{}
        $content -split "`n" | ForEach-Object {
            if ($_ -match '^(?<hash>\S+)\s{2}(?<path>.+)$') {
                $actual[$matches.path.Trim()] = $matches.hash.ToLower()
            }
        }

        $missing = 0; $mismatch = 0
        foreach ($relPath in $ExpectedHashes.Keys) {
            if (-not $actual.ContainsKey($relPath)) { $missing++ }
            elseif ($actual[$relPath] -ne $ExpectedHashes[$relPath]) { $mismatch++ }
        }

        if ($missing -gt 0 -or $mismatch -gt 0) {
            Add-LogEntry "Проверка целостности НЕ ПРОШЛА: $missing отсутствует, $mismatch не совпадают" "Error"
            return $false
        }
        
        Add-LogEntry "Проверка целостности архива пройдена успешно" "Success"
        return $true
    }
    catch {
        Add-LogEntry "Ошибка проверки архива: $($_.Exception.Message)" "Error"
        return $false
    }
}

function Rotate-Backups {
    param([string]$BackupRoot, [string]$ArchiveRoot, [int]$MaxCount)
    
    if (-not (Test-Path $ArchiveRoot)) {
        New-Item -ItemType Directory -Path $ArchiveRoot -Force | Out-Null
        Add-LogEntry "Создана папка архива: $ArchiveRoot" "Info"
    }
    
    $backups = Get-ChildItem -Path $BackupRoot -Filter "Main-*.zip" -File -ErrorAction SilentlyContinue | 
        Sort-Object LastWriteTime -Descending
    
    if ($backups.Count -gt $MaxCount) {
        $toArchive = $backups | Select-Object -Skip $MaxCount
        
        Add-LogEntry "Перемещение $($toArchive.Count) старых бэкапов в архив" "Info"
        
        foreach ($backup in $toArchive) {
            try {
                $destination = Join-Path $ArchiveRoot $backup.Name
                
                if (Test-Path $destination) {
                    $timestamp = Get-Date -Format "HHmmss"
                    $newName = $backup.BaseName + "_moved_$timestamp" + $backup.Extension
                    $destination = Join-Path $ArchiveRoot $newName
                }
                
                Move-Item -LiteralPath $backup.FullName -Destination $destination -Force
                Add-LogEntry "Перемещён в архив: $($backup.Name)" "Info"
            }
            catch {
                Add-LogEntry "Не удалось переместить $($backup.Name): $($_.Exception.Message)" "Error"
            }
        }
    }
}

# ---------------- ОСНОВНОЙ КОД ----------------

Clear-Host

$driveRoot = Split-Path $DestinationRoot -Qualifier
if (-not (Test-Path $driveRoot)) {
    Write-Host "✗ Диск назначения недоступен: $driveRoot" -ForegroundColor Red
    exit 1
}

# Создаём папку для логов
if (-not (Test-Path $LogFolder)) {
    New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
}

$dt = Get-Date -Format $DateTimeFormat
$archiveName = "Main-$dt.zip"
$finalPath = Join-Path $DestinationRoot $archiveName
$tempPath = $finalPath + $TempArchiveSuffix

Add-LogEntry "Запуск резервного копирования" "Info"
Add-LogEntry "Целевая папка: $DestinationRoot" "Info"

Write-Status "Сканирую файлы..."

$files = Get-FilesToBackup -Folders $MainFolders

if ($files.Count -eq 0) {
    Write-Status "Файлы для бэкапа не найдены" "WARN"
    Add-LogEntry "Файлы для резервного копирования не найдены" "Warning"
}
else {
    Write-Status "Найдено файлов: $($files.Count)" "SUCCESS"

    $hashes = Get-FileHashes -Files $files -BasePath $UserPath

    Write-Status "Создаю архив..."
    Create-Archive -Files $files -BasePath $UserPath -Hashes $hashes -OutputPath $tempPath

    if (Test-Path $tempPath) {
        Write-Status "Проверяю целостность архива..."
        $valid = Test-ArchiveHashes -ArchivePath $tempPath -ExpectedHashes $hashes
        if ($valid) {
            if (Test-Path $finalPath) { Remove-Item $finalPath -Force }
            Move-Item $tempPath $finalPath -Force
            
            $sizeGB = [math]::Round((Get-Item $finalPath).Length / 1GB, 2)
            Write-Status "Архив готов и проверен: $archiveName ($sizeGB GB)" "SUCCESS"
            
            Write-Status "Проверяю старые бэкапы..."
            Rotate-Backups -BackupRoot $DestinationRoot -ArchiveRoot $ArchiveFolder -MaxCount $MaxBackups
        }
        else {
            Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
            Write-Status "Ошибка проверки хешей — архив удалён" "ERROR"
        }
    }
    else {
        Write-Status "Не удалось создать архив" "ERROR"
        Add-LogEntry "Не удалось создать архив" "Error"
    }
}

# Сохраняем HTML-лог
$duration = New-TimeSpan -Start $Global:StartTime
$logStatus = if ($Global:HasErrors) { " [Ошибка]" } elseif ($Global:HasWarnings) { " [Внимание]" } else { "" }
$logFileName = "Backup_$dt$logStatus.html"
$logPath = Join-Path $LogFolder $logFileName

Save-HtmlLog -LogPath $logPath `
             -ArchiveName $archiveName `
             -FileCount $Global:ProcessedFiles `
             -TotalBytes $Global:TotalSize `
             -Duration $duration `
             -HasErrors $Global:HasErrors `
             -HasWarnings $Global:HasWarnings

Write-Status "HTML-лог сохранён: $logFileName" "SUCCESS"
Write-Host "  📄 $logPath" -ForegroundColor Cyan

if (-not $NoPause) {
    Write-Host "`nНажмите Enter..." -ForegroundColor Gray
    Read-Host | Out-Null
}
