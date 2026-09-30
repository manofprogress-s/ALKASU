# ALKASU

Alay Ticaret için bulut tabanlı stok, satış, kasa ve yönetim uygulaması (Next.js + Supabase, Türkçe, mobil öncelikli PWA).

## Belgeler
- [Ürün gereksinimleri](docs/PRODUCT_SPEC.md) · [İş kuralları](docs/BUSINESS_RULES.md) · [Karar kaydı](docs/DECISIONS.md) · [Geliştirme planı](docs/IMPLEMENTATION_PLAN.md)
- [Kurulum ve yayın](docs/SETUP.md) · [Yedekleme ve geri yükleme](docs/BACKUP_RESTORE.md) · [Kullanım kılavuzu](docs/OPERATIONS.md)

## Yapı
```
supabase/migrations/   Şema, RLS politikaları, iş kuralı fonksiyonları (tüm yazmalar buradan)
supabase/tests/        Veritabanı testleri (scripts/test-db.sh)
src/app/               Sayfalar (App Router)
src/components/        Arayüz bileşenleri (pos/ = satış ekranı)
src/lib/               Sepet hesabı, biçimlendirme, çevrimdışı kuyruk, Excel
templates/             Excel/CSV içe aktarma şablonu
```

## Komutlar
| Komut | İş |
|---|---|
| `npm run dev` | Geliştirme sunucusu |
| `npm run check` | Lint + tip kontrolü + birim testleri + production build |
| `npm run test:db` | Veritabanı testleri (PostgreSQL 15+) |
| `npm run seed:demo` | Demo verisi (yalnızca demo projesi) |

## Güvenlik ilkeleri
- Tablolara istemciden doğrudan yazma kapalıdır; her işlem yetki kontrollü bir veritabanı fonksiyonudur.
- Maliyet/kâr verisi ayrı tablolarda, yalnızca yöneticiye açıktır.
- Gizli anahtarlar yalnızca ortam değişkenlerindedir (`.env.example`).
