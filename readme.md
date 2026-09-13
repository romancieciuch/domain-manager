# Domain Manager

Lekki, lokalny manager projektów PHP. Pierwsza implementowana platforma to
Windows 11; adaptery dla Debiana i macOS będą korzystały z tego samego rdzenia
aplikacji.

Projekt jest obecnie w Etapie 1: fundament architektury i model danych.

## Wymagania deweloperskie

- PHP 8.2 lub nowszy z `PDO` i `pdo_sqlite`
- SQLite przez rozszerzenie PHP
- .NET SDK 10 do zbudowania usługi helpera Windows

Composer ani Node.js nie są wymagane.

## Testy

Lekki zestaw testów nie wymaga PHPUnit ani Composera:

```powershell
php tests/run.php
```

Pełna kontrola Windows sprawdza dodatkowo składnię instalatora i wszystkich
skryptów administracyjnych oraz buduje helpera:

```powershell
pwsh .\tests\windows\run.ps1
```

Kontrolowany test ponownego uruchomienia Apache, helpera, Named Pipe i HTTPS
(PowerShell uruchomiony jako administrator):

```powershell
pwsh .\tests\windows\test-service-recovery.ps1
```

## Pierwsze uruchomienie

Pełna instalacja lub naprawa środowiska Windows (PowerShell 7 jako administrator):

```powershell
.\install.ps1
```

Instalator nie pobiera Apache ani PHP. Czyta ścieżki z `config/runtime.json`,
sprawdza wymagane moduły i rozszerzenia, a jeśli czegoś brakuje — zatrzymuje się
z konkretną instrukcją. Następnie przygotowuje SQLite, HTTPS, VirtualHost,
ograniczony helper, rotację logów i autostart.

Uruchomienie wyłącznie deweloperskiego serwera PHP:

```powershell
php bin/migrate.php
php -S 127.0.0.1:8097 -t public
```

Baza zostanie utworzona domyślnie w `data/app.sqlite`. Interfejs będzie dostępny
pod adresem `http://127.0.0.1:8097`.

## Dokumentacja

- [Architektura MVP](docs/architecture.md)
- [Bezpieczeństwo usługi Apache na Windows](docs/windows-service-security.md)
- [Konfiguracja Apache i wersji PHP](docs/runtime-configuration.md)

## Helper Windows

Helper nie przyjmuje dowolnych poleceń systemowych. Wersja usługowa komunikuje
się lokalnym Named Pipe z restrykcyjnym ACL i wykonuje wyłącznie jawnie
zaimplementowane operacje. Host usługi korzysta bezpośrednio z API Windows,
więc projekt nie wymaga dodatkowego pakietu NuGet ani zewnętrznego wrappera.

Instalacja usługi (PowerShell 7 uruchomiony jako administrator):

```powershell
.\scripts\windows\install-helper-service.ps1
```

Udostępnienie GUI przez zabezpieczoną usługę Apache:

```powershell
.\scripts\windows\install-manager-vhost.ps1
```

Po instalacji interfejs działa pod `https://domain-manager.localhost/` bez wpisu
w systemowym pliku `hosts`.

Aktualizacja już zainstalowanej usługi helpera:

```powershell
.\scripts\windows\update-helper-service.ps1
```

Katalog `C:\ProgramData\DomainManager` jest chroniony przed zapisem i odczytem
przez zwykłych użytkowników. Pełny dostęp zachowują `SYSTEM` i lokalni
administratorzy, a konto usługi Apache otrzymuje wyłącznie odczyt potrzebny do
przejścia do osobno chronionego katalogu certyfikatów. Apache nie może czytać
konfiguracji helpera, stanu, logów, backupów ani katalogu stagingowego.

Jednorazowe przygotowanie lokalnego CA i portu HTTPS:

```powershell
.\scripts\windows\setup-https.ps1
```

Ustawienie Domain Managera jako domyślnego serwera po starcie Windows:

```powershell
.\scripts\windows\enable-domain-manager-autostart.ps1
```

Ręczne uruchomienie środowiska:

```powershell
.\scripts\windows\start-domain-manager.ps1
```

Ograniczenie rozmiaru logów błędów Apache (domyślnie 5 × 10 MB):

```powershell
.\scripts\windows\configure-apache-log-rotation.ps1
```

## Weryfikacja Windows

Pełny zestaw kontroli składni, testów PHP, buildu helpera i redakcji sekretów:

```powershell
.\tests\windows\run.ps1
```

Test restartu usług bez restartowania komputera:

```powershell
.\tests\windows\test-service-recovery.ps1
```

Test po pełnym restarcie jest celowo dwuetapowy. Najpierw jako administrator
zarejestruj jednorazowy checker, a następnie samodzielnie uruchom ponownie Windows:

```powershell
.\tests\windows\schedule-post-reboot-check.ps1
```

Wynik zostanie zapisany w chronionym pliku
`C:\ProgramData\DomainManager\logs\post-reboot-result.json`, a zadanie usunie się
automatycznie po wykonaniu.

## Deinstalacja Windows

Bezpieczna deinstalacja usuwa helper, konfiguracje Apache, certyfikaty i lokalne
CA Domain Managera, ale zachowuje katalogi projektów i bazę aplikacji. Jeśli
Apache istniał wcześniej, przywraca jego konfigurację, konto usługi, tryb startu
i ACL-e. Usługę Apache usuwa automatycznie tylko wtedy, gdy utworzył ją instalator:

```powershell
.\uninstall.ps1
```

Opcjonalnie można też usunąć bazę aplikacji, usługę Apache utworzoną dla Domain
Managera albo ponownie włączyć IIS:

```powershell
.\uninstall.ps1 -RemoveApplicationData -RemoveApacheService -EnableIis
```

Instalację wykonaną starszą wersją, która nie zapisała jeszcze migawki stanu,
można jednorazowo przygotować do bezpiecznej deinstalacji na podstawie najstarszych
backupów konfiguracji i ACL:

```powershell
.\scripts\windows\migrate-legacy-installation-state.ps1
```
