<?php

declare(strict_types=1);

namespace DomainManager\Infrastructure\Helper;

use JsonException;
use RuntimeException;

final readonly class WindowsHelperClient
{
    public function __construct(
        private string $hostExecutable,
        private string $helperAssembly,
        private int $protocolVersion,
        private int $timeoutSeconds,
    ) {}

    /** @param array<string, mixed> $arguments */
    public function call(string $action, array $arguments = []): array
    {
        if (!is_file($this->hostExecutable)) {
            throw new RuntimeException('Nie znaleziono hosta .NET dla helpera Windows.');
        }

        if (!is_file($this->helperAssembly)) {
            throw new RuntimeException('Helper Windows nie został skompilowany.');
        }

        $requestId = $this->uuid();
        $request = json_encode([
            'protocol' => $this->protocolVersion,
            'request_id' => $requestId,
            'action' => $action,
            'arguments' => $arguments,
        ], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);

        $pipes = [];
        $process = proc_open(
            [$this->hostExecutable, $this->helperAssembly],
            [
                0 => ['pipe', 'r'],
                1 => ['pipe', 'w'],
                2 => ['pipe', 'w'],
            ],
            $pipes,
            dirname($this->helperAssembly),
            null,
            ['bypass_shell' => true],
        );

        if (!is_resource($process)) {
            throw new RuntimeException('Nie można uruchomić helpera Windows.');
        }

        fwrite($pipes[0], $request);
        fclose($pipes[0]);
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);
        $stdout = '';
        $stderr = '';
        $deadline = microtime(true) + $this->timeoutSeconds;

        do {
            $stdout .= stream_get_contents($pipes[1]);
            $stderr .= stream_get_contents($pipes[2]);
            $status = proc_get_status($process);

            if (!$status['running']) {
                break;
            }

            if (microtime(true) >= $deadline) {
                proc_terminate($process);
                throw new RuntimeException('Przekroczono czas oczekiwania na helper Windows.');
            }

            usleep(10_000);
        } while (true);

        $stdout .= stream_get_contents($pipes[1]);
        $stderr .= stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        proc_close($process);

        try {
            $response = json_decode(trim($stdout), true, flags: JSON_THROW_ON_ERROR);
        } catch (JsonException $error) {
            throw new RuntimeException('Helper zwrócił nieprawidłową odpowiedź JSON: ' . trim($stderr), 0, $error);
        }

        if (!is_array($response) || ($response['request_id'] ?? null) !== $requestId) {
            throw new RuntimeException('Odpowiedź helpera nie pasuje do wysłanego żądania.');
        }

        if (($response['ok'] ?? false) !== true) {
            $helperError = $response['error'] ?? [];
            throw new HelperException(
                (string) ($helperError['code'] ?? 'unknown_error'),
                (string) ($helperError['message'] ?? 'Helper odrzucił operację.'),
                is_array($helperError['details'] ?? null) ? $helperError['details'] : [],
            );
        }

        return is_array($response['data'] ?? null) ? $response['data'] : [];
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

