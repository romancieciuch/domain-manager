<?php

declare(strict_types=1);

use DomainManager\Application\Project\ProjectInput;
use DomainManager\Infrastructure\Database\MigrationRunner;
use DomainManager\Infrastructure\Database\SqliteConnection;
use DomainManager\Infrastructure\Database\SqliteProjectRepository;
use DomainManager\Infrastructure\Database\SqliteOperationHistoryRepository;
use DomainManager\Infrastructure\Helper\WindowsNamedPipeClient;
use DomainManager\Infrastructure\Platform\Windows\WindowsEnvironmentInspector;

require dirname(__DIR__) . '/bootstrap.php';

$config = require dirname(__DIR__) . '/config/app.php';
$sessionPath = $config['paths']['sessions'];
if (!is_dir($sessionPath) && !mkdir($sessionPath, 0700, true) && !is_dir($sessionPath)) {
    throw new RuntimeException('Nie można utworzyć katalogu sesji Domain Managera.');
}
session_name('domain_manager_session');
session_save_path($sessionPath);
session_set_cookie_params([
    'lifetime' => 0,
    'path' => '/',
    'secure' => isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off',
    'httponly' => true,
    'samesite' => 'Strict',
]);
session_start();
$database = SqliteConnection::open($config['database']['path']);
(new MigrationRunner($database, dirname(__DIR__) . '/database/migrations'))->migrate();
$repository = new SqliteProjectRepository($database);
$operationHistory = new SqliteOperationHistoryRepository($database);
$requestPath = rawurldecode((string) (parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/'));
$requestPath = '/' . trim($requestPath, '/');
$routeProjectId = null;
$page = match (true) {
    $requestPath === '/', $requestPath === '/projects', $requestPath === '/projects/new' => 'projects',
    preg_match('~^/projects/\d+/edit$~D', $requestPath) === 1 => 'projects',
    $requestPath === '/environment' => 'environment',
    $requestPath === '/operations' => 'operations',
    $requestPath === '/apache' => 'apache-diagnostics',
    preg_match('~^/projects/(\d+)/apache$~D', $requestPath, $routeMatch) === 1 => 'apache',
    default => 'not-found',
};
if (isset($routeMatch[1])) $routeProjectId = (int) $routeMatch[1];

if ($_SERVER['REQUEST_METHOD'] === 'GET' && isset($_GET['page'])) {
    $legacyPage = (string) $_GET['page'];
    if ($legacyPage === 'environment') {
        header('Location: /environment/', true, 301);
        exit;
    }
    if ($legacyPage === 'apache' && filter_input(INPUT_GET, 'project', FILTER_VALIDATE_INT)) {
        header('Location: /projects/' . (int) $_GET['project'] . '/apache/', true, 301);
        exit;
    }
}

if (!isset($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}

$errors = [];
$showForm = $requestPath === '/projects/new' || isset($_GET['add']);
$old = [];
$editingProjectId = preg_match('~^/projects/(\d+)/edit$~D', $requestPath, $editMatch) === 1
    ? (int) $editMatch[1]
    : (filter_input(INPUT_GET, 'edit', FILTER_VALIDATE_INT) ?: null);
if ($editingProjectId !== null) $page = 'projects';

if ($editingProjectId !== null) {
    $editingProject = $repository->find($editingProjectId);

    if ($editingProject === null) {
        $_SESSION['flash_error'] = 'Nie znaleziono projektu do edycji.';
        header('Location: /');
        exit;
    }

    $showForm = true;
    $old = [
        'name' => $editingProject->name,
        'root_path' => $editingProject->rootPath,
        'php_version' => $editingProject->phpVersion,
        'https_enabled' => $editingProject->httpsEnabled ? '1' : null,
        'domains' => array_map(static fn ($domain): string => $domain->value, $editingProject->domains),
        'primary_domain' => (string) $editingProject->primaryDomainIndex,
    ];
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = (string) ($_POST['action'] ?? 'save');

    if (!hash_equals($_SESSION['csrf_token'], (string) ($_POST['csrf_token'] ?? ''))) {
        $errors[] = 'Sesja formularza wygasła. Odśwież stronę i spróbuj ponownie.';
    } elseif ($action === 'apply_apache') {
        $projectId = filter_var($_POST['project_id'] ?? null, FILTER_VALIDATE_INT);
        $project = $projectId === false ? null : $repository->find($projectId);

        if ($project === null) {
            $_SESSION['flash_error'] = 'Nie znaleziono projektu do zastosowania w Apache.';
        } else {
            $operationId = $operationHistory->start('project.sync', $project->id, $project->name);
            try {
                $pipeConfig = $config['helper']['windows'];
                (new WindowsNamedPipeClient(
                    $pipeConfig['pipe_name'],
                    $config['helper']['protocol_version'],
                    $config['helper']['timeout_seconds'],
                ))->call('project.apply', projectHelperArguments(
                    $project,
                    ($_POST['expected_previous_hash'] ?? '') !== '' ? (string) $_POST['expected_previous_hash'] : null,
                    ($_POST['expected_hosts_hash'] ?? '') !== '' ? (string) $_POST['expected_hosts_hash'] : null,
                ));
                $operationHistory->complete($operationId);
                $_SESSION['flash'] = 'Domeny, certyfikat i VirtualHost zostały zastosowane. Apache został przeładowany.';
            } catch (Throwable $error) {
                $operationHistory->fail($operationId, $error->getMessage());
                $_SESSION['flash_error'] = $error->getMessage();
            }
        }

        header('Location: /');
        exit;
    } elseif (in_array($action, ['apache_test', 'apache_reload', 'apache_clear_log'], true)) {
        $operationType = match ($action) {
            'apache_reload' => 'apache.reload',
            'apache_clear_log' => 'apache.clear_error_log',
            default => 'apache.test',
        };
        $operationId = $operationHistory->start($operationType, null, 'Apache');
        try {
            $pipeConfig = $config['helper']['windows'];
            $client = new WindowsNamedPipeClient(
                $pipeConfig['pipe_name'],
                $config['helper']['protocol_version'],
                $config['helper']['timeout_seconds'],
            );
            $helperAction = match ($action) {
                'apache_reload' => 'apache.reload',
                'apache_clear_log' => 'apache.clear_error_log',
                default => 'apache.diagnostics',
            };
            $result = $client->call($helperAction);
            if ($action === 'apache_test' && ($result['configuration_valid'] ?? false) !== true) {
                throw new RuntimeException('Konfiguracja Apache jest nieprawidłowa: ' . (string) ($result['configuration_test'] ?? 'brak szczegółów'));
            }
            $operationHistory->complete($operationId);
            $_SESSION['flash'] = match ($action) {
                'apache_reload' => 'Konfiguracja jest poprawna, a Apache został przeładowany.',
                'apache_clear_log' => 'Dziennik błędów Apache został wyczyszczony.',
                default => 'Test konfiguracji Apache zakończył się powodzeniem.',
            };
        } catch (Throwable $error) {
            $operationHistory->fail($operationId, $error->getMessage());
            $_SESSION['flash_error'] = $error->getMessage();
        }
        header('Location: /apache/');
        exit;
    } elseif ($action === 'delete') {
        $projectId = filter_var($_POST['project_id'] ?? null, FILTER_VALIDATE_INT);
        $project = $projectId === false ? null : $repository->find($projectId);

        if ($project === null) {
            $_SESSION['flash_error'] = 'Nie znaleziono projektu do usunięcia.';
        } else {
            $operationId = $operationHistory->start('project.delete', $project->id, $project->name);
            try {
                $pipeConfig = $config['helper']['windows'];
                (new WindowsNamedPipeClient(
                    $pipeConfig['pipe_name'],
                    $config['helper']['protocol_version'],
                    $config['helper']['timeout_seconds'],
                ))->call('project.delete', projectHelperArguments(
                    $project,
                    ($_POST['expected_previous_hash'] ?? '') !== '' ? (string) $_POST['expected_previous_hash'] : null,
                    ($_POST['expected_hosts_hash'] ?? '') !== '' ? (string) $_POST['expected_hosts_hash'] : null,
                ));

                if (!$repository->delete($project->id)) {
                    throw new RuntimeException('Konfiguracja systemowa została usunięta, ale nie udało się usunąć rekordu z bazy. Projekt można ponownie zsynchronizować.');
                }

                $operationHistory->complete($operationId);
                $_SESSION['flash'] = 'Projekt oraz jego konfiguracja Apache, wpisy hosts i certyfikat zostały usunięte. Pliki projektu pozostały bez zmian.';
            } catch (Throwable $error) {
                $operationHistory->fail($operationId, $error->getMessage());
                $_SESSION['flash_error'] = $error->getMessage();
            }
        }

        header('Location: /');
        exit;
    } else {
        $showForm = true;
        $old = $_POST;
        $editingProjectId = filter_var($_POST['project_id'] ?? null, FILTER_VALIDATE_INT) ?: null;
        $result = (new ProjectInput($config['php']['available_versions']))->validate($_POST);
        $errors = $result['errors'];

        if ($result['project'] !== null) {
            try {
                $previousProject = $editingProjectId === null ? null : $repository->find($editingProjectId);
                if ($editingProjectId !== null && $previousProject === null) {
                    throw new RuntimeException('Projekt nie istnieje.');
                }

                if ($editingProjectId === null) {
                    $savedProjectId = $repository->create($result['project']);
                } else {
                    $repository->update($editingProjectId, $result['project']);
                    $savedProjectId = $editingProjectId;
                }

                $operationId = $operationHistory->start(
                    $editingProjectId === null ? 'project.create' : 'project.update',
                    $savedProjectId,
                    $result['project']->name,
                );
                try {
                    $savedProject = $repository->find($savedProjectId);
                    if ($savedProject === null) throw new RuntimeException('Nie udało się odczytać zapisanego projektu.');

                    $helperConfig = $config['helper']['windows'];
                    $preview = (new WindowsNamedPipeClient(
                        $helperConfig['pipe_name'],
                        $config['helper']['protocol_version'],
                        min(5, $config['helper']['timeout_seconds']),
                    ))->call('apache.preview_project', projectHelperArguments($savedProject));

                    (new WindowsNamedPipeClient(
                        $helperConfig['pipe_name'],
                        $config['helper']['protocol_version'],
                        $config['helper']['timeout_seconds'],
                    ))->call('project.apply', projectHelperArguments(
                        $savedProject,
                        is_string($preview['current_hash'] ?? null) ? $preview['current_hash'] : null,
                        is_string($preview['hosts_hash'] ?? null) ? $preview['hosts_hash'] : null,
                        $previousProject?->rootPath,
                    ));
                    $operationHistory->complete($operationId);
                } catch (Throwable $systemError) {
                    if ($previousProject === null) {
                        $repository->delete($savedProjectId);
                    } else {
                        $repository->update($savedProjectId, $previousProject);
                    }
                    $operationHistory->fail($operationId, $systemError->getMessage());
                    throw new RuntimeException(
                        'Nie udało się zastosować środowiska. Zapis w bazie został cofnięty. ' . $systemError->getMessage(),
                        0,
                        $systemError,
                    );
                }

                $_SESSION['flash'] = $editingProjectId === null
                    ? 'Projekt został dodany, a domeny, HTTPS i Apache są już aktywne.'
                    : 'Zmiany zostały zapisane i zsynchronizowane z Apache.';

                header('Location: /');
                exit;
            } catch (Throwable $error) {
                $errors[] = $error->getMessage();
            }
        }
    }
}

$projects = $repository->all();
$projectStatuses = [];
$helperConfig = $config['helper']['windows'];
$previewClient = new WindowsNamedPipeClient(
    $helperConfig['pipe_name'],
    $config['helper']['protocol_version'],
    min(5, $config['helper']['timeout_seconds']),
);
foreach ($projects as $project) {
    try {
        $status = $previewClient->call('apache.preview_project', projectHelperArguments($project));
        $missingParts = [];
        if (($status['configuration_current'] ?? false) !== true) $missingParts[] = 'VirtualHost';
        if (($status['hosts_current'] ?? false) !== true) $missingParts[] = 'hosts';
        if (($status['certificate_ready'] ?? false) !== true) $missingParts[] = 'certyfikat';
        if (($status['apache_running'] ?? false) !== true) $missingParts[] = 'Apache';
        $projectStatuses[$project->id] = [
            'active' => ($status['configured'] ?? false) === true,
            'label' => ($status['configured'] ?? false) === true ? 'Aktywny' : 'Wymaga synchronizacji',
            'apache' => ($status['apache_running'] ?? false) === true ? 'Apache działa' : 'Apache zatrzymany',
            'detail' => $missingParts === [] ? 'Całe środowisko jest zsynchronizowane.' : 'Do synchronizacji: ' . implode(', ', $missingParts),
            'config_hash' => is_string($status['current_hash'] ?? null) ? $status['current_hash'] : null,
            'hosts_hash' => is_string($status['hosts_hash'] ?? null) ? $status['hosts_hash'] : null,
        ];
    } catch (Throwable $error) {
        $projectStatuses[$project->id] = [
            'active' => false,
            'label' => 'Błąd statusu',
            'apache' => $error->getMessage(),
            'detail' => $error->getMessage(),
            'config_hash' => null,
            'hosts_hash' => null,
        ];
    }
}
$availablePhpVersions = $config['php']['available_versions'];
$defaultPhpVersion = $config['php']['default_version'];
$environment = $page === 'environment'
    ? (new WindowsEnvironmentInspector(
        $config['php']['available_versions'],
        $config['php']['windows_search_roots'],
        $config['apache']['windows_search_roots'],
    ))->inspect()
    : null;
$operations = $page === 'operations' ? $operationHistory->recent() : [];
$apacheDiagnostics = null;
if ($page === 'apache-diagnostics') {
    try {
        $pipeConfig = $config['helper']['windows'];
        $apacheDiagnostics = (new WindowsNamedPipeClient(
            $pipeConfig['pipe_name'],
            $config['helper']['protocol_version'],
            min(10, $config['helper']['timeout_seconds']),
        ))->call('apache.diagnostics');
    } catch (Throwable $error) {
        $_SESSION['flash_error'] = $error->getMessage();
    }
}

if ($environment !== null) {
    try {
        $pipeConfig = $config['helper']['windows'];
        $helperStatus = (new WindowsNamedPipeClient(
            $pipeConfig['pipe_name'],
            $config['helper']['protocol_version'],
            min(5, $config['helper']['timeout_seconds']),
        ))->call('helper.status');
        $environment['required'][] = [
            'name' => 'Helper systemowy',
            'state' => ($helperStatus['elevated'] ?? false) === true ? 'available' : 'warning',
            'version' => 'protokół ' . ($helperStatus['protocol'] ?? '?'),
            'detail' => 'Usługa działa, a zabezpieczony Named Pipe odpowiada.',
        ];
        foreach ($environment['optional'] as &$optionalComponent) {
            if ($optionalComponent['name'] === 'mkcert') {
                $mkcertStatusSupported = array_key_exists('mkcert_available', $helperStatus);
                $mkcertAvailable = ($helperStatus['mkcert_available'] ?? false) === true;
                $mkcertDetail = match (true) {
                    !$mkcertStatusSupported => 'Zainstalowana usługa helpera wymaga aktualizacji.',
                    ($helperStatus['mkcert_executable_exists'] ?? false) !== true => 'Helper nie widzi chronionego pliku mkcert.exe.',
                    ($helperStatus['mkcert_ca_key_exists'] ?? false) !== true => 'Helper nie widzi klucza lokalnego CA.',
                    default => 'Dostępny w chronionym środowisku helpera.',
                };
                $optionalComponent = [
                    'name' => 'mkcert',
                    'state' => $mkcertAvailable ? 'available' : 'missing',
                    'version' => null,
                    'detail' => $mkcertDetail,
                ];
                break;
            }
        }
        unset($optionalComponent);
    } catch (Throwable $error) {
        $environment['required'][] = [
            'name' => 'Helper systemowy',
            'state' => 'missing',
            'version' => null,
            'detail' => $error->getMessage(),
        ];
    }
}
$apachePreview = null;
$apachePreviewProject = null;
$apacheCurrentHash = null;
$hostsCurrentHash = null;
$flash = $_SESSION['flash'] ?? null;
$flashError = $_SESSION['flash_error'] ?? null;
unset($_SESSION['flash']);
unset($_SESSION['flash_error']);

if ($page === 'apache') {
    $previewProjectId = $routeProjectId ?? 0;
    $apachePreviewProject = $repository->find($previewProjectId);

    if ($apachePreviewProject === null) {
        $_SESSION['flash_error'] = 'Nie znaleziono projektu do wygenerowania konfiguracji Apache.';
        header('Location: /');
        exit;
    }

    try {
        $helperConfig = $config['helper']['windows'];
        $helperResult = (new WindowsNamedPipeClient(
            $helperConfig['pipe_name'],
            $config['helper']['protocol_version'],
            $config['helper']['timeout_seconds'],
        ))->call('apache.preview_project', [
            'project_id' => $apachePreviewProject->id,
            'root_path' => $apachePreviewProject->rootPath,
            'php_version' => $apachePreviewProject->phpVersion,
            'primary_domain' => $apachePreviewProject->primaryDomain()->value,
            'domains' => array_map(static fn ($domain): string => $domain->value, $apachePreviewProject->domains),
            'https_enabled' => $apachePreviewProject->httpsEnabled,
        ]);
        $apachePreview = (string) ($helperResult['configuration'] ?? '');
        $apacheCurrentHash = is_string($helperResult['current_hash'] ?? null)
            ? $helperResult['current_hash']
            : null;
        $hostsCurrentHash = is_string($helperResult['hosts_hash'] ?? null)
            ? $helperResult['hosts_hash']
            : null;
    } catch (Throwable $error) {
        $flashError = $error->getMessage();
    }
}

/** @return array<string, mixed> */
function projectHelperArguments(
    \DomainManager\Domain\Project $project,
    ?string $expectedPreviousHash = null,
    ?string $expectedHostsHash = null,
    ?string $previousRootPath = null,
): array
{
    return [
        'project_id' => $project->id,
        'root_path' => $project->rootPath,
        'php_version' => $project->phpVersion,
        'primary_domain' => $project->primaryDomain()->value,
        'domains' => array_map(static fn ($domain): string => $domain->value, $project->domains),
        'https_enabled' => $project->httpsEnabled,
        'expected_previous_hash' => $expectedPreviousHash,
        'expected_hosts_hash' => $expectedHostsHash,
        'previous_root_path' => $previousRootPath,
    ];
}

function additionalDomainsLabel(int $count): string
{
    if ($count === 1) return 'dodatkowa domena';
    $lastTwoDigits = $count % 100;
    $lastDigit = $count % 10;
    if ($lastTwoDigits < 12 || $lastTwoDigits > 14) {
        if ($lastDigit >= 2 && $lastDigit <= 4) return 'dodatkowe domeny';
    }
    return 'dodatkowych domen';
}

function e(string $value): string
{
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

require dirname(__DIR__) . '/templates/pages/home.php';
