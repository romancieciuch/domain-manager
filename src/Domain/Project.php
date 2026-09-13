<?php

declare(strict_types=1);

namespace DomainManager\Domain;

final readonly class Project
{
    /**
     * @param list<DomainName> $domains
     */
    public function __construct(
        public ?int $id,
        public string $name,
        public string $rootPath,
        public string $phpVersion,
        public bool $httpsEnabled,
        public array $domains,
        public int $primaryDomainIndex,
        public string $status = 'active',
    ) {}

    public function primaryDomain(): DomainName
    {
        return $this->domains[$this->primaryDomainIndex];
    }
}

