"use client";
import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { ArrowLeft, ArrowLeftRight, ArrowRight, EyeOff, Replace, RotateCcw, Search, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { Input } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useToast } from "@/components/ui/toast";
import { supabaseBrowser } from "@/lib/supabase/client";
import { errorMessage } from "@/lib/errors";
import { searchKey } from "@/lib/catalog";
import { sectionOf, shortName, unitLabel, type ShopItem } from "@/lib/shop";
import { applyLayout, moveSection, type LayoutOp } from "@/lib/shop-layout";
import { ItemImage, ShopCatalog } from "./shop-catalog";

/** Yönetici: müşteri sipariş ekranının düzeni (W-11). Müşterinin gördüğü ekranın aynısı, düzenleme modunda. */
export function ShopLayoutEditor({ initial }: { initial: ShopItem[] }) {
  const ctx = useAppContext();
  const router = useRouter();
  const toast = useToast();
  const [items, setItems] = useState(initial);
  const [menu, setMenu] = useState<ShopItem | null>(null);
  const [swapFrom, setSwapFrom] = useState<ShopItem | null>(null);
  const [replaceFor, setReplaceFor] = useState<ShopItem | null>(null);
  const [q, setQ] = useState("");
  const [saving, setSaving] = useState(false);
  const hidden = items.filter((i) => i.hidden);

  async function run(op: LayoutOp, success: string) {
    const prev = items;
    const r = applyLayout(items, op);
    if (!r.changes.length) return;
    setItems(r.items); // anında göster, sonra kaydet
    setSaving(true);
    const { error } = await supabaseBrowser().rpc("save_shop_layout", { p_business: ctx.businessId, p_items: r.changes });
    setSaving(false);
    if (error) {
      setItems(prev);
      toast(errorMessage(error), "danger");
      return;
    }
    toast(success, "ok");
    router.refresh();
  }

  async function onMoveSection(key: string, dir: -1 | 1) {
    const r = moveSection(items, key, dir);
    if (!r) return;
    const prev = items;
    setItems(r.items);
    const { error } = await supabaseBrowser().rpc("save_shop_sections", { p_business: ctx.businessId, p_titles: r.titles });
    if (error) {
      setItems(prev);
      toast(errorMessage(error), "danger");
      return;
    }
    toast(dir < 0 ? "Bölüm yukarı taşındı" : "Bölüm aşağı taşındı", "ok");
    router.refresh();
  }

  function onPress(item: ShopItem, how: "long" | "tap") {
    if (swapFrom) {
      if (swapFrom.unitId !== item.unitId) void run({ op: "swap", a: swapFrom.unitId, b: item.unitId }, "Yerleri değiştirildi");
      setSwapFrom(null);
      return;
    }
    if (how === "long" || how === "tap") setMenu(item);
  }

  const candidates = useMemo(() => {
    if (!replaceFor) return [];
    const k = searchKey(q.trim());
    return items
      .filter((i) => i.unitId !== replaceFor.unitId)
      .filter((i) => !k || searchKey(`${i.productName} ${i.unitName}`).includes(k))
      .sort((a, b) => Number(b.hidden) - Number(a.hidden) || a.productName.localeCompare(b.productName, "tr"));
  }, [items, replaceFor, q]);

  const act = (fn: () => void) => () => { const m = menu; setMenu(null); if (m) fn(); };

  return (
    <div className="space-y-4">
      <Alert tone="neutral">
        Müşterinin sipariş ekranı. Bir ürüne <b>basılı tutun</b> (ya da dokunun): kaldırın, yerine başka ürün koyun, yerini değiştirin.
        Bölümlerin sırasını başlıktaki ↑ ↓ ile değiştirin. Değişiklik anında müşteriye yansır. “Çok satanlar”ın ürünleri satışa göre kendiliğinden seçilir.
      </Alert>
      {swapFrom ? (
        <div className="sticky top-2 z-20 flex items-center justify-between gap-2 rounded-2xl bg-warn-soft p-3 text-sm font-medium text-warn shadow">
          <span><b>{shortName(swapFrom)}</b> ile yer değiştirecek ürüne dokunun</span>
          <Button size="sm" variant="ghost" onClick={() => setSwapFrom(null)}><X className="h-4 w-4" /> Vazgeç</Button>
        </div>
      ) : null}
      <ShopCatalog items={items} qty={{}} onStep={() => undefined} edit={{ onPress, selectedId: swapFrom?.unitId ?? null, onMoveSection: (k, d) => void onMoveSection(k, d) }} />

      {hidden.length ? (
        <Card className="space-y-2">
          <h2 className="font-semibold">Gizlenenler ({hidden.length})</h2>
          <p className="text-sm text-muted">Müşteri bu ürünleri görmez.</p>
          <ul className="divide-y divide-border">
            {hidden.map((i) => (
              <li key={i.unitId} className="flex items-center gap-3 py-2">
                <ItemImage item={i} className="h-12 w-10 shrink-0" />
                <span className="min-w-0 flex-1">
                  <span className="block font-medium leading-tight">{i.productName}</span>
                  <span className="block text-xs text-muted">{unitLabel(i)}</span>
                </span>
                <Button size="sm" variant="secondary" loading={saving} onClick={() => void run({ op: "show", unitId: i.unitId }, "Ürün geri getirildi")}>Geri getir</Button>
              </li>
            ))}
          </ul>
        </Card>
      ) : null}

      <Dialog open={!!menu} onClose={() => setMenu(null)} title={menu ? `${menu.productName} · ${unitLabel(menu)}` : ""}>
        {menu ? (
          <div className="grid gap-2">
            <p className="text-sm text-muted">Bölüm: {sectionOf(menu)}</p>
            <Button variant="secondary" className="justify-start" onClick={act(() => setSwapFrom(menu))}>
              <ArrowLeftRight className="h-4 w-4" /> Yer değiştir (sonra diğer ürüne dokunun)
            </Button>
            <Button variant="secondary" className="justify-start" onClick={act(() => { setQ(""); setReplaceFor(menu); })}>
              <Replace className="h-4 w-4" /> Yerine başka ürün koy
            </Button>
            <div className="grid grid-cols-2 gap-2">
              <Button variant="secondary" onClick={act(() => void run({ op: "move", unitId: menu.unitId, dir: -1 }, "Sola taşındı"))}><ArrowLeft className="h-4 w-4" /> Sola</Button>
              <Button variant="secondary" onClick={act(() => void run({ op: "move", unitId: menu.unitId, dir: 1 }, "Sağa taşındı"))}>Sağa <ArrowRight className="h-4 w-4" /></Button>
            </div>
            {menu.sort !== null || menu.section !== null ? (
              <Button variant="ghost" className="justify-start" onClick={act(() => void run({ op: "reset", unitId: menu.unitId }, "Otomatik düzene döndü"))}>
                <RotateCcw className="h-4 w-4" /> Otomatik yerine döndür
              </Button>
            ) : null}
            <Button variant="danger" className="justify-start" onClick={act(() => void run({ op: "hide", unitId: menu.unitId }, "Ürün müşteri ekranından kaldırıldı"))}>
              <EyeOff className="h-4 w-4" /> Müşteri ekranından kaldır
            </Button>
          </div>
        ) : null}
      </Dialog>

      <Dialog open={!!replaceFor} onClose={() => setReplaceFor(null)} title={replaceFor ? `${shortName(replaceFor)} yerine` : ""}>
        <div className="space-y-3">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" />
            <Input className="pl-9" placeholder="Ürün ara" value={q} onChange={(e) => setQ(e.target.value)} />
          </div>
          <ul className="max-h-[55vh] divide-y divide-border overflow-y-auto">
            {candidates.map((i) => (
              <li key={i.unitId}>
                <button type="button" className="flex w-full items-center gap-3 py-2 text-left hover:bg-surface-2"
                  onClick={() => { const a = replaceFor; setReplaceFor(null); if (a) void run({ op: "replace", unitId: a.unitId, withUnitId: i.unitId }, "Ürün değiştirildi"); }}>
                  <ItemImage item={i} className="h-12 w-10 shrink-0" />
                  <span className="min-w-0 flex-1">
                    <span className="block font-medium leading-tight">{i.productName}</span>
                    <span className="block text-xs text-muted">{unitLabel(i)}{i.hidden ? " · gizli" : ` · ${sectionOf(i)}`}</span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </div>
      </Dialog>
    </div>
  );
}
