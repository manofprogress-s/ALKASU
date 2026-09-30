# Yedekleme ve geri yükleme

## Yedekler
1. **Supabase otomatik yedeği** — Pro planda günlük (7 gün); ücretsiz planda yoktur.
2. **Bağımsız günlük yedek** (T-019) — `.github/workflows/backup.yml` her gece 03:15'te (İstanbul) `pg_dump` alır,
   **age** ile şifreler ve GitHub Actions artifact'ı olarak **30 gün** saklar. Şifresiz yedek hiçbir yere yazılmaz.

### Kurulum (bir kez)
```bash
age-keygen -o alkasu-yedek-anahtari.txt      # ÖZEL anahtar: güvenli bir yerde (şifre yöneticisi + çevrimdışı kopya) saklayın
grep 'public key' alkasu-yedek-anahtari.txt  # "age1..." ile başlayan AÇIK anahtar
```
GitHub → Settings → Environments → **production** secrets:
- `SUPABASE_DB_URL` — Supabase bağlantı adresi
- `BACKUP_AGE_RECIPIENT` — yukarıdaki açık anahtar (`age1...`)

Özel anahtar kaybolursa yedekler açılamaz.

## Geri yükleme
1. GitHub → Actions → "Günlük yedek" → ilgili çalıştırma → artifact'ı indirin.
2. Şifreyi çözün: `age -d -i alkasu-yedek-anahtari.txt -o alkasu.dump alkasu_YYYY-MM-DD_HHMM.dump.age`
3. **Önce boş bir Supabase projesine** (veya yerel PostgreSQL'e) geri yükleyip kontrol edin:
   ```bash
   supabase db push --db-url "$HEDEF_DB_URL" --include-all          # şema
   pg_restore --data-only --no-owner --disable-triggers -d "$HEDEF_DB_URL" \
     --schema=public --schema=audit alkasu.dump
   ```
   `auth` şeması (kullanıcılar) gerekiyorsa ayrıca `--schema=auth` ile geri yüklenir.
4. Kontrol: uygulamada ürün, stok ve veresiye bakiyelerini karşılaştırın; SQL'de
   `select * from public.stock_consistency_check('<işletme-id>');` boş dönmelidir.
5. Doğrulandıktan sonra Vercel ortam değişkenlerini yeni projeye çevirin.

## Tatbikat
Her ay bir yedeği boş bir projeye geri yükleyip 4. adımdaki kontrolleri yapın ve tarihi buraya not edin.

| Tarih | Yedek | Sonuç | Yapan |
|---|---|---|---|
