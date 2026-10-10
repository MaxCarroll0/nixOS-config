PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS person (
  id            INTEGER PRIMARY KEY,
  name          TEXT NOT NULL,
  sort_name     TEXT,
  born          TEXT,
  died          TEXT,
  gnd_id        TEXT UNIQUE,
  mb_id         TEXT UNIQUE,
  openopus_id   TEXT UNIQUE,
  created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS person_name ON person (name);

CREATE TABLE IF NOT EXISTS work (
  id              INTEGER PRIMARY KEY,
  person_id       INTEGER REFERENCES person (id) ON DELETE SET NULL,
  title           TEXT NOT NULL,
  uniform_title   TEXT,
  catalogue_label TEXT,
  genre           TEXT,
  music_key       TEXT,
  instrumentation TEXT,
  gnd_work_id     TEXT UNIQUE,
  mb_work_id      TEXT UNIQUE,
  created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS work_person ON work (person_id);

CREATE TABLE IF NOT EXISTS movement (
  id         INTEGER PRIMARY KEY,
  work_id    INTEGER NOT NULL REFERENCES work (id) ON DELETE CASCADE,
  ordinal    INTEGER NOT NULL,
  title      TEXT NOT NULL,
  tempo      TEXT,
  music_key  TEXT,
  UNIQUE (work_id, ordinal)
);

CREATE TABLE IF NOT EXISTS edition (
  id                INTEGER PRIMARY KEY,
  publisher         TEXT,
  cat_no_raw        TEXT,
  cat_no_norm       TEXT,
  ismn              TEXT,
  isbn13            TEXT,
  title             TEXT NOT NULL,
  title_en          TEXT,
  edition_statement TEXT,
  series            TEXT,
  year              INTEGER,
  pages             INTEGER,
  extent            TEXT,
  binding           TEXT,
  person_id         INTEGER REFERENCES person (id) ON DELETE SET NULL,
  uniform_title     TEXT,
  catalogue_label   TEXT,
  music_key         TEXT,
  instrumentation   TEXT,
  gnd_work_id       TEXT,
  kind              TEXT NOT NULL DEFAULT 'score',
  resolved_from     TEXT NOT NULL DEFAULT 'manual',
  source_ref        TEXT,
  created_at        TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS edition_catno ON edition (cat_no_norm) WHERE cat_no_norm IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS edition_ismn ON edition (ismn) WHERE ismn IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS edition_isbn ON edition (isbn13) WHERE isbn13 IS NOT NULL;

CREATE TABLE IF NOT EXISTS edition_content (
  id         INTEGER PRIMARY KEY,
  edition_id INTEGER NOT NULL REFERENCES edition (id) ON DELETE CASCADE,
  work_id    INTEGER REFERENCES work (id) ON DELETE SET NULL,
  ordinal    INTEGER NOT NULL,
  label      TEXT NOT NULL,
  page_from  INTEGER,
  UNIQUE (edition_id, ordinal)
);

CREATE TABLE IF NOT EXISTS copy (
  id          INTEGER PRIMARY KEY,
  edition_id  INTEGER NOT NULL REFERENCES edition (id) ON DELETE CASCADE,
  cover_type  TEXT NOT NULL DEFAULT 'soft',
  condition   TEXT NOT NULL DEFAULT 'good',
  acquired_on TEXT,
  price_paid  REAL,
  currency    TEXT NOT NULL DEFAULT 'GBP',
  shelf       TEXT,
  notes       TEXT,
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS copy_edition ON copy (edition_id);

CREATE TABLE IF NOT EXISTS category (
  id        INTEGER PRIMARY KEY,
  name      TEXT NOT NULL UNIQUE,
  parent_id INTEGER REFERENCES category (id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS edition_category (
  edition_id  INTEGER NOT NULL REFERENCES edition (id) ON DELETE CASCADE,
  category_id INTEGER NOT NULL REFERENCES category (id) ON DELETE CASCADE,
  PRIMARY KEY (edition_id, category_id)
);

CREATE TABLE IF NOT EXISTS price_new (
  id          INTEGER PRIMARY KEY,
  edition_id  INTEGER NOT NULL REFERENCES edition (id) ON DELETE CASCADE,
  price       REAL NOT NULL,
  currency    TEXT NOT NULL,
  source      TEXT NOT NULL,
  url         TEXT,
  observed_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS price_new_edition ON price_new (edition_id, observed_at DESC);

CREATE TABLE IF NOT EXISTS comp (
  id          INTEGER PRIMARY KEY,
  edition_id  INTEGER NOT NULL REFERENCES edition (id) ON DELETE CASCADE,
  source      TEXT NOT NULL,
  condition   TEXT,
  price       REAL NOT NULL,
  shipping    REAL,
  currency    TEXT NOT NULL,
  is_sold     INTEGER NOT NULL DEFAULT 0,
  url         TEXT,
  external_id TEXT,
  observed_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (source, external_id)
);
CREATE INDEX IF NOT EXISTS comp_edition ON comp (edition_id, observed_at DESC);

CREATE TABLE IF NOT EXISTS valuation (
  id           INTEGER PRIMARY KEY,
  copy_id      INTEGER NOT NULL REFERENCES copy (id) ON DELETE CASCADE,
  as_of        TEXT NOT NULL DEFAULT (datetime('now')),
  cost_basis   REAL,
  cost_method  TEXT,
  market_value REAL,
  market_lo    REAL,
  market_hi    REAL,
  method       TEXT NOT NULL,
  n_comps      INTEGER NOT NULL DEFAULT 0,
  currency     TEXT NOT NULL DEFAULT 'GBP'
);
CREATE INDEX IF NOT EXISTS valuation_copy ON valuation (copy_id, as_of DESC);

CREATE TABLE IF NOT EXISTS model_fit (
  id            INTEGER PRIMARY KEY,
  fitted_at     TEXT NOT NULL DEFAULT (datetime('now')),
  n_obs         INTEGER NOT NULL,
  sigma         REAL NOT NULL,
  r_squared     REAL,
  coefficients  TEXT NOT NULL,
  is_seed       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS provider_health (
  name        TEXT PRIMARY KEY,
  ok          INTEGER NOT NULL DEFAULT 1,
  last_ok_at  TEXT,
  last_err_at TEXT,
  last_error  TEXT,
  calls       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS publisher_key (
  kind      TEXT NOT NULL,
  key       TEXT NOT NULL,
  stem      TEXT NOT NULL,
  publisher TEXT NOT NULL,
  seen      INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (kind, key, stem)
);
CREATE INDEX IF NOT EXISTS publisher_key_stem ON publisher_key (stem, seen DESC);

CREATE TABLE IF NOT EXISTS http_cache (
  url         TEXT PRIMARY KEY,
  body        BLOB NOT NULL,
  status      INTEGER NOT NULL,
  fetched_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5 (
  kind UNINDEXED,
  ref_id UNINDEXED,
  edition_id UNINDEXED,
  text,
  tokenize = 'unicode61 remove_diacritics 2'
);
