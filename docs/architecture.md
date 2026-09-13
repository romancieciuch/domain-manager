# Architektura MVP

## Zasady

Domain Manager jest modularnym monolitem PHP. Logika projektów nie zna systemu
operacyjnego. Różnice Windows, Debian i macOS znajdują się w małych adapterach
implementujących kontrakty Apache, hosts, PHP, certyfikatów, usług i integracji
z pulpitem.

Kolejność implementacji platform:

1. Windows 11
2. Debian/Linux
3. macOS

Backend aplikacji działa bez uprawnień administratora. Operacje uprzywilejowane
wykonuje osobny helper przez lokalny, uwierzytelniony kanał IPC. Helper przyjmuje
zamknięty zestaw typowanych operacji i nigdy nie przyjmuje dowolnej komendy
powłoki.

## Model

Projekt opisuje wspólne środowisko: DocumentRoot, wersję PHP, HTTPS i ustawienia
Apache. Projekt ma co najmniej jedną domenę. Domeny są równorzędnymi rekordami,
ale dokładnie jedna jest oznaczona jako główna.

W Apache domena główna staje się `ServerName`, a pozostałe domeny
`ServerAlias`. Usunięcie domeny głównej wymaga wybrania nowej. Usunięcie projektu
nigdy nie usuwa jego DocumentRoot.

## PHP i Apache

- Windows: wspólny Apache, `mod_fcgid` i wersjonowane `php-cgi.exe` przypisane
  per VirtualHost.
- Debian: wspólny Apache i wersjonowane sockety PHP-FPM.
- macOS: adapter zostanie wybrany po implementacji Windows i Debiana.

VirtualHost projektu obsługuje `.htaccess` przez `AllowOverride All` w MVP.
Instalator i diagnostyka sprawdzają `mod_rewrite`, `mod_ssl` oraz mechanizm
FastCGI odpowiedni dla platformy.

## Operacje systemowe

Zmiany systemowe są wykonywane jako plan kroków:

1. `prepare` - walidacja, odczyt poprzedniego stanu i staging,
2. `apply` - atomowe zastosowanie przygotowanej zmiany,
3. `verify` - test konfiguracji i kontrola wyniku,
4. `commit` - zatwierdzenie danych aplikacji,
5. `compensate` - odtworzenie poprzedniego stanu po błędzie.

Manifest operacji jest przechowywany w `data/operations/<uuid>/`, aby po awarii
można było rozpoznać i bezpiecznie dokończyć rollback. SQLite pozostaje jedynym
źródłem prawdy dla projektów. JSON manifestu jest tylko dziennikiem operacji.

Manager modyfikuje w pliku hosts wyłącznie oznaczony blok Domain Managera.
Przed zapisem helper porównuje hash aktualnego pliku z hashem fazy `prepare`,
aby nie nadpisać równolegle wprowadzonych zmian.

## Bezpieczenstwo helpera

Planowane operacje protokołu obejmują m.in.:

- `hosts.apply_managed_block`,
- `apache.write_project_config`,
- `apache.remove_project_config`,
- `apache.test`,
- `apache.reload`,
- `certificate.generate`,
- `service.query`.

Nie istnieje operacja `run_command`. Helper ponownie waliduje domeny, ścieżki,
dozwolone katalogi, oczekiwane hashe i rozmiary danych. Każda operacja otrzymuje
identyfikator i jest zapisywana w audycie.

## Najblizsze iteracje

1. Model domenowy projektu i walidacja domen.
2. Repozytorium SQLite oraz przypadki użycia list/create/edit/delete.
3. Kontrakty platformowe i fałszywe adaptery do testów rollbacku.
4. Referencyjne adaptery Windows i helper.
5. Proste, przyjazne GUI.
