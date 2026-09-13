<?php

declare(strict_types=1);

namespace DomainManager\Infrastructure\Helper;

use JsonException;
use RuntimeException;

final readonly class WindowsNamedPipeClient
{
    public function __construct(
        private string $pipeName,
        private int $protocolVersion,
        private int $timeoutSeconds,
    ) {}

    /** @param array<string, mixed> $arguments */
    public function call(string $action, array $arguments = []): array
    {
        $requestId = $this->uuid();
        $request = json_encode([
            'protocol' => $this->protocolVersion,
            'request_id' => $requestId,
            'action' => $action,
            'arguments' => $arguments,
        ], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);

        $pipe = @fopen('\\\\.\\pipe\\' . $this->pipeName, 'r+b');
        if ($pipe === false) {
            throw new RuntimeException('Nie można połączyć się z usługą Domain Manager Helper.');
        }

        try {
            stream_set_timeout($pipe, $this->timeoutSeconds);
            if (fwrite($pipe, $request . "\n") === false || fflush($pipe) === false) {
                throw new RuntimeException('Nie można wysłać żądania do helpera Windows.');
            }
            $responseJson = fgets($pipe, 1024 * 1024);
            if ((stream_get_meta_data($pipe)['timed_out'] ?? false) === true) {
                throw new RuntimeException('Przekroczono czas oczekiwania na usługę helpera Windows.');
            }
            if ($responseJson === false) {
                throw new RuntimeException('Usługa helpera Windows nie zwróciła odpowiedzi.');
            }
        } finally {
            fclose($pipe);
        }

        try {
            $response = json_decode(trim($responseJson), true, flags: JSON_THROW_ON_ERROR);
        } catch (JsonException $error) {
            throw new RuntimeException('Usługa helpera zwróciła nieprawidłową odpowiedź JSON.', 0, $error);
        }
        if (!is_array($response) || ($response['request_id'] ?? null) !== $requestId) {
            throw new RuntimeException('Odpowiedź helpera nie pasuje do wysłanego żądania.');
        }
        if (($response['ok'] ?? false) !== true) {
            $helperError = is_array($response['error'] ?? null) ? $response['error'] : [];
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
