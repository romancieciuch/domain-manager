<?php

declare(strict_types=1);

namespace DomainManager\Application\Project;

use DomainManager\Domain\DomainName;
use DomainManager\Domain\Project;

final class ProjectInput
{
    /** @param list<string> $availablePhpVersions */
    public function __construct(private readonly array $availablePhpVersions) {}

    /**
     * @param array<string, mixed> $input
     * @return array{project: ?Project, errors: list<string>}
     */
    public function validate(array $input): array
    {
        $errors = [];
        $name = trim((string) ($input['name'] ?? ''));
        $rootPath = trim((string) ($input['root_path'] ?? ''));
        $phpVersion = trim((string) ($input['php_version'] ?? ''));
        $httpsEnabled = isset($input['https_enabled']);

        if ($name === '' || mb_strlen($name) > 120) {
            $errors[] = 'Nazwa projektu jest wymagana i może mieć maksymalnie 120 znaków.';
        }

        if ($rootPath === '') {
            $errors[] = 'DocumentRoot jest wymagany.';
        } elseif (!is_dir($rootPath)) {
            $errors[] = 'Podany DocumentRoot nie istnieje lub nie jest katalogiem.';
        } elseif (preg_match('/["\r\n]/', $rootPath) === 1) {
            $errors[] = 'DocumentRoot zawiera niedozwolone znaki.';
        } else {
            $rootPath = realpath($rootPath) ?: $rootPath;
        }

        if (!in_array($phpVersion, $this->availablePhpVersions, true)) {
            $errors[] = 'Wybrana wersja PHP nie jest dostępna w tym środowisku.';
        }

        $rawDomains = $input['domains'] ?? [];
        $rawDomains = is_array($rawDomains) ? $rawDomains : [];
        $domains = [];

        foreach ($rawDomains as $rawDomain) {
            if (trim((string) $rawDomain) === '') {
                continue;
            }

            try {
                $domains[] = new DomainName((string) $rawDomain);
            } catch (\InvalidArgumentException $error) {
                $errors[] = $error->getMessage();
            }
        }

        if ($domains === []) {
            $errors[] = 'Dodaj co najmniej jedną domenę projektu.';
        }

        $domainValues = array_map(static fn (DomainName $domain): string => $domain->value, $domains);

        if (count($domainValues) !== count(array_unique($domainValues))) {
            $errors[] = 'Ta sama domena nie może występować w projekcie kilka razy.';
        }

        $primaryIndex = filter_var($input['primary_domain'] ?? 0, FILTER_VALIDATE_INT);
        $primaryIndex = $primaryIndex === false ? 0 : $primaryIndex;

        if ($domains !== [] && !array_key_exists($primaryIndex, $domains)) {
            $errors[] = 'Wybierz poprawną domenę główną.';
        }

        if ($errors !== []) {
            return ['project' => null, 'errors' => array_values(array_unique($errors))];
        }

        return [
            'project' => new Project(
                null,
                $name,
                $rootPath,
                $phpVersion,
                $httpsEnabled,
                $domains,
                $primaryIndex,
            ),
            'errors' => [],
        ];
    }
}
