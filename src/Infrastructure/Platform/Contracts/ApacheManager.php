<?php

declare(strict_types=1);

namespace DomainManager\Infrastructure\Platform\Contracts;

use DomainManager\Domain\Project;

interface ApacheManager
{
    public function renderVirtualHost(Project $project): string;
}

