using System.Text.Json;
using System.Text.RegularExpressions;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.IO.Pipes;
using System.Net;

namespace DomainManager.Helper;

internal static partial class Program
{
    private const int ProtocolVersion = 1;
    private const int MaximumRequestBytes = 128 * 1024;
    private const string PipeName = "DomainManager.Helper.v1";
    private const string MkcertCaRoot = @"C:\ProgramData\DomainManager\mkcert";
    internal const string CertificateRoot = @"C:\ProgramData\DomainManager\certificates";
    private const string ProjectStateRoot = @"C:\ProgramData\DomainManager\state";

    private static RuntimeSettings Runtime => RuntimeSettings.Current;

    public static async Task<int> Main(string[] args)
    {
        if (args.Length == 1 && args[0].Equals("--service", StringComparison.Ordinal))
            return WindowsServiceHost.Run("DomainManagerHelper", RunPipeServerAsync);

        if (args.Length == 1 && args[0].Equals("--pipe-server", StringComparison.Ordinal))
            return await RunPipeServerAsync(CancellationToken.None);

        return await ProcessStandardInputAsync();
    }

    private static async Task<int> ProcessStandardInputAsync()
    {
        try
        {
            string payload = await ReadBoundedRequestAsync(Console.OpenStandardInput());
            HelperRequest? request = JsonSerializer.Deserialize<HelperRequest>(payload, JsonOptions.Default);

            if (request is null)
            {
                return WriteError(null, "invalid_request", "Żądanie jest puste lub nieprawidłowe.");
            }

            if (request.Protocol != ProtocolVersion)
            {
                return WriteError(request.RequestId, "unsupported_protocol", "Nieobsługiwana wersja protokołu.");
            }

            if (!Guid.TryParse(request.RequestId, out _))
            {
                return WriteError(request.RequestId, "invalid_request_id", "request_id musi być prawidłowym UUID.");
            }

            return request.Action switch
            {
                "helper.status" => WriteSuccess(request.RequestId, new
                {
                    protocol = ProtocolVersion,
                    platform = "windows",
                    elevated = IsElevated(),
                    mkcert_available = File.Exists(Runtime.MkcertExecutable) && File.Exists(Path.Combine(MkcertCaRoot, "rootCA-key.pem")),
                    mkcert_executable_exists = File.Exists(Runtime.MkcertExecutable),
                    mkcert_ca_key_exists = File.Exists(Path.Combine(MkcertCaRoot, "rootCA-key.pem")),
                    allowed_php_versions = Runtime.PhpRuntimes.Keys,
                }),
                "apache.preview_project" => PreviewProject(request),
                "apache.diagnostics" => ApacheDiagnostics(request),
                "apache.reload" => ReloadApache(request),
                "apache.clear_error_log" => ClearApacheErrorLog(request),
                "project.apply" => ApplyProject(request),
                "project.delete" => DeleteProject(request),
                _ => WriteError(request.RequestId, "unknown_action", "Operacja nie znajduje się na liście dozwolonych operacji."),
            };
        }
        catch (RequestTooLargeException error)
        {
            return WriteError(null, "request_too_large", error.Message);
        }
        catch (JsonException)
        {
            return WriteError(null, "invalid_json", "Nie można odczytać żądania JSON.");
        }
        catch (Exception error)
        {
            return WriteError(null, "internal_error", error.Message);
        }
    }

    private static async Task<int> RunPipeServerAsync(CancellationToken cancellationToken)
    {
        if (!IsElevated())
            return WriteError(null, "elevation_required", "Serwer Named Pipe musi działać z uprawnieniami administratora.");

        PipeSecurity security = CreatePipeSecurity();
        Console.Error.WriteLine($"Domain Manager Helper nasłuchuje na \\.\\pipe\\{PipeName}.");

        while (!cancellationToken.IsCancellationRequested)
        {
            await using NamedPipeServerStream pipe = NamedPipeServerStreamAcl.Create(
                PipeName,
                PipeDirection.InOut,
                4,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.WriteThrough,
                4096,
                MaximumRequestBytes,
                security);

            try
            {
                await pipe.WaitForConnectionAsync(cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }

            try
            {
                string payload = await ReadPipeRequestAsync(pipe);
                string response = await CaptureResponseAsync(payload);
                byte[] bytes = System.Text.Encoding.UTF8.GetBytes(response.TrimEnd() + "\n");
                await pipe.WriteAsync(bytes);
                await pipe.FlushAsync();
            }
            catch (Exception error)
            {
                byte[] bytes = System.Text.Encoding.UTF8.GetBytes(SerializeError(null, "transport_error", error.Message) + "\n");
                await pipe.WriteAsync(bytes);
                await pipe.FlushAsync();
            }
        }

        return 0;
    }

    private static PipeSecurity CreatePipeSecurity()
    {
        var security = new PipeSecurity();
        security.SetAccessRuleProtection(true, false);
        AddPipeAccess(security, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null));
        AddPipeAccess(security, new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));

        var apacheAccount = new NTAccount($@"NT SERVICE\{Runtime.ApacheServiceName}");
        AddPipeAccess(security, (SecurityIdentifier)apacheAccount.Translate(typeof(SecurityIdentifier)));

        return security;
    }

    private static void AddPipeAccess(PipeSecurity security, SecurityIdentifier sid) =>
        security.AddAccessRule(new PipeAccessRule(sid, PipeAccessRights.ReadWrite, AccessControlType.Allow));

    private static async Task<string> CaptureResponseAsync(string payload)
    {
        TextWriter original = Console.Out;
        using var output = new StringWriter(System.Globalization.CultureInfo.InvariantCulture);
        Console.SetOut(output);
        try
        {
            using var input = new MemoryStream(System.Text.Encoding.UTF8.GetBytes(payload));
            await ProcessRequestAsync(input);
            return output.ToString();
        }
        finally
        {
            Console.SetOut(original);
        }
    }

    private static async Task<string> ReadPipeRequestAsync(Stream stream)
    {
        using var reader = new StreamReader(
            stream,
            System.Text.Encoding.UTF8,
            detectEncodingFromByteOrderMarks: false,
            bufferSize: 4096,
            leaveOpen: true);
        string? payload = await reader.ReadLineAsync();
        if (payload is null)
            throw new InvalidDataException("Klient nie przesłał żądania.");
        if (System.Text.Encoding.UTF8.GetByteCount(payload) > MaximumRequestBytes)
            throw new RequestTooLargeException($"Żądanie przekracza limit {MaximumRequestBytes} bajtów.");
        return payload;
    }

    private static async Task<int> ProcessRequestAsync(Stream input)
    {
        try
        {
            string payload = await ReadBoundedRequestAsync(input);
            HelperRequest? request = JsonSerializer.Deserialize<HelperRequest>(payload, JsonOptions.Default);

            if (request is null)
                return WriteError(null, "invalid_request", "Żądanie jest puste lub nieprawidłowe.");

            if (request.Protocol != ProtocolVersion)
                return WriteError(request.RequestId, "unsupported_protocol", "Nieobsługiwana wersja protokołu.");

            if (!Guid.TryParse(request.RequestId, out _))
                return WriteError(request.RequestId, "invalid_request_id", "request_id musi być prawidłowym UUID.");

            return request.Action switch
            {
                "helper.status" => WriteSuccess(request.RequestId, new
                {
                    protocol = ProtocolVersion,
                    platform = "windows",
                    elevated = IsElevated(),
                    transport = "named_pipe",
                    mkcert_available = File.Exists(Runtime.MkcertExecutable) && File.Exists(Path.Combine(MkcertCaRoot, "rootCA-key.pem")),
                    mkcert_executable_exists = File.Exists(Runtime.MkcertExecutable),
                    mkcert_ca_key_exists = File.Exists(Path.Combine(MkcertCaRoot, "rootCA-key.pem")),
                    allowed_php_versions = Runtime.PhpRuntimes.Keys,
                }),
                "apache.preview_project" => PreviewProject(request),
                "apache.diagnostics" => ApacheDiagnostics(request),
                "apache.reload" => ReloadApache(request),
                "apache.clear_error_log" => ClearApacheErrorLog(request),
                "project.apply" => ApplyProject(request),
                "project.delete" => DeleteProject(request),
                _ => WriteError(request.RequestId, "unknown_action", "Operacja nie znajduje się na liście dozwolonych operacji."),
            };
        }
        catch (RequestTooLargeException error)
        {
            return WriteError(null, "request_too_large", error.Message);
        }
        catch (JsonException)
        {
            return WriteError(null, "invalid_json", "Nie można odczytać żądania JSON.");
        }
        catch (Exception error)
        {
            return WriteError(null, "internal_error", error.Message);
        }
    }

    private static int PreviewProject(HelperRequest request)
    {
        if (request.Arguments.ValueKind != JsonValueKind.Object)
        {
            return WriteError(request.RequestId, "invalid_arguments", "Brak parametrów projektu.");
        }

        ProjectArguments? project = request.Arguments.Deserialize<ProjectArguments>(JsonOptions.Default);
        List<string> errors = ValidateProject(project);

        if (errors.Count > 0)
        {
            return WriteError(request.RequestId, "validation_failed", "Dane projektu są nieprawidłowe.", errors);
        }

        string configuration = ApacheProjectRenderer.Render(project!, Runtime.PhpRuntimes[project!.PhpVersion]);
        string target = Path.Combine(Runtime.ApacheRoot, "conf", "domain-manager", $"project-{project.ProjectId}.conf");
        string? currentHash = File.Exists(target) ? Hash(File.ReadAllBytes(target)) : null;
        string hostsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "drivers", "etc", "hosts");
        byte[] hostsBytes = File.ReadAllBytes(hostsPath);
        string hostsHash = Hash(hostsBytes);
        string certificateDirectory = Path.Combine(CertificateRoot, project.ProjectId.ToString(System.Globalization.CultureInfo.InvariantCulture));
        bool certificateReady = !project.HttpsEnabled || (
            File.Exists(Path.Combine(certificateDirectory, "certificate.pem")) &&
            File.Exists(Path.Combine(certificateDirectory, "private-key.pem")));
        bool configurationCurrent = string.Equals(
            currentHash,
            Hash(System.Text.Encoding.UTF8.GetBytes(configuration)),
            StringComparison.OrdinalIgnoreCase);
        bool hostsCurrent = ManagedHostsMatch(System.Text.Encoding.UTF8.GetString(hostsBytes), project);
        bool apacheRunning = IsApacheServiceRunning();
        return WriteSuccess(request.RequestId, new
        {
            configuration,
            current_hash = currentHash,
            hosts_hash = hostsHash,
            configuration_current = configurationCurrent,
            hosts_current = hostsCurrent,
            certificate_ready = certificateReady,
            apache_running = apacheRunning,
            configured = configurationCurrent && hostsCurrent && certificateReady && apacheRunning,
        });
    }

    private static int ApacheDiagnostics(HelperRequest request)
    {
        string httpd = Path.Combine(Runtime.ApacheRoot, "bin", "httpd.exe");
        if (!File.Exists(httpd))
            return WriteError(request.RequestId, "apache_not_found", "Nie znaleziono skonfigurowanej instalacji Apache.");

        ProcessResult test = Run(httpd, ["-t"], 15_000);
        IPEndPoint[] listeners = System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners();
        return WriteSuccess(request.RequestId, new
        {
            service_running = IsApacheServiceRunning(),
            configuration_valid = test.ExitCode == 0,
            configuration_test = test.Output,
            port_80_listening = listeners.Any(endpoint => endpoint.Port == 80),
            port_443_listening = listeners.Any(endpoint => endpoint.Port == 443),
            error_log = ReadApacheErrorLog(),
        });
    }

    private static int ReloadApache(HelperRequest request)
    {
        if (!IsElevated())
            return WriteError(request.RequestId, "elevation_required", "Operacja wymaga uruchomienia helpera jako administrator.");

        string httpd = Path.Combine(Runtime.ApacheRoot, "bin", "httpd.exe");
        ProcessResult test = Run(httpd, ["-t"], 15_000);
        if (test.ExitCode != 0)
            return WriteError(request.RequestId, "apache_config_invalid", "Test konfiguracji Apache nie powiódł się. Usługa nie została przeładowana.", [test.Output]);

        ProcessResult reload = Run(httpd, ["-k", "restart", "-n", Runtime.ApacheServiceName], 20_000);
        if (reload.ExitCode != 0 || !WaitForApacheHealthy())
            return WriteError(request.RequestId, "apache_reload_failed", "Nie udało się bezpiecznie przeładować Apache.", [reload.Output]);

        WriteAudit(request.RequestId, "apache.reload", 0, "completed", null);
        return WriteSuccess(request.RequestId, new { configuration_test = test.Output, reload_output = reload.Output });
    }

    private static int ClearApacheErrorLog(HelperRequest request)
    {
        if (!IsElevated())
            return WriteError(request.RequestId, "elevation_required", "Operacja wymaga uruchomienia helpera jako administrator.");

        string logDirectory = Path.Combine(Runtime.ApacheRoot, "logs");
        if (!Directory.Exists(logDirectory))
            return WriteError(request.RequestId, "apache_logs_not_found", "Nie znaleziono katalogu logów Apache.");

        long removedBytes = 0;
        int clearedFiles = 0;
        try
        {
            foreach (string path in Directory.EnumerateFiles(logDirectory, "error_log*", SearchOption.TopDirectoryOnly))
            {
                string name = Path.GetFileName(path);
                if (!Regex.IsMatch(name, @"^error_log(?:\.\d+)?$", RegexOptions.CultureInvariant)) continue;
                removedBytes += new FileInfo(path).Length;
                if (name.Equals("error_log", StringComparison.OrdinalIgnoreCase))
                {
                    using var stream = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                    stream.SetLength(0);
                }
                else
                {
                    File.Delete(path);
                }
                clearedFiles++;
            }
            WriteAudit(request.RequestId, "apache.clear_error_log", 0, "completed", null);
            return WriteSuccess(request.RequestId, new { cleared_files = clearedFiles, removed_bytes = removedBytes });
        }
        catch (Exception error)
        {
            WriteAudit(request.RequestId, "apache.clear_error_log", 0, "failed", error.Message);
            return WriteError(request.RequestId, "apache_log_clear_failed", "Nie udało się wyczyścić dziennika błędów Apache.", [error.Message]);
        }
    }

    private static string ReadApacheErrorLog()
    {
        string path = Path.Combine(Runtime.ApacheRoot, "logs", "error_log");
        if (!File.Exists(path)) return string.Empty;
        const int maximumBytes = 64 * 1024;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        long offset = Math.Max(0, stream.Length - maximumBytes);
        stream.Seek(offset, SeekOrigin.Begin);
        using var reader = new StreamReader(stream, System.Text.Encoding.UTF8, true);
        string text = reader.ReadToEnd();
        string[] lines = text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
        return string.Join(Environment.NewLine, lines.TakeLast(60));
    }

    private static int ApplyProject(HelperRequest request)
    {
        if (!IsElevated())
            return WriteError(request.RequestId, "elevation_required", "Operacja wymaga uruchomienia helpera jako administrator.");

        if (request.Arguments.ValueKind != JsonValueKind.Object)
            return WriteError(request.RequestId, "invalid_arguments", "Brak parametrów projektu.");

        ProjectArguments? project = request.Arguments.Deserialize<ProjectArguments>(JsonOptions.Default);
        List<string> errors = ValidateProject(project);

        if (project is not null && !string.IsNullOrWhiteSpace(project.RootPath) && !IsWithinAllowedRoot(project.RootPath, Runtime.AllowedProjectRoot))
            errors.Add($"DocumentRoot musi znajdować się w {Runtime.AllowedProjectRoot}.");

        if (project is not null && !string.IsNullOrWhiteSpace(project.RootPath) && ContainsReparsePoint(project.RootPath, Runtime.AllowedProjectRoot))
            errors.Add("DocumentRoot nie może prowadzić przez dowiązanie ani punkt ponownej analizy.");
        if (project is not null && !string.IsNullOrWhiteSpace(project.PreviousRootPath) &&
            (!Directory.Exists(project.PreviousRootPath) || !IsWithinAllowedRoot(project.PreviousRootPath, Runtime.AllowedProjectRoot) || ContainsReparsePoint(project.PreviousRootPath, Runtime.AllowedProjectRoot)))
            errors.Add("Poprzedni DocumentRoot jest niedostępny albo znajduje się poza dozwolonym katalogiem.");

        if (errors.Count > 0)
            return WriteError(request.RequestId, "validation_failed", "Dane projektu są nieprawidłowe.", errors);

        string httpd = Path.Combine(Runtime.ApacheRoot, "bin", "httpd.exe");
        string mainConfig = Path.Combine(Runtime.ApacheRoot, "conf", "httpd.conf");
        string managedDirectory = Path.Combine(Runtime.ApacheRoot, "conf", "domain-manager");
        string target = Path.Combine(managedDirectory, $"project-{project!.ProjectId}.conf");
        string hostsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "drivers", "etc", "hosts");
        string certificateDirectory = Path.Combine(CertificateRoot, project.ProjectId.ToString(System.Globalization.CultureInfo.InvariantCulture));

        if (!File.Exists(httpd) || !File.Exists(mainConfig))
            return WriteError(request.RequestId, "apache_not_found", "Nie znaleziono zatwierdzonej instalacji Apache.");

        string mainConfigText = File.ReadAllText(mainConfig);
        if (!ManagedIncludeRegex().IsMatch(mainConfigText))
            return WriteError(request.RequestId, "managed_include_missing", "W httpd.conf brakuje aktywnego IncludeOptional conf/domain-manager/*.conf.");

        Directory.CreateDirectory(managedDirectory);
        byte[]? previous = File.Exists(target) ? File.ReadAllBytes(target) : null;
        string? previousHash = previous is null ? null : Hash(previous);

        if (!string.Equals(project.ExpectedPreviousHash, previousHash, StringComparison.OrdinalIgnoreCase))
            return WriteError(request.RequestId, "configuration_conflict", "Konfiguracja projektu zmieniła się od czasu przygotowania operacji.");

        byte[] previousHosts = File.ReadAllBytes(hostsPath);
        if (!string.Equals(project.ExpectedHostsHash, Hash(previousHosts), StringComparison.OrdinalIgnoreCase))
            return WriteError(request.RequestId, "hosts_conflict", "Plik hosts zmienił się od czasu przygotowania operacji. Odśwież podgląd.");

        string hostsText = System.Text.Encoding.UTF8.GetString(previousHosts);
        string hostsWithoutProject = RemoveManagedHostsBlock(hostsText, project.ProjectId);
        List<string> hostConflicts = FindHostsConflicts(hostsWithoutProject, project.Domains);
        if (hostConflicts.Count > 0)
            return WriteError(request.RequestId, "hosts_domain_conflict", "Co najmniej jedna domena istnieje już poza zarządzanym blokiem projektu.", hostConflicts);

        string configuration = ApacheProjectRenderer.Render(project, Runtime.PhpRuntimes[project.PhpVersion]);
        byte[] next = System.Text.Encoding.UTF8.GetBytes(configuration);
        string staging = target + "." + request.RequestId + ".tmp";
        string certificateStaging = Path.Combine(CertificateRoot, $".staging-{project.ProjectId}-{request.RequestId}");
        byte[]? previousCertificate = ReadOptional(Path.Combine(certificateDirectory, "certificate.pem"));
        byte[]? previousPrivateKey = ReadOptional(Path.Combine(certificateDirectory, "private-key.pem"));
        string? previousProjectAcl = null;
        string statePath = ProjectStatePath(project.ProjectId);
        byte[]? previousState = ReadOptional(statePath);
        bool rootChanged = !string.IsNullOrWhiteSpace(project.PreviousRootPath) &&
            !Path.GetFullPath(project.PreviousRootPath).Equals(Path.GetFullPath(project.RootPath), StringComparison.OrdinalIgnoreCase);
        string? previousRootAcl = rootChanged ? GetDirectoryAcl(project.PreviousRootPath!) : null;

        try
        {
            if (project.HttpsEnabled)
                GenerateCertificate(project, certificateStaging, certificateDirectory);
            else if (Directory.Exists(certificateDirectory))
                Directory.Delete(certificateDirectory, true);

            previousProjectAcl = GrantProjectReadAccess(project.RootPath);
            // Stan ACL zapisujemy tylko przy pierwszym zastosowaniu projektu.
            // Starsze, już istniejące konfiguracje nie mają wiarygodnego ACL sprzed instalacji;
            // przy ich usuwaniu kasujemy więc wyłącznie dokładnie naszą regułę dostępu.
            if (!File.Exists(statePath) && previous is null)
            {
                WriteProjectState(statePath, new ProjectState(project.ProjectId, Path.GetFullPath(project.RootPath), previousProjectAcl));
            }
            else if (rootChanged)
            {
                WriteProjectState(statePath, new ProjectState(project.ProjectId, Path.GetFullPath(project.RootPath), previousProjectAcl));
            }
            File.WriteAllText(hostsPath, BuildManagedHosts(hostsWithoutProject, project), new System.Text.UTF8Encoding(false));
            File.WriteAllBytes(staging, next);
            File.Move(staging, target, true);
            ProcessResult test = Run(httpd, ["-t"], 15_000);

            if (test.ExitCode != 0)
            {
                Restore(target, previous);
                Restore(hostsPath, previousHosts);
                RestoreCertificate(certificateDirectory, previousCertificate, previousPrivateKey);
                RestoreDirectoryAcl(project.RootPath, previousProjectAcl);
                Restore(statePath, previousState);
                return WriteError(request.RequestId, "apache_config_invalid", "Test konfiguracji Apache nie powiódł się.", [test.Output]);
            }

            ProcessResult reload = Run(httpd, ["-k", "restart", "-n", Runtime.ApacheServiceName], 20_000);
            if (reload.ExitCode != 0 || !WaitForApacheHealthy())
            {
                Restore(target, previous);
                Restore(hostsPath, previousHosts);
                RestoreCertificate(certificateDirectory, previousCertificate, previousPrivateKey);
                RestoreDirectoryAcl(project.RootPath, previousProjectAcl);
                Restore(statePath, previousState);
                Run(httpd, ["-k", "restart", "-n", Runtime.ApacheServiceName], 20_000);
                return WriteError(request.RequestId, "apache_reload_failed", "Nie udało się przeładować Apache; przywrócono poprzednią konfigurację.", [reload.Output]);
            }

            if (rootChanged)
            {
                ProjectState? oldState = previousState is null ? null : JsonSerializer.Deserialize<ProjectState>(previousState, JsonOptions.Default);
                if (oldState is not null && Path.GetFullPath(oldState.RootPath).Equals(Path.GetFullPath(project.PreviousRootPath!), StringComparison.OrdinalIgnoreCase))
                    RestoreDirectoryAcl(project.PreviousRootPath!, oldState.OriginalAclSddl);
                else
                    RemoveProjectReadAccess(project.PreviousRootPath!);
            }

            WriteAudit(request.RequestId, "project.apply", project.ProjectId, "completed", null);
            return WriteSuccess(request.RequestId, new { path = target, hash = Hash(next), apache_test = test.Output });
        }
        catch (Exception error)
        {
            if (File.Exists(staging)) File.Delete(staging);
            if (Directory.Exists(certificateStaging)) Directory.Delete(certificateStaging, true);
            Restore(target, previous);
            Restore(hostsPath, previousHosts);
            RestoreCertificate(certificateDirectory, previousCertificate, previousPrivateKey);
            if (previousProjectAcl is not null) RestoreDirectoryAcl(project.RootPath, previousProjectAcl);
            if (rootChanged && previousRootAcl is not null) RestoreDirectoryAcl(project.PreviousRootPath!, previousRootAcl);
            Restore(statePath, previousState);
            WriteAudit(request.RequestId, "project.apply", project.ProjectId, "failed", error.Message);
            return WriteError(request.RequestId, "apply_failed", "Nie udało się zastosować konfiguracji Apache.", [error.Message]);
        }
    }

    private static int DeleteProject(HelperRequest request)
    {
        if (!IsElevated())
            return WriteError(request.RequestId, "elevation_required", "Operacja wymaga uruchomienia helpera jako administrator.");

        if (request.Arguments.ValueKind != JsonValueKind.Object)
            return WriteError(request.RequestId, "invalid_arguments", "Brak parametrów projektu.");

        ProjectArguments? project = request.Arguments.Deserialize<ProjectArguments>(JsonOptions.Default);
        List<string> errors = ValidateProject(project);
        if (project is not null && !string.IsNullOrWhiteSpace(project.RootPath) && !IsWithinAllowedRoot(project.RootPath, Runtime.AllowedProjectRoot))
            errors.Add($"DocumentRoot musi znajdować się w {Runtime.AllowedProjectRoot}.");
        if (errors.Count > 0)
            return WriteError(request.RequestId, "validation_failed", "Dane projektu są nieprawidłowe.", errors);

        string httpd = Path.Combine(Runtime.ApacheRoot, "bin", "httpd.exe");
        string target = Path.Combine(Runtime.ApacheRoot, "conf", "domain-manager", $"project-{project!.ProjectId}.conf");
        string hostsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "drivers", "etc", "hosts");
        string certificateDirectory = Path.Combine(CertificateRoot, project.ProjectId.ToString(System.Globalization.CultureInfo.InvariantCulture));
        string statePath = ProjectStatePath(project.ProjectId);
        byte[]? previousConfiguration = ReadOptional(target);
        byte[] previousHosts = File.ReadAllBytes(hostsPath);
        byte[]? previousCertificate = ReadOptional(Path.Combine(certificateDirectory, "certificate.pem"));
        byte[]? previousPrivateKey = ReadOptional(Path.Combine(certificateDirectory, "private-key.pem"));
        byte[]? previousState = ReadOptional(statePath);
        string currentAcl = GetDirectoryAcl(project.RootPath);

        if (!string.Equals(project.ExpectedPreviousHash, previousConfiguration is null ? null : Hash(previousConfiguration), StringComparison.OrdinalIgnoreCase))
            return WriteError(request.RequestId, "configuration_conflict", "Konfiguracja projektu zmieniła się od czasu przygotowania operacji.");
        if (!string.Equals(project.ExpectedHostsHash, Hash(previousHosts), StringComparison.OrdinalIgnoreCase))
            return WriteError(request.RequestId, "hosts_conflict", "Plik hosts zmienił się od czasu przygotowania operacji. Odśwież stronę.");

        try
        {
            Restore(target, null);
            File.WriteAllText(hostsPath, RemoveManagedHostsBlock(System.Text.Encoding.UTF8.GetString(previousHosts), project.ProjectId) + "\r\n", new System.Text.UTF8Encoding(false));
            if (Directory.Exists(certificateDirectory)) Directory.Delete(certificateDirectory, true);

            ProjectState? state = ReadProjectState(statePath);
            if (state is not null && state.ProjectId == project.ProjectId && Path.GetFullPath(state.RootPath).Equals(Path.GetFullPath(project.RootPath), StringComparison.OrdinalIgnoreCase))
                RestoreDirectoryAcl(project.RootPath, state.OriginalAclSddl);
            else
                RemoveProjectReadAccess(project.RootPath);

            ProcessResult test = Run(httpd, ["-t"], 15_000);
            if (test.ExitCode != 0) throw new InvalidOperationException("Test konfiguracji Apache nie powiódł się: " + test.Output);
            ProcessResult reload = Run(httpd, ["-k", "restart", "-n", Runtime.ApacheServiceName], 20_000);
            if (reload.ExitCode != 0 || !WaitForApacheHealthy())
                throw new InvalidOperationException("Nie udało się przeładować Apache: " + reload.Output);

            if (File.Exists(statePath)) File.Delete(statePath);
            WriteAudit(request.RequestId, "project.delete", project.ProjectId, "completed", null);
            return WriteSuccess(request.RequestId, new { removed = true, apache_test = test.Output });
        }
        catch (Exception error)
        {
            Restore(target, previousConfiguration);
            Restore(hostsPath, previousHosts);
            RestoreCertificate(certificateDirectory, previousCertificate, previousPrivateKey);
            Restore(statePath, previousState);
            RestoreDirectoryAcl(project.RootPath, currentAcl);
            Run(httpd, ["-k", "restart", "-n", Runtime.ApacheServiceName], 20_000);
            WriteAudit(request.RequestId, "project.delete", project.ProjectId, "failed", error.Message);
            return WriteError(request.RequestId, "delete_failed", "Nie udało się bezpiecznie usunąć konfiguracji projektu; przywrócono poprzedni stan.", [error.Message]);
        }
    }

    private static void GenerateCertificate(ProjectArguments project, string stagingDirectory, string targetDirectory)
    {
        if (!File.Exists(Runtime.MkcertExecutable) || !File.Exists(Path.Combine(MkcertCaRoot, "rootCA-key.pem")))
            throw new InvalidOperationException("Nie znaleziono przygotowanego mkcert lub klucza lokalnego CA.");

        Directory.CreateDirectory(stagingDirectory);
        string certificate = Path.Combine(stagingDirectory, "certificate.pem");
        string privateKey = Path.Combine(stagingDirectory, "private-key.pem");
        var arguments = new List<string> { "-cert-file", certificate, "-key-file", privateKey };
        arguments.AddRange(project.Domains);
        ProcessResult result = Run(Runtime.MkcertExecutable, arguments, 30_000, new Dictionary<string, string> { ["CAROOT"] = MkcertCaRoot });
        if (result.ExitCode != 0 || !File.Exists(certificate) || !File.Exists(privateKey))
            throw new InvalidOperationException("Generowanie certyfikatu nie powiodło się: " + result.Output);

        Directory.CreateDirectory(targetDirectory);
        File.Move(certificate, Path.Combine(targetDirectory, "certificate.pem"), true);
        File.Move(privateKey, Path.Combine(targetDirectory, "private-key.pem"), true);
        GrantApacheReadAccess(CertificateRoot);
        GrantApacheReadAccess(targetDirectory);
        Directory.Delete(stagingDirectory, true);
    }

    private static void GrantApacheReadAccess(string path)
    {
        var directory = new DirectoryInfo(path);
        DirectorySecurity acl = directory.GetAccessControl(AccessControlSections.Access);
        var account = new NTAccount($@"NT SERVICE\{Runtime.ApacheServiceName}");
        var sid = (SecurityIdentifier)account.Translate(typeof(SecurityIdentifier));
        acl.AddAccessRule(new FileSystemAccessRule(
            sid,
            FileSystemRights.Read,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        directory.SetAccessControl(acl);
    }

    private static bool WaitForApacheHealthy()
    {
        using var handler = new HttpClientHandler { AllowAutoRedirect = false };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(2) };
        for (int attempt = 0; attempt < 10; attempt++)
        {
            Thread.Sleep(500);
            try
            {
                using HttpResponseMessage response = client.GetAsync("http://domain-manager.localhost/").GetAwaiter().GetResult();
                if ((int)response.StatusCode >= 200 && (int)response.StatusCode < 400) return true;
            }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) { }
        }
        return false;
    }

    private static bool IsApacheServiceRunning()
    {
        string serviceControl = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "sc.exe");
        ProcessResult result = Run(serviceControl, ["query", Runtime.ApacheServiceName], 5_000);
        return result.ExitCode == 0 && Regex.IsMatch(result.Output, @"STATE\s*:\s*4\s+RUNNING", RegexOptions.IgnoreCase);
    }

    private static string RemoveManagedHostsBlock(string contents, int projectId)
    {
        string id = projectId.ToString(System.Globalization.CultureInfo.InvariantCulture);
        string pattern = $@"(?ms)^# BEGIN Domain Manager project:{Regex.Escape(id)}\r?\n.*?^# END Domain Manager project:{Regex.Escape(id)}\r?\n?";
        return Regex.Replace(contents, pattern, string.Empty).TrimEnd('\r', '\n');
    }

    private static List<string> FindHostsConflicts(string contents, IEnumerable<string> domains)
    {
        var wanted = domains.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var conflicts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string rawLine in contents.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            string line = rawLine.Split('#', 2)[0];
            string[] parts = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            foreach (string hostname in parts.Skip(1))
                if (wanted.Contains(hostname)) conflicts.Add(hostname);
        }
        return conflicts.Order(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static string BuildManagedHosts(string previous, ProjectArguments project)
    {
        string id = project.ProjectId.ToString(System.Globalization.CultureInfo.InvariantCulture);
        var lines = new List<string> { previous, string.Empty, $"# BEGIN Domain Manager project:{id}" };
        lines.AddRange(project.Domains.Select(domain => $"127.0.0.1 {domain}"));
        lines.AddRange(project.Domains.Select(domain => $"::1 {domain}"));
        lines.Add($"# END Domain Manager project:{id}");
        return string.Join("\r\n", lines) + "\r\n";
    }

    private static bool ManagedHostsMatch(string contents, ProjectArguments project)
    {
        string id = project.ProjectId.ToString(System.Globalization.CultureInfo.InvariantCulture);
        Match match = Regex.Match(
            contents,
            $@"(?ms)^# BEGIN Domain Manager project:{Regex.Escape(id)}\r?\n(.*?)^# END Domain Manager project:{Regex.Escape(id)}\r?$");
        if (!match.Success) return false;

        var expected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string domain in project.Domains)
        {
            expected.Add($"127.0.0.1 {domain}");
            expected.Add($"::1 {domain}");
        }
        var actual = match.Groups[1].Value
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(line => Regex.Replace(line, @"\s+", " "))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        return actual.SetEquals(expected);
    }

    private static byte[]? ReadOptional(string path) => File.Exists(path) ? File.ReadAllBytes(path) : null;

    private static void RestoreCertificate(string directory, byte[]? certificate, byte[]? privateKey)
    {
        if (certificate is null && privateKey is null)
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
            return;
        }
        Directory.CreateDirectory(directory);
        Restore(Path.Combine(directory, "certificate.pem"), certificate);
        Restore(Path.Combine(directory, "private-key.pem"), privateKey);
    }

    private static List<string> ValidateProject(ProjectArguments? project)
    {
        var errors = new List<string>();

        if (project is null)
        {
            errors.Add("Nie przekazano projektu.");
            return errors;
        }

        if (project.ProjectId <= 0)
            errors.Add("project_id musi być dodatnią liczbą całkowitą.");

        if (string.IsNullOrWhiteSpace(project.RootPath) || !Path.IsPathFullyQualified(project.RootPath) || !Directory.Exists(project.RootPath))
            errors.Add("root_path musi wskazywać istniejący katalog bezwzględny.");

        if (project.RootPath?.IndexOfAny(['\r', '\n', '"']) >= 0)
            errors.Add("root_path zawiera niedozwolone znaki.");

        if (!Runtime.PhpRuntimes.TryGetValue(project.PhpVersion, out string? phpCgi) || !File.Exists(phpCgi))
            errors.Add("Wybrany runtime PHP nie jest dozwolony lub nie istnieje.");

        if (project.Domains is null || project.Domains.Count == 0)
        {
            errors.Add("Projekt musi mieć co najmniej jedną domenę.");
        }
        else
        {
            if (project.Domains.Count > 50)
                errors.Add("Projekt może mieć maksymalnie 50 domen.");

            foreach (string domain in project.Domains)
            {
                if (!DomainRegex().IsMatch(domain) || domain.Length > 253)
                    errors.Add($"Nieprawidłowa domena: {domain}");
            }

            if (project.Domains.Distinct(StringComparer.OrdinalIgnoreCase).Count() != project.Domains.Count)
                errors.Add("Domeny projektu nie mogą się powtarzać.");

            if (!project.Domains.Contains(project.PrimaryDomain, StringComparer.OrdinalIgnoreCase))
                errors.Add("Domena główna nie znajduje się na liście domen projektu.");
        }

        return errors;
    }

    private static bool IsWithinAllowedRoot(string path, string allowedRoot)
    {
        string fullPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string fullRoot = Path.GetFullPath(allowedRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return fullPath.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase);
    }

    private static bool ContainsReparsePoint(string path, string allowedRoot)
    {
        string root = Path.GetFullPath(allowedRoot).TrimEnd(Path.DirectorySeparatorChar);
        string current = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);

        while (current.Length >= root.Length)
        {
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                return true;

            if (current.Equals(root, StringComparison.OrdinalIgnoreCase))
                break;

            string? parent = Directory.GetParent(current)?.FullName;
            if (parent is null || parent.Equals(current, StringComparison.OrdinalIgnoreCase))
                break;
            current = parent;
        }

        return false;
    }

    private static string GrantProjectReadAccess(string path)
    {
        var directory = new DirectoryInfo(path);
        DirectorySecurity acl = directory.GetAccessControl(AccessControlSections.Access);
        string previousSddl = acl.GetSecurityDescriptorSddlForm(AccessControlSections.Access);
        var serviceAccount = new NTAccount($@"NT SERVICE\{Runtime.ApacheServiceName}");
        SecurityIdentifier serviceSid = (SecurityIdentifier)serviceAccount.Translate(typeof(SecurityIdentifier));
        var rule = new FileSystemAccessRule(
            serviceSid,
            FileSystemRights.ReadAndExecute,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow);
        acl.AddAccessRule(rule);
        directory.SetAccessControl(acl);
        return previousSddl;
    }

    private static string GetDirectoryAcl(string path)
    {
        var directory = new DirectoryInfo(path);
        return directory.GetAccessControl(AccessControlSections.Access)
            .GetSecurityDescriptorSddlForm(AccessControlSections.Access);
    }

    private static void RemoveProjectReadAccess(string path)
    {
        var directory = new DirectoryInfo(path);
        DirectorySecurity acl = directory.GetAccessControl(AccessControlSections.Access);
        var serviceAccount = new NTAccount($@"NT SERVICE\{Runtime.ApacheServiceName}");
        SecurityIdentifier serviceSid = (SecurityIdentifier)serviceAccount.Translate(typeof(SecurityIdentifier));
        var rule = new FileSystemAccessRule(
            serviceSid,
            FileSystemRights.ReadAndExecute,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow);
        acl.RemoveAccessRuleSpecific(rule);
        directory.SetAccessControl(acl);
    }

    private static string ProjectStatePath(int projectId) =>
        Path.Combine(ProjectStateRoot, $"project-{projectId.ToString(System.Globalization.CultureInfo.InvariantCulture)}.json");

    private static void WriteProjectState(string path, ProjectState state)
    {
        Directory.CreateDirectory(ProjectStateRoot);
        string temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(state, JsonOptions.Default), new System.Text.UTF8Encoding(false));
        File.Move(temporary, path, true);
    }

    private static ProjectState? ReadProjectState(string path)
    {
        if (!File.Exists(path)) return null;
        return JsonSerializer.Deserialize<ProjectState>(File.ReadAllText(path), JsonOptions.Default);
    }

    private static void RestoreDirectoryAcl(string path, string previousSddl)
    {
        var directory = new DirectoryInfo(path);
        DirectorySecurity acl = directory.GetAccessControl(AccessControlSections.Access);
        acl.SetSecurityDescriptorSddlForm(previousSddl, AccessControlSections.Access);
        directory.SetAccessControl(acl);
    }

    private static void Restore(string target, byte[]? previous)
    {
        if (previous is null)
        {
            if (File.Exists(target)) File.Delete(target);
            return;
        }

        string restore = target + ".rollback.tmp";
        File.WriteAllBytes(restore, previous);
        File.Move(restore, target, true);
    }

    private static ProcessResult Run(string executable, IReadOnlyList<string> arguments, int timeoutMilliseconds, IReadOnlyDictionary<string, string>? environment = null)
    {
        var startInfo = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (string argument in arguments) startInfo.ArgumentList.Add(argument);
        if (environment is not null)
            foreach ((string key, string value) in environment) startInfo.Environment[key] = value;

        using Process process = Process.Start(startInfo) ?? throw new InvalidOperationException("Nie można uruchomić procesu Apache.");
        string stdout = process.StandardOutput.ReadToEnd();
        string stderr = process.StandardError.ReadToEnd();
        if (!process.WaitForExit(timeoutMilliseconds))
        {
            process.Kill(true);
            throw new TimeoutException("Proces Apache przekroczył limit czasu.");
        }

        return new ProcessResult(process.ExitCode, (stdout + "\n" + stderr).Trim());
    }

    private static string Hash(byte[] content) => "sha256:" + Convert.ToHexString(SHA256.HashData(content)).ToLowerInvariant();

    private static void WriteAudit(string requestId, string action, int projectId, string status, string? error)
    {
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "DomainManager", "logs");
        Directory.CreateDirectory(directory);
        string line = JsonSerializer.Serialize(new { timestamp = DateTimeOffset.UtcNow, request_id = requestId, action, project_id = projectId, status, error }, JsonOptions.Default);
        File.AppendAllText(Path.Combine(directory, "helper-audit.jsonl"), line + Environment.NewLine);
    }

    private static async Task<string> ReadBoundedRequestAsync(Stream stream)
    {
        using var buffer = new MemoryStream();
        var chunk = new byte[4096];
        int read;

        while ((read = await stream.ReadAsync(chunk)) > 0)
        {
            if (buffer.Length + read > MaximumRequestBytes)
                throw new RequestTooLargeException($"Żądanie przekracza limit {MaximumRequestBytes} bajtów.");

            buffer.Write(chunk, 0, read);
        }

        return System.Text.Encoding.UTF8.GetString(buffer.ToArray());
    }

    private static bool IsElevated()
    {
        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        var principal = new System.Security.Principal.WindowsPrincipal(identity);
        return principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
    }

    private static int WriteSuccess(string requestId, object data)
    {
        Console.WriteLine(JsonSerializer.Serialize(new { ok = true, request_id = requestId, data }, JsonOptions.Default));
        return 0;
    }

    private static int WriteError(string? requestId, string code, string message, IEnumerable<string>? details = null)
    {
        Console.WriteLine(SerializeError(requestId, code, message, details));
        return 1;
    }

    private static string SerializeError(string? requestId, string code, string message, IEnumerable<string>? details = null) =>
        JsonSerializer.Serialize(new { ok = false, request_id = requestId, error = new { code, message, details } }, JsonOptions.Default);

    [GeneratedRegex(@"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DomainRegex();

    [GeneratedRegex("""(?im)^\s*IncludeOptional\s+["']?conf/domain-manager/\*\.conf["']?\s*$""", RegexOptions.CultureInvariant)]
    private static partial Regex ManagedIncludeRegex();
}

internal sealed record HelperRequest(int Protocol, string RequestId, string Action, JsonElement Arguments);

internal sealed record ProjectArguments(
    int ProjectId,
    string RootPath,
    string PhpVersion,
    string PrimaryDomain,
    List<string> Domains,
    bool HttpsEnabled,
    string? ExpectedPreviousHash = null,
    string? ExpectedHostsHash = null,
    string? PreviousRootPath = null);

internal sealed record ProjectState(int ProjectId, string RootPath, string OriginalAclSddl);

internal static class ApacheProjectRenderer
{
    public static string Render(ProjectArguments project, string phpCgi)
    {
        string root = ApachePath(project.RootPath);
        phpCgi = ApachePath(phpCgi);
        string phpDirectory = ApachePath(Path.GetDirectoryName(phpCgi)!);
        IEnumerable<string> aliases = project.Domains.Where(domain =>
            !domain.Equals(project.PrimaryDomain, StringComparison.OrdinalIgnoreCase));
        string aliasLine = aliases.Any() ? $"    ServerAlias {string.Join(' ', aliases)}\n" : string.Empty;
        string common =
               $"    ServerName {project.PrimaryDomain}\n" + aliasLine +
               $"    DocumentRoot \"{root}\"\n" +
               $"    <Directory \"{root}\">\n" +
               "        Options FollowSymLinks ExecCGI\n" +
               "        AllowOverride All\n" +
               "        Require all granted\n" +
               "        DirectoryIndex index.php index.html\n" +
               "    </Directory>\n" +
               $"    FcgidInitialEnv PHPRC \"{phpDirectory}\"\n" +
               "    <FilesMatch \"\\.php$\">\n" +
               "        SetHandler fcgid-script\n" +
               "    </FilesMatch>\n" +
               $"    FcgidWrapper \"{phpCgi}\" .php\n";
        string configuration = "<VirtualHost *:80>\n" + common + "</VirtualHost>\n";
        if (project.HttpsEnabled)
        {
            string certificateDirectory = ApachePath(Path.Combine(Program.CertificateRoot, project.ProjectId.ToString(System.Globalization.CultureInfo.InvariantCulture)));
            configuration += "\n<VirtualHost *:443>\n" + common +
                "    SSLEngine on\n" +
                $"    SSLCertificateFile \"{certificateDirectory}/certificate.pem\"\n" +
                $"    SSLCertificateKeyFile \"{certificateDirectory}/private-key.pem\"\n" +
                "</VirtualHost>\n";
        }
        return configuration;
    }

    private static string ApachePath(string path) => path.Replace('\\', '/');
}

internal static class JsonOptions
{
    public static readonly JsonSerializerOptions Default = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = false,
        WriteIndented = false,
    };
}

internal sealed class RequestTooLargeException(string message) : Exception(message);

internal sealed record ProcessResult(int ExitCode, string Output);
