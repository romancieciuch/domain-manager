<?php

declare(strict_types=1);

use DomainManager\Application\Project\ProjectInput;
use DomainManager\Domain\DomainName;
use DomainManager\Domain\Project;
use DomainManager\Infrastructure\Database\MigrationRunner;
use DomainManager\Infrastructure\Database\SqliteConnection;
use DomainManager\Infrastructure\Database\SqliteOperationHistoryRepository;
use DomainManager\Infrastructure\Database\SqliteProjectRepository;
use DomainManager\Infrastructure\Configuration\RuntimeConfiguration;
use DomainManager\Infrastructure\Platform\Windows\WindowsApacheManager;

require dirname(__DIR__) . '/bootstrap.php';

$passed = 0;
$failed = 0;
$temporaryRoot = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'domain-manager-tests-' . bin2hex(random_bytes(6));
$documentRoot = $temporaryRoot . DIRECTORY_SEPARATOR . 'www';
mkdir($documentRoot, 0770, true);

function cleanTemporaryTestDirectory(string $temporaryRoot, string $documentRoot): void
{
    foreach (glob($temporaryRoot . DIRECTORY_SEPARATOR . '*') ?: [] as $path) {
        if (is_file($path)) unlink($path);
    }
    if (is_dir($documentRoot)) rmdir($documentRoot);
    if (is_dir($temporaryRoot)) rmdir($temporaryRoot);
}

/** @param callable(): void $test */
function test(string $name, callable $test): void
{
    global $passed, $failed;
    try {
        $test();
        $passed++;
        fwrite(STDOUT, "✓ $name\n");
    } catch (Throwable $error) {
        $failed++;
        fwrite(STDERR, "✗ $name\n  {$error->getMessage()}\n");
    }
}

function assertSameValue(mixed $expected, mixed $actual, string $message = ''): void
{
    if ($expected !== $actual) {
        throw new RuntimeException(($message === '' ? 'Wartości nie są identyczne.' : $message) .
            ' Oczekiwano: ' . var_export($expected, true) . ', otrzymano: ' . var_export($actual, true));
    }
}

function assertTrue(bool $condition, string $message = 'Warunek nie został spełniony.'): void
{
    if (!$condition) throw new RuntimeException($message);
}

/** @param class-string<Throwable> $exception */
function assertThrows(string $exception, callable $callback): void
{
    try {
        $callback();
    } catch (Throwable $error) {
        if ($error instanceof $exception) return;
        throw new RuntimeException('Rzucono ' . $error::class . ' zamiast ' . $exception, 0, $error);
    }
    throw new RuntimeException("Oczekiwany wyjątek $exception nie został rzucony.");
}

test('Domena jest normalizowana do małych liter bez końcowej kropki', static function (): void {
    assertSameValue('local.example.test', (new DomainName(' LOCAL.Example.Test. '))->value);
});

test('Domena odrzuca protokół, port, ścieżkę i pojedynczą etykietę', static function (): void {
    foreach (['https://local.test', 'local.test:8080', 'local.test/path', 'localhost'] as $invalid) {
        assertThrows(InvalidArgumentException::class, static fn () => new DomainName($invalid));
    }
});

test('Formularz buduje projekt z domeną główną i aliasem', static function () use ($documentRoot): void {
    $result = (new ProjectInput(['8.5.10']))->validate([
        'name' => 'Testowy projekt',
        'root_path' => $documentRoot,
        'php_version' => '8.5.10',
        'https_enabled' => '1',
        'domains' => ['local.primary.test', 'local.alias.test'],
        'primary_domain' => '1',
    ]);
    assertSameValue([], $result['errors']);
    assertSameValue('local.alias.test', $result['project']?->primaryDomain()->value);
    assertTrue($result['project']?->httpsEnabled === true);
});

test('Formularz odrzuca duplikaty domen po normalizacji', static function () use ($documentRoot): void {
    $result = (new ProjectInput(['8.5.10']))->validate([
        'name' => 'Duplikat', 'root_path' => $documentRoot, 'php_version' => '8.5.10',
        'domains' => ['LOCAL.same.test', 'local.same.test.'], 'primary_domain' => '0',
    ]);
    assertTrue($result['project'] === null);
    assertTrue(in_array('Ta sama domena nie może występować w projekcie kilka razy.', $result['errors'], true));
});

test('Konfiguracja Windows akceptuje pełne ścieżki i wybraną wersję PHP', static function () use ($temporaryRoot): void {
    $path = $temporaryRoot . DIRECTORY_SEPARATOR . 'runtime-valid.json';
    file_put_contents($path, json_encode([
        'schema_version' => 1,
        'platform' => 'windows',
        'apache' => ['version' => '2.4.65', 'root' => 'C:\\Apache24', 'service_name' => 'Apache2.4'],
        'php' => [
            'default_version' => '8.5.10',
            'versions' => ['8.5.10' => [
                'root' => 'C:\\php-8.5.10',
                'cli' => 'C:\\php-8.5.10\\php.exe',
                'cgi' => 'C:\\php-8.5.10\\php-cgi.exe',
            ]],
        ],
        'projects' => ['allowed_roots' => ['D:\\Projects']],
        'tools' => ['mkcert' => 'C:\\tools\\mkcert.exe'],
    ], JSON_THROW_ON_ERROR));

    $configuration = RuntimeConfiguration::load($path);
    assertSameValue('8.5.10', $configuration['php']['default_version']);
    assertSameValue('Apache2.4', $configuration['apache']['service_name']);
});

test('Konfiguracja Windows odrzuca ścieżkę względną, złą usługę i brak domyślnego PHP', static function () use ($temporaryRoot): void {
    $base = [
        'schema_version' => 1,
        'platform' => 'windows',
        'apache' => ['version' => '2.4.65', 'root' => 'C:\\Apache24', 'service_name' => 'Apache2.4'],
        'php' => [
            'default_version' => '8.5.10',
            'versions' => ['8.5.10' => [
                'root' => 'C:\\php', 'cli' => 'C:\\php\\php.exe', 'cgi' => 'C:\\php\\php-cgi.exe',
            ]],
        ],
        'projects' => ['allowed_roots' => ['D:\\Projects']],
    ];
    $invalid = [
        array_replace_recursive($base, ['apache' => ['root' => '.\\Apache24']]),
        array_replace_recursive($base, ['apache' => ['service_name' => 'Apache & cmd']]),
        array_replace_recursive($base, ['php' => ['default_version' => '8.4.0']]),
    ];

    foreach ($invalid as $index => $configuration) {
        $path = $temporaryRoot . DIRECTORY_SEPARATOR . "runtime-invalid-$index.json";
        file_put_contents($path, json_encode($configuration, JSON_THROW_ON_ERROR));
        assertThrows(RuntimeException::class, static fn () => RuntimeConfiguration::load($path));
    }
});

test('Renderer Apache dla Windows tworzy HTTP, HTTPS i alias bez backslashy', static function () use ($temporaryRoot, $documentRoot): void {
    $phpCgi = $temporaryRoot . DIRECTORY_SEPARATOR . 'php-cgi.exe';
    touch($phpCgi);
    $project = new Project(42, 'Windows', $documentRoot, '8.5.10', true, [
        new DomainName('windows.localhost'), new DomainName('alias.windows.localhost'),
    ], 0);

    $configuration = (new WindowsApacheManager(['8.5.10' => $phpCgi], 'C:\\ProgramData\\DomainManager\\certificates'))
        ->renderVirtualHost($project);

    assertTrue(str_contains($configuration, '<VirtualHost *:80>'));
    assertTrue(str_contains($configuration, '<VirtualHost *:443>'));
    assertTrue(str_contains($configuration, 'ServerName windows.localhost'));
    assertTrue(str_contains($configuration, 'ServerAlias alias.windows.localhost'));
    assertTrue(str_contains($configuration, 'certificates/42/certificate.pem'));
    assertTrue(!str_contains($configuration, $documentRoot), 'DocumentRoot nie został zapisany w formacie Apache.');
    assertTrue(!str_contains($configuration, $phpCgi), 'Ścieżka php-cgi nie została zapisana w formacie Apache.');
});

$database = SqliteConnection::open(':memory:');
$runner = new MigrationRunner($database, dirname(__DIR__) . '/database/migrations');
$repository = new SqliteProjectRepository($database);
$history = new SqliteOperationHistoryRepository($database);

test('Migracje SQLite są idempotentne', static function () use ($runner): void {
    assertSameValue(['001_initial_schema.sql', '002_operation_project_name.sql'], $runner->migrate());
    assertSameValue([], $runner->migrate());
});

test('Historia zapisuje powodzenie i błąd operacji', static function () use ($history): void {
    $completed = $history->start('project.sync', null, 'Alpha');
    $history->complete($completed);
    $failed = $history->start('project.update', null, 'Beta');
    $history->fail($failed, 'Kontrolowany błąd');
    $rows = $history->recent();
    assertSameValue('failed', $rows[0]['status']);
    assertSameValue('Kontrolowany błąd', $rows[0]['error_message']);
    assertSameValue('completed', $rows[1]['status']);
});

test('Repozytorium zapisuje projekt i relacyjne aliasy', static function () use ($repository, $documentRoot): void {
    $id = $repository->create(new Project(null, 'Alpha', $documentRoot, '8.5.10', true, [
        new DomainName('local.alpha.test'), new DomainName('local.alpha-alias.test'),
    ], 0));
    $project = $repository->find($id);
    assertSameValue('Alpha', $project?->name);
    assertSameValue(2, count($project?->domains ?? []));
    assertSameValue('local.alpha.test', $project?->primaryDomain()->value);
});

test('Unikalność domen działa pomiędzy projektami', static function () use ($repository, $documentRoot): void {
    assertThrows(RuntimeException::class, static fn () => $repository->create(new Project(
        null, 'Konflikt', $documentRoot, '8.5.10', false, [new DomainName('LOCAL.ALPHA.TEST')], 0,
    )));
});

test('Aktualizacja zastępuje aliasy, a usunięcie uruchamia kaskadę', static function () use ($repository, $database, $documentRoot): void {
    $project = $repository->all()[0];
    $repository->update($project->id, new Project(null, 'Beta', $documentRoot, '8.5.10', false, [
        new DomainName('local.beta.test'),
    ], 0));
    assertSameValue('local.beta.test', $repository->find($project->id)?->primaryDomain()->value);
    assertTrue($repository->delete($project->id));
    assertSameValue(0, (int) $database->query('SELECT COUNT(*) FROM project_domains')->fetchColumn());
});

$repository = null;
$history = null;
$runner = null;
$database = null;
gc_collect_cycles();
cleanTemporaryTestDirectory($temporaryRoot, $documentRoot);
fwrite(STDOUT, "\nWynik: $passed zaliczonych, $failed niezaliczonych.\n");
exit($failed === 0 ? 0 : 1);
