# Konfiguracja środowiska

Lokalne instalacje Apache i PHP opisuje plik `config/runtime.json`. Jest to
konfiguracja wdrożeniowa; dane projektów nadal znajdują się w SQLite.

## PHP

Każdy wpis `php.versions` ma pełną wersję jako klucz oraz trzy ścieżki:

- `root` — katalog danej dystrybucji PHP,
- `cli` — `php.exe`,
- `cgi` — `php-cgi.exe` używany przez Apache i `mod_fcgid`.

`php.default_version` musi wskazywać jeden z wpisów `php.versions`. Dodanie nowej
wersji do mapy automatycznie udostępnia ją w formularzu projektu.

## Apache

Sekcja `apache` zawiera pełną wersję, katalog instalacji oraz nazwę usługi
Windows. Ścieżka wskazuje katalog nadrzędny zawierający `bin/httpd.exe` i
`conf/httpd.conf`.

## Bezpieczeństwo helpera

Plik w repozytorium jest edytowalny przez użytkownika, dlatego nie może być
bezpośrednim źródłem zaufania dla procesu `LocalSystem`. Instalator waliduje
ścieżki i kopiuje zatwierdzoną konfigurację do
`C:/ProgramData/DomainManager/config/runtime.json`. Helper odczytuje wyłącznie tę
chronioną kopię. Skrypty instalacji i aktualizacji helpera walidują konfigurację,
kopiują ją atomowo oraz ograniczają ACL katalogu do `SYSTEM` i administratorów.
Zmiana ścieżek wymaga ponownego uruchomienia skryptu aktualizacji helpera.
