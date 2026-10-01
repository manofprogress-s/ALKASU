#!/usr/bin/env bash
# Her migration ayrı işlemde (enum değeri eklendikten sonra kullanılabilmesi için commit gerekir).
# Tüm migrationları tek bir SQL Editor kurulum dosyasında birleştirir: supabase/kurulum.sql
set -euo pipefail
cd "$(dirname "$0")/.."
{
  echo "-- ALKASU veritabanı kurulumu (tüm migrationlar, sırayla). Supabase SQL Editor'de bir kez çalıştırın."
  echo "begin;"
  for f in supabase/migrations/*.sql; do echo; echo "-- ===== $(basename "$f") ====="; cat "$f"; echo; echo "commit;"; echo "begin;"; done
  echo
  echo "create schema if not exists supabase_migrations;"
  echo "create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);"
  for f in supabase/migrations/*.sql; do b=$(basename "$f" .sql); echo "insert into supabase_migrations.schema_migrations(version, name) values ('${b%%_*}', '${b#*_}') on conflict do nothing;"; done
  echo "commit;"
} > supabase/kurulum.sql
echo "supabase/kurulum.sql üretildi"
