# Historia zmian

## v0.6 — 2026-09-13

### Windows

- Dokończono instalator z kontrolą wymagań, rollbackiem i obsługą istniejących usług Apache oraz IIS.
- Dodano bezpieczną deinstalację, migrację starszych instalacji i odtwarzanie stanu sprzed instalacji.
- Utwardzono konta usług, ACL-e Apache, PHP, helpera, certyfikatów i danych w `ProgramData`.
- Dodano automatyczny start usług, kontrolę ich odzyskiwania oraz test po pełnym restarcie Windows.
- Usprawniono konfigurację lokalnego CA, HTTPS i cyklu życia certyfikatów.
- Rozbudowano diagnostykę Apache o stan certyfikatu, podsumowanie logów i zdarzenia od ostatniego startu.
- Dodano centralne maskowanie haseł, tokenów, kluczy API, nagłówków autoryzacji i kluczy prywatnych.
- Dodano automatyczne testy PowerShell, PHP i helpera .NET oraz kontrolę działania usług, Named Pipe i HTTPS.

### Zgodność

- Windows 10/11 z PowerShell 7 i .NET SDK 10.
- Apache 2.4 oraz wiele skonfigurowanych wersji PHP.
