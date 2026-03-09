#!/bin/bash

# Initialize schema and seed data for the notes app (PostgreSQL).
# - Idempotent: safe to run multiple times.
# - Aligns with existing startup/restore workflow by being invoked from startup.sh
#   (fresh start) and restore_db.sh (after restore completes).
#
# IMPORTANT:
# - Uses db_connection.txt as the authoritative connection source.
# - Executes SQL statements one-at-a-time (per container rules).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [ ! -f "db_connection.txt" ]; then
  echo "⚠ db_connection.txt not found; cannot initialize schema."
  echo "  Run startup.sh first to generate db_connection.txt."
  exit 1
fi

PSQL_CMD="$(cat db_connection.txt)"

run_sql () {
  local sql="$1"
  # Run statements one at a time, stop on error.
  ${PSQL_CMD} -v ON_ERROR_STOP=1 -c "$sql"
}

echo "Initializing notes app schema..."

# Extensions (optional but useful)
run_sql "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# notes table
run_sql "CREATE TABLE IF NOT EXISTS notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  is_pinned BOOLEAN NOT NULL DEFAULT FALSE,
  is_favorite BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

# tags table
run_sql "CREATE TABLE IF NOT EXISTS tags (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

# note_tags join table
run_sql "CREATE TABLE IF NOT EXISTS note_tags (
  note_id UUID NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  tag_id UUID NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (note_id, tag_id)
);"

# Helpful indexes for search/filtering
run_sql "CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes(updated_at DESC);"
run_sql "CREATE INDEX IF NOT EXISTS idx_notes_is_pinned ON notes(is_pinned);"
run_sql "CREATE INDEX IF NOT EXISTS idx_notes_is_favorite ON notes(is_favorite);"
run_sql "CREATE INDEX IF NOT EXISTS idx_note_tags_tag_id ON note_tags(tag_id);"

# Trigger to auto-update updated_at
run_sql "CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;"

run_sql "DROP TRIGGER IF EXISTS trg_notes_set_updated_at ON notes;"
run_sql "CREATE TRIGGER trg_notes_set_updated_at
BEFORE UPDATE ON notes
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();"

echo "Schema ensured."

echo "Seeding minimal data (only if empty)..."

# Seed tags (no-op if already present)
run_sql "INSERT INTO tags (name)
SELECT 'welcome'
WHERE NOT EXISTS (SELECT 1 FROM tags WHERE name='welcome');"

run_sql "INSERT INTO tags (name)
SELECT 'ideas'
WHERE NOT EXISTS (SELECT 1 FROM tags WHERE name='ideas');"

run_sql "INSERT INTO tags (name)
SELECT 'todo'
WHERE NOT EXISTS (SELECT 1 FROM tags WHERE name='todo');"

# Seed a couple notes only if notes table is empty
run_sql "INSERT INTO notes (title, content, is_pinned, is_favorite)
SELECT
  'Welcome to NoteMaster',
  'This is your first note. You can edit, tag, favorite, and pin notes.',
  TRUE,
  TRUE
WHERE NOT EXISTS (SELECT 1 FROM notes);"

run_sql "INSERT INTO notes (title, content, is_pinned, is_favorite)
SELECT
  'Quick Tips',
  'Try adding tags like #ideas or #todo, and use search to find notes quickly.',
  FALSE,
  FALSE
WHERE (SELECT COUNT(*) FROM notes) = 1;"

# Associate seeded notes to tags (idempotent via PK constraint and WHERE NOT EXISTS)
run_sql "INSERT INTO note_tags (note_id, tag_id)
SELECT n.id, t.id
FROM notes n
JOIN tags t ON t.name = 'welcome'
WHERE n.title = 'Welcome to NoteMaster'
AND NOT EXISTS (
  SELECT 1 FROM note_tags nt WHERE nt.note_id = n.id AND nt.tag_id = t.id
);"

run_sql "INSERT INTO note_tags (note_id, tag_id)
SELECT n.id, t.id
FROM notes n
JOIN tags t ON t.name = 'ideas'
WHERE n.title = 'Quick Tips'
AND NOT EXISTS (
  SELECT 1 FROM note_tags nt WHERE nt.note_id = n.id AND nt.tag_id = t.id
);"

echo "✓ Notes app initialization complete."
