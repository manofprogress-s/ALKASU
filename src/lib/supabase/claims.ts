import type { SupabaseClient } from "@supabase/supabase-js";

export interface SessionUser {
  id: string;
  email: string | null;
}

/**
 * Oturumdaki kullanıcı (T-031). Erişim jetonunun imzası Supabase'in açık anahtarıyla (ES256, JWKS)
 * sunucuda doğrulanır; her istekte Supabase Auth'a ağ isteği atılmaz. Süresi dolmuş jeton önce yenilenir.
 * Yetki kararları yine veritabanındaki RLS ve yetki fonksiyonlarında verilir.
 */
export async function sessionUser(supabase: SupabaseClient): Promise<SessionUser | null> {
  const { data, error } = await supabase.auth.getClaims();
  const claims = data?.claims;
  if (error || !claims?.sub) return null;
  return { id: claims.sub, email: typeof claims.email === "string" ? claims.email : null };
}
