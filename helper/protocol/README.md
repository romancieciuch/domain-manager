# Protokół helpera Windows

Helper obsługuje dwa transporty protokołu:

- standardowe wejście/wyjście — transport deweloperski do podglądu konfiguracji,
- `\\.\pipe\DomainManager.Helper.v1` — transport usługi Windows dla operacji
  uprzywilejowanych; każde żądanie i odpowiedź to pojedynczy JSON zakończony LF.

Named Pipe ma chronioną listę ACL. Dostęp otrzymują wyłącznie `LOCAL SYSTEM`,
lokalni administratorzy i SID usługi `NT SERVICE\DomainManagerApache`. Sama
usługa helpera nadal sprawdza zamkniętą listę akcji oraz wszystkie argumenty.

Helper nie przyjmuje poleceń powłoki, nazw programów ani dowolnych ścieżek
docelowych. Każda akcja znajduje się na zamkniętej liście.

## Akcje protokołu 1

- `helper.status` — wersja protokołu i stan procesu,
- `apache.preview_project` — walidacja danych i bezpieczne wygenerowanie podglądu,
- `apache.diagnostics` — stan usługi, test konfiguracji, porty 80/443 i maksymalnie
  60 ostatnich wierszy zarządzanego `error_log`; hasła, tokeny, klucze API,
  nagłówki autoryzacji i klucze prywatne są maskowane przed zwróceniem odpowiedzi,
- `apache.reload` — test konfiguracji i kontrolowane przeładowanie usługi Apache;
  nie wykonuje restartu, jeśli `httpd -t` zgłosi błąd,
- `apache.clear_error_log` — zeruje aktywny `error_log` i usuwa wyłącznie jego
  numerowane rotacje w zatwierdzonym katalogu logów Apache,
- `project.apply` — transakcyjna aktualizacja zarządzanego bloku `hosts`,
  certyfikatu obejmującego wszystkie domeny, konfiguracji VirtualHost, ACL
  DocumentRoot, test Apache i reload. Wymaga zgodnych hashy konfiguracji i pliku
  `hosts`; w przypadku błędu odtwarza wszystkie zmienione zasoby,
- `project.delete` — transakcyjne usunięcie wyłącznie zasobów zarządzanych dla
  wskazanego projektu: bloku `hosts`, VirtualHosta, certyfikatu i uprawnienia
  Apache do DocumentRoot. Nie usuwa katalogu ani plików projektu. Po błędzie
  przywraca konfigurację, certyfikat, ACL i poprzedni stan Apache.

Kolejne akcje mutujące (`hosts.apply_managed_block`, certyfikaty) zostaną dodane
dopiero wraz z odpowiadającymi im mechanizmami rollbacku.
