<?php

declare(strict_types=1);

namespace DomainManager\Infrastructure\Database;

use PDO;
use RuntimeException;
use Throwable;

final class MigrationRunner
{
    public function __construct(
        private readonly PDO $database,
        private readonly string $migrationDirectory,
    ) {}

    /** @return list<string> */
    public function migrate(): array
    {
        $this->database->exec(
            'CREATE TABLE IF NOT EXISTS schema_migrations (' .
            'version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)'
        );

        $files = glob($this->migrationDirectory . '/*.sql');

        if ($files === false) {
            throw new RuntimeException('Nie można odczytać katalogu migracji.');
        }

        sort($files, SORT_STRING);
        $applied = [];

        foreach ($files as $file) {
            $version = $this->versionFromFilename($file);

            if ($this->isApplied($version)) {
                continue;
            }

            $sql = file_get_contents($file);

            if ($sql === false) {
                throw new RuntimeException(sprintf('Nie można odczytać migracji: %s', $file));
            }

            $this->database->beginTransaction();

            try {
                $this->database->exec($sql);
                $statement = $this->database->prepare(
                    'INSERT INTO schema_migrations (version, applied_at) VALUES (:version, :applied_at)'
                );
                $statement->execute([
                    'version' => $version,
                    'applied_at' => gmdate('Y-m-d\TH:i:s\Z'),
                ]);
                $this->database->commit();
                $applied[] = basename($file);
            } catch (Throwable $error) {
                if ($this->database->inTransaction()) {
                    $this->database->rollBack();
                }

                throw new RuntimeException(
                    sprintf('Migracja %s nie powiodła się.', basename($file)),
                    0,
                    $error,
                );
            }
        }

        return $applied;
    }

    private function versionFromFilename(string $file): int
    {
        if (preg_match('/^(\d+)_/', basename($file), $matches) !== 1) {
            throw new RuntimeException(sprintf('Nieprawidłowa nazwa migracji: %s', basename($file)));
        }

        return (int) $matches[1];
    }

    private function isApplied(int $version): bool
    {
        $statement = $this->database->prepare(
            'SELECT 1 FROM schema_migrations WHERE version = :version'
        );
        $statement->execute(['version' => $version]);

        return $statement->fetchColumn() !== false;
    }
}
