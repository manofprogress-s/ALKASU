"use server";
import { redactSecrets, serviceRoleKey, supabaseAdmin, supabaseServer } from "@/lib/supabase/server";
import { isSyntheticEmail, usernameOf } from "@/lib/username";

type Result = { ok: boolean };

/**
 * D-120: e-postayla açılmış personel hesabına kullanıcı adıyla giriş (ör. yönetici "EKA").
 * Kullanıcı adı üyelikte kayıtlı; e-posta sunucuda bulunur ve tarayıcıya hiç gönderilmez.
 * Oturum sunucuda açılır (çerezler yazılır). Her hatada aynı genel yanıt döner (kullanıcı adı var/yok belli olmaz).
 */
export async function signInWithUsername(login: string, password: string): Promise<Result> {
  const fail = { ok: false };
  try {
    const username = usernameOf(login);
    if (!username || !password || password.length > 72 || !serviceRoleKey()) return fail;
    const admin = supabaseAdmin();
    const { data: rows } = await admin.from("memberships").select("user_id")
      .eq("username", username).eq("active", true).neq("role", "musteri").limit(2);
    const ids = [...new Set((rows ?? []).map((r: { user_id: string }) => r.user_id))];
    if (ids.length !== 1) return fail;
    const { data: u } = await admin.auth.admin.getUserById(ids[0]);
    const email = u?.user?.email;
    // Sentetik e-postalı hesap (kullanici.alkasu.app) zaten tarayıcıdaki ilk denemede kullanıldı
    if (!email || isSyntheticEmail(email)) return fail;
    const { error } = await (await supabaseServer()).auth.signInWithPassword({ email, password });
    return error ? fail : { ok: true };
  } catch (e) {
    console.error("Kullanıcı adıyla giriş hatası:", redactSecrets(e instanceof Error ? e.message : String(e)));
    return fail;
  }
}
