-- ALKASU 0013 — Yeni rol: musteri (internetten kayıt olan ev müşterisi; yalnızca kendi siparişleri)
-- Enum değeri ayrı migration'da eklenir (aynı işlemde kullanılamaz).
alter type public.member_role add value if not exists 'musteri';
