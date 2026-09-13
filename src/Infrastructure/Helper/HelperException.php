<?php

declare(strict_types=1);

namespace DomainManager\Infrastructure\Helper;

use RuntimeException;

final class HelperException extends RuntimeException
{
    public function __construct(
        public readonly string $errorCode,
        string $message,
        public readonly array $details = [],
    ) {
        parent::__construct($message);
    }
}

