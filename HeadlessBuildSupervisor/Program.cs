using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Management;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

internal static class Program
{
    private const string BuildTarget = "StandaloneLinux64";
    private const string BuildTargetLabel = "StandaloneLinux64-Server";
    private const string LogsFolderName = "logs";
    private const string BuildManifestName = "build_manifest.json";
    private const string BuildOutcomeName = "build_outcome.json";
    private const string BuildReportJsonName = "build_report.json";
    private const string BuildReportTextName = "build_report.txt";
    private const string EditorLogName = "editor.log";
    private const string EditorPrevLogName = "editor-prev.log";
    private const string EditorLogMissingName = "editor_log_missing.txt";
    private static readonly TimeSpan LogReadRetryWindow = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan ProjectLockTimeout = TimeSpan.FromSeconds(30);
    private const int LogReadRetryDelayMs = 100;

    private static int Main(string[] args)
    {
        var options = Options.Parse(args);
        Directory.CreateDirectory(options.ArtifactDir);

        var stagingDir = options.StagingDir;
        if (string.IsNullOrWhiteSpace(stagingDir))
        {
            stagingDir = Path.Combine(options.ArtifactDir, $"staging_{options.BuildId}_{DateTime.UtcNow:yyyyMMdd_HHmmss}");
        }

        Directory.CreateDirectory(stagingDir);
        var logsDir = Path.Combine(stagingDir, LogsFolderName);
        Directory.CreateDirectory(logsDir);

        var supervisorLog = Path.Combine(logsDir, "supervisor.log");
        var logger = new Logger(supervisorLog);
        logger.Info($"start build_id={options.BuildId} commit={options.Commit} staging={stagingDir}");

        var unityLog = Path.Combine(logsDir, $"unity_full_{options.BuildId}.log");
        var unityLogLegacy = Path.Combine(logsDir, "unity_build.log");
        var reportJsonPath = Path.Combine(logsDir, BuildReportJsonName);
        var reportTextPath = Path.Combine(logsDir, BuildReportTextName);
        var outcomePath = Path.Combine(logsDir, BuildOutcomeName);
        var manifestPath = Path.Combine(stagingDir, BuildManifestName);
        var failureReasonPath = Path.Combine(stagingDir, "failure_reason.txt");

        var success = false;
        FailureSignature failureSignature = FailureSignature.Unknown;
        string failureMessage = string.Empty;
        UnityRunResult? runResult = null;

        var attempts = options.MaxRetries + 1;
        for (var attempt = 1; attempt <= attempts; attempt++)
        {
            if (attempt > 1)
            {
                ArchiveAttemptLogs(logsDir, attempt - 1, logger);
                CleanBuildOutput(stagingDir, logger);
            }

            logger.Info($"attempt {attempt}/{attempts}");
            runResult = RunUnity(options, stagingDir, unityLog, logger);
            if (File.Exists(unityLog))
            {
                TryCopyFileWithRetries(unityLog, unityLogLegacy, logger);
            }

            var outcomeResult = TryReadOutcomeResult(outcomePath);
            var hasOutcome = !string.IsNullOrWhiteSpace(outcomeResult);
            var outcomeSucceeded = hasOutcome && outcomeResult.Equals("Succeeded", StringComparison.OrdinalIgnoreCase);
            var exitOk = runResult.ExitCode == 0;

            if (runResult.TimedOut)
            {
                failureSignature = DetectFailureSignature(unityLog, runResult, outcomeResult, logger);
                failureMessage = "Unity build timed out.";
            }
            else if (exitOk && outcomeSucceeded)
            {
                success = true;
                break;
            }
            else
            {
                failureSignature = DetectFailureSignature(unityLog, runResult, outcomeResult, logger);
                failureMessage = hasOutcome
                    ? $"Unity exit={runResult.ExitCode} outcome={outcomeResult}"
                    : $"Unity exit={runResult.ExitCode} outcome=missing";
            }

            CaptureEditorLogs(logsDir, options.BuildId, logger);

            if (attempt < attempts && ShouldRetry(failureSignature, runResult))
            {
                logger.Info($"retrying after signature={failureSignature}");
                CleanCaches(options.ProjectPath, failureSignature, logger);
                continue;
            }

            break;
        }

        var buildDir = Path.Combine(stagingDir, "build");
        var entrypoint = FindEntrypoint(buildDir);
        if (!success && runResult != null && runResult.ExitCode == 0 && !string.IsNullOrWhiteSpace(entrypoint))
        {
            success = true;
            failureSignature = FailureSignature.Unknown;
            failureMessage = "SUCCESS_INFERRED: Unity exit=0 and entrypoint exists; Unity did not emit build_outcome.json";
            logger.Info("success_inferred");
        }

        if (!success)
        {
            var primaryError = TryExtractPrimaryError(unityLog, logger);
            if (!string.IsNullOrWhiteSpace(primaryError))
            {
                failureMessage = $"PRIMARY_ERROR: {primaryError}";
            }

            WriteFailureReason(failureReasonPath, failureSignature, failureMessage, logger);
        }
        if (!File.Exists(reportJsonPath) && !File.Exists(reportTextPath))
        {
            WriteFallbackReport(reportJsonPath, reportTextPath, logger);
        }

        if (!File.Exists(manifestPath))
        {
            WriteFallbackManifest(manifestPath, stagingDir, options, unityLog, logger);
        }

        if (!success)
        {
            WriteLogTail(unityLog, Path.Combine(logsDir, "unity_build_tail.txt"), options.TailLines, logger);
            WriteProcessSnapshot(Path.Combine(logsDir, "process_snapshot.txt"), logger);
            CopyCrashArtifacts(options.ProjectPath, Path.Combine(logsDir, "crash"), logger);
        }

        var zipTemp = Path.Combine(options.ArtifactDir, $"artifact_{options.BuildId}.zip.tmp");
        var zipFinal = Path.Combine(options.ArtifactDir, $"artifact_{options.BuildId}.zip");

        if (File.Exists(zipFinal))
        {
            var requiredEntries = new[]
            {
                $"{LogsFolderName}/{BuildOutcomeName}",
                BuildManifestName
            };

            if (ZipHasEntries(zipFinal, requiredEntries, logger))
            {
                logger.Info($"artifact_exists path={zipFinal} valid=true");
                return 2;
            }

            logger.Info($"artifact_exists path={zipFinal} valid=false");
            try
            {
                File.Delete(zipFinal);
            }
            catch (Exception ex)
            {
                logger.Info($"artifact_delete_failed path={zipFinal} error={ex.GetType().Name}");
                throw;
            }
        }

        if (File.Exists(zipTemp))
        {
            File.Delete(zipTemp);
        }

        CreateZip(stagingDir, zipTemp, logger);
        EnsureRequiredZipEntries(
            zipTemp,
            stagingDir,
            unityLog,
            outcomePath,
            manifestPath,
            options,
            success,
            failureMessage,
            logger);
        File.Move(zipTemp, zipFinal);
        logger.Info($"artifact_published path={zipFinal}");

        return success ? 0 : 1;
    }

    private static bool ZipHasEntries(string zipPath, IReadOnlyCollection<string> requiredEntries, Logger logger)
    {
        try
        {
            using var archive = ZipFile.OpenRead(zipPath);
            var remaining = new HashSet<string>(requiredEntries, StringComparer.OrdinalIgnoreCase);
            foreach (var entry in archive.Entries)
            {
                remaining.Remove(entry.FullName);
                if (remaining.Count == 0)
                {
                    return true;
                }
            }

            return false;
        }
        catch (Exception ex)
        {
            logger.Info($"artifact_validate_failed path={zipPath} error={ex.GetType().Name}");
            return false;
        }
    }

    private static UnityRunResult RunUnity(Options options, string artifactRoot, string unityLog, Logger logger)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(unityLog) ?? artifactRoot);
        File.WriteAllText(unityLog, $"UNITY_LOG_PLACEHOLDER utc={DateTime.UtcNow:O}{Environment.NewLine}", Encoding.ASCII);

        var buildOut = options.BuildOut;
        if (string.IsNullOrWhiteSpace(buildOut))
        {
            buildOut = Path.Combine(artifactRoot, "build");
        }

        Directory.CreateDirectory(buildOut);
        KillUnityProcessesForProject(options.ProjectPath, logger);
        DeleteUnityLockfiles(options.ProjectPath, logger);
        if (!TryAcquireProjectMutex(options.ProjectPath, logger, out var projectMutex))
        {
            File.AppendAllText(unityLog, $"UNITY_PROJECT_MUTEX_TIMEOUT project={options.ProjectPath}{Environment.NewLine}", Encoding.ASCII);
            return new UnityRunResult(1, false);
        }
        var args = new List<string>
        {
            "-batchmode",
            "-nographics",
            "-quit",
            "-projectPath", options.ProjectPath,
            "-buildTarget", BuildTarget,
            "-executeMethod", options.ExecuteMethod,
            "-logFile", unityLog,
            "-buildId", options.BuildId,
            "-commit", options.Commit,
            "-artifactRoot", artifactRoot,
            "-buildOut", buildOut
        };

        if (options.DefaultArgs.Count > 0)
        {
            args.Add("-defaultArgs");
            args.Add(string.Join(";", options.DefaultArgs));
        }

        if (options.Scenarios.Count > 0)
        {
            args.Add("-scenarios");
            args.Add(string.Join(";", options.Scenarios));
        }

        if (!string.IsNullOrWhiteSpace(options.Notes))
        {
            args.Add("-notes");
            args.Add(options.Notes);
        }

        var logsDir = Path.GetDirectoryName(unityLog) ?? artifactRoot;
        var stdoutPath = Path.Combine(logsDir, $"unity_stdout_{options.BuildId}.log");
        var stderrPath = Path.Combine(logsDir, $"unity_stderr_{options.BuildId}.log");
        var psi = new ProcessStartInfo
        {
            FileName = options.UnityExe,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        foreach (var arg in args)
        {
            psi.ArgumentList.Add(arg);
        }

        logger.Info($"unity_start exe={options.UnityExe}");
        logger.Info($"unity_args {FormatArgsForLog(args)}");
        logger.Info($"unity_stdout path={stdoutPath}");
        logger.Info($"unity_stderr path={stderrPath}");
        using var job = new JobObject();
        using var process = Process.Start(psi);
        if (process == null)
        {
            ReleaseProjectMutex(projectMutex, logger);
            throw new InvalidOperationException("Failed to start Unity process.");
        }
        using var stdoutWriter = new StreamWriter(stdoutPath, false, Encoding.UTF8) { AutoFlush = true };
        using var stderrWriter = new StreamWriter(stderrPath, false, Encoding.UTF8) { AutoFlush = true };
        var stdoutLock = new object();
        var stderrLock = new object();
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data == null)
            {
                return;
            }

            lock (stdoutLock)
            {
                stdoutWriter.WriteLine(e.Data);
            }
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data == null)
            {
                return;
            }

            lock (stderrLock)
            {
                stderrWriter.WriteLine(e.Data);
            }
        };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        job.Assign(process);
        var timedOut = !process.WaitForExit((int)options.Timeout.TotalMilliseconds);
        if (timedOut)
        {
            logger.Info($"unity_timeout pid={process.Id} timeout={options.Timeout.TotalMinutes:F1}m");
            job.Terminate(1);
            TryKillProcess(process);
            WaitForProcessExit(process, TimeSpan.FromSeconds(2), logger);
            KillStrayUnityProcesses(unityLog, artifactRoot, options.ExecuteMethod, logger);
            ReleaseProjectMutex(projectMutex, logger);
            return new UnityRunResult(process.HasExited ? process.ExitCode : 124, timedOut);
        }

        process.WaitForExit();
        logger.Info($"unity_exit pid={process.Id} exit={process.ExitCode}");
        ReleaseProjectMutex(projectMutex, logger);
        return new UnityRunResult(process.ExitCode, timedOut);
    }

    private static string FormatArgsForLog(IReadOnlyList<string> args)
    {
        var sb = new StringBuilder();
        for (var i = 0; i < args.Count; i++)
        {
            var arg = args[i];
            var needsQuote = arg.IndexOfAny(new[] { ' ', '\t', '"' }) >= 0;
            if (needsQuote)
            {
                sb.Append('"');
                sb.Append(arg.Replace("\"", "\\\""));
                sb.Append('"');
            }
            else
            {
                sb.Append(arg);
            }

            if (i < args.Count - 1)
            {
                sb.Append(' ');
            }
        }

        return sb.ToString();
    }

    private static void CaptureEditorLogs(string logsDir, string buildId, Logger logger)
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var editorDir = Path.Combine(localAppData, "Unity", "Editor");
        var editorLog = Path.Combine(editorDir, "Editor.log");
        var editorPrev = Path.Combine(editorDir, "Editor-prev.log");
        var upmLog = Path.Combine(editorDir, "upm.log");
        var missingPath = string.Empty;

        if (File.Exists(editorLog))
        {
            if (TryCopyFileWithRetries(editorLog, Path.Combine(logsDir, EditorLogName), logger))
            {
                logger.Info($"editor_log_captured src={editorLog}");
            }

            TryCopyFileWithRetries(editorLog, Path.Combine(logsDir, $"Editor_global_{buildId}.log"), logger);
        }
        else
        {
            missingPath = editorLog;
        }

        if (File.Exists(editorPrev))
        {
            if (TryCopyFileWithRetries(editorPrev, Path.Combine(logsDir, EditorPrevLogName), logger))
            {
                logger.Info($"editor_prev_log_captured src={editorPrev}");
            }
        }
        else if (string.IsNullOrWhiteSpace(missingPath))
        {
            missingPath = editorPrev;
        }

        if (File.Exists(upmLog))
        {
            TryCopyFileWithRetries(upmLog, Path.Combine(logsDir, $"upm_global_{buildId}.log"), logger);
        }

        if (!string.IsNullOrWhiteSpace(missingPath))
        {
            var missingFile = Path.Combine(logsDir, EditorLogMissingName);
            File.WriteAllText(missingFile, missingPath, Encoding.ASCII);
            logger.Info($"editor_log_missing path={missingPath}");
        }
    }

    private static bool TryCopyFileWithRetries(string sourcePath, string destPath, Logger logger)
    {
        var deadline = DateTime.UtcNow + LogReadRetryWindow;
        while (true)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(destPath) ?? ".");
                using var source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var dest = new FileStream(destPath, FileMode.Create, FileAccess.Write, FileShare.Read);
                source.CopyTo(dest);
                return true;
            }
            catch (IOException ex)
            {
                if (DateTime.UtcNow < deadline)
                {
                    Thread.Sleep(LogReadRetryDelayMs);
                    continue;
                }

                logger.Warn($"editor_log_copy_failed path={sourcePath} err={ex.Message}");
                return false;
            }
            catch (UnauthorizedAccessException ex)
            {
                logger.Warn($"editor_log_copy_denied path={sourcePath} err={ex.Message}");
                return false;
            }
            catch (Exception ex)
            {
                logger.Warn($"editor_log_copy_error path={sourcePath} err={ex.Message}");
                return false;
            }
        }
    }

    private static void TryKillProcess(Process process)
    {
        try
        {
            process.Kill(true);
        }
        catch
        {
        }
    }

    private static void WaitForProcessExit(Process process, TimeSpan timeout, Logger logger)
    {
        try
        {
            if (!process.HasExited)
            {
                process.WaitForExit((int)timeout.TotalMilliseconds);
            }
        }
        catch (Exception ex)
        {
            logger.Warn($"unity_wait_exit_failed pid={process.Id} err={ex.Message}");
        }
    }

    private static void KillStrayUnityProcesses(string unityLog, string stagingDir, string executeMethod, Logger logger)
    {
        try
        {
            var candidates = new List<int>();
            using var searcher = new ManagementObjectSearcher("SELECT ProcessId, CommandLine, Name FROM Win32_Process WHERE Name='Unity.exe'");
            foreach (ManagementObject process in searcher.Get())
            {
                var commandLine = process["CommandLine"] as string;
                if (string.IsNullOrWhiteSpace(commandLine))
                {
                    continue;
                }

                if (!ShouldKillUnityProcess(commandLine, unityLog, stagingDir, executeMethod))
                {
                    continue;
                }

                if (process["ProcessId"] is uint pid)
                {
                    candidates.Add(unchecked((int)pid));
                }
            }

            foreach (var pid in candidates)
            {
                TryKillProcessTree(pid, logger);
            }
        }
        catch (Exception ex)
        {
            logger.Warn($"unity_stray_scan_failed err={ex.Message}");
        }
    }

    private static bool ShouldKillUnityProcess(string commandLine, string unityLog, string stagingDir, string executeMethod)
    {
        var cmd = commandLine.ToLowerInvariant();
        var logPath = NormalizePathForMatch(unityLog);
        var logPathAlt = NormalizePathForMatch(unityLog).Replace('\\', '/');
        var stagingPath = NormalizePathForMatch(stagingDir);
        var stagingPathAlt = NormalizePathForMatch(stagingDir).Replace('\\', '/');
        var execute = executeMethod.ToLowerInvariant();

        if (cmd.Contains(logPath) || cmd.Contains(logPathAlt))
        {
            return true;
        }

        if (!string.IsNullOrWhiteSpace(stagingPath) && (cmd.Contains(stagingPath) || cmd.Contains(stagingPathAlt)))
        {
            return true;
        }

        if (cmd.Contains("-executemethod") && cmd.Contains(execute) && cmd.Contains("-artifactroot") &&
            (cmd.Contains(stagingPath) || cmd.Contains(stagingPathAlt)))
        {
            return true;
        }

        return false;
    }

    private static void KillUnityProcessesForProject(string projectPath, Logger logger)
    {
        var matches = FindUnityProcessesForProject(projectPath, logger);
        if (matches.Count == 0)
        {
            return;
        }

        foreach (var pid in matches)
        {
            try
            {
                using var process = Process.GetProcessById(pid);
                process.Kill(true);
                logger.Info($"unity_project_killed pid={pid}");
            }
            catch (Exception ex)
            {
                logger.Warn($"unity_project_kill_failed pid={pid} err={ex.Message}");
            }
        }

        Thread.Sleep(2000);
        var remaining = FindUnityProcessesForProject(projectPath, logger);
        if (remaining.Count > 0)
        {
            logger.Warn($"unity_project_kill_remaining pids={string.Join(",", remaining)}");
        }
    }

    private static List<int> FindUnityProcessesForProject(string projectPath, Logger logger)
    {
        var matches = new List<int>();
        if (string.IsNullOrWhiteSpace(projectPath))
        {
            return matches;
        }

        var normalized = NormalizeProjectPath(projectPath);
        var normalizedAlt = normalized.Replace('\\', '/');
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return matches;
        }

        try
        {
            using var searcher = new ManagementObjectSearcher("SELECT ProcessId, CommandLine, Name FROM Win32_Process WHERE Name='Unity.exe' OR Name='Unity'");
            foreach (ManagementObject process in searcher.Get())
            {
                var commandLine = process["CommandLine"]?.ToString();
                if (string.IsNullOrWhiteSpace(commandLine))
                {
                    continue;
                }

                var cmd = commandLine.ToLowerInvariant();
                if (!cmd.Contains("-projectpath"))
                {
                    continue;
                }

                if (!(cmd.Contains(normalized) || cmd.Contains(normalizedAlt)))
                {
                    continue;
                }

                if (process["ProcessId"] is uint pid)
                {
                    matches.Add((int)pid);
                }
            }
        }
        catch (Exception ex)
        {
            logger.Warn($"unity_project_scan_failed err={ex.Message}");
        }

        return matches;
    }

    private static void DeleteUnityLockfiles(string projectPath, Logger logger)
    {
        if (string.IsNullOrWhiteSpace(projectPath))
        {
            return;
        }

        foreach (var relPath in new[] { "Temp\\UnityLockfile", "Library\\UnityLockfile" })
        {
            try
            {
                var fullPath = Path.Combine(projectPath, relPath);
                if (File.Exists(fullPath))
                {
                    File.Delete(fullPath);
                    logger.Info($"unity_lockfile_deleted path={fullPath}");
                }
            }
            catch (Exception ex)
            {
                logger.Warn($"unity_lockfile_delete_failed path={relPath} err={ex.Message}");
            }
        }
    }

    private static bool TryAcquireProjectMutex(string projectPath, Logger logger, out Mutex? mutex)
    {
        mutex = null;
        var normalized = NormalizeProjectPath(projectPath);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            logger.Warn("unity_project_mutex_missing_project_path");
            return false;
        }

        var hash = Sha256Hex(normalized);
        var name = $"Global\\ANVILOOP_UNITY_PROJECT_{hash}";
        try
        {
            mutex = new Mutex(false, name);
        }
        catch (Exception ex)
        {
            logger.Warn($"unity_project_mutex_create_failed name={name} err={ex.Message}");
            return false;
        }

        try
        {
            if (mutex.WaitOne(ProjectLockTimeout))
            {
                logger.Info($"unity_project_mutex_acquired name={name}");
                return true;
            }
        }
        catch (AbandonedMutexException)
        {
            logger.Warn($"unity_project_mutex_abandoned name={name}");
            return true;
        }
        catch (Exception ex)
        {
            logger.Warn($"unity_project_mutex_wait_failed name={name} err={ex.Message}");
        }

        var pids = FindUnityProcessesForProject(projectPath, logger);
        logger.Warn($"unity_project_mutex_timeout name={name} project={normalized} pids={string.Join(",", pids)}");
        return false;
    }

    private static void ReleaseProjectMutex(Mutex? mutex, Logger logger)
    {
        if (mutex == null)
        {
            return;
        }

        try
        {
            mutex.ReleaseMutex();
        }
        catch (ApplicationException)
        {
        }
        catch (Exception ex)
        {
            logger.Warn($"unity_project_mutex_release_failed err={ex.Message}");
        }
        finally
        {
            mutex.Dispose();
        }
    }

    private static string NormalizeProjectPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return string.Empty;
        }

        var full = Path.GetFullPath(path);
        return full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).ToLowerInvariant();
    }

    private static string NormalizePathForMatch(string path)
    {
        return string.IsNullOrWhiteSpace(path) ? string.Empty : path.Trim().ToLowerInvariant();
    }

    private static void TryKillProcessTree(int pid, Logger logger)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            process.Kill(true);
            logger.Info($"unity_stray_killed pid={pid}");
        }
        catch (Exception ex)
        {
            logger.Warn($"unity_stray_kill_failed pid={pid} err={ex.Message}");
        }
    }
    private static void ArchiveAttemptLogs(string logsDir, int attempt, Logger logger)
    {
        foreach (var file in new[]
                 {
                     "unity_build.log",
                     EditorLogName,
                     EditorPrevLogName,
                     EditorLogMissingName,
                     BuildOutcomeName,
                     BuildReportJsonName,
                     BuildReportTextName
                 })
        {
            var path = Path.Combine(logsDir, file);
            if (!File.Exists(path))
            {
                continue;
            }

            var dest = Path.Combine(logsDir, $"{Path.GetFileNameWithoutExtension(file)}_attempt{attempt}{Path.GetExtension(file)}");
            File.Move(path, dest, overwrite: true);
            logger.Info($"archive_log src={path} dst={dest}");
        }
    }

    private static void CleanBuildOutput(string stagingDir, Logger logger)
    {
        var buildDir = Path.Combine(stagingDir, "build");
        if (!Directory.Exists(buildDir))
        {
            return;
        }

        try
        {
            Directory.Delete(buildDir, true);
            logger.Info($"clean_build_output path={buildDir}");
        }
        catch (Exception ex)
        {
            logger.Info($"clean_build_output_failed path={buildDir} err={ex.Message}");
        }
    }

    private static void CleanCaches(string projectPath, FailureSignature signature, Logger logger)
    {
        var targets = new List<string>();
        switch (signature)
        {
            case FailureSignature.BeeStall:
                targets.Add(Path.Combine(projectPath, "Library", "Bee"));
                targets.Add(Path.Combine(projectPath, "Library", "BeeBackend"));
                targets.Add(Path.Combine(projectPath, "Library", "BuildCache"));
                targets.Add(Path.Combine(projectPath, "Temp"));
                break;
            case FailureSignature.ImportLoop:
                targets.Add(Path.Combine(projectPath, "Library", "Artifacts"));
                targets.Add(Path.Combine(projectPath, "Library", "AssetImportState"));
                break;
            default:
                return;
        }

        foreach (var target in targets)
        {
            if (!Directory.Exists(target))
            {
                continue;
            }

            try
            {
                Directory.Delete(target, true);
                logger.Info($"cache_clean path={target}");
            }
            catch (Exception ex)
            {
                logger.Info($"cache_clean_failed path={target} err={ex.Message}");
            }
        }
    }

    private static bool ShouldRetry(FailureSignature signature, UnityRunResult result)
    {
        if (signature == FailureSignature.BeeStall || signature == FailureSignature.ImportLoop)
        {
            return true;
        }

        if (result.TimedOut && signature == FailureSignature.BuildTimeout)
        {
            return false;
        }

        return false;
    }

    private static FailureSignature DetectFailureSignature(string logPath, UnityRunResult result, string? outcomeResult, Logger logger)
    {
        try
        {
            if (result.TimedOut)
            {
                return FailureSignature.BuildTimeout;
            }

            var text = ReadTail(logPath, 800, logger, out var logLocked);
            if (logLocked)
            {
                return FailureSignature.LogLocked;
            }

            if (string.IsNullOrWhiteSpace(text))
            {
                return string.IsNullOrWhiteSpace(outcomeResult) ? FailureSignature.InfraFail : FailureSignature.Unknown;
            }

            if (ContainsStrictLicenseFailure(text))
            {
                return FailureSignature.LicenseError;
            }

            if (Regex.IsMatch(text, "error\\s+CS\\d+", RegexOptions.IgnoreCase))
            {
                return FailureSignature.CompilerError;
            }

            var importingAssets = ContainsIgnoreCase(text, "Importing Assets");
            var importLoopSignal = ContainsIgnoreCase(text, "Rebuilding Library") ||
                                   ContainsIgnoreCase(text, "Refresh:") ||
                                   ContainsIgnoreCase(text, "AssetImportState");
            if (importingAssets && importLoopSignal)
            {
                return FailureSignature.ImportLoop;
            }

            if (ContainsIgnoreCase(text, "bee_backend") || ContainsIgnoreCase(text, "ScriptCompilationBuildProgram"))
            {
                return FailureSignature.BeeStall;
            }

            if (string.IsNullOrWhiteSpace(outcomeResult))
            {
                return FailureSignature.InfraFail;
            }

            return FailureSignature.Unknown;
        }
        catch (Exception ex)
        {
            logger.Warn($"failure_signature_failed err={ex.Message}");
            return FailureSignature.Unknown;
        }
    }

    private static bool ContainsStrictLicenseFailure(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        return ContainsIgnoreCase(text, "No valid Unity license") ||
               ContainsIgnoreCase(text, "entitlement denied") ||
               ContainsIgnoreCase(text, "access token unavailable");
    }

    private static string? TryExtractPrimaryError(string logPath, Logger logger)
    {
        try
        {
            if (!File.Exists(logPath))
            {
                return null;
            }

            foreach (var line in File.ReadLines(logPath))
            {
                if (string.IsNullOrWhiteSpace(line))
                {
                    continue;
                }

                if (IsPrimaryErrorLine(line))
                {
                    return line.Trim();
                }
            }
        }
        catch (Exception ex)
        {
            logger.Warn($"primary_error_extract_failed err={ex.Message}");
        }

        return null;
    }

    private static bool IsPrimaryErrorLine(string line)
    {
        if (Regex.IsMatch(line, "error\\s+CS\\d+", RegexOptions.IgnoreCase))
        {
            return true;
        }

        if (ContainsIgnoreCase(line, "Build failed"))
        {
            return true;
        }

        if (ContainsIgnoreCase(line, "BuildPipeline.BuildPlayer"))
        {
            return true;
        }

        if (ContainsIgnoreCase(line, "executeMethod") &&
            (ContainsIgnoreCase(line, "not found") || ContainsIgnoreCase(line, "not static")))
        {
            return true;
        }

        if (ContainsIgnoreCase(line, "ScriptCompilation") || ContainsIgnoreCase(line, "Assembly-CSharp"))
        {
            return true;
        }

        if (ContainsIgnoreCase(line, "Bee.BeeException") ||
            (ContainsIgnoreCase(line, "bee") && ContainsIgnoreCase(line, "error")) ||
            ContainsIgnoreCase(line, "bee_backend"))
        {
            return true;
        }

        return Regex.IsMatch(line, "\\b\\w*Exception\\b");
    }

    private static bool ContainsIgnoreCase(string text, string fragment)
    {
        return text.IndexOf(fragment, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static string? TryReadOutcomeResult(string outcomePath)
    {
        if (!File.Exists(outcomePath))
        {
            return null;
        }

        var text = File.ReadAllText(outcomePath);
        var match = Regex.Match(text, "\\\"result\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"", RegexOptions.IgnoreCase);
        return match.Success ? match.Groups[1].Value : null;
    }

    private static void WriteFinalOutcome(string outcomePath, Options options, bool success, string failureMessage, Logger logger)
    {
        var outcomeResult = success ? "Succeeded" : "Failed";
        var message = success
            ? string.IsNullOrWhiteSpace(failureMessage) ? "Succeeded" : failureMessage
            : string.IsNullOrWhiteSpace(failureMessage) ? "INFRA_FAIL: build_outcome.json missing" : failureMessage;
        var reportPath = File.Exists(Path.Combine(Path.GetDirectoryName(outcomePath) ?? string.Empty, BuildReportJsonName))
            ? $"{LogsFolderName}/{BuildReportJsonName}"
            : $"{LogsFolderName}/{BuildReportTextName}";

        var json = new StringBuilder();
        json.Append("{");
        AppendJsonField(json, "build_id", options.BuildId, prependComma: false);
        AppendJsonField(json, "commit", options.Commit, prependComma: true);
        AppendJsonField(json, "result", outcomeResult, prependComma: true);
        AppendJsonField(json, "message", message, prependComma: true);
        AppendJsonField(json, "report_path", reportPath, prependComma: true);
        AppendJsonField(json, "utc", DateTime.UtcNow.ToString("O"), prependComma: true);
        json.Append("}");

        File.WriteAllText(outcomePath, json.ToString(), Encoding.ASCII);
        logger.Info($"outcome_final_written result={outcomeResult}");
    }

    private static void WriteFallbackReport(string jsonPath, string textPath, Logger logger)
    {
        File.WriteAllText(textPath, "BuildReport missing.", Encoding.ASCII);
        File.WriteAllText(jsonPath, "{\"summary\":{\"result\":\"Unknown\",\"message\":\"BuildReport missing\"}}", Encoding.ASCII);
        logger.Info("fallback_report_written");
    }

    private static void WriteFallbackManifest(string manifestPath, string stagingDir, Options options, string unityLog, Logger logger)
    {
        var unityVersion = TryExtractUnityVersion(unityLog, logger) ?? "unknown";
        var buildDir = Path.Combine(stagingDir, "build");
        var entrypoint = FindEntrypoint(buildDir);
        var dataDir = string.IsNullOrWhiteSpace(entrypoint) ? string.Empty : GetPlayerDataFolderPath(entrypoint);

        var dataPaths = new List<string>();
        if (Directory.Exists(dataDir))
        {
            dataPaths.Add(MakeRelativePath(stagingDir, dataDir));
        }

        var scenarios = DetectScenarioLabels(dataDir);
        var contentHashes = BuildContentHashes(stagingDir, entrypoint, dataDir);
        var manifest = BuildManifest(
            options.BuildId,
            options.Commit,
            unityVersion,
            BuildTargetLabel,
            DateTime.UtcNow,
            MakeRelativePath(stagingDir, entrypoint),
            dataPaths,
            options.DefaultArgs,
            scenarios,
            contentHashes,
            options.Notes);

        var manifestHash = Sha256Hex(manifest);
        if (!string.IsNullOrEmpty(manifestHash))
        {
            contentHashes[BuildManifestName] = manifestHash;
        }

        var finalManifest = BuildManifest(
            options.BuildId,
            options.Commit,
            unityVersion,
            BuildTargetLabel,
            DateTime.UtcNow,
            MakeRelativePath(stagingDir, entrypoint),
            dataPaths,
            options.DefaultArgs,
            scenarios,
            contentHashes,
            options.Notes);

        File.WriteAllText(manifestPath, finalManifest, Encoding.ASCII);
        logger.Info("fallback_manifest_written");
    }

    private static void EnsureRequiredZipEntries(
        string zipPath,
        string stagingDir,
        string unityLog,
        string outcomePath,
        string manifestPath,
        Options options,
        bool success,
        string failureMessage,
        Logger logger)
    {
        WriteFinalOutcome(outcomePath, options, success, failureMessage, logger);

        if (!File.Exists(manifestPath))
        {
            WriteFallbackManifest(manifestPath, stagingDir, options, unityLog, logger);
        }

        try
        {
            using var archive = ZipFile.Open(zipPath, ZipArchiveMode.Update);
            EnsureZipEntry(archive, $"{LogsFolderName}/{BuildOutcomeName}", outcomePath, logger);
            EnsureZipEntry(archive, BuildManifestName, manifestPath, logger);
        }
        catch (Exception ex)
        {
            logger.Info($"zip_repair_failed path={zipPath} error={ex.GetType().Name}");
            throw;
        }
    }

    private static void EnsureZipEntry(ZipArchive archive, string entryPath, string sourcePath, Logger logger)
    {
        ZipArchiveEntry? exactEntry = null;
        var matches = new List<ZipArchiveEntry>();
        foreach (var entry in archive.Entries)
        {
            if (string.Equals(entry.FullName, entryPath, StringComparison.OrdinalIgnoreCase))
            {
                matches.Add(entry);
                if (string.Equals(entry.FullName, entryPath, StringComparison.Ordinal))
                {
                    exactEntry = entry;
                }
            }
        }

        var needsReplace = exactEntry == null || exactEntry.Length == 0;
        if (matches.Count > 0 && needsReplace)
        {
            foreach (var entry in matches)
            {
                entry.Delete();
            }
        }
        else if (matches.Count > 1 && exactEntry != null)
        {
            foreach (var entry in matches)
            {
                if (!ReferenceEquals(entry, exactEntry))
                {
                    entry.Delete();
                }
            }
        }

        if (!File.Exists(sourcePath))
        {
            logger.Info($"zip_repair_source_missing entry={entryPath} path={sourcePath}");
            return;
        }

        if (needsReplace)
        {
            archive.CreateEntryFromFile(sourcePath, entryPath, CompressionLevel.Optimal);
            logger.Info($"zip_repaired missing={entryPath}");
        }
    }

    private static string? TryExtractUnityVersion(string unityLog, Logger logger)
    {
        if (!File.Exists(unityLog))
        {
            return null;
        }

        try
        {
            foreach (var line in File.ReadLines(unityLog))
            {
                var match = Regex.Match(line, "Initialize engine version:\\s*(.+)", RegexOptions.IgnoreCase);
                if (match.Success)
                {
                    return match.Groups[1].Value.Trim();
                }

                match = Regex.Match(line, "Unity Editor\\s*([0-9]+\\.[^\\s]+)", RegexOptions.IgnoreCase);
                if (match.Success)
                {
                    return match.Groups[1].Value.Trim();
                }
            }
        }
        catch (IOException ex)
        {
            logger.Warn($"unity_version_read_failed path={unityLog} err={ex.Message}");
        }
        catch (UnauthorizedAccessException ex)
        {
            logger.Warn($"unity_version_read_denied path={unityLog} err={ex.Message}");
        }
        catch (Exception ex)
        {
            logger.Warn($"unity_version_read_error path={unityLog} err={ex.Message}");
        }

        return null;
    }
    private static string FindEntrypoint(string buildDir)
    {
        if (!Directory.Exists(buildDir))
        {
            return string.Empty;
        }

        var files = Directory.GetFiles(buildDir, "*.x86_64", SearchOption.TopDirectoryOnly);
        if (files.Length == 0)
        {
            return string.Empty;
        }

        Array.Sort(files, StringComparer.OrdinalIgnoreCase);
        return files[0];
    }

    private static string GetPlayerDataFolderPath(string executablePath)
    {
        var playerDirectory = Path.GetDirectoryName(executablePath) ?? string.Empty;
        var playerName = Path.GetFileNameWithoutExtension(executablePath);
        return Path.Combine(playerDirectory, $"{playerName}_Data");
    }

    private static List<string> DetectScenarioLabels(string dataPath)
    {
        var labels = new List<string>();
        if (string.IsNullOrWhiteSpace(dataPath))
        {
            return labels;
        }

        var scenarioRoot = Path.Combine(dataPath, "Scenarios");
        if (!Directory.Exists(scenarioRoot))
        {
            return labels;
        }

        foreach (var directory in Directory.GetDirectories(scenarioRoot))
        {
            var name = Path.GetFileName(directory);
            if (!string.IsNullOrWhiteSpace(name))
            {
                labels.Add(name);
            }
        }

        labels.Sort(StringComparer.OrdinalIgnoreCase);
        return labels;
    }

    private static Dictionary<string, string> BuildContentHashes(string artifactRoot, string entrypointPath, string dataPath)
    {
        var hashes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(entrypointPath) && File.Exists(entrypointPath))
        {
            hashes[MakeRelativePath(artifactRoot, entrypointPath)] = HashFile(entrypointPath);
        }

        if (!string.IsNullOrWhiteSpace(dataPath) && Directory.Exists(dataPath))
        {
            hashes[MakeRelativePath(artifactRoot, dataPath)] = HashDirectory(dataPath);
        }

        return hashes;
    }

    private static string HashDirectory(string root)
    {
        var files = Directory.GetFiles(root, "*", SearchOption.AllDirectories);
        Array.Sort(files, StringComparer.OrdinalIgnoreCase);
        var sb = new StringBuilder();
        foreach (var file in files)
        {
            var relative = file.Substring(root.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var normalized = relative.Replace('\\', '/');
            sb.Append(normalized);
            sb.Append(':');
            sb.Append(HashFile(file));
            sb.Append('\n');
        }

        return Sha256Hex(sb.ToString());
    }

    private static string HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha = SHA256.Create();
        return ToHex(sha.ComputeHash(stream));
    }

    private static string Sha256Hex(string content)
    {
        using var sha = SHA256.Create();
        var bytes = Encoding.UTF8.GetBytes(content);
        return ToHex(sha.ComputeHash(bytes));
    }

    private static string ToHex(byte[] bytes)
    {
        var sb = new StringBuilder(bytes.Length * 2);
        foreach (var b in bytes)
        {
            sb.Append(b.ToString("x2"));
        }
        return sb.ToString();
    }

    private static string BuildManifest(
        string buildId,
        string commit,
        string unityVersion,
        string buildTarget,
        DateTime createdUtc,
        string entrypoint,
        List<string> dataPaths,
        List<string> defaultArgs,
        List<string> scenariosSupported,
        Dictionary<string, string> contentHashes,
        string notes)
    {
        var sb = new StringBuilder();
        sb.Append("{");
        AppendJsonField(sb, "build_id", buildId, prependComma: false);
        AppendJsonField(sb, "commit", commit, prependComma: true);
        AppendJsonField(sb, "unity_version", unityVersion, prependComma: true);
        AppendJsonField(sb, "build_target", buildTarget, prependComma: true);
        AppendJsonField(sb, "created_utc", createdUtc.ToString("O"), prependComma: true);
        AppendJsonField(sb, "entrypoint", entrypoint, prependComma: true);
        sb.Append(",\"data_paths\":");
        AppendJsonArray(sb, dataPaths);
        sb.Append(",\"default_args\":");
        AppendJsonArray(sb, defaultArgs);
        sb.Append(",\"scenarios_supported\":");
        AppendJsonArray(sb, scenariosSupported);

        if (contentHashes.Count > 0)
        {
            sb.Append(",\"content_hashes\":");
            AppendJsonObject(sb, contentHashes);
        }

        if (!string.IsNullOrWhiteSpace(notes))
        {
            AppendJsonField(sb, "notes", notes, prependComma: true);
        }

        sb.Append("}");
        return sb.ToString();
    }

    private static void AppendJsonArray(StringBuilder sb, List<string> values)
    {
        sb.Append("[");
        for (var i = 0; i < values.Count; i++)
        {
            if (i > 0)
            {
                sb.Append(",");
            }
            AppendJsonString(sb, values[i]);
        }
        sb.Append("]");
    }

    private static void AppendJsonObject(StringBuilder sb, Dictionary<string, string> values)
    {
        sb.Append("{");
        var keys = new List<string>(values.Keys);
        keys.Sort(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < keys.Count; i++)
        {
            var key = keys[i];
            if (i > 0)
            {
                sb.Append(",");
            }
            AppendJsonString(sb, key);
            sb.Append(":");
            AppendJsonString(sb, values[key]);
        }
        sb.Append("}");
    }

    private static void AppendJsonField(StringBuilder sb, string name, string value, bool prependComma)
    {
        if (prependComma)
        {
            sb.Append(",");
        }

        AppendJsonString(sb, name);
        sb.Append(":");
        AppendJsonString(sb, value);
    }

    private static void AppendJsonString(StringBuilder sb, string value)
    {
        sb.Append('"');
        if (!string.IsNullOrEmpty(value))
        {
            foreach (var ch in value)
            {
                switch (ch)
                {
                    case '\\':
                        sb.Append("\\\\");
                        break;
                    case '"':
                        sb.Append("\\\"");
                        break;
                    case '\n':
                        sb.Append("\\n");
                        break;
                    case '\r':
                        sb.Append("\\r");
                        break;
                    case '\t':
                        sb.Append("\\t");
                        break;
                    default:
                        if (ch < 32)
                        {
                            sb.Append("\\u");
                            sb.Append(((int)ch).ToString("x4"));
                        }
                        else
                        {
                            sb.Append(ch);
                        }
                        break;
                }
            }
        }
        sb.Append('"');
    }
    private static string MakeRelativePath(string root, string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return string.Empty;
        }

        try
        {
            var relative = Path.GetRelativePath(root, path);
            return relative.Replace('\\', '/');
        }
        catch
        {
            return path.Replace('\\', '/');
        }
    }

    private static void WriteFailureReason(string path, FailureSignature signature, string message, Logger logger)
    {
        var line = $"{GetFailureCode(signature)}: {message}";
        File.WriteAllText(path, line, Encoding.ASCII);
        logger.Info($"failure_reason_written code={signature}");
    }

    private static string GetFailureCode(FailureSignature signature)
    {
        return signature switch
        {
            FailureSignature.BuildTimeout => "BUILD_TIMEOUT",
            FailureSignature.LicenseError => "LICENSE_ERROR",
            FailureSignature.CompilerError => "COMPILER_ERROR",
            FailureSignature.ImportLoop => "IMPORT_LOOP",
            FailureSignature.BeeStall => "BEE_STALL",
            FailureSignature.InfraFail => "INFRA_FAIL",
            FailureSignature.LogLocked => "LOG_LOCKED",
            _ => "UNKNOWN"
        };
    }

    private static void WriteLogTail(string unityLog, string tailPath, int maxLines, Logger logger)
    {
        if (maxLines <= 0)
        {
            File.WriteAllText(tailPath, "tail disabled", Encoding.ASCII);
            return;
        }

        if (!File.Exists(unityLog))
        {
            File.WriteAllText(tailPath, "unity_build.log missing", Encoding.ASCII);
            return;
        }

        var tail = ReadTail(unityLog, maxLines, logger, out var logLocked);
        if (string.IsNullOrWhiteSpace(tail))
        {
            var message = logLocked ? "unity_build.log locked" : "unity_build.log empty";
            File.WriteAllText(tailPath, message, Encoding.ASCII);
            return;
        }

        File.WriteAllText(tailPath, tail, Encoding.ASCII);
        logger.Info("unity_log_tail_written");
    }

    private static string ReadTail(string unityLog, int maxLines, Logger logger, out bool logLocked)
    {
        logLocked = false;
        if (maxLines <= 0)
        {
            return string.Empty;
        }

        if (!File.Exists(unityLog))
        {
            return string.Empty;
        }

        var deadline = DateTime.UtcNow + LogReadRetryWindow;
        while (true)
        {
            try
            {
                var queue = new Queue<string>(maxLines);
                using var stream = new FileStream(unityLog, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var reader = new StreamReader(stream, Encoding.UTF8, true);
                while (!reader.EndOfStream)
                {
                    var line = reader.ReadLine();
                    if (line == null)
                    {
                        break;
                    }

                    if (queue.Count == maxLines)
                    {
                        queue.Dequeue();
                    }
                    queue.Enqueue(line);
                }

                return string.Join("\n", queue);
            }
            catch (IOException ex)
            {
                logLocked = true;
                if (DateTime.UtcNow < deadline)
                {
                    Thread.Sleep(LogReadRetryDelayMs);
                    continue;
                }

                logger.Warn($"unity_log_read_failed path={unityLog} err={ex.Message}");
                return string.Empty;
            }
            catch (UnauthorizedAccessException ex)
            {
                logLocked = true;
                logger.Warn($"unity_log_read_denied path={unityLog} err={ex.Message}");
                return string.Empty;
            }
            catch (Exception ex)
            {
                logger.Warn($"unity_log_read_error path={unityLog} err={ex.Message}");
                return string.Empty;
            }
        }
    }

    private static void WriteProcessSnapshot(string path, Logger logger)
    {
        try
        {
            var lines = new List<string>
            {
                $"snapshot_utc={DateTime.UtcNow:O}"
            };

            foreach (var proc in Process.GetProcesses())
            {
                string name;
                long ws;
                try
                {
                    name = proc.ProcessName;
                    ws = proc.WorkingSet64;
                }
                catch
                {
                    continue;
                }

                var line = $"{proc.Id}\t{name}\t{ws}";
                lines.Add(line);
            }

            File.WriteAllLines(path, lines, Encoding.ASCII);
            logger.Info("process_snapshot_written");
        }
        catch (Exception ex)
        {
            logger.Info($"process_snapshot_failed err={ex.Message}");
        }
    }

    private static void CopyCrashArtifacts(string projectPath, string destinationDir, Logger logger)
    {
        var candidates = new[]
        {
            Path.Combine(projectPath, "Library", "Crashes"),
            Path.Combine(projectPath, "Library", "CrashReports"),
            Path.Combine(projectPath, "Logs"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Unity", "Editor", "Crashes"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Unity", "Crashes")
        };

        Directory.CreateDirectory(destinationDir);
        foreach (var dir in candidates)
        {
            if (!Directory.Exists(dir))
            {
                continue;
            }

            foreach (var file in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
            {
                var name = Path.GetFileName(file);
                if (!IsCrashArtifact(name))
                {
                    continue;
                }

                var dest = Path.Combine(destinationDir, name);
                try
                {
                    File.Copy(file, dest, true);
                }
                catch
                {
                }
            }
        }

        logger.Info("crash_artifacts_copied");
    }

    private static bool IsCrashArtifact(string name)
    {
        var lower = name.ToLowerInvariant();
        if (lower.Contains("crash") || lower.EndsWith(".dmp") || lower.EndsWith(".mdmp"))
        {
            return true;
        }

        return lower.EndsWith(".log") || lower.EndsWith(".txt");
    }

    private static void CreateZip(string sourceDir, string zipPath, Logger logger)
    {
        var files = Directory.GetFiles(sourceDir, "*", SearchOption.AllDirectories);
        Array.Sort(files, StringComparer.OrdinalIgnoreCase);

        using var archive = ZipFile.Open(zipPath, ZipArchiveMode.Create, Encoding.UTF8);
        foreach (var file in files)
        {
            var relative = Path.GetRelativePath(sourceDir, file).Replace('\\', '/');
            var entry = archive.CreateEntry(relative, CompressionLevel.Optimal);
            entry.LastWriteTime = new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero);
            using var entryStream = entry.Open();
            using var fileStream = File.OpenRead(file);
            fileStream.CopyTo(entryStream);
        }

        logger.Info($"zip_created files={files.Length}");
    }
    private enum FailureSignature
    {
        BuildTimeout,
        LicenseError,
        CompilerError,
        ImportLoop,
        BeeStall,
        InfraFail,
        LogLocked,
        Unknown
    }

    private sealed class Logger
    {
        private readonly string _path;
        private readonly object _lock = new object();

        public Logger(string path)
        {
            _path = path;
            Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
            File.WriteAllText(_path, $"supervisor_start utc={DateTime.UtcNow:O}{Environment.NewLine}", Encoding.ASCII);
        }

        public void Info(string message)
        {
            var line = $"utc={DateTime.UtcNow:O} {message}";
            lock (_lock)
            {
                File.AppendAllText(_path, line + Environment.NewLine, Encoding.ASCII);
            }
        }

        public void Warn(string message)
        {
            Info($"WARN {message}");
        }
    }

    private sealed class UnityRunResult
    {
        public UnityRunResult(int exitCode, bool timedOut)
        {
            ExitCode = exitCode;
            TimedOut = timedOut;
        }

        public int ExitCode { get; }
        public bool TimedOut { get; }
    }

    private sealed class Options
    {
        public string UnityExe { get; private set; } = string.Empty;
        public string ProjectPath { get; private set; } = string.Empty;
        public string BuildId { get; private set; } = string.Empty;
        public string Commit { get; private set; } = string.Empty;
        public string ArtifactDir { get; private set; } = string.Empty;
        public string ExecuteMethod { get; private set; } = "Tri.BuildTools.HeadlessLinuxBuild.Build";
        public string? StagingDir { get; private set; }
        public string? BuildOut { get; private set; }
        public List<string> DefaultArgs { get; } = new List<string>();
        public List<string> Scenarios { get; } = new List<string>();
        public string Notes { get; private set; } = string.Empty;
        public TimeSpan Timeout { get; private set; } = TimeSpan.FromMinutes(30);
        public int MaxRetries { get; private set; } = 1;
        public int TailLines { get; private set; } = 200;

        public static Options Parse(string[] args)
        {
            var options = new Options();
            var map = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);

            for (var i = 0; i < args.Length; i++)
            {
                var arg = args[i];
                if (!arg.StartsWith("-", StringComparison.Ordinal))
                {
                    continue;
                }

                var key = arg.TrimStart('-');
                string value = string.Empty;
                var eq = key.IndexOf('=');
                if (eq >= 0)
                {
                    value = key.Substring(eq + 1);
                    key = key.Substring(0, eq);
                }
                else if (i + 1 < args.Length && !args[i + 1].StartsWith("-", StringComparison.Ordinal))
                {
                    value = args[++i];
                }

                if (!map.TryGetValue(key, out var list))
                {
                    list = new List<string>();
                    map[key] = list;
                }

                if (!string.IsNullOrWhiteSpace(value))
                {
                    list.Add(value);
                }
            }

            options.UnityExe = ReadRequired(map, "unity-exe");
            options.ProjectPath = ReadRequired(map, "project-path");
            options.BuildId = ReadRequired(map, "build-id");
            options.Commit = ReadRequired(map, "commit");
            options.ArtifactDir = ReadRequired(map, "artifact-dir");
            options.ExecuteMethod = ReadOptional(map, "execute-method", options.ExecuteMethod);
            options.StagingDir = ReadOptional(map, "staging-dir", string.Empty);
            options.BuildOut = ReadOptional(map, "build-out", string.Empty);
            options.Notes = ReadOptional(map, "notes", string.Empty);
            options.Timeout = TimeSpan.FromMinutes(ReadOptionalInt(map, "timeout-minutes", 30));
            options.MaxRetries = ReadOptionalInt(map, "max-retries", 1);
            options.TailLines = ReadOptionalInt(map, "tail-lines", 200);

            options.DefaultArgs.AddRange(ReadList(map, "default-args"));
            options.Scenarios.AddRange(ReadList(map, "scenarios"));

            if (string.IsNullOrWhiteSpace(options.UnityExe) || !File.Exists(options.UnityExe))
            {
                throw new ArgumentException("unity-exe is missing or invalid.");
            }

            if (string.IsNullOrWhiteSpace(options.ProjectPath) || !Directory.Exists(options.ProjectPath))
            {
                throw new ArgumentException("project-path is missing or invalid.");
            }

            return options;
        }

        private static string ReadRequired(Dictionary<string, List<string>> map, string key)
        {
            if (map.TryGetValue(key, out var list) && list.Count > 0)
            {
                return list[0];
            }

            throw new ArgumentException($"Missing required argument: {key}");
        }

        private static string ReadOptional(Dictionary<string, List<string>> map, string key, string fallback)
        {
            if (map.TryGetValue(key, out var list) && list.Count > 0)
            {
                return list[0];
            }

            return fallback;
        }

        private static int ReadOptionalInt(Dictionary<string, List<string>> map, string key, int fallback)
        {
            if (map.TryGetValue(key, out var list) && list.Count > 0 && int.TryParse(list[0], out var value))
            {
                return value;
            }

            return fallback;
        }

        private static List<string> ReadList(Dictionary<string, List<string>> map, string key)
        {
            if (!map.TryGetValue(key, out var list))
            {
                return new List<string>();
            }

            var result = new List<string>();
            foreach (var value in list)
            {
                if (string.IsNullOrWhiteSpace(value))
                {
                    continue;
                }

                var parts = value.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length == 1)
                {
                    result.Add(value.Trim());
                }
                else
                {
                    foreach (var part in parts)
                    {
                        result.Add(part.Trim());
                    }
                }
            }

            return result;
        }
    }

    private sealed class JobObject : IDisposable
    {
        private readonly IntPtr _handle;

        public JobObject()
        {
            _handle = CreateJobObject(IntPtr.Zero, null);
            if (_handle == IntPtr.Zero)
            {
                throw new InvalidOperationException("CreateJobObject failed.");
            }

            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION
            {
                BasicLimitInformation = new JOBOBJECT_BASIC_LIMIT_INFORMATION
                {
                    LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                }
            };

            var length = Marshal.SizeOf(info);
            var ptr = Marshal.AllocHGlobal(length);
            try
            {
                Marshal.StructureToPtr(info, ptr, false);
                if (!SetInformationJobObject(_handle, JobObjectInfoType.ExtendedLimitInformation, ptr, (uint)length))
                {
                    throw new InvalidOperationException("SetInformationJobObject failed.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(ptr);
            }
        }

        public void Assign(Process process)
        {
            if (!AssignProcessToJobObject(_handle, process.Handle))
            {
                throw new InvalidOperationException("AssignProcessToJobObject failed.");
            }
        }

        public void Terminate(uint exitCode)
        {
            TerminateJobObject(_handle, exitCode);
        }

        public void Dispose()
        {
            CloseHandle(_handle);
        }

        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string? lpName);

        [DllImport("kernel32.dll")]
        private static extern bool SetInformationJobObject(IntPtr hJob, JobObjectInfoType infoType, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll")]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll")]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        private enum JobObjectInfoType
        {
            ExtendedLimitInformation = 9
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public long Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }
    }
}
