CREATE TABLE IF NOT EXISTS bewerbungen (
    id BIGSERIAL PRIMARY KEY,
    sender TEXT,
    subject TEXT,
    mail_text TEXT,
    status VARCHAR(30) NOT NULL,
    received_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
