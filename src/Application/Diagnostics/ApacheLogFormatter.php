<?php

declare(strict_types=1);

namespace DomainManager\Application\Diagnostics;

final class ApacheLogFormatter
{
    /** @return list<array{level: string, content: string}> */
    public static function entries(string $log): array
    {
        $lines = preg_split('/\R/', trim($log));
        if ($lines === false || $lines === ['']) return [];

        $entries = [];
        $current = [];

        foreach ($lines as $line) {
            if (preg_match('/^\[(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s/', $line) === 1 && $current !== []) {
                $entries[] = self::entry($current);
                $current = [];
            }
            $current[] = $line;
        }

        if ($current !== []) $entries[] = self::entry($current);
        return $entries;
    }

    /** @param list<string> $lines @return array{level: string, content: string} */
    private static function entry(array $lines): array
    {
        $content = implode("\n", $lines);
        preg_match('/\[[^\]]+:(emerg|alert|crit|error|warn|notice|info|debug|trace\d*)\]/i', $content, $match);
        $severity = strtolower($match[1] ?? '');
        $level = match ($severity) {
            'emerg', 'alert', 'crit', 'error' => 'error',
            'warn' => 'warning',
            'notice', 'info' => 'notice',
            'debug', 'trace1', 'trace2', 'trace3', 'trace4', 'trace5', 'trace6', 'trace7', 'trace8' => 'debug',
            default => 'unknown',
        };

        return ['level' => $level, 'content' => self::formatLongLines($content)];
    }

    private static function formatLongLines(string $content): string
    {
        $lines = preg_split('/\R/', $content);
        if ($lines === false) return $content;

        return implode("\n", array_map(static function (string $line): string {
            if (strlen($line) < 240) return $line;

            $prefix = '';
            $payload = $line;
            if (preg_match('/^(.*?\b(?:stderr|stdout):)\s+(.*)$/i', $line, $match) === 1) {
                $prefix = $match[1] . "\n";
                $payload = $match[2];
            }

            return $prefix . self::formatStructuredPayload($payload);
        }, $lines));
    }

    private static function formatStructuredPayload(string $payload): string
    {
        $formatted = '';
        $indent = 0;
        $quote = null;
        $escaped = false;
        $length = strlen($payload);

        for ($index = 0; $index < $length; $index++) {
            $character = $payload[$index];

            if ($quote !== null) {
                $formatted .= $character;
                if ($escaped) {
                    $escaped = false;
                } elseif ($character === '\\') {
                    $escaped = true;
                } elseif ($character === $quote) {
                    $quote = null;
                }
                continue;
            }

            if ($character === "'" || $character === '"') {
                $quote = $character;
                $formatted .= $character;
            } elseif ($character === '{') {
                $formatted = rtrim($formatted) . " {\n" . str_repeat('  ', ++$indent);
                while ($index + 1 < $length && $payload[$index + 1] === ' ') $index++;
            } elseif ($character === '}') {
                $indent = max(0, $indent - 1);
                $formatted = rtrim($formatted) . "\n" . str_repeat('  ', $indent) . '}';
            } elseif ($character === ';') {
                $formatted .= ";\n" . str_repeat('  ', $indent);
                while ($index + 1 < $length && $payload[$index + 1] === ' ') $index++;
            } else {
                $formatted .= $character;
            }
        }

        return trim($formatted);
    }
}
