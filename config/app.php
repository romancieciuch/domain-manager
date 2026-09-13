<?php

declare(strict_types=1);

$runtime = \DomainManager\Infrastructure\Configuration\RuntimeConfiguration::load(__DIR__ . '/runtime.json');
$phpVersions = array_keys($runtime['php']['versions']);
$phpRuntimes = [];
$phpSearchRoots = [];
foreach ($runtime['php']['versions'] as $version => $phpRuntime) {
    $phpRuntimes[$version] = $phpRuntime['cgi'];
    $phpSearchRoots[] = dirname($phpRuntime['root']);
}

return [
    'runtime' => $runtime,
    'database' => [
        'path' => dirname(__DIR__) . '/data/app.sqlite',
    ],
    'domains' => [
        'default_address' => '127.0.0.1',
        'recommended_suffix' => '.test',
    ],
    'php' => [
        'available_versions' => $phpVersions,
        'default_version' => $runtime['php']['default_version'],
        'windows_search_roots' => array_values(array_unique($phpSearchRoots)),
        'windows_runtimes' => $phpRuntimes,
    ],
    'apache' => [
        'windows_root' => $runtime['apache']['root'],
        'windows_version' => $runtime['apache']['version'],
        'windows_service_name' => $runtime['apache']['service_name'],
        'windows_search_roots' => [dirname($runtime['apache']['root'])],
    ],
    'paths' => [
        'certificates' => dirname(__DIR__) . '/data/certificates',
        'logs' => dirname(__DIR__) . '/data/logs',
        'operations' => dirname(__DIR__) . '/data/operations',
        'sessions' => dirname(__DIR__) . '/data/sessions',
    ],
    'helper' => [
        'protocol_version' => 1,
        'timeout_seconds' => 30,
        'windows' => [
            'host' => 'C:/Program Files/dotnet/dotnet.exe',
            'assembly' => dirname(__DIR__) . '/helper/windows/bin/Release/net10.0-windows/domain-manager-helper.dll',
            'pipe_name' => 'DomainManager.Helper.v1',
        ],
    ],
];
