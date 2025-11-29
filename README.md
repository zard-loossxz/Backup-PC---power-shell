# Backup-PC---power-shell

---

![Structure](https://github.com/user-attachments/assets/1ef89485-4c4a-495a-be8b-100f7a0b3c75)





## 🇬🇧 English Project Description

### 🌟 Project Name: **Robust-Parallel-Backup-PS**

### 🎯 What It Does (Functional Overview)

This project is a highly **optimized and reliable PowerShell script** designed for creating **full, non-compressed archives (ZIP)** of a user's key profile folders. It leverages **multi-threading (RunspacePools)** to parallelize the time-consuming process of file hashing, ensuring speed and efficiency. A critical feature is its **dual-pass hash validation** (SHA512) to guarantee data integrity before and during archiving. The script writes the final ZIP archive directly to the destination in a single operation, minimizing disk I/O and creating a temporary `.partial.zip` file first for atomic finalization. It includes an **internal hash manifest** within the ZIP file for post-archive verification.

### 📁 Files Used and What Happens to Them

* **Source Files (Input):**
    * Files located within standard user profile directories (`$env:USERPROFILE`): **Videos**, **Documents**, **Downloads**, **Music**, **Pictures**, **Desktop**, and **3D Objects**.
    * *Process:* These files are recursively scanned. For each file, the **SHA512 hash** is calculated twice in parallel threads for integrity check. The files are then added to a new ZIP archive one by one.

* **Output Files:**
    * **`.zip` Archive File:** (e.g., `G:\Backups\Backup-dd-MM-yyyy-HH_mm\Backup-dd-MM-yyyy-HH_mm.zip`). This is the final backup containing all source files and the internal hash manifest.
    * **Log File:** (e.g., `Backup-dd-MM-yyyy-HH_mm.zip.log`). Contains timestamps, operational messages, warnings, errors, and details about hash mismatches or reading errors.

### ⚙️ Key Configuration and Implementation Details

| Parameter | Value/Description | Rationale |
| :--- | :--- | :--- |
| **Hash Algorithm** | `SHA512` | High security and reliability for data integrity verification. |
| **Max Threads** | `10` | Defines the size of the `RunspacePool` for parallel hashing, balancing speed and system load. |
| **Zip Compression Level** | `NoCompression` | Prioritizes **maximum speed** over archive size, reducing CPU load. |
| **Buffer Size** | `1MB` | Optimized buffer for read/write operations during file copying and hashing. |
| **Path Handling** | `-LiteralPath` | Crucial fix for handling file paths that contain wildcard characters (e.g., `[`, `]`). |
| **Integrity Check** | **Double-Pass Hashing** | Calculates hashes twice on all files and compares the results to ensure files weren't corrupted or modified during the initial scan/hashing process. |
| **Archiving Method** | **Direct Memory-to-Disk Streaming** | Uses `ZipArchive` and manual buffer copy, avoiding temporary files for hash content and optimizing the file addition process. |

***

## 🇷🇺 Русское описание проекта

### 🌟 Название проекта: **Надежное-Параллельное-Резервирование-PS**

### 🎯 Что он делает (Обзор функциональности)

Этот проект представляет собой **высокооптимизированный и надежный скрипт PowerShell**, предназначенный для создания **полных, несжатых архивов (ZIP)** ключевых пользовательских папок профиля. Он использует **многопоточность (RunspacePools)** для параллельного выполнения трудоемкого процесса хеширования файлов, обеспечивая высокую скорость и эффективность. Критически важной особенностью является **двойная проверка хеша (SHA512)** для гарантии целостности данных до и во время архивирования. Скрипт записывает финальный ZIP-архив напрямую в место назначения за одну операцию, минимизируя дисковый ввод/вывод, и использует временный файл `.partial.zip` для атомарной финализации. Архив включает **внутренний манифест хешей** для последующей проверки.

### 📁 Обрабатываемые файлы и что с ними происходит

* **Исходные файлы (Вход):**
    * Файлы, расположенные в стандартных директориях профиля пользователя (`$env:USERPROFILE`): **Видео**, **Документы**, **Загрузки**, **Музыка**, **Изображения**, **Рабочий стол** и **3D Объекты**.
    * *Процесс:* Эти файлы рекурсивно сканируются. Для каждого файла **хеш SHA512** рассчитывается дважды в параллельных потоках для проверки целостности. Затем файлы поочередно добавляются в новый ZIP-архив.

* **Выходные файлы:**
    * **ZIP-Архив:** (например, `G:\Backups\Backup-дд-ММ-гггг-ЧЧ_мм\Backup-дд-ММ-гггг-ЧЧ_мм.zip`). Это финальный бэкап, содержащий все исходные файлы и внутренний манифест хешей.
    * **Файл лога:** (например, `Backup-дд-ММ-гггг-ЧЧ_мм.zip.log`). Содержит временные метки, операционные сообщения, предупреждения, ошибки и детали о несоответствиях хешей или ошибках чтения.

### ⚙️ Ключевые настройки и детали реализации

| Параметр | Значение/Описание | Обоснование |
| :--- | :--- | :--- |
| **Алгоритм хеширования** | `SHA512` | Высокая безопасность и надежность для проверки целостности данных. |
| **Макс. потоков** | `10` | Определяет размер `RunspacePool` для параллельного хеширования, балансируя скорость и нагрузку на систему. |
| **Уровень сжатия ZIP** | `NoCompression` | Приоритет **максимальной скорости** над размером архива, снижает нагрузку на процессор. |
| **Размер буфера** | `1MB` | Оптимизированный буфер для операций чтения/записи во время копирования файлов и хеширования. |
| **Обработка путей** | `-LiteralPath` | Критическое исправление для обработки путей к файлам, содержащих символы-шаблоны (например, `[`, `]`). |
| **Проверка целостности** | **Двойное хеширование** | Рассчитывает хеши для всех файлов дважды и сравнивает результаты, чтобы убедиться, что файлы не были повреждены или изменены во время начального сканирования/хеширования. |
| **Метод архивирования** | **Потоковая передача напрямую в файл** | Использует `ZipArchive` и ручное копирование с буфером, избегая временных файлов для содержимого хешей и оптимизируя процесс добавления файлов. |

---

Хотели бы вы, чтобы я создал файл **`README.md`** для вашего GitHub-репозитория на английском или русском языке, используя эту информацию?
