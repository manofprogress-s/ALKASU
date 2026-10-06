-- 07.10.2026 kurulum — 1. ADIM (tek başına çalıştırın): yeni rol
-- ALKASU 0013 — Yeni rol: musteri (internetten kayıt olan ev müşterisi; yalnızca kendi siparişleri)
-- Enum değeri ayrı migration'da eklenir (aynı işlemde kullanılamaz).
alter type public.member_role add value if not exists 'musteri';
insert into supabase_migrations.schema_migrations(version, name) values ('20261006001300','customer_role') on conflict do nothing;
