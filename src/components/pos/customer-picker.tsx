"use client";
import { useMemo, useState } from "react";
import { UserPlus } from "lucide-react";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { Alert } from "@/components/ui/card";
import { useAppContext } from "@/components/shell/context";
import { searchKey, type PosCustomer } from "@/lib/catalog";
import { formatTRY } from "@/lib/format";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";

export function CustomerPicker({
  open,
  onClose,
  customers,
  onPick,
  onCreated,
}: {
  open: boolean;
  onClose: () => void;
  customers: PosCustomer[];
  onPick: (c: PosCustomer) => void;
  onCreated: (c: PosCustomer) => void;
}) {
  const ctx = useAppContext();
  const [q, setQ] = useState("");
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const list = useMemo(() => {
    const k = searchKey(q.trim());
    const digits = q.replace(/\D/g, "");
    return customers
      .filter((c) => !k || searchKey(`${c.name} ${c.code}`).includes(k) || (digits.length >= 3 && (c.phone ?? "").replace(/\D/g, "").includes(digits)))
      .slice(0, 50);
  }, [customers, q]);

  async function create() {
    if (!name.trim()) return setError("Ad zorunludur");
    setSaving(true);
    setError(null);
    const { data, error } = await supabaseBrowser().rpc("upsert_customer", {
      p_business: ctx.businessId,
      p: { name: name.trim(), phone: phone.trim() || null },
    });
    setSaving(false);
    if (error) return setError(errorMessage(error));
    onCreated({ id: data as string, code: "", name: name.trim(), phone: phone.trim() || null, creditLimit: 0, unlimited: false, balance: 0, priceList: "perakende" });
    setCreating(false);
    setName("");
    setPhone("");
  }

  return (
    <Dialog open={open} onClose={onClose} title={creating ? "Yeni müşteri" : "Müşteri seç"}>
      {creating ? (
        <div className="space-y-3">
          <Field label="Ad / unvan">
            <Input autoFocus value={name} onChange={(e) => setName(e.target.value)} />
          </Field>
          <Field label="Telefon">
            <Input inputMode="tel" value={phone} onChange={(e) => setPhone(e.target.value)} />
          </Field>
          <p className="text-xs text-muted">Veresiye limiti yönetici tarafından müşteri kartından tanımlanır.</p>
          {error ? <Alert>{error}</Alert> : null}
          <div className="flex gap-2">
            <Button variant="secondary" onClick={() => setCreating(false)}>
              Vazgeç
            </Button>
            <Button className="flex-1" onClick={create} loading={saving}>
              Kaydet ve seç
            </Button>
          </div>
        </div>
      ) : (
        <div className="space-y-3">
          <Input autoFocus placeholder="Ad, kod veya telefon" value={q} onChange={(e) => setQ(e.target.value)} />
          <Button variant="secondary" className="w-full" onClick={() => { setCreating(true); setName(q); }}>
            <UserPlus className="h-4 w-4" /> Yeni müşteri ekle
          </Button>
          <ul className="divide-y divide-border">
            {list.map((c) => (
              <li key={c.id}>
                <button className="flex w-full items-center justify-between gap-2 py-3 text-left" onClick={() => onPick(c)}>
                  <span className="min-w-0">
                    <span className="block truncate font-medium">{c.name}</span>
                    <span className="block text-xs text-muted">
                      {c.code} {c.phone ? `· ${c.phone}` : ""}
                    </span>
                  </span>
                  <span className={`num text-sm ${c.balance > 0 ? "text-warn" : "text-muted"}`}>{formatTRY(c.balance)}</span>
                </button>
              </li>
            ))}
            {list.length === 0 ? <li className="py-6 text-center text-muted">Müşteri bulunamadı</li> : null}
          </ul>
        </div>
      )}
    </Dialog>
  );
}
