# Kurulum ve yayın

ALKASU üç hizmet kullanır: **Supabase** (veritabanı + giriş), **GitHub** (kod + otomatik test + yedek), **Vercel** (yayın).

## 1. Supabase projesi (demo ve canlı için ayrı ayrı)
1. supabase.com → New project. Bölge: **Frankfurt (eu-central-1)**. Güçlü bir veritabanı şifresi belirleyin ve saklayın.
2. **Authentication → Sign In / Providers → Email**: "Allow new users to sign up" **kapalı** (kullanıcıları yalnızca yönetici davet eder).
3. **Authentication → URL Configuration**: Site URL = Vercel adresi (ör. `https://alkasu.vercel.app`); Redirect URLs'e `https://alkasu.vercel.app/auth/callback` ekleyin.
4. **Project Settings → API**: `Project URL`, `anon public` ve `service_role` anahtarlarını not edin.
5. **Project Settings → Database → Connection string (URI, Session pooler)**: `SUPABASE_DB_URL` olarak kullanılacak.

## 2. Migrationlar
GitHub'da `main` dalına her gönderimde CI testleri geçerse `migrate` işi migrationları otomatik uygular (`supabase db push`).
Bunun için GitHub → Settings → Environments → **production** ortamında secret: `SUPABASE_DB_URL`.

Elle uygulamak için: `supabase db push --db-url "$SUPABASE_DB_URL" --include-all`

## 3. İlk işletme ve yönetici
Supabase → Authentication → Users → **Add user** (e-posta + şifre, "Auto confirm"). Kullanıcının `id` değerini kopyalayın. SQL Editor'de:
```sql
select public.create_business('Alay Ticaret', '<kullanıcı-id>', 'Ad Soyad');
```
Diğer kullanıcıları uygulamada **Ayarlar → Davet et** ile ekleyin.

## 4. Vercel
1. vercel.com → Add New → Project → GitHub deposunu seçin. Framework: Next.js (otomatik).
2. Environment Variables:
   | Ad | Değer |
   |---|---|
   | `NEXT_PUBLIC_SUPABASE_URL` | Supabase Project URL |
   | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | anon public anahtarı |
   | `SUPABASE_SERVICE_ROLE_KEY` | service_role anahtarı (**yalnızca Vercel'e**, asla koda/sohbete değil). Ayarlar → Kullanıcılar ekranında kullanıcı oluşturmak ve geçici şifre vermek için gerekir. Ekledikten sonra Vercel'de **Redeploy** yapın. |
   | `NEXT_PUBLIC_SITE_URL` | `https://<proje>.vercel.app` |
3. Node.js sürümü: Settings → General → Node.js Version = **24.x**.
4. Preview ortamı demo Supabase projesine, Production ortamı canlı projeye bağlanır (Vercel'de ortam bazında değişken tanımlanır).

## 5. Demo verisi
Yerelde `.env.local` demo projesinin değerleriyle doluyken: `DEMO_PASSWORD='en-az-10-karakter' npm run seed:demo`

## 6. Yerel geliştirme
```bash
nvm use            # Node 24
npm install
cp .env.example .env.local   # değerleri doldurun
npm run dev
```
Veritabanı testleri yerel PostgreSQL 15+ ile: `PGHOST=... PGUSER=... npm run test:db`

## Ek: SQL Editor ile kurulum (CLI erişimi yoksa)
`supabase/kurulum.sql` tüm migrationları tek işlemde uygular ve `supabase_migrations.schema_migrations` tablosuna kaydeder;
böylece sonraki migrationlar CLI/CI ile (`supabase db push`) kaldığı yerden devam eder. Dosya şu komutla yeniden üretilir:
`bash scripts/build-setup-sql.sh`
