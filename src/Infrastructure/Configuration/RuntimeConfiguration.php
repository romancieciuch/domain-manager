<?php

declare(strict_types=1);

namespace DomainManager\Infrastructure\Configuration;

use JsonException;
use RuntimeException;

final class RuntimeConfiguration
{
    /** @return array<string, mixed> */
    public static function load(string $path): array
    {
        $contents = @file_get_contents($path);
        if (!is_string($contents)) {
            throw new RuntimeException('Nie można odczytać konfiguracji środowiska: ' . $path);
        }

        try {
            $config = json_decode($contents, true, flags: JSON_THROW_ON_ERROR);
        } catch (JsonException $error) {
            throw new RuntimeException('Plik runtime.json zawiera nieprawidłowy JSON: ' . $error->getMessage(), 0, $error);
        }

        if (!is_array($config)) {
            throw new RuntimeException('Plik runtime.json musi zawierać obiekt JSON.');
        }

        self::assertSame(1, $config['schema_version'] ?? null, 'Nieobsługiwana wersja schematu runtime.json.');
        self::assertSame('windows', $config['platform'] ?? null, 'Ta instalacja oczekuje platformy windows.');
        self::assertVersion($config['apache']['version'] ?? null, 'apache.version');
        self::assertAbsoluteWindowsPath($config['apache']['root'] ?? null, 'apache.root');
        self::assertServiceName($config['apache']['service_name'] ?? null);

        $versions = $config['php']['versions'] ?? null;
        if (!is_array($versions) || $versions === []) {
            throw new RuntimeException('php.versions musi zawierać co najmniej jedną wersję PHP.');
        }
        foreach ($versions as $version => $runtime) {
            self::assertVersion($version, 'klucz php.versions');
            if (!is_array($runtime)) {
                throw new RuntimeException("Konfiguracja PHP $version musi być obiektem.");
            }
            self::assertAbsoluteWindowsPath($runtime['root'] ?? null, "php.versions.$version.root");
            self::assertAbsoluteWindowsPath($runtime['cli'] ?? null, "php.versions.$version.cli");
            self::assertAbsoluteWindowsPath($runtime['cgi'] ?? null, "php.versions.$version.cgi");
        }

        $defaultVersion = $config['php']['default_version'] ?? null;
        if (!is_string($defaultVersion) || !array_key_exists($defaultVersion, $versions)) {
            throw new RuntimeException('php.default_version musi wskazywać wersję z php.versions.');
        }

        $allowedRoots = $config['projects']['allowed_roots'] ?? null;
        if (!is_array($allowedRoots) || $allowedRoots === []) {
            throw new RuntimeException('projects.allowed_roots musi zawierać co najmniej jeden katalog.');
        }
        foreach ($allowedRoots as $index => $root) {
            self::assertAbsoluteWindowsPath($root, "projects.allowed_roots.$index");
        }

        if (isset($config['tools']['mkcert'])) {
            self::assertAbsoluteWindowsPath($config['tools']['mkcert'], 'tools.mkcert');
        }

        return $config;
    }

    private static function assertSame(mixed $expected, mixed $actual, string $message): void
    {
        if ($actual !== $expected) throw new RuntimeException($message);
    }

    private static function assertVersion(mixed $version, string $field): void
    {
        if (!is_string($version) || preg_match('/^\d+\.\d+\.\d+$/D', $version) !== 1) {
            throw new RuntimeException("$field musi mieć format major.minor.patch.");
        }
    }

    private static function assertAbsoluteWindowsPath(mixed $path, string $field): void
    {
        if (!is_string($path) || preg_match('~^[A-Za-z]:[\\/]~D', $path) !== 1 || str_contains($path, "\0")) {
            throw new RuntimeException("$field musi być bezwzględną ścieżką Windows.");
        }
    }

    private static function assertServiceName(mixed $name): void
    {
        if (!is_string($name) || preg_match('/^[A-Za-z0-9._-]+$/D', $name) !== 1) {
            throw new RuntimeException('apache.service_name zawiera niedozwolone znaki.');
        }
    }
}
