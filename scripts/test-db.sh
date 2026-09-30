#!/usr/bin/env bash
# Veritabanı testleri: boş bir veritabanı oluşturur, Supabase taklidini + migrationları
# uygular ve supabase/tests/*.test.sql dosyalarını çalıştırır.
# Gerekli: PostgreSQL 15+ istemci/sunucu. Bağlantı: PGHOST/PGPORT/PGUSER (varsayılan postgres).
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${TEST_DB:-alkasu_test}"
PSQL=(psql -v ON_ERROR_STOP=1 -q -X -t -A)

dropdb --if-exists "$DB" >/dev/null 2>&1 || true
createdb "$DB"
"${PSQL[@]}" -d "$DB" -f supabase/tests/_supabase_stub.sql >/dev/null
for f in supabase/migrations/*.sql; do
  "${PSQL[@]}" -d "$DB" -f "$f" >/dev/null || { echo "MIGRATION HATASI: $f"; exit 1; }
done
"${PSQL[@]}" -d "$DB" -f supabase/tests/_helpers.sql >/dev/null

fail=0; total=0
for t in supabase/tests/*.test.sql; do
  [ -f "$t" ] || continue
  total=$((total+1))
  if out=$("${PSQL[@]}" -d "$DB" -f "$t" 2>&1); then
    echo "✓ $(basename "$t")  $(echo "$out" | grep -c "NOTICE:  ok -" || true) kontrol"
  else
    fail=$((fail+1)); echo "✗ $(basename "$t")"; echo "$out" | sed 's/^/    /' | tail -20
  fi
done
echo "----"; echo "$((total-fail))/$total test dosyası başarılı"
[ "$fail" -eq 0 ]
