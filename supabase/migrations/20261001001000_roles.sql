-- ALKASU 0010 — Yeni roller: sevkiyat (depo yöneticisi, sipariş teslimi), bayi (kendi siparişleri ve cari hesabı)
-- Enum değerleri ayrı migration'da eklenir: PostgreSQL yeni değerin aynı işlemde kullanılmasına izin vermez.
alter type public.member_role add value if not exists 'sevkiyat';
alter type public.member_role add value if not exists 'bayi';
