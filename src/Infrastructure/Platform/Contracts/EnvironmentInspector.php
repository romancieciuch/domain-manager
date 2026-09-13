<?php

declare(strict_types=1);

namespace DomainManager\Infrastructure\Platform\Contracts;

interface EnvironmentInspector
{
    /** @return array<string, mixed> */
    public function inspect(): array;
}

