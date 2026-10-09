"use client";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import { Badge, Card } from "@/components/ui/card";
import { useAppContext } from "@/components/shell/context";
import { supabaseBrowser } from "@/lib/supabase/client";
import { useRpc } from "@/lib/use-action";
import { formatDateTime } from "@/lib/format";
import { KVKK_VERSION, MARKETING_TEXT } from "@/lib/kvkk";

/** Personel / bayi müşteri açarken: ilk iletişimde aydınlatma yapıldı mı (K-04). Rıza değil, bilgilendirme kaydı. */
export function NoticeCheck({ checked, onChange }: { checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="flex items-start gap-2 text-sm">
      <input type="checkbox" className="mt-0.5 h-5 w-5 shrink-0" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      <span>
        Müşteriyi kişisel verileri hakkında bilgilendirdim (
        <Link href="/kvkk" target="_blank" className="text-brand underline">aydınlatma metni</Link>
        ; ör. bağlantıyı gönderdim veya özetini anlattım).
      </span>
    </label>
  );
}

export async function recordNotice(customerId: string): Promise<boolean> {
  const { error } = await supabaseBrowser().rpc("record_customer_privacy", { p_customer: customerId, p_kind: "aydinlatma", p_version: KVKK_VERSION });
  return !error;
}

export interface PrivacyEvent {
  kind: "aydinlatma" | "kampanya_izni" | "kampanya_ret";
  channel: string;
  notice_version: string;
  created_at: string;
}

const KIND: Record<PrivacyEvent["kind"], string> = { aydinlatma: "Aydınlatma yapıldı", kampanya_izni: "Kampanya izni verildi", kampanya_ret: "Kampanya izni geri çekildi" };
const CHANNEL: Record<string, string> = { online_kayit: "online kayıt", musteri: "müşteri", personel: "personel", bayi: "bayi" };

/**
 * KVKK kartı. mode="self": müşteri kendi kampanya iznini yönetir (Hesabım).
 * mode="staff": personel/bayi aydınlatma ve telefonla bildirilen izin değişikliğini kaydeder.
 */
export function PrivacyCard({ mode, customerId, marketing, marketingAt, events }: {
  mode: "self" | "staff";
  customerId: string;
  marketing: boolean;
  marketingAt: string | null;
  events: PrivacyEvent[];
}) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const notice = events.find((e) => e.kind === "aydinlatma");

  function setMarketing(value: boolean) {
    const msg = value ? "Kampanya izni kaydedildi" : "Kampanya izni geri çekildi";
    if (mode === "self") void call("set_my_marketing", { p_business: ctx.businessId, p_value: value, p_version: KVKK_VERSION }, { success: msg });
    else void call("record_customer_privacy", { p_customer: customerId, p_kind: value ? "kampanya_izni" : "kampanya_ret", p_version: KVKK_VERSION }, { success: msg });
  }

  return (
    <Card className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="font-semibold">Kişisel veriler (KVKK)</h2>
        <Link href="/kvkk" target="_blank" className="text-sm text-brand underline">Aydınlatma metni</Link>
      </div>

      {mode === "staff" ? (
        <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
          <span>
            {notice ? <Badge tone="ok">Bilgilendirildi</Badge> : <Badge tone="warn">Bilgilendirme kaydı yok</Badge>}{" "}
            {notice ? <span className="text-muted">{formatDateTime(notice.created_at)} · {CHANNEL[notice.channel] ?? notice.channel} · sürüm {notice.notice_version}</span> : null}
          </span>
          {!notice || notice.notice_version !== KVKK_VERSION ? (
            <Button size="sm" variant="secondary" loading={busy}
              onClick={() => void call("record_customer_privacy", { p_customer: customerId, p_kind: "aydinlatma", p_version: KVKK_VERSION }, { success: "Bilgilendirme kaydedildi" })}>
              Bilgilendirdim, kaydet
            </Button>
          ) : null}
        </div>
      ) : null}

      <div className="space-y-2 rounded-xl bg-bg p-3 text-sm">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <span className="font-medium">
            Kampanya iletileri: {marketing ? <Badge tone="ok">İzin var</Badge> : <Badge>İzin yok</Badge>}
            {marketingAt ? <span className="ml-1 text-xs font-normal text-muted">{formatDateTime(marketingAt)}</span> : null}
          </span>
          <Button size="sm" variant={marketing ? "secondary" : "primary"} loading={busy} onClick={() => setMarketing(!marketing)}>
            {marketing ? (mode === "self" ? "İznimi geri çek" : "İzni geri çekildi olarak kaydet") : (mode === "self" ? "İzin veriyorum" : "Müşteri izin verdi")}
          </Button>
        </div>
        <p className="text-xs text-muted">{MARKETING_TEXT}</p>
        {mode === "staff" ? <p className="text-xs text-muted">Yalnızca müşteri açıkça istediğinde değiştirin. İzinsiz kampanya mesajı gönderilmez.</p> : null}
      </div>

      {mode === "self" ? (
        <p className="text-xs text-muted">
          Bilgilerinizin düzeltilmesi, silinmesi veya diğer haklarınız için aydınlatma metnindeki <Link href="/kvkk#basvuru" target="_blank" className="underline">başvuru</Link> kanallarını kullanabilirsiniz.
        </p>
      ) : events.length ? (
        <details className="text-xs text-muted">
          <summary className="cursor-pointer">Kayıt geçmişi ({events.length})</summary>
          <ul className="mt-1 space-y-0.5">
            {events.map((e, i) => <li key={i}>{formatDateTime(e.created_at)} · {KIND[e.kind]} · {CHANNEL[e.channel] ?? e.channel} · sürüm {e.notice_version}</li>)}
          </ul>
        </details>
      ) : null}
    </Card>
  );
}
