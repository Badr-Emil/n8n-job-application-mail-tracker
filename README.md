# n8n Job Application Mail Tracker

An [n8n](https://n8n.io/) workflow that automatically tracks job application emails. It reads incoming emails via IMAP, classifies them with rule-based regular expressions (no AI or external API), stores the result in PostgreSQL, and sends a notification to Telegram.

The classification rules are written for **German-language** application emails, and the status values are stored in German.

---

## Table of Contents

- [Features](#features)
- [Email Classification Categories](#email-classification-categories)
- [Architecture](#architecture)
- [How the Workflow Works](#how-the-workflow-works)
- [Requirements](#requirements)
- [Project Structure](#project-structure)
- [Installation](#installation)
- [PostgreSQL Setup](#postgresql-setup)
- [Importing the Workflow into n8n](#importing-the-workflow-into-n8n)
- [Credential Configuration](#credential-configuration)
- [Telegram Configuration](#telegram-configuration)
- [Testing](#testing)
- [Known Limitations](#known-limitations)
- [Security](#security)
- [Future Improvements](#future-improvements)
- [Author](#author)

---

## Features

- **IMAP email trigger** – polls a mailbox for new emails
- **Field extraction** – extracts sender, subject and plain-text body
- **Normalized search text** – builds a lowercase `searchText` field from subject and body
- **Rule-based classification** – n8n `Switch` node with regex rules, no AI required
- **Five status categories** – `Bewerbung`, `Einladung`, `Zusage`, `Absage`, `Unbekannt`
- **PostgreSQL persistence** – every classified email is stored in the `bewerbungen` table
- **Telegram notification** – sends a message with status, sender, subject and text

---

## Email Classification Categories

| Status      | Meaning (English)                      | Example trigger phrases (German)                                                 |
|-------------|----------------------------------------|----------------------------------------------------------------------------------|
| `Absage`    | Rejection                              | `leider`, `absage`, `andere bewerber`, `anders entschieden`                      |
| `Einladung` | Interview invitation                   | `vorstellungsgespräch`, `interview`, `telefoninterview`, `termin vereinbaren`    |
| `Zusage`    | Job offer / acceptance                 | `zusage`, `stellenangebot`, `arbeitsvertrag`, `willkommen im team`               |
| `Bewerbung` | Application received / acknowledgement | `bewerbung eingegangen`, `vielen dank für ihre bewerbung`, `unterlagen erhalten` |
| `Unbekannt` | Unknown – no rule matched              | *(fallback output)*                                                              |

The full regular expressions are defined in the `Switch` node of the workflow.

**Rule order matters.** The `Switch` node evaluates the rules in the order listed above (`Absage` → `Einladung` → `Zusage` → `Bewerbung`) and routes each email to the **first** matching output. Emails that match no rule go to the `Unbekannt` fallback output. For example, an email containing both *"vielen dank für ihre bewerbung"* and *"leider"* is classified as `Absage`.

---

## Architecture

```text
 IMAP Email Trigger
         |
         v
    Edit Fields          (subject, from, text, searchText)
         |
         v
   Switch / Regex        (first matching rule wins)
         |
   +-----+------+--------+----------+-----------+
   |            |        |          |           |
   v            v        v          v           v
 Absage    Einladung   Zusage   Bewerbung   Unbekannt    (Set Status)
   |            |        |          |           |
   +-----+------+--------+----------+-----------+
         |
         v
       Merge             (5 inputs)
         |
         v
     PostgreSQL          (INSERT into bewerbungen)
         |
         v
      Telegram           (notification)
```

---

## How the Workflow Works

1. **Email Trigger (IMAP)** – The `n8n-nodes-base.emailReadImap` node polls the configured mailbox using the node's default options.

2. **Edit Fields** – A `Set` node extracts the relevant data:

   | Field        | Source                                      |
   |--------------|---------------------------------------------|
   | `subject`    | `$json.subject`                             |
   | `from`       | `$json.from`                                |
   | `text`       | `$json.textPlain`                           |
   | `searchText` | `(subject + ' ' + textPlain).toLowerCase()` |

   The sender address is **not** part of `searchText`; classification is based only on subject and body.

3. **Switch / Regex** – A `Switch` node tests `searchText` against one regex per category and routes the item to the first matching output, or to the `Unbekannt` fallback output.

4. **Set Status** – One `Set` node per category (`Absage`, `Einladung`, `Zusage`, `Bewerbung`, `Unbekannt`) adds a `status` field while keeping all other fields.

5. **Merge** – A `Merge` node with five inputs combines all branches into a single stream.

6. **PostgreSQL** – The `Insert rows in a table` node writes to `public.bewerbungen`:

   | Column      | Value                 |
   |-------------|-----------------------|
   | `sender`    | `{{ $json.from }}`    |
   | `subject`   | `{{ $json.subject }}` |
   | `mail_text` | `{{ $json.text }}`    |
   | `status`    | `{{ $json.status }}`  |

   `id`, `received_at` and `created_at` are filled by database defaults.

7. **Telegram** – The `Send a text message` node sends a notification built from the inserted row:

   ```text
   📩 Neue Bewerbungs-Mail  Status: <status>  Von: <sender>  Betreff: <subject>  Nachricht: <mail_text>
   ```

---

## Requirements

- A running [n8n](https://docs.n8n.io/hosting/) instance (self-hosted or n8n Cloud)
- A PostgreSQL database reachable from n8n
- An email account with IMAP access (many providers require an app password)
- A Telegram bot token (created via [@BotFather](https://t.me/BotFather)) and the target chat ID

---

## Project Structure

```text
n8n-job-application-mail-tracker/
├── database/
│   └── schema.sql                               # PostgreSQL table definition
├── workflow/
│   └── n8n-job-application-mail-tracker.json    # n8n workflow export (no credentials)
├── .env.example                                 # Placeholder reference for required settings
├── .gitignore
└── README.md
```

---

## Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/Badr-Emil/n8n-job-application-mail-tracker.git
   cd n8n-job-application-mail-tracker
   ```

2. Optionally copy the placeholder file to keep track of your own settings locally:

   ```bash
   cp .env.example .env
   ```

   > **Note:** The workflow does **not** read `.env` automatically. The file is only a checklist of the values you need when creating credentials in n8n. `.env` is excluded by `.gitignore` – never commit it.

3. Set up the database ([PostgreSQL Setup](#postgresql-setup)).
4. Import the workflow ([Importing the Workflow into n8n](#importing-the-workflow-into-n8n)).
5. Configure credentials ([Credential Configuration](#credential-configuration)) and Telegram ([Telegram Configuration](#telegram-configuration)).
6. Test the workflow ([Testing](#testing)), then activate it in n8n.

---

## PostgreSQL Setup

Example: create a dedicated database and user (adjust the names and use a strong password):

```sql
CREATE DATABASE bewerbungen_db;
CREATE USER n8n_bewerbungen WITH PASSWORD 'CHANGE_ME';
GRANT CONNECT ON DATABASE bewerbungen_db TO n8n_bewerbungen;
```

Create the table using the provided schema:

```bash
psql -h localhost -U postgres -d bewerbungen_db -f database/schema.sql
```

Grant only the permissions the workflow needs (insert rows and read back the inserted row):

```sql
\c bewerbungen_db
GRANT USAGE ON SCHEMA public TO n8n_bewerbungen;
GRANT SELECT, INSERT ON TABLE public.bewerbungen TO n8n_bewerbungen;
GRANT USAGE ON SEQUENCE public.bewerbungen_id_seq TO n8n_bewerbungen;
```

Table definition (`database/schema.sql`):

```sql
CREATE TABLE IF NOT EXISTS bewerbungen (
    id BIGSERIAL PRIMARY KEY,
    sender TEXT,
    subject TEXT,
    mail_text TEXT,
    status VARCHAR(30) NOT NULL,
    received_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

---

## Importing the Workflow into n8n

1. Open n8n and create a new workflow.
2. Open the workflow menu **⋯ → Import from File…** and select `workflow/n8n-job-application-mail-tracker.json`.
   Alternatively, copy the file content and paste it directly into the canvas.
3. The workflow is imported **inactive** and **without credentials**. Nodes that need credentials show a warning until you assign them.

---

## Credential Configuration

Create the following credentials in n8n (**Credentials → Add Credential**) and assign them to the corresponding nodes:

| Node                     | Credential type | Required values                                     |
|--------------------------|-----------------|-----------------------------------------------------|
| `Email Trigger (IMAP)`   | IMAP            | Host, port (usually `993`), user, password, SSL/TLS |
| `Insert rows in a table` | Postgres        | Host, port (`5432`), database, user, password       |
| `Send a text message`    | Telegram API    | Bot access token                                    |

After assigning the Postgres credential, open the `Insert rows in a table` node and verify that schema `public` and table `bewerbungen` are selected.

---

## Telegram Configuration

1. Open [@BotFather](https://t.me/BotFather) in Telegram, send `/newbot` and follow the steps. Copy the bot token into the n8n **Telegram API** credential.
2. Send any message to your new bot (or add the bot to a group).
3. Find your chat ID by opening the following URL in a browser (insert your token) and reading `message.chat.id`:

   ```text
   https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates
   ```

4. Open the `Send a text message` node and replace the placeholder `YOUR_TELEGRAM_CHAT_ID` in the **Chat ID** field with your chat ID.

---

## Testing

### Manual end-to-end test

1. In n8n, click **Test workflow**. The IMAP trigger waits for a new email.
2. Send an email to the monitored mailbox using one of the examples below.
3. Check the node outputs in n8n, the new row in PostgreSQL, and the Telegram message.

### Example emails

| Expected status | Subject                | Body                                                                                    |
|-----------------|------------------------|-----------------------------------------------------------------------------------------|
| `Absage`        | Ihre Bewerbung         | Leider müssen wir Ihnen mitteilen, dass wir uns für andere Bewerber entschieden haben. |
| `Einladung`     | Einladung zum Gespräch | Wir möchten Sie gerne zu einem Vorstellungsgespräch einladen.                           |
| `Zusage`        | Ihr Stellenangebot     | Wir freuen uns, Ihnen mitteilen zu können, dass wir Ihnen die Position anbieten.       |
| `Bewerbung`     | Eingangsbestätigung    | Vielen Dank für Ihre Bewerbung. Wir prüfen Ihre Unterlagen und melden uns.             |
| `Unbekannt`     | Newsletter             | Hier sind die aktuellen Neuigkeiten aus unserem Unternehmen.                            |

### Verify the database

```sql
-- Latest entries
SELECT id, sender, subject, status, created_at
FROM bewerbungen
ORDER BY created_at DESC
LIMIT 10;

-- Count per status
SELECT status, COUNT(*) AS total
FROM bewerbungen
GROUP BY status
ORDER BY total DESC;
```

---

## Known Limitations

- **First match wins** – Each email receives exactly one status, determined by rule order (see [Email Classification Categories](#email-classification-categories)).
- **Keyword-based** – Broad keywords such as `leider` or `interview` can cause false positives.
- **German only** – The regex rules target German phrasing; English emails usually end up as `Unbekannt`.
- **Plain-text body only** – Classification uses `textPlain`; HTML-only emails are effectively classified by subject only.
- **One Telegram message per execution** – The Telegram node has *Execute Once* enabled. If a single trigger run delivers several emails, only the first one is sent to Telegram (all of them are still stored in PostgreSQL).
- **Long messages** – The full email text is included in the Telegram message; Telegram limits messages to 4096 characters.
- **`received_at`** – Filled with the database insert time (`DEFAULT NOW()`), not the original email date.

---

## Security

- This repository contains **no real credentials, tokens, email addresses or chat IDs**.
- The workflow export contains **no credential references**, no pinned or execution data, and no instance-specific metadata.
- The Telegram chat ID is a placeholder (`YOUR_TELEGRAM_CHAT_ID`) that you must replace after import.
- All secrets live in the **n8n credential store**, which is encrypted with your instance's encryption key.
- `.env` and `.env.*` files are git-ignored; only `.env.example` with placeholder values is tracked.
- Use a dedicated PostgreSQL user with minimal privileges and an app-specific IMAP password where your provider supports it.
- Email content is personal data: the database and the Telegram chat will contain full email texts. Protect them accordingly.
- **Before exporting and committing a modified workflow**, check that it contains no pinned data, real chat IDs or other personal information.

---

## Future Improvements

- Use the original email date for `received_at`
- Truncate or summarize the email text in Telegram notifications
- Send a Telegram notification for every email instead of once per execution
- Add English-language classification rules
- Prevent duplicate entries (e.g. store and check the email `Message-ID`)
- Extract the company name and job title
- Add error handling / an error workflow for failed database or Telegram calls
- Optional AI-based classification as a fallback for `Unbekannt`
- Dashboard or reporting on application statistics

---

## Author

**Badr-Emil** – [GitHub](https://github.com/Badr-Emil)
