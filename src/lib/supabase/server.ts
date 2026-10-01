import "server-only";
import { createServerClient } from "@supabase/ssr";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { cookies } from "next/headers";
import { SUPABASE_ANON_KEY, SUPABASE_URL } from "@/lib/env";

/** Oturumdaki kullanıcı adına çalışan istemci (RLS geçerlidir). */
export async function supabaseServer(): Promise<SupabaseClient> {
  const store = await cookies();
  return createServerClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    cookies: {
      getAll: () => store.getAll(),
      setAll: (list) => {
        try {
          list.forEach(({ name, value, options }) => store.set(name, value, options));
        } catch {
          // Server Component içinden çağrıldığında yazılamaz; oturum yenilemesini proxy yapar.
        }
      },
    },
  });
}

/** Yalnızca sunucuda, yalnızca kullanıcı daveti gibi yönetim işleri için (T-018). */
export function serviceRoleKey(): string | null {
  // Anahtarda boşluk/satır sonu olamaz; yapıştırırken araya girenleri temizle
  const key = (process.env.SUPABASE_SERVICE_ROLE_KEY ?? "").replace(/\s+/g, "");
  return key || null;
}

/** Hata mesajlarında gizli anahtar asla görünmesin */
export function redactSecrets(message: string): string {
  return message.replace(/sb_secret_[^\s"']*(\s+[^\s"']+)?/g, "[gizli anahtar]").replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, "[gizli anahtar]");
}

export function supabaseAdmin(): SupabaseClient {
  const key = serviceRoleKey();
  if (!key) throw new Error("SUPABASE_SERVICE_ROLE_KEY tanımlı değil");
  return createClient(SUPABASE_URL, key, { auth: { persistSession: false, autoRefreshToken: false } });
}
