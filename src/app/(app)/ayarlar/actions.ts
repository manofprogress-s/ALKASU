"use server";
import { z } from "zod";
import { getContext } from "@/lib/session";
import { redactSecrets, serviceRoleKey, supabaseAdmin, supabaseServer } from "@/lib/supabase/server";
import { loginEmail, normalizeUsername } from "@/lib/username";
import { ASSIGNABLE_ROLES } from "@/lib/roles";

type Result = { ok: boolean; message: string };

const PasswordSchema = z
  .string()
  .min(8, "Geçici şifre en az 8 karakter olmalı")
  .max(72, "Şifre çok uzun");

const CreateSchema = z
  .object({
    login: z.string().trim().min(3, "Kullanıcı adı en az 3 karakter olmalı"),
    name: z.string().trim().min(2, "Ad en az 2 karakter olmalı"),
    role: z.enum(ASSIGNABLE_ROLES as [string, ...string[]]),
    customerId: z.string().uuid().nullable(),
    password: PasswordSchema,
  })
  .refine((v) => v.role !== "bayi" || !!v.customerId, { message: "Bayi kullanıcısı için bayi müşteri kartını seçin", path: ["customerId"] })
  .refine((v) => v.login.includes("@") || normalizeUsername(v.login).length >= 3, { message: "Kullanıcı adı yalnızca harf ve rakam içermeli", path: ["login"] });

function serviceKeyMissing(): Result | null {
  return serviceRoleKey()
    ? null
    : { ok: false, message: "Sunucu ayarı eksik: SUPABASE_SERVICE_ROLE_KEY Vercel ortam değişkenlerine eklenmeli (bkz. docs/SETUP.md)." };
}

async function findUserId(email: string): Promise<string | null> {
  const admin = supabaseAdmin();
  for (let page = 1; page <= 20; page++) {
    const { data } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    const hit = data.users.find((u) => u.email?.toLowerCase() === email);
    if (hit) return hit.id;
    if (data.users.length < 200) break;
  }
  return null;
}

/**
 * Kullanıcı oluşturma (R-08, T-029): yalnızca yönetici. Kullanıcı adı ve geçici şifreyle hesap açılır,
 * ilk girişte şifre değiştirmek zorunludur. service_role anahtarı yalnızca burada, sunucuda kullanılır.
 */
async function createUserImpl(input: {
  login: string;
  name: string;
  role: string;
  customerId: string | null;
  password: string;
}): Promise<Result> {
  const ctx = await getContext();
  if (ctx.role !== "yonetici") return { ok: false, message: "Bu işlem için yetkiniz yok" };
  const missing = serviceKeyMissing();
  if (missing) return missing;
  const parsed = CreateSchema.safeParse(input);
  if (!parsed.success) return { ok: false, message: parsed.error.issues[0]?.message ?? "Geçersiz bilgi" };
  const { login, name, role, customerId, password } = parsed.data;
  const email = loginEmail(login);
  const username = login.includes("@") ? null : normalizeUsername(login);
  const admin = supabaseAdmin();

  let userId: string | null = null;
  let created = false;
  const res = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { display_name: name, username },
  });
  if (res.data?.user) {
    userId = res.data.user.id;
    created = true;
  } else if (res.error && /already|registered|exists/i.test(res.error.message)) {
    userId = await findUserId(email);
  } else if (res.error) {
    return { ok: false, message: res.error.message };
  }
  if (!userId) return { ok: false, message: "Kullanıcı oluşturulamadı" };

  // Üyelik, yöneticinin kendi oturumuyla eklenir (veritabanı yetkiyi tekrar kontrol eder)
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc("add_member", {
    p_business: ctx.businessId,
    p_user: userId,
    p_role: role,
    p_name: name,
    p_customer: role === "bayi" ? customerId : null,
    p_username: username,
    p_must_change: created,
  });
  if (error) {
    if (created) await admin.auth.admin.deleteUser(userId); // yarım hesap bırakma
    return { ok: false, message: error.message };
  }
  return {
    ok: true,
    message: created
      ? `Kullanıcı oluşturuldu. Giriş: ${username ?? email} — ilk girişte şifresini değiştirecek.`
      : "Bu kullanıcı zaten vardı; işletmeye eklendi (şifresi değişmedi).",
  };
}

/** Yönetici bir kullanıcıya yeni geçici şifre verir; kullanıcı ilk girişte değiştirmek zorundadır. */
async function resetUserPasswordImpl(input: { membershipId: string; password: string }): Promise<Result> {
  const ctx = await getContext();
  if (ctx.role !== "yonetici") return { ok: false, message: "Bu işlem için yetkiniz yok" };
  const missing = serviceKeyMissing();
  if (missing) return missing;
  const pw = PasswordSchema.safeParse(input.password);
  if (!pw.success) return { ok: false, message: pw.error.issues[0]?.message ?? "Geçersiz şifre" };

  const supabase = await supabaseServer();
  const { data: m } = await supabase
    .from("memberships")
    .select("user_id")
    .eq("id", input.membershipId)
    .eq("business_id", ctx.businessId)
    .maybeSingle();
  if (!m) return { ok: false, message: "Kullanıcı bulunamadı" };
  if (m.user_id === ctx.userId) return { ok: false, message: "Kendi şifrenizi Şifre değiştir sayfasından değiştirin" };

  const { error: rpcError } = await supabase.rpc("require_password_change", { p_membership: input.membershipId });
  if (rpcError) return { ok: false, message: rpcError.message };
  const { error } = await supabaseAdmin().auth.admin.updateUserById(m.user_id as string, { password: pw.data });
  if (error) return { ok: false, message: error.message };
  return { ok: true, message: "Geçici şifre verildi; kullanıcı girişte yeni şifre belirleyecek." };
}

function safe(r: Result): Result {
  return { ok: r.ok, message: redactSecrets(r.message) };
}

function failure(e: unknown): Result {
  console.error("Kullanıcı yönetimi hatası:", redactSecrets(e instanceof Error ? e.message : String(e)));
  return { ok: false, message: "Sunucu Supabase'e bağlanamadı. SUPABASE_SERVICE_ROLE_KEY değerini kontrol edin (Vercel → Environment Variables)." };
}

export async function createUser(input: Parameters<typeof createUserImpl>[0]): Promise<Result> {
  try {
    return safe(await createUserImpl(input));
  } catch (e) {
    return failure(e);
  }
}

export async function resetUserPassword(input: Parameters<typeof resetUserPasswordImpl>[0]): Promise<Result> {
  try {
    return safe(await resetUserPasswordImpl(input));
  } catch (e) {
    return failure(e);
  }
}
