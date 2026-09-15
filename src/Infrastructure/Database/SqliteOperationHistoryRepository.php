<?php

declare(strict_types=1);

namespace DomainManager\Infrastructure\Database;

use PDO;

final readonly class SqliteOperationHistoryRepository
{
    public function __construct(private PDO $database) {}

    public function start(string $type, ?int $projectId, ?string $projectName): string
    {
        $id = $this->uuid();
        $statement = $this->database->prepare(
            'INSERT INTO operation_history (id, project_id, project_name, operation_type, status, started_at)' .
            ' VALUES (:id, :project_id, :project_name, :operation_type, :status, :started_at)'
        );
        $statement->execute([
            'id' => $id,
            'project_id' => $projectId,
            'project_name' => $projectName,
            'operation_type' => $type,
            'status' => 'applying',
            'started_at' => gmdate('Y-m-d\TH:i:s\Z'),
        ]);
        return $id;
    }

    public function complete(string $id): void
    {
        $this->finish($id, 'completed', null, null);
    }

    public function fail(string $id, string $message, ?string $code = null): void
    {
        $this->finish($id, 'failed', $code, mb_substr($message, 0, 2000));
    }

    /** @return list<array<string, mixed>> */
    public function recent(int $limit = 100): array
    {
        $statement = $this->database->prepare(
            'SELECT id, project_id, project_name, operation_type, status, started_at, finished_at, error_code, error_message' .
            ' FROM operation_history ORDER BY started_at DESC, rowid DESC LIMIT :limit'
        );
        $statement->bindValue('limit', max(1, min($limit, 500)), PDO::PARAM_INT);
        $statement->execute();
        return $statement->fetchAll();
    }

    public function clear(): void
    {
        $this->database->exec('DELETE FROM operation_history');
    }

    private function finish(string $id, string $status, ?string $code, ?string $message): void
    {
        $statement = $this->database->prepare(
            'UPDATE operation_history SET status = :status, finished_at = :finished_at,' .
            ' error_code = :error_code, error_message = :error_message WHERE id = :id'
        );
        $statement->execute([
            'id' => $id,
            'status' => $status,
            'finished_at' => gmdate('Y-m-d\TH:i:s\Z'),
            'error_code' => $code,
            'error_message' => $message,
        ]);
    }

    private function uuid(): string
    {
        $bytes = random_bytes(16);
        $bytes[6] = chr((ord($bytes[6]) & 0x0f) | 0x40);
        $bytes[8] = chr((ord($bytes[8]) & 0x3f) | 0x80);
        $hex = bin2hex($bytes);
        return sprintf('%s-%s-%s-%s-%s', substr($hex, 0, 8), substr($hex, 8, 4), substr($hex, 12, 4), substr($hex, 16, 4), substr($hex, 20));
    }
}
