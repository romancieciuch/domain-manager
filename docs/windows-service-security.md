# Bezpieczeństwo usługi Apache na Windows

Apache uruchamia procesy FastCGI projektu, dlatego nie może działać jako
`LocalSystem`. Docelowym kontem jest wirtualne konto usługi:

```text
NT SERVICE\DomainManagerApache
```

Instalator `scripts/windows/secure-apache-service.ps1`:

1. wymaga administratora,
2. akceptuje tylko istniejące, bezwzględne katalogi,
3. zatrzymuje usługę i zachowuje stan początkowy,
4. tworzy wersjonowany backup `httpd.conf`,
5. atomowo dodaje zarządzany `IncludeOptional`,
6. włącza SID usługi i zmienia konto,
7. nadaje Apache i runtime'om PHP tylko odczyt/uruchamianie,
8. nadaje prawo modyfikacji wyłącznie katalogowi logów Apache,
9. wykonuje `httpd.exe -t` i sprawdza start usługi,
10. przy błędzie odtwarza konfigurację i konto `LocalSystem`.

ACL DocumentRoot są poza tym skryptem. Helper nada je osobno podczas aktywacji
projektu, dzięki czemu Apache nie otrzyma automatycznie dostępu do wszystkich
katalogów użytkownika.

Istniejące instalacje Apache/PHP mogą dziedziczyć z dysku `C:` prawo modyfikacji
dla wszystkich uwierzytelnionych użytkowników. Skrypt
`scripts/windows/harden-runtime-acls.ps1` odcina dziedziczenie wyłącznie na
konkretnych katalogach wersji Apache i PHP, zapisuje backup SDDL oraz pozostawia:

- pełny dostęp dla `SYSTEM` i Administratorów,
- odczyt/uruchamianie dla zwykłych użytkowników i usługi Apache,
- zapis usługi Apache tylko w katalogu `logs`.

Próba bez zmian:

```powershell
pwsh -File scripts/windows/harden-runtime-acls.ps1 -WhatIf
```

## Uruchomienie próbne

```powershell
pwsh -File scripts/windows/secure-apache-service.ps1 -WhatIf
```

## Wykonanie

Uruchomić dopiero po sprawdzeniu wyniku `-WhatIf`, w PowerShellu administratora:

```powershell
pwsh -File scripts/windows/secure-apache-service.ps1
```
