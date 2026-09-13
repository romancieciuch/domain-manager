<?php

declare(strict_types=1);

namespace DomainManager\Infrastructure\Database;

use DomainManager\Domain\DomainName;
use DomainManager\Domain\Project;
use PDO;
use PDOException;
use RuntimeException;
use Throwable;

final class SqliteProjectRepository
{
    public function __construct(private readonly PDO $database) {}

    /** @return list<Project> */
    public function all(): array
    {
        $rows = $this->database->query(
            'SELECT p.id, p.name, p.root_path, p.php_version, p.https_enabled, p.status,' .
            ' d.domain, d.is_primary' .
            ' FROM projects p' .
            ' JOIN project_domains d ON d.project_id = p.id' .
            ' ORDER BY p.name COLLATE NOCASE, d.is_primary DESC, d.domain COLLATE NOCASE'
        )->fetchAll();

        $projects = [];

        foreach ($rows as $row) {
            $id = (int) $row['id'];

            if (!isset($projects[$id])) {
                $projects[$id] = [
                    'row' => $row,
                    'domains' => [],
                    'primary' => 0,
                ];
            }

            $projects[$id]['domains'][] = new DomainName($row['domain']);

            if ((int) $row['is_primary'] === 1) {
                $projects[$id]['primary'] = count($projects[$id]['domains']) - 1;
            }
        }

        return array_values(array_map(static function (array $data): Project {
            $row = $data['row'];

            return new Project(
                (int) $row['id'],
                $row['name'],
                $row['root_path'],
                $row['php_version'],
                (bool) $row['https_enabled'],
                $data['domains'],
                $data['primary'],
                $row['status'],
            );
        }, $projects));
    }

    public function find(int $id): ?Project
    {
        foreach ($this->all() as $project) {
            if ($project->id === $id) {
                return $project;
            }
        }

        return null;
    }

    public function create(Project $project): int
    {
        $now = gmdate('Y-m-d\TH:i:s\Z');
        $this->database->beginTransaction();

        try {
            $statement = $this->database->prepare(
                'INSERT INTO projects' .
                ' (name, root_path, php_version, https_enabled, status, created_at, updated_at)' .
                ' VALUES (:name, :root_path, :php_version, :https_enabled, :status, :created_at, :updated_at)'
            );
            $statement->execute([
                'name' => $project->name,
                'root_path' => $project->rootPath,
                'php_version' => $project->phpVersion,
                'https_enabled' => (int) $project->httpsEnabled,
                'status' => $project->status,
                'created_at' => $now,
                'updated_at' => $now,
            ]);

            $projectId = (int) $this->database->lastInsertId();
            $domainStatement = $this->database->prepare(
                'INSERT INTO project_domains (project_id, domain, is_primary, created_at)' .
                ' VALUES (:project_id, :domain, :is_primary, :created_at)'
            );

            foreach ($project->domains as $index => $domain) {
                $domainStatement->execute([
                    'project_id' => $projectId,
                    'domain' => $domain->value,
                    'is_primary' => (int) ($index === $project->primaryDomainIndex),
                    'created_at' => $now,
                ]);
            }

            $this->database->commit();

            return $projectId;
        } catch (PDOException $error) {
            $this->rollBack();

            if (str_contains($error->getMessage(), 'project_domains.domain')) {
                throw new RuntimeException('Jedna z domen jest już przypisana do innego projektu.', 0, $error);
            }

            throw $error;
        } catch (Throwable $error) {
            $this->rollBack();
            throw $error;
        }
    }

    public function update(int $id, Project $project): void
    {
        $now = gmdate('Y-m-d\TH:i:s\Z');
        $this->database->beginTransaction();

        try {
            $statement = $this->database->prepare(
                'UPDATE projects SET name = :name, root_path = :root_path, php_version = :php_version,' .
                ' https_enabled = :https_enabled, updated_at = :updated_at WHERE id = :id'
            );
            $statement->execute([
                'id' => $id,
                'name' => $project->name,
                'root_path' => $project->rootPath,
                'php_version' => $project->phpVersion,
                'https_enabled' => (int) $project->httpsEnabled,
                'updated_at' => $now,
            ]);

            if ($statement->rowCount() === 0 && !$this->exists($id)) {
                throw new RuntimeException('Projekt nie istnieje.');
            }

            $deleteDomains = $this->database->prepare('DELETE FROM project_domains WHERE project_id = :project_id');
            $deleteDomains->execute(['project_id' => $id]);

            $domainStatement = $this->database->prepare(
                'INSERT INTO project_domains (project_id, domain, is_primary, created_at)' .
                ' VALUES (:project_id, :domain, :is_primary, :created_at)'
            );

            foreach ($project->domains as $index => $domain) {
                $domainStatement->execute([
                    'project_id' => $id,
                    'domain' => $domain->value,
                    'is_primary' => (int) ($index === $project->primaryDomainIndex),
                    'created_at' => $now,
                ]);
            }

            $this->database->commit();
        } catch (PDOException $error) {
            $this->rollBack();

            if (str_contains($error->getMessage(), 'project_domains.domain')) {
                throw new RuntimeException('Jedna z domen jest już przypisana do innego projektu.', 0, $error);
            }

            throw $error;
        } catch (Throwable $error) {
            $this->rollBack();
            throw $error;
        }
    }

    public function delete(int $id): bool
    {
        $statement = $this->database->prepare('DELETE FROM projects WHERE id = :id');
        $statement->execute(['id' => $id]);

        return $statement->rowCount() === 1;
    }

    private function exists(int $id): bool
    {
        $statement = $this->database->prepare('SELECT 1 FROM projects WHERE id = :id');
        $statement->execute(['id' => $id]);

        return $statement->fetchColumn() !== false;
    }

    private function rollBack(): void
    {
        if ($this->database->inTransaction()) {
            $this->database->rollBack();
        }
    }
}
