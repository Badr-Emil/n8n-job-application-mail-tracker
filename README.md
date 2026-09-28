# n8n Job Application Mail Tracker

Ein n8n-Workflow zur automatischen Verarbeitung von Bewerbungs-E-Mails.

## Features

- IMAP Email Trigger
- Klassifizierung ohne KI
- Regex-basierte Erkennung
- Kategorien:
  - Absage
  - Einladung
  - Zusage
  - Bewerbung / Eingangsbestätigung
  - Unbekannt
- Speicherung in PostgreSQL
- Telegram-Benachrichtigungen

## Workflow

IMAP Email
→ Edit Fields
→ Switch / Regex
→ Status setzen
→ Merge
→ PostgreSQL
→ Telegram

## Installation

1. Repository klonen
2. `database/schema.sql` in PostgreSQL ausführen
3. Workflow aus `workflow/` in n8n importieren
4. Eigenes IMAP-Credential erstellen
5. Eigenes PostgreSQL-Credential erstellen
6. Eigenes Telegram-Credential erstellen
7. Telegram Chat ID eintragen
8. Workflow testen
9. Workflow veröffentlichen

## Sicherheit

Dieses Repository enthält keine echten Passwörter, Tokens oder persönlichen Zugangsdaten.

Alle Credentials müssen lokal in n8n eingerichtet werden.
