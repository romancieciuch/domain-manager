<?php

declare(strict_types=1);

namespace DomainManager\Domain;

use InvalidArgumentException;

final readonly class DomainName
{
    public string $value;

    public function __construct(string $value)
    {
        $value = strtolower(rtrim(trim($value), '.'));

        if ($value === '' || strlen($value) > 253) {
            throw new InvalidArgumentException('Podaj poprawną domenę o długości do 253 znaków.');
        }

        if (str_contains($value, '://') || str_contains($value, '/') || str_contains($value, ':')) {
            throw new InvalidArgumentException('Domena nie może zawierać protokołu, portu ani ścieżki.');
        }

        $labels = explode('.', $value);

        if (count($labels) < 2) {
            throw new InvalidArgumentException('Domena musi zawierać co najmniej jedną kropkę.');
        }

        foreach ($labels as $label) {
            if ($label === '' || strlen($label) > 63 || preg_match('/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/', $label) !== 1) {
                throw new InvalidArgumentException(sprintf('Niepoprawny fragment domeny: %s', $label ?: '(pusty)'));
            }
        }

        $this->value = $value;
    }

    public function __toString(): string
    {
        return $this->value;
    }
}
