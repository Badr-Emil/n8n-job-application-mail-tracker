# n8n Job Application Mail Tracker

**Hybrid rule-based + AI job application email classification** with [n8n](https://n8n.io/).

The workflow reads incoming emails via IMAP, classifies them, stores the result in PostgreSQL, and sends a notification to Telegram. Classification is hybrid:

1. **Regular expressions classify clear cases first.** This is the primary classifier.
2. **Only emails that no regex rule matches are sent to OpenAI** as a fallback.
3. The AI result is **validated**; any invalid response falls back to `Unknown`.

Because most emails are handled by the free, deterministic regex rules, API usage and cost stay low.

The regex rules are written for **German-language** application emails; everything else (status values, database, notifications) is in English.

**Version:** v0.4.0

---

## Table of Contents

- [Features](#features)
- [Email Classification Categories](#email-classification-categories)
- [AI Fallback Classification](#ai-fallback-classification)
- [Architecture](#architecture)
- [How the Workflow Works](#how-the-workflow-works)
- [Requirements](#requirements)
- [Project Structure](#project-structure)
- [Installation](#installation)
- [PostgreSQL Setup](#postgresql-setup)
- [Importing the Workflow into n8n](#importing-the-workflow-into-n8n)
- [Credential Configuration](#credential-configuration)
- [Telegram Configuration](#telegram-configuration)
- [OpenAI Configuration](#openai-configuration)
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
- **Rule-based classification** – n8n `Switch` node with regex rules as the primary classifier
- **AI fallback** – only emails that no regex rule matches are classified by OpenAI
- **Validated AI output** – only the five allowed status values are accepted; anything else becomes `Unknown`
- **Fail-safe** – OpenAI errors or malformed responses do not stop the workflow
- **Five status categories** – `Application`, `Invitation`, `Offer`, `Rejection`, `Unknown`
- **PostgreSQL persistence** – every classified email is stored in the `job_applications` table
- **Telegram notification** – sends a message with the final status, sender, subject and text

---

## Email Classification Categories

| Workflow Status | Meaning                                | Example trigger phrases (German)                                                 |
|-----------------|----------------------------------------|----------------------------------------------------------------------------------|
| `Rejection`        | Rejection                              | `leider`, `absage`, `andere bewerber`, `anders entschieden`                      |
| `Invitation`     | Interview invitation                   | `vorstellungsgespräch`, `interview`, `telefoninterview`, `termin vereinbaren`    |
| `Offer`        | Positive response or job offer         | `zusage`, `stellenangebot`, `arbeitsvertrag`, `willkommen im team`               |
| `Application`     | Application received or under review   | `bewerbung eingegangen`, `vielen dank für ihre bewerbung`, `unterlagen erhalten` |
| `Unknown`     | Unknown or unclassified                | *(fallback output, sent to the AI classifier)*                                   |

The status values are the exact strings written by the `Set` nodes and stored in the `status` column of the `job_applications` table. The [AI fallback](#ai-fallback-classification) returns the same values, so every classification, regex or AI, ends up as exactly one of `Application`, `Invitation`, `Offer`, `Rejection` or `Unknown`.

The full regular expressions are defined in the `Switch` node of the workflow.

**Rule order matters.** The `Switch` node evaluates the rules in the order listed above (`Rejection` → `Invitation` → `Offer` → `Application`) and routes each email to the **first** matching output. Emails that match no rule go to the `Unknown` fallback output and are then classified by the [AI fallback](#ai-fallback-classification). For example, an email containing both *"vielen dank für ihre bewerbung"* and *"leider"* is classified as `Rejection`.

---

## AI Fallback Classification

The AI is **only a fallback**. It never overrides a regex match, and emails that were already classified by regex are never sent to OpenAI.

| Status      | Definition used in the AI prompt                                                                                       |
|-------------|------------------------------------------------------------------------------------------------------------------------|
| `Application` | The employer confirms that the application was received or is currently being reviewed.                               |
| `Invitation` | The applicant is invited to an interview, phone interview, video interview, meeting or similar recruiting conversation. |
| `Offer`    | The applicant receives a job offer, employment offer, contract offer or clearly positive hiring decision.             |
| `Rejection`    | The employer rejects the application or states that they continue with other candidates.                              |
| `Unknown` | The email cannot be classified reliably or is not related to a job application.                                       |

**How it works:**

- **Node:** the official n8n OpenAI node (`@n8n/n8n-nodes-langchain.openAi`, version 2.3, *Message a Model*), which uses the OpenAI Responses API.
- **Input:** the email subject and the plain-text body, truncated to the first 4,000 characters to limit cost.
- **Prompt:** written in English. It lists the five definitions above, tells the model not to invent information, and treats the email content as untrusted data.
- **Fixed output values:** the model must answer with one of the five status values. The JSON schema and the validation node enforce this.
- **Deterministic settings:** temperature `0`, at most 50 output tokens, and a JSON schema output format that restricts `status` to the five allowed values. `store` is disabled so OpenAI does not keep the response for later retrieval.
- **Expected output:** `{"status": "Rejection"}` (or one of the other allowed values).
- **Default model:** `gpt-4.1-mini`. You can change it in the `OpenAI Classifier` node. If you select a model that does not support the `temperature` parameter, remove that option.

**Validation** (`Validate AI Result` Code node):

- Accepts only the exact values `Application`, `Invitation`, `Offer`, `Rejection` and `Unknown`.
- Falls back to `Unknown` if the response is missing, is not valid JSON, has no `status`, or contains any other value.
- The OpenAI node is set to **continue on error** (with one retry), so an API error, timeout or quota problem produces `Unknown` instead of stopping the workflow.
- Restores the original email fields (`from`, `subject`, `text`) so PostgreSQL and Telegram receive the same data as for regex matches.

**Internal field `classificationSource`:** each item carries `regex` or `ai` inside the workflow, which is useful when inspecting executions in n8n. It is **not** stored in the database, and the schema is unchanged.

AI classification is not perfectly accurate. It reduces the number of `Unknown` results, but individual emails can still be misclassified.

---

## Architecture

```text
    IMAP Email Trigger
            |
            v
       Edit Fields              (subject, from, text, searchText)
            |
            v
     Switch / Regex             (first matching rule wins)
       |          |
    matched     unknown
       |          |
       |          v
       |     Unknown            (Set Status, default)
       |          |
       |          v
       |     OpenAI Classifier  (fallback only)
       |          |
       |          v
       |     Validate AI Result (invalid -> Unknown)
       |          |
       +----------+
            |
            v
          Merge                 (5 inputs)
            |
            v
       PostgreSQL               (INSERT into job_applications)
            |
            v
        Telegram                (notification)
```

The `matched` path consists of the four regex routes `Rejection`, `Invitation`, `Offer` and `Application`, each with its own Set Status node.

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

3. **Switch / Regex** – A `Switch` node tests `searchText` against one regex per category and routes the item to the first matching output, or to the `Unknown` fallback output.

4. **Set Status** – One `Set` node per category (`Rejection`, `Invitation`, `Offer`, `Application`, `Unknown`) adds a `status` field while keeping all other fields. The four regex routes also set `classificationSource = regex`.

5. **AI fallback** – Only items from the `Unknown` route continue to the `OpenAI Classifier` node. The `Validate AI Result` Code node checks the response, sets the final `status` and `classificationSource = ai`, and restores the original email fields. See [AI Fallback Classification](#ai-fallback-classification).

6. **Merge** – A `Merge` node with five inputs combines the four regex branches and the validated AI branch into a single stream.

7. **PostgreSQL** – The `Insert rows in a table` node writes to `public.job_applications`:

   | Column      | Value                 |
   |-------------|-----------------------|
   | `sender`    | `{{ $json.from }}`    |
   | `subject`   | `{{ $json.subject }}` |
   | `mail_text` | `{{ $json.text }}`    |
   | `status`    | `{{ $json.status }}`  |

   `id`, `received_at` and `created_at` are filled by database defaults.

8. **Telegram** – The `Send a text message` node sends a notification built from the inserted row. It shows the final status, regardless of whether it came from regex or the AI fallback. No prompts or raw AI output are included:

   ```text
   📩 New job application email  Status: <status>  From: <sender>  Subject: <subject>  Message: <mail_text>
   ```

---

## Requirements

- A running [n8n](https://docs.n8n.io/hosting/) instance (self-hosted or n8n Cloud)
- A PostgreSQL database reachable from n8n
- An email account with IMAP access (many providers require an app password)
- A Telegram bot token (created via [@BotFather](https://t.me/BotFather)) and the target chat ID
- An OpenAI API key ([platform.openai.com](https://platform.openai.com/api-keys)) for the AI fallback
- n8n with the OpenAI node version 2.3 (developed against n8n 2.39)

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
5. Configure credentials ([Credential Configuration](#credential-configuration)), Telegram ([Telegram Configuration](#telegram-configuration)) and OpenAI ([OpenAI Configuration](#openai-configuration)).
6. Test the workflow ([Testing](#testing)), then activate it in n8n.

---

## PostgreSQL Setup

Example: create a dedicated database and user (adjust the names and use a strong password):

```sql
CREATE DATABASE job_applications_db;
CREATE USER n8n_job_tracker WITH PASSWORD 'CHANGE_ME';
GRANT CONNECT ON DATABASE job_applications_db TO n8n_job_tracker;
```

Create the table using the provided schema:

```bash
psql -h localhost -U postgres -d job_applications_db -f database/schema.sql
```

Grant only the permissions the workflow needs (insert rows and read back the inserted row):

```sql
\c job_applications_db
GRANT USAGE ON SCHEMA public TO n8n_job_tracker;
GRANT SELECT, INSERT ON TABLE public.job_applications TO n8n_job_tracker;
GRANT USAGE ON SEQUENCE public.job_applications_id_seq TO n8n_job_tracker;
```

Table definition (`database/schema.sql`):

```sql
CREATE TABLE IF NOT EXISTS job_applications (
    id BIGSERIAL PRIMARY KEY,
    sender TEXT,
    subject TEXT,
    mail_text TEXT,
    status VARCHAR(30) NOT NULL,
    received_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```


### Upgrading from v0.3.x

v0.4.0 renamed the table and the status values to English. Migrate an existing database before importing the new workflow:

```sql
ALTER TABLE bewerbungen RENAME TO job_applications;
ALTER SEQUENCE bewerbungen_id_seq RENAME TO job_applications_id_seq;
UPDATE job_applications SET status = CASE status
    WHEN 'Bewerbung' THEN 'Application'
    WHEN 'Einladung' THEN 'Invitation'
    WHEN 'Zusage'    THEN 'Offer'
    WHEN 'Absage'    THEN 'Rejection'
    WHEN 'Unbekannt' THEN 'Unknown'
    ELSE status END;
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
| `OpenAI Classifier`      | OpenAI          | API key                                             |

After assigning the Postgres credential, open the `Insert rows in a table` node and verify that schema `public` and table `job_applications` are selected.

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

## OpenAI Configuration

1. Create an API key at [platform.openai.com](https://platform.openai.com/api-keys).
2. In n8n, open the `OpenAI Classifier` node and create a new **OpenAI** credential with this key (or select an existing one).
3. Optionally change the model in the node (default: `gpt-4.1-mini`).

After import, the node shows a missing-credential warning until you do this. **No OpenAI API key or credential reference is stored in this repository**; the key lives only in the n8n credential store.

To disable the AI fallback, open `Unknown` in n8n and connect it directly to input 5 of the `Merge` node instead of to `OpenAI Classifier`.

---

## Testing

### Manual end-to-end test

1. In n8n, click **Test workflow**. The IMAP trigger waits for a new email.
2. Send an email to the monitored mailbox using one of the examples below.
3. Check the node outputs in n8n, the new row in PostgreSQL, and the Telegram message.

### Example emails

| Expected status | Subject                | Body                                                                                    |
|-----------------|------------------------|-----------------------------------------------------------------------------------------|
| `Rejection`        | Ihre Bewerbung         | Leider müssen wir Ihnen mitteilen, dass wir uns für andere Bewerber entschieden haben. |
| `Invitation`     | Einladung zum Gespräch | Wir möchten Sie gerne zu einem Vorstellungsgespräch einladen.                           |
| `Offer`        | Ihr Stellenangebot     | Wir freuen uns, Ihnen mitteilen zu können, dass wir Ihnen die Position anbieten.       |
| `Application`     | Eingangsbestätigung    | Vielen Dank für Ihre Bewerbung. Wir prüfen Ihre Unterlagen und melden uns.             |
| `Rejection` (AI)   | Ihre Bewerbung         | Nach sorgfältiger Prüfung Ihrer Unterlagen haben wir entschieden, den Auswahlprozess mit anderen Kandidaten fortzuführen. |
| `Unknown`     | Newsletter             | Hier sind die aktuellen Neuigkeiten aus unserem Unternehmen.                            |

The `Rejection (AI)` example matches none of the regex rules, so it is routed to the AI fallback. The newsletter also reaches the AI and is expected to stay `Unknown`. In the n8n execution view, the `classificationSource` field shows which classifier handled an email.

### Verify the database

```sql
-- Latest entries
SELECT id, sender, subject, status, created_at
FROM job_applications
ORDER BY created_at DESC
LIMIT 10;

-- Count per status
SELECT status, COUNT(*) AS total
FROM job_applications
GROUP BY status
ORDER BY total DESC;
```

---

## Known Limitations

- **First match wins** – Each email receives exactly one status, determined by rule order (see [Email Classification Categories](#email-classification-categories)).
- **Keyword-based** – Broad keywords such as `leider` or `interview` can cause false positives. Regex matches are never re-checked by the AI.
- **German regex rules** – The regex rules target German phrasing. Other emails are handled by the AI fallback.
- **AI is not perfectly accurate** – The AI can misclassify ambiguous emails. Invalid responses and API errors are stored as `Unknown`, which is indistinguishable from a genuinely unknown email in the database.
- **AI cost and availability** – Every email that reaches `Unknown` causes one OpenAI API request (plus one retry on failure).
- **Email text is truncated for the AI** – Only the first 4,000 characters of the body are sent to OpenAI.
- **Prompt injection** – Email content is untrusted. The prompt, the JSON schema and the validation restrict the result to the five allowed values, but a crafted email could still influence its own classification.
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
- The workflow export contains **no OpenAI API key and no OpenAI credential reference**. You create the credential manually in n8n.
- Email content is personal data: the database and the Telegram chat will contain full email texts. Protect them accordingly.
- Emails that no regex rule matches are **sent to OpenAI** (subject and up to 4,000 characters of the body). Check that this is acceptable for your data before enabling the workflow. The node sets `store: false`; see OpenAI's data usage policies for API retention details.
- **Before exporting and committing a modified workflow**, check that it contains no pinned data, real chat IDs or other personal information.

---

## Future Improvements

- Use the original email date for `received_at`
- Truncate or summarize the email text in Telegram notifications
- Send a Telegram notification for every email instead of once per execution
- Add English-language regex rules to reduce AI usage further
- Prevent duplicate entries (e.g. store and check the email `Message-ID`)
- Extract the company name and job title
- Add error handling / an error workflow for failed database or Telegram calls
- Optionally store `classificationSource` in the database for reporting
- Dashboard or reporting on application statistics

---

## Author

**Badr-Emil** – [GitHub](https://github.com/Badr-Emil)
