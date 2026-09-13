<?php

declare(strict_types=1);

use DomainManager\Infrastructure\Database\MigrationRunner;
use DomainManager\Infrastructure\Database\SqliteConnection;

require dirname(__DIR__) . '/bootstrap.php';

$config = require dirname(__DIR__) . '/config/app.php';
$database = SqliteConnection::open($config['database']['path']);
$runner = new MigrationRunner($database, dirname(__DIR__) . '/database/migrations');
$applied = $runner->migrate();

if ($applied === []) {
    fwrite(STDOUT, "Baza danych jest aktualna.\n");
    exit(0);
}

foreach ($applied as $migration) {
    fwrite(STDOUT, sprintf("Zastosowano migrację: %s\n", $migration));
}
