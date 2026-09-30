import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, PageHeader } from "@/components/ui/card";
import { formatDateTime } from "@/lib/format";

export const metadata = { title: "İşlem geçmişi" };

const ACTIONS: Record<string, string> = {
  satis: "Satış", satis_limit_asimi: "Satış (limit aşımı onaylı)", satis_iptal: "Satış iptali", iade: "İade", tahsilat: "Tahsilat", tahsilat_iptal: "Tahsilat iptali",
  mal_kabul: "Mal kabul", mal_kabul_onay: "Mal kabul onayı", fire: "Fire", sayim_onay: "Sayım onayı", kasa_kapanis: "Kasa kapanışı",
  kasa_giris: "Kasaya giriş", kasa_cikis: "Kasadan çıkış", kasa_duzeltme: "Kasa düzeltme", kap_iade: "Kap iadesi", kap_kayip: "Kap kaybı",
  urun_ice_aktarma: "Ürün aktarımı", musteri_ice_aktarma: "Müşteri aktarımı", insert: "Kayıt ekleme", update: "Kayıt değişikliği",
};
const TABLES: Record<string, string> = {
  products: "Ürün", product_units: "Ürün birimi", customers: "Müşteri", memberships: "Kullanıcı", app_settings: "Ayarlar", brands: "Marka",
  categories: "Kategori", suppliers: "Tedarikçi", expenses: "Gider",
};

function changed(o: Record<string, unknown> | null, n: Record<string, unknown> | null): string {
  if (!o || !n) return "";
  return Object.keys(n).filter((k) => !["updated_at", "created_at"].includes(k) && JSON.stringify(o[k]) !== JSON.stringify(n[k]))
    .map((k) => `${k}: ${JSON.stringify(o[k])} → ${JSON.stringify(n[k])}`).join(" · ");
}

export default async function AuditPage({ searchParams }: { searchParams: Promise<{ sayfa?: string }> }) {
  const ctx = await requirePermission("audit");
  const sp = await searchParams;
  const page = Math.max(0, parseInt(sp.sayfa ?? "0", 10) || 0);
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("audit_log", { p_business: ctx.businessId, p_limit: 100, p_offset: page * 100 });
  const rows = (data ?? []) as { id: number; at: string; user_name: string | null; action: string; table_name: string | null; record_id: string | null; old_data: Record<string, unknown> | null; new_data: Record<string, unknown> | null }[];
  return (
    <div className="space-y-3">
      <PageHeader title="İşlem geçmişi" subtitle="Kim, ne zaman, neyi değiştirdi" />
      {error ? <Alert>{error.message}</Alert> : null}
      <ul className="divide-y divide-border rounded-2xl border border-border bg-surface">
        {rows.map((r) => (
          <li key={r.id} className="p-3 text-sm">
            <div className="flex flex-wrap justify-between gap-2">
              <span className="font-medium">{ACTIONS[r.action] ?? r.action}{r.table_name && (r.action === "insert" || r.action === "update") ? ` · ${TABLES[r.table_name] ?? r.table_name}` : ""}</span>
              <span className="text-muted">{formatDateTime(r.at)} · {r.user_name ?? "Sistem"}</span>
            </div>
            {r.action === "update" ? <div className="mt-1 break-all text-xs text-muted">{changed(r.old_data, r.new_data)}</div> : null}
            {r.action === "insert" && r.new_data?.name ? <div className="mt-1 text-xs text-muted">{String(r.new_data.name)}</div> : null}
          </li>
        ))}
      </ul>
      <div className="flex justify-between">
        {page > 0 ? <a className="text-brand" href={`?sayfa=${page - 1}`}>← Daha yeni</a> : <span />}
        {rows.length === 100 ? <a className="text-brand" href={`?sayfa=${page + 1}`}>Daha eski →</a> : null}
      </div>
    </div>
  );
}
