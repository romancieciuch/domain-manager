<?php

declare(strict_types=1);

namespace DomainManager\Infrastructure\Platform\Windows;

use DomainManager\Infrastructure\Platform\Contracts\EnvironmentInspector;

final readonly class WindowsEnvironmentInspector implements EnvironmentInspector
{
    /**
     * @param list<string> $expectedPhpVersions
     * @param list<string> $phpSearchRoots
     * @param list<string> $apacheSearchRoots
     */
    public function __construct(
        private array $expectedPhpVersions,
        private array $phpSearchRoots,
        private array $apacheSearchRoots,
    ) {}

    public function inspect(): array
    {
        return [
            'platform' => 'Windows',
            'required' => [
                $this->detectApache(),
                $this->detectApacheService(),
                $this->detectManagedInclude(),
                [
                    'name' => 'SQLite',
                    'state' => extension_loaded('pdo_sqlite') ? 'available' : 'missing',
                    'version' => extension_loaded('sqlite3') ? \SQLite3::version()['versionString'] : null,
                    'detail' => extension_loaded('pdo_sqlite') ? 'Rozszerzenie PDO SQLite jest aktywne.' : 'Brak rozszerzenia pdo_sqlite.',
                ],
            ],
            'php' => $this->detectPhp(),
            'optional' => [
                $this->tool('mkcert', ['mkcert.exe']),
                $this->tool('Composer', ['composer.bat', 'composer.cmd', 'composer.exe']),
                $this->tool('Git', ['git.exe']),
                $this->tool('Node.js', ['node.exe']),
                $this->tool('npm', ['npm.cmd', 'npm.exe']),
                $this->tool('VS Code', ['code.cmd', 'code.exe']),
            ],
        ];
    }

    private function detectPhp(): array
    {
        $found = [];

        foreach ($this->phpSearchRoots as $root) {
            foreach (glob(rtrim($root, '/') . '/*/php.exe') ?: [] as $executable) {
                if (preg_match('~/(?:php-)?(\d+\.\d+\.\d+)/php\.exe$~i', str_replace('\\', '/', $executable), $match) === 1) {
                    $found[$match[1]] = str_replace('\\', '/', $executable);
                }
            }
        }

        if (preg_match('/^(\d+\.\d+\.\d+)/', PHP_VERSION, $match) === 1) {
            $found[$match[1]] ??= str_replace('\\', '/', PHP_BINARY);
        }

        $statuses = [];
        foreach ($this->expectedPhpVersions as $version) {
            $statuses[] = [
                'name' => 'PHP ' . $version,
                'state' => isset($found[$version]) ? 'available' : 'missing',
                'version' => $version,
                'detail' => $found[$version] ?? 'Wersja skonfigurowana, ale nie znaleziono php.exe.',
            ];
        }

        return $statuses;
    }

    private function detectApache(): array
    {
        foreach ($this->apacheSearchRoots as $root) {
            $candidates = array_merge(
                glob(rtrim($root, '/') . '/*/bin/httpd.exe') ?: [],
                glob(rtrim($root, '/') . '/*apache*/bin/httpd.exe') ?: [],
                [rtrim($root, '/') . '/bin/httpd.exe'],
            );

            foreach (array_unique($candidates) as $executable) {
                if (!is_file($executable)) {
                    continue;
                }

                $normalized = str_replace('\\', '/', $executable);
                preg_match('~/(?:apache-?)?(\d+(?:\.\d+)+)/bin/httpd\.exe$~i', $normalized, $match);
                return [
                    'name' => 'Apache',
                    'state' => 'available',
                    'version' => $match[1] ?? null,
                    'detail' => $normalized,
                ];
            }
        }

        return ['name' => 'Apache', 'state' => 'missing', 'version' => null, 'detail' => 'Nie znaleziono httpd.exe.'];
    }

    private function detectApacheService(): array
    {
        $result = $this->runProcess('C:/Windows/System32/sc.exe', ['qc', 'DomainManagerApache']);

        if ($result === null || $result['exit_code'] !== 0) {
            return [
                'name' => 'Usługa Apache',
                'state' => 'missing',
                'version' => null,
                'detail' => 'Nie znaleziono usługi DomainManagerApache.',
            ];
        }

        preg_match('/SERVICE_START_NAME\s*:\s*([^\r\n]+)/i', $result['output'], $accountMatch);
        $account = trim($accountMatch[1] ?? 'Nieznane konto');
        $expectedAccount = 'NT SERVICE\\DomainManagerApache';
        $isExpectedAccount = strcasecmp($account, $expectedAccount) === 0;
        $isLocalSystem = strcasecmp($account, 'LocalSystem') === 0;

        return [
            'name' => 'Konto usługi Apache',
            'state' => $isExpectedAccount ? 'available' : 'warning',
            'version' => null,
            'detail' => match (true) {
                $isExpectedAccount => $account . ' — dedykowane konto usługi.',
                $isLocalSystem => 'LocalSystem — wymaga ograniczenia przed uruchamianiem projektów PHP.',
                default => $account . ' — uruchom ponownie instalator, aby zweryfikować konto.',
            },
        ];
    }

    private function detectManagedInclude(): array
    {
        foreach ($this->apacheSearchRoots as $root) {
            foreach (array_merge(glob(rtrim($root, '/') . '/*/conf/httpd.conf') ?: [], [rtrim($root, '/') . '/conf/httpd.conf']) as $config) {
                if (!is_file($config)) {
                    continue;
                }

                $contents = file_get_contents($config);
                $enabled = is_string($contents)
                    && preg_match('~^\s*IncludeOptional\s+["\']?conf/domain-manager/\*\.conf["\']?\s*$~mi', $contents) === 1;

                return [
                    'name' => 'Konfiguracje Domain Managera',
                    'state' => $enabled ? 'available' : 'warning',
                    'version' => null,
                    'detail' => $enabled
                        ? 'Apache wczytuje conf/domain-manager/*.conf.'
                        : 'Brakuje IncludeOptional conf/domain-manager/*.conf.',
                ];
            }
        }

        return ['name' => 'Konfiguracje Domain Managera', 'state' => 'missing', 'version' => null, 'detail' => 'Nie znaleziono httpd.conf.'];
    }

    /** @param list<string> $arguments */
    private function runProcess(string $executable, array $arguments): ?array
    {
        if (!is_file($executable)) {
            return null;
        }

        $pipes = [];
        $process = proc_open(
            array_merge([$executable], $arguments),
            [1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
            $pipes,
            null,
            null,
            ['bypass_shell' => true],
        );

        if (!is_resource($process)) {
            return null;
        }

        $output = stream_get_contents($pipes[1]) . stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $exitCode = proc_close($process);

        return ['exit_code' => $exitCode, 'output' => $output];
    }

    private function tool(string $name, array $filenames): array
    {
        $path = $this->findOnPath($filenames);

        return [
            'name' => $name,
            'state' => $path === null ? 'missing' : 'available',
            'version' => null,
            'detail' => $path ?? 'Nie wykryto w PATH.',
        ];
    }

    private function findOnPath(array $filenames): ?string
    {
        foreach (explode(PATH_SEPARATOR, (string) getenv('PATH')) as $directory) {
            $directory = trim($directory, " \t\n\r\0\x0B\"");
            foreach ($filenames as $filename) {
                $candidate = rtrim($directory, '\\/') . DIRECTORY_SEPARATOR . $filename;
                if ($directory !== '' && is_file($candidate)) {
                    return str_replace('\\', '/', $candidate);
                }
            }
        }

        return null;
    }
}
