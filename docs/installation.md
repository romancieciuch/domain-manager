# Instalacja Domain Managera na czystym Windowsie

Poniższa instrukcja prowadzi od świeżej instalacji Windows 10 lub Windows 11 do
działającego Domain Managera pod adresem
`https://domain-manager.localhost/`.

## 1. Zainstaluj podstawowe narzędzia

Uruchom Terminal albo Windows PowerShell jako administrator, a następnie wykonaj:

```powershell
winget install Git.Git
winget install Microsoft.PowerShell
winget install Microsoft.DotNet.SDK.10
winget install FiloSottile.mkcert
```

Po instalacji zamknij terminal i uruchom **PowerShell 7 jako administrator**.
Sprawdź dostępność narzędzi:

```powershell
git --version
pwsh --version
dotnet --list-sdks
mkcert -version
```

Na liście SDK musi znajdować się wersja `10.x`.

## 2. Przygotuj Apache i PHP

Instalator Domain Managera nie pobiera jeszcze Apache ani PHP. Domyślna
konfiguracja oczekuje następujących katalogów:

```text
C:\apache\2.4.68
C:\php\8.5.10
```

Można użyć innych wersji i katalogów, ale później trzeba wpisać ich rzeczywiste
ścieżki w `config/runtime.json`.

Dystrybucja PHP musi zawierać co najmniej:

```text
C:\php\8.5.10\php.exe
C:\php\8.5.10\php-cgi.exe
```

W pliku `C:\php\8.5.10\php.ini` włącz rozszerzenia SQLite, usuwając poprzedzający
je średnik, jeżeli jest obecny:

```ini
extension=pdo_sqlite
extension=sqlite3
```

Sprawdź rozszerzenia poleceniem:

```powershell
C:\php\8.5.10\php.exe -m
```

Na liście muszą znajdować się `PDO`, `pdo_sqlite` i `sqlite3`.

W pliku `C:\apache\2.4.68\conf\httpd.conf` włącz następujące moduły:

```apache
LoadModule rewrite_module modules/mod_rewrite.so
LoadModule ssl_module modules/mod_ssl.so
LoadModule fcgid_module modules/mod_fcgid.so
```

Wykonaj kontrolę modułów Apache:

```powershell
C:\apache\2.4.68\bin\httpd.exe -M
```

Na liście muszą znajdować się `rewrite_module`, `ssl_module` i `fcgid_module`.

## 3. Utwórz katalog projektów

Domyślna konfiguracja pozwala tworzyć projekty w `D:\Projekty`:

```powershell
New-Item -ItemType Directory -Path D:\Projekty -Force
```

Jeśli komputer nie ma dysku `D:`, użyj innego katalogu, na przykład
`C:\Projekty`, i wpisz go później w `projects.allowed_roots`.

## 4. Pobierz Domain Managera

Przykład instalacji w `D:\Projekty\local`:

```powershell
New-Item -ItemType Directory -Path D:\Projekty\local -Force
Set-Location D:\Projekty\local
git clone https://github.com/romancieciuch/domain-manager.git
Set-Location .\domain-manager
```

Jeśli aplikacja ma znajdować się w innym miejscu, sklonuj repozytorium do
wybranego katalogu i wykonuj kolejne polecenia z jego głównego katalogu.

## 5. Skonfiguruj ścieżki

Otwórz `config/runtime.json` i dopasuj ścieżki Apache, PHP oraz katalogu
projektów. Przykładowa konfiguracja:

```json
{
  "schema_version": 1,
  "platform": "windows",
  "apache": {
    "version": "2.4.68",
    "root": "C:/apache/2.4.68",
    "service_name": "DomainManagerApache"
  },
  "php": {
    "default_version": "8.5.10",
    "versions": {
      "8.5.10": {
        "root": "C:/php/8.5.10",
        "cli": "C:/php/8.5.10/php.exe",
        "cgi": "C:/php/8.5.10/php-cgi.exe"
      }
    }
  },
  "projects": {
    "allowed_roots": [
      "D:/Projekty"
    ]
  },
  "tools": {
    "mkcert": "C:/Program Files/Domain Manager/Tools/mkcert.exe"
  }
}
```

`php.default_version` musi wskazywać wersję istniejącą w `php.versions`.
Każdy katalog wymieniony w `projects.allowed_roots` musi istnieć przed
uruchomieniem instalatora.

## 6. Uruchom instalator

W głównym katalogu Domain Managera, w **PowerShell 7 uruchomionym jako
administrator**, wykonaj:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

Zmiana zasad wykonywania dotyczy tylko bieżącego okna PowerShell. Jeśli
instalator nie znajdzie `mkcert`, wskaż plik bezpośrednio:

```powershell
.\install.ps1 -MkcertSource (Get-Command mkcert.exe).Source
```

Instalator automatycznie:

- sprawdzi PHP, Apache i .NET SDK;
- zapisze stan Windows potrzebny do bezpiecznej deinstalacji;
- utworzy lub skonfiguruje usługę `DomainManagerApache`;
- ograniczy uprawnienia usług oraz katalogów runtime;
- utworzy bazę SQLite i wykona migracje;
- zbuduje i zainstaluje usługę `DomainManagerHelper`;
- utworzy lokalne CA i certyfikaty HTTPS;
- skonfiguruje VirtualHost Domain Managera;
- skonfiguruje rotację logów i automatyczny start;
- wykona końcowy test strony po HTTPS.

Jeśli brakuje wymagania, instalator zatrzyma się i wyświetli konkretną instrukcję.
Po uzupełnieniu wymagania można bezpiecznie uruchomić `install.ps1` ponownie.

## 7. Sprawdź instalację

Otwórz w przeglądarce:

```text
https://domain-manager.localhost/
```

Domain Manager nie wymaga ręcznego dodawania tego adresu do systemowego pliku
`hosts`.

Sprawdź usługi:

```powershell
Get-Service DomainManagerApache, DomainManagerHelper
```

Obie powinny mieć status `Running`. Następnie uruchom testy:

```powershell
.\tests\windows\run.ps1 -SkipBuild
.\tests\windows\test-service-recovery.ps1
```

## 8. Ręczne uruchomienie i naprawa autostartu

Jeżeli po uruchomieniu Windows aplikacja nie odpowiada od razu, dwukrotnie
kliknij:

```text
start-domain-manager.cmd
```

Launcher poprosi o zgodę UAC, uruchomi Apache i helpera, sprawdzi stronę oraz
otworzy ją w domyślnej przeglądarce.

Aby ponownie skonfigurować szybki autostart usług, uruchom PowerShell 7 jako
administrator i wykonaj:

```powershell
.\scripts\windows\enable-domain-manager-autostart.ps1
```

## Deinstalacja

PowerShell 7 uruchomiony jako administrator:

```powershell
.\uninstall.ps1
```

Domyślna deinstalacja zachowuje katalogi projektów i bazę aplikacji. Aby usunąć
również dane aplikacji i usługę Apache utworzoną przez Domain Managera oraz
ponownie włączyć IIS, użyj:

```powershell
.\uninstall.ps1 -RemoveApplicationData -RemoveApacheService -EnableIis
```
