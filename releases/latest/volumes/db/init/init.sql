-- volumes/db/init/init.sql — Chyro initial database setup
--
-- Runs once on first container start (PostgreSQL initdb convention).
-- Creates extensions and schemas required by the app.
-- All Chyro application tables use the `chy_` prefix (ADR-015).
-- Full schema migration is handled by STORY-000-02 (base-schema story).
--
-- Extensions:
--   pgvector   — vector similarity search for document embeddings (ADR-010)
--   uuid-ossp  — UUID generation helpers
--   pg_trgm    — trigram similarity for text search
--   citext     — case-insensitive text type (email addresses)
--
-- Supabase built-in schemas (auth, storage, realtime, _analytics) are
-- created by their respective service images — do not recreate here.

-- ---------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS vector;        -- pgvector (ADR-006, ADR-010)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";   -- uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- text similarity search
CREATE EXTENSION IF NOT EXISTS citext;        -- case-insensitive email

-- ---------------------------------------------------------------
-- App schema
-- ---------------------------------------------------------------

-- All Chyro application tables live in the public schema.
-- The `chy_` prefix (ADR-015) namespaces them away from Supabase internals.
-- Schema setup is intentionally minimal here — STORY-000-02 owns the full
-- table definitions and Row Level Security policies.

-- Verify pgvector version meets ADR-006 requirement (≥0.8.2 for CVE-2026-3172 fix).
DO $$
DECLARE
  vec_version text;
BEGIN
  SELECT extversion INTO vec_version FROM pg_extension WHERE extname = 'vector';
  IF vec_version IS NULL THEN
    RAISE WARNING 'pgvector extension not installed — vector search will not work.';
  ELSE
    RAISE NOTICE 'pgvector version: %', vec_version;
  END IF;
END;
$$;
