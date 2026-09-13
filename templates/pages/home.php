<!doctype html>
<html lang="pl">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Domain Manager</title>
    <link rel="icon" type="image/png" href="/favicon.png?v=2">
    <link rel="apple-touch-icon" href="/favicon.png?v=2">
    <link rel="stylesheet" href="/assets/app.css?v=<?= filemtime(dirname(__DIR__, 2) . '/public/assets/app.css') ?>">
    <script src="/assets/app.js?v=<?= filemtime(dirname(__DIR__, 2) . '/public/assets/app.js') ?>" defer></script>
</head>
<body>
<div class="app-shell">
    <header class="topbar">
        <a class="brand" href="/" aria-label="Domain Manager - strona główna">
            <img class="brand-mark" src="/assets/domain-manager-logo.svg" width="42" height="42" alt="">
            <span><strong>Domain Manager</strong><small>Lokalne projekty PHP</small></span>
        </a>
        <nav class="main-nav" aria-label="Główna nawigacja">
            <a class="nav-link <?= in_array($page, ['projects', 'apache'], true) ? 'active' : '' ?>" href="/">Projekty</a>
            <a class="nav-link <?= $page === 'environment' ? 'active' : '' ?>" href="/environment/">Środowisko</a>
            <a class="nav-link <?= $page === 'apache-diagnostics' ? 'active' : '' ?>" href="/apache/">Apache</a>
            <a class="nav-link <?= $page === 'operations' ? 'active' : '' ?>" href="/operations/">Historia</a>
            <a class="button button-primary" href="/projects/new/">+ Dodaj projekt</a>
        </nav>
    </header>

    <main>
        <?php if ($page === 'projects'): ?>
        <section class="hero">
            <div>
                <span class="eyebrow">Windows MVP</span>
                <h1>Twoje lokalne projekty,<br>bez grzebania w konfiguracji.</h1>
                <p>Jedno miejsce na domeny, wersje PHP, HTTPS i Apache.</p>
            </div>
            <div class="environment-pill"><span></span> Fundament gotowy</div>
        </section>
        <?php endif; ?>

        <?php if ($flash !== null): ?>
            <div class="notice notice-success"><?= e($flash) ?></div>
        <?php endif; ?>
        <?php if ($flashError !== null): ?>
            <div class="notice notice-error"><?= e($flashError) ?></div>
        <?php endif; ?>

        <?php if ($page === 'projects' && $showForm): ?>
            <section class="panel form-panel" id="project-form">
                <div class="panel-heading">
                    <div><span class="eyebrow"><?= $editingProjectId === null ? 'Nowe środowisko' : 'Edycja środowiska' ?></span><h2><?= $editingProjectId === null ? 'Dodaj projekt' : 'Edytuj projekt' ?></h2></div>
                    <a class="close-button" href="/" aria-label="Zamknij formularz">&times;</a>
                </div>

                <?php if ($errors !== []): ?>
                    <div class="notice notice-error"><strong>Sprawdź formularz:</strong><ul>
                        <?php foreach ($errors as $error): ?><li><?= e($error) ?></li><?php endforeach; ?>
                    </ul></div>
                <?php endif; ?>

                <form method="post" class="project-form">
                    <input type="hidden" name="csrf_token" value="<?= e($_SESSION['csrf_token']) ?>">
                    <input type="hidden" name="action" value="save">
                    <?php if ($editingProjectId !== null): ?><input type="hidden" name="project_id" value="<?= $editingProjectId ?>"><?php endif; ?>
                    <div class="field-grid">
                        <label class="field"><span>Nazwa projektu</span><input name="name" maxlength="120" required placeholder="Energy Days" value="<?= e((string) ($old['name'] ?? '')) ?>"></label>
                        <label class="field"><span>Wersja PHP</span><select name="php_version">
                            <?php foreach ($availablePhpVersions as $version): ?>
                                <option value="<?= e($version) ?>" <?= (($old['php_version'] ?? $defaultPhpVersion) === $version) ? 'selected' : '' ?>>PHP <?= e($version) ?></option>
                            <?php endforeach; ?>
                        </select></label>
                    </div>
                    <label class="field"><span>DocumentRoot</span><input name="root_path" required placeholder="D:\Projekty\konferencje\www" value="<?= e((string) ($old['root_path'] ?? '')) ?>"><small>Katalog musi już istnieć. Wybór katalogu przez okno systemowe dodamy z integracją Windows.</small></label>

                    <fieldset class="domains-fieldset">
                        <legend>Domeny projektu</legend>
                        <p>Gwiazdka wskazuje adres otwierany domyślnie. Pozostałe domeny prowadzą do tego samego projektu.</p>
                        <div id="domain-list">
                            <?php $oldDomains = is_array($old['domains'] ?? null) ? $old['domains'] : ['']; ?>
                            <?php foreach ($oldDomains as $index => $domain): ?>
                                <div class="domain-row">
                                    <label class="primary-choice" title="Domena główna"><input type="radio" name="primary_domain" value="<?= $index ?>" <?= ((string) ($old['primary_domain'] ?? '0') === (string) $index) ? 'checked' : '' ?>><span>★</span></label>
                                    <input name="domains[]" required placeholder="local.energydays.pl" value="<?= e((string) $domain) ?>">
                                    <button class="icon-button remove-domain" type="button" aria-label="Usuń domenę">&minus;</button>
                                </div>
                            <?php endforeach; ?>
                        </div>
                        <button class="button button-quiet" id="add-domain" type="button">+ Dodaj kolejną domenę</button>
                    </fieldset>

                    <label class="toggle"><input type="checkbox" name="https_enabled" value="1" <?= isset($old['https_enabled']) || $old === [] ? 'checked' : '' ?>><span></span><div><strong>Zaufany lokalny HTTPS</strong><small>Certyfikat obejmie wszystkie domeny projektu.</small></div></label>

                    <div class="form-note"><strong>Automatyczna konfiguracja:</strong> po zapisaniu Domain Manager skonfiguruje domeny, certyfikat HTTPS i VirtualHost, przetestuje konfigurację oraz przeładuje Apache.</div>
                    <div class="form-actions"><a class="button button-secondary" href="/">Anuluj</a><button class="button button-primary" type="submit"><?= $editingProjectId === null ? 'Dodaj i uruchom' : 'Zapisz i synchronizuj' ?></button></div>
                </form>
            </section>
        <?php endif; ?>

        <?php if ($page === 'projects'): ?>
        <section class="projects-section">
            <div class="section-heading">
                <div><span class="eyebrow">Workspace</span><h2>Projekty <span><?= count($projects) ?></span></h2></div>
                <label class="project-search">
                    <span aria-hidden="true">⌕</span>
                    <input id="project-search" type="search" placeholder="Szukaj projektu lub domeny…" autocomplete="off" <?= $projects === [] ? 'disabled' : '' ?>>
                </label>
            </div>
            <?php if ($projects === []): ?>
                <div class="empty-state"><div class="empty-icon">⌂</div><h3>Jeszcze nie ma tu projektów</h3><p>Dodaj pierwszy katalog i przypisz mu wygodną lokalną domenę.</p><a class="button button-primary" href="/projects/new/">Dodaj pierwszy projekt</a></div>
            <?php else: ?>
                <div class="project-grid" id="project-grid">
                    <?php foreach ($projects as $project): ?>
                        <?php $url = ($project->httpsEnabled ? 'https://' : 'http://') . $project->primaryDomain()->value; ?>
                        <?php $projectStatus = $projectStatuses[$project->id]; ?>
                        <?php $searchValue = implode(' ', array_merge([$project->name, $project->rootPath, $project->phpVersion], array_map(static fn ($domain) => $domain->value, $project->domains))); ?>
                        <article class="project-card" data-project-card data-search="<?= e(strtolower($searchValue)) ?>">
                            <div class="card-top"><div class="project-avatar"><?= e(strtoupper(substr($project->name, 0, 2))) ?></div><span class="status <?= $projectStatus['active'] ? 'status-active' : 'status-draft' ?>" title="<?= e($projectStatus['detail']) ?>"><i></i> <?= e($projectStatus['label']) ?></span></div>
                            <h3><?= e($project->name) ?></h3>
                            <a class="project-url" href="<?= e($url) ?>" target="_blank" rel="noopener"><?= e($url) ?></a>
                            <?php if (count($project->domains) > 1): ?><?php $additionalDomains = count($project->domains) - 1; ?><p class="aliases">+<?= $additionalDomains ?> <?= additionalDomainsLabel($additionalDomains) ?></p><?php endif; ?>
                            <div class="root-path-row">
                                <p class="root-path" title="<?= e($project->rootPath) ?>"><?= e($project->rootPath) ?></p>
                                <button class="copy-path" type="button" data-copy-path="<?= e($project->rootPath) ?>" title="Kopiuj ścieżkę" aria-label="Kopiuj ścieżkę projektu">Kopiuj</button>
                            </div>
                            <div class="chips"><span>PHP <?= e($project->phpVersion) ?></span><span><?= $project->httpsEnabled ? 'HTTPS' : 'HTTP' ?></span><span title="<?= e($projectStatus['apache']) ?>"><?= e($projectStatus['apache']) ?></span></div>
                            <div class="card-actions">
                                <?php if (!$projectStatus['active']): ?>
                                    <form method="post" class="sync-form">
                                        <input type="hidden" name="csrf_token" value="<?= e($_SESSION['csrf_token']) ?>">
                                        <input type="hidden" name="action" value="apply_apache">
                                        <input type="hidden" name="project_id" value="<?= $project->id ?>">
                                        <input type="hidden" name="expected_previous_hash" value="<?= e((string) $projectStatus['config_hash']) ?>">
                                        <input type="hidden" name="expected_hosts_hash" value="<?= e((string) $projectStatus['hosts_hash']) ?>">
                                        <button class="button button-primary" type="submit">Synchronizuj</button>
                                    </form>
                                <?php else: ?>
                                    <a class="button button-secondary" href="<?= e($url) ?>" target="_blank" rel="noopener">Otwórz</a>
                                <?php endif; ?>
                                <div class="card-tools">
                                    <a class="icon-button icon-link" href="/projects/<?= $project->id ?>/apache/" aria-label="Podgląd konfiguracji Apache" title="Konfiguracja Apache">&lt;/&gt;</a>
                                    <a class="icon-button icon-link" href="/projects/<?= $project->id ?>/edit/" aria-label="Edytuj projekt" title="Edytuj">✎</a>
                                    <form method="post" class="delete-form" data-project-name="<?= e($project->name) ?>">
                                        <input type="hidden" name="csrf_token" value="<?= e($_SESSION['csrf_token']) ?>">
                                        <input type="hidden" name="action" value="delete">
                                        <input type="hidden" name="project_id" value="<?= $project->id ?>">
                                        <input type="hidden" name="expected_previous_hash" value="<?= e((string) $projectStatus['config_hash']) ?>">
                                        <input type="hidden" name="expected_hosts_hash" value="<?= e((string) $projectStatus['hosts_hash']) ?>">
                                        <button class="icon-button delete-button" type="submit" aria-label="Usuń projekt" title="Usuń">×</button>
                                    </form>
                                </div>
                            </div>
                        </article>
                    <?php endforeach; ?>
                </div>
                <div class="search-empty" id="search-empty" hidden><h3>Brak pasujących projektów</h3><p>Spróbuj wpisać nazwę, domenę, ścieżkę lub wersję PHP.</p></div>
            <?php endif; ?>
        </section>
        <?php elseif ($page === 'environment'): ?>
            <section class="environment-header">
                <div><span class="eyebrow">Diagnostyka Windows</span><h1>Środowisko lokalne</h1><p>Rzeczywisty stan komponentów wykryty bez modyfikowania systemu.</p></div>
                <a class="button button-secondary" href="/environment/">Odśwież status</a>
            </section>
            <section class="environment-layout">
                <div class="environment-group">
                    <div class="section-heading"><div><span class="eyebrow">Wymagane</span><h2>Podstawowe komponenty</h2></div></div>
                    <div class="status-list"><?php foreach ($environment['required'] as $component) require __DIR__ . '/../partials/component-status.php'; ?></div>
                </div>
                <div class="environment-group">
                    <div class="section-heading"><div><span class="eyebrow">Per projekt</span><h2>Wersje PHP</h2></div></div>
                    <div class="status-list"><?php foreach ($environment['php'] as $component) require __DIR__ . '/../partials/component-status.php'; ?></div>
                </div>
                <div class="environment-group environment-group-wide">
                    <div class="section-heading"><div><span class="eyebrow">Opcjonalne</span><h2>Narzędzia dodatkowe</h2></div></div>
                    <div class="status-list status-list-grid"><?php foreach ($environment['optional'] as $component) require __DIR__ . '/../partials/component-status.php'; ?></div>
                </div>
            </section>
        <?php elseif ($page === 'operations'): ?>
            <section class="environment-header">
                <div><span class="eyebrow">Dziennik zmian</span><h1>Historia operacji</h1><p>Ostatnie operacje wykonane przez Domain Managera i ich wynik.</p></div>
                <a class="button button-secondary" href="/operations/">Odśwież</a>
            </section>
            <?php if ($operations === []): ?>
                <section class="empty-state"><div class="empty-icon">↺</div><h3>Brak zapisanych operacji</h3><p>Historia pojawi się po synchronizacji, dodaniu, edycji lub usunięciu projektu.</p></section>
            <?php else: ?>
                <section class="operation-list">
                    <?php $operationLabels = ['project.create' => 'Dodanie projektu', 'project.update' => 'Edycja projektu', 'project.sync' => 'Synchronizacja', 'project.delete' => 'Usunięcie projektu', 'apache.test' => 'Test Apache', 'apache.reload' => 'Przeładowanie Apache', 'apache.clear_error_log' => 'Czyszczenie logów Apache']; ?>
                    <?php foreach ($operations as $operation): ?>
                        <?php $successful = $operation['status'] === 'completed'; ?>
                        <?php $failedOperation = $operation['status'] === 'failed'; ?>
                        <?php $operationState = $successful ? 'success' : ($failedOperation ? 'failure' : 'pending'); ?>
                        <article class="operation-row">
                            <span class="operation-icon <?= $operationState ?>"><?= $successful ? '✓' : ($failedOperation ? '!' : '…') ?></span>
                            <div class="operation-main">
                                <strong><?= e($operationLabels[$operation['operation_type']] ?? $operation['operation_type']) ?></strong>
                                <span><?= e((string) ($operation['project_name'] ?: 'Projekt usunięty')) ?></span>
                                <?php if ($operation['error_message']): ?><small><?= e($operation['error_message']) ?></small><?php endif; ?>
                            </div>
                            <div class="operation-meta">
                                <span class="operation-status <?= $operationState ?>"><?= $successful ? 'Zakończono' : ($failedOperation ? 'Błąd' : 'W toku') ?></span>
                                <time datetime="<?= e($operation['started_at']) ?>"><?= e((new DateTimeImmutable($operation['started_at']))->setTimezone(new DateTimeZone('Europe/Warsaw'))->format('d.m.Y, H:i:s')) ?></time>
                            </div>
                        </article>
                    <?php endforeach; ?>
                </section>
            <?php endif; ?>
        <?php elseif ($page === 'apache-diagnostics'): ?>
            <section class="environment-header">
                <div><span class="eyebrow">Diagnostyka Windows</span><h1>Apache</h1><p>Stan usługi, portów, konfiguracji i ostatnich wpisów dziennika błędów.</p></div>
                <div class="diagnostic-actions">
                    <form method="post"><input type="hidden" name="csrf_token" value="<?= e($_SESSION['csrf_token']) ?>"><input type="hidden" name="action" value="apache_test"><button class="button button-secondary" type="submit">Testuj konfigurację</button></form>
                    <form method="post"><input type="hidden" name="csrf_token" value="<?= e($_SESSION['csrf_token']) ?>"><input type="hidden" name="action" value="apache_reload"><button class="button button-primary" type="submit">Przeładuj Apache</button></form>
                    <form method="post" class="clear-log-form"><input type="hidden" name="csrf_token" value="<?= e($_SESSION['csrf_token']) ?>"><input type="hidden" name="action" value="apache_clear_log"><button class="button button-danger" type="submit">Wyczyść logi</button></form>
                </div>
            </section>
            <?php if ($apacheDiagnostics !== null): ?>
                <section class="diagnostic-grid">
                    <?php foreach ([
                        ['Usługa Apache', ($apacheDiagnostics['service_running'] ?? false), ($apacheDiagnostics['service_running'] ?? false) ? 'Działa' : 'Zatrzymana'],
                        ['Konfiguracja', ($apacheDiagnostics['configuration_valid'] ?? false), (string) ($apacheDiagnostics['configuration_test'] ?? '')],
                        ['Port 80', ($apacheDiagnostics['port_80_listening'] ?? false), ($apacheDiagnostics['port_80_listening'] ?? false) ? 'Nasłuchuje' : 'Wolny'],
                        ['Port 443', ($apacheDiagnostics['port_443_listening'] ?? false), ($apacheDiagnostics['port_443_listening'] ?? false) ? 'Nasłuchuje' : 'Wolny'],
                    ] as [$label, $ok, $detail]): ?>
                        <article class="diagnostic-card"><span class="component-icon <?= $ok ? 'available' : 'missing' ?>"><?= $ok ? '✓' : '×' ?></span><div><strong><?= e($label) ?></strong><small><?= e($detail) ?></small></div></article>
                    <?php endforeach; ?>
                </section>
                <section class="log-panel">
                    <div class="log-heading"><div><span class="eyebrow">Maksymalnie 60 wierszy</span><h2>Ostatnie błędy Apache</h2></div><a class="button button-secondary" href="/apache/">Odśwież</a></div>
                    <?php if (($apacheDiagnostics['error_log'] ?? '') === ''): ?><p class="log-empty">Dziennik błędów jest pusty.</p><?php else: ?><pre><?= e((string) $apacheDiagnostics['error_log']) ?></pre><?php endif; ?>
                </section>
            <?php endif; ?>
        <?php elseif ($page === 'apache'): ?>
            <section class="preview-header">
                <div><span class="eyebrow">Podgląd bez zapisu</span><h1>VirtualHost: <?= e($apachePreviewProject->name) ?></h1><p>Konfiguracja wygenerowana dla PHP <?= e($apachePreviewProject->phpVersion) ?>. System nie został zmodyfikowany.</p></div>
                <a class="button button-secondary" href="/">Wróć do projektów</a>
            </section>
            <?php if ($apachePreview !== null): ?>
                <section class="config-preview">
                    <div class="config-toolbar"><span><?= e(rtrim(str_replace('\\', '/', $config['apache']['windows_root']), '/')) ?>/conf/domain-manager/project-<?= $apachePreviewProject->id ?>.conf</span><button class="button button-secondary" type="button" id="copy-config">Kopiuj</button></div>
                    <pre><code id="apache-config"><?= e($apachePreview) ?></code></pre>
                </section>
                <section class="preview-actions">
                        <form method="post">
                            <input type="hidden" name="csrf_token" value="<?= e($_SESSION['csrf_token']) ?>">
                            <input type="hidden" name="action" value="apply_apache">
                            <input type="hidden" name="project_id" value="<?= $apachePreviewProject->id ?>">
                            <input type="hidden" name="expected_previous_hash" value="<?= e((string) $apacheCurrentHash) ?>">
                            <input type="hidden" name="expected_hosts_hash" value="<?= e((string) $hostsCurrentHash) ?>">
                            <button class="button button-primary" type="submit">Zastosuj domeny i Apache</button>
                        </form>
                </section>
            <?php endif; ?>
        <?php else: ?>
            <section class="empty-state">
                <div class="empty-icon">404</div>
                <h1>Nie znaleziono strony</h1>
                <p>Ten adres nie prowadzi do żadnego widoku Domain Managera.</p>
                <a class="button button-primary" href="/">Wróć do projektów</a>
            </section>
        <?php endif; ?>
    </main>
</div>
</body>
</html>
