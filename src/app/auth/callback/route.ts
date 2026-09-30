import { NextResponse, type NextRequest } from "next/server";
import { supabaseServer } from "@/lib/supabase/server";

// Davet ve şifre sıfırlama bağlantılarının dönüşü
export async function GET(request: NextRequest) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const tokenHash = url.searchParams.get("token_hash");
  const type = url.searchParams.get("type");
  const next = url.searchParams.get("next") ?? "/";
  const safeNext = next.startsWith("/") && !next.startsWith("//") ? next : "/";
  const supabase = await supabaseServer();

  let error: unknown = null;
  if (code) {
    ({ error } = await supabase.auth.exchangeCodeForSession(code));
  } else if (tokenHash && type) {
    ({ error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type: type as "invite" | "recovery" | "email" }));
  }
  if (error) return NextResponse.redirect(new URL("/giris?hata=baglanti", url.origin));
  const dest = type === "invite" || type === "recovery" ? "/sifre" : safeNext;
  return NextResponse.redirect(new URL(dest, url.origin));
}
