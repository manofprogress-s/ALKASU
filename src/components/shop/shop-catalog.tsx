"use client";
import { useMemo, useRef, useState } from "react";
import { ChevronRight, Droplet, Minus, MoreHorizontal, Plus, ShoppingCart } from "lucide-react";
import { formatTRY, fromKurus, toKurus } from "@/lib/format";
import { brandColor, buildSections, productKind, shortName, unitLabel, type ShopItem } from "@/lib/shop";
import { ProductArt } from "./product-art";

export type Qty = Record<string, number>;

export function cartTotals(items: ShopItem[], qty: Qty) {
  const chosen = items.filter((i) => (qty[i.unitId] ?? 0) > 0);
  const totalK = chosen.reduce((s, i) => s + toKurus(i.price * (qty[i.unitId] ?? 0)), 0);
  const count = chosen.reduce((s, i) => s + (qty[i.unitId] ?? 0), 0);
  return { chosen, totalK, count };
}

export function nextQty(q: Qty, unitId: string, d: number): Qty {
  return { ...q, [unitId]: Math.max(0, Math.min(1000, (q[unitId] ?? 0) + d)) };
}

/** Ürün görseli: yüklenmiş fotoğraf, yoksa markanın renginde çizim */
export function ItemImage({ item, className }: { item: ShopItem; className?: string }) {
  if (item.imageUrl) {
    // Supabase Storage'daki küçük (≤600 px) webp; Next görüntü servisi gerekmiyor
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={item.imageUrl} alt="" loading="lazy" className={`object-contain ${className ?? ""}`} />;
  }
  return <ProductArt kind={productKind(item)} color={brandColor(item.brand)} className={className} />;
}

export function Stepper({ n, onStep, size = "md", label }: { n: number; onStep: (d: number) => void; size?: "md" | "lg"; label: string }) {
  const b = size === "lg" ? "h-11 w-11" : "h-10 w-10";
  if (n === 0) {
    return (
      <button type="button" aria-label={`${label} ekle`} onClick={() => onStep(1)}
        className={`${b} inline-flex items-center justify-center rounded-full bg-brand text-white shadow-md shadow-brand/30 transition active:scale-95`}>
        <Plus className="h-5 w-5" strokeWidth={2.6} />
      </button>
    );
  }
  return (
    <span className="inline-flex items-center rounded-full bg-brand-soft p-0.5">
      <button type="button" aria-label={`${label} azalt`} onClick={() => onStep(-1)}
        className={`${b} inline-flex items-center justify-center rounded-full bg-surface text-brand shadow-sm active:scale-95`}>
        <Minus className="h-4 w-4" strokeWidth={2.6} />
      </button>
      <span className="num w-8 text-center text-base font-bold text-brand" aria-live="polite">{n}</span>
      <button type="button" aria-label={`${label} artır`} onClick={() => onStep(1)}
        className={`${b} inline-flex items-center justify-center rounded-full bg-brand text-white shadow-sm active:scale-95`}>
        <Plus className="h-4 w-4" strokeWidth={2.6} />
      </button>
    </span>
  );
}

/** Mağaza düzeni (yalnızca yönetici, W-11): basılı tut / dokun / "⋯" */
export interface ShopEdit {
  onPress: (item: ShopItem, how: "long" | "tap") => void;
  selectedId?: string | null;
}

/** 450 ms basılı tutma (telefon); kaydırma başlarsa iptal */
function useLongPress(onLong: () => void) {
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const start = useRef<{ x: number; y: number } | null>(null);
  const fired = useRef(false);
  const clear = () => { if (timer.current) clearTimeout(timer.current); timer.current = null; };
  return {
    fired,
    handlers: {
      onPointerDown: (e: React.PointerEvent) => {
        fired.current = false;
        start.current = { x: e.clientX, y: e.clientY };
        clear();
        timer.current = setTimeout(() => { fired.current = true; onLong(); }, 450);
      },
      onPointerMove: (e: React.PointerEvent) => {
        if (start.current && Math.hypot(e.clientX - start.current.x, e.clientY - start.current.y) > 10) clear();
      },
      onPointerUp: clear,
      onPointerLeave: clear,
      onPointerCancel: clear,
      onContextMenu: (e: React.MouseEvent) => e.preventDefault(),
    },
  };
}

function ItemCard({ item, n, onStep, edit }: { item: ShopItem; n: number; onStep: (d: number) => void; edit?: ShopEdit }) {
  const name = shortName(item);
  const lp = useLongPress(() => edit?.onPress(item, "long"));
  const selected = edit?.selectedId === item.unitId;
  return (
    <div
      {...(edit ? lp.handlers : {})}
      onClick={edit ? () => { if (!lp.fired.current) edit.onPress(item, "tap"); } : undefined}
      className={`flex h-full select-none flex-col items-center rounded-2xl border bg-surface p-2.5 pb-3 text-center shadow-sm transition [-webkit-touch-callout:none] ${
        selected ? "border-warn ring-4 ring-warn/40" : n ? "border-brand ring-2 ring-brand/25" : "border-border"} ${edit ? "cursor-pointer active:scale-[0.98]" : ""}`}
    >
      <ItemImage item={item} className="pointer-events-none h-28 w-full" />
      <div className="mt-1.5 line-clamp-2 min-h-[2.5rem] text-[15px] font-semibold leading-tight">{name}</div>
      <div className="mt-0.5 text-xs text-muted">{unitLabel(item)}</div>
      <div className="num mb-2 mt-0.5 font-semibold text-brand">{formatTRY(item.price)}</div>
      <div className="mt-auto">
        {edit ? (
          <span className="inline-flex h-10 items-center gap-1 rounded-full bg-surface-2 px-3 text-sm text-muted">
            <MoreHorizontal className="h-4 w-4" /> Düzenle
          </span>
        ) : <Stepper n={n} onStep={onStep} label={name} />}
      </div>
    </div>
  );
}

/** Marka bölümleri + yatay kaydırmalı kartlar (W-08). "›" ile bölüm ızgara olarak açılır. */
export function ShopCatalog({ items, qty, onStep, edit }: {
  items: ShopItem[]; qty: Qty; onStep: (unitId: string, d: number) => void;
  /** Yönetici düzenleme modu: çok satanlar otomatik olduğu için gösterilmez */
  edit?: ShopEdit;
}) {
  const sections = useMemo(() => buildSections(items, edit ? 0 : undefined), [items, edit]);
  const [open, setOpen] = useState<Record<string, boolean>>({});
  return (
    <div className="space-y-4">
      <div className="flex items-center gap-3 rounded-3xl bg-gradient-to-r from-brand-soft to-surface p-4 shadow-sm">
        <Droplet className="h-8 w-8 shrink-0 fill-brand/20 text-brand" />
        <p className="text-lg font-bold leading-snug">İhtiyacın olan suyu <span className="text-brand">kolayca seç</span></p>
      </div>
      {sections.map((s) => {
        const expanded = open[s.key] ?? false;
        return (
          <section key={s.key} className="rounded-3xl bg-brand-soft/60 p-3" aria-labelledby={`h-${s.key}`}>
            <div className="mb-2 flex items-center justify-between px-1">
              <h2 id={`h-${s.key}`} className="text-xl font-bold tracking-tight">{s.title}</h2>
              {s.items.length > 2 ? (
                <button type="button" onClick={() => setOpen((o) => ({ ...o, [s.key]: !expanded }))}
                  aria-expanded={expanded} aria-label={expanded ? "Daralt" : "Tümünü göster"}
                  className="inline-flex h-9 w-9 items-center justify-center rounded-full bg-surface text-brand shadow-sm">
                  <ChevronRight className={`h-5 w-5 transition ${expanded ? "rotate-90" : ""}`} />
                </button>
              ) : null}
            </div>
            <ul className={expanded
              ? "grid grid-cols-2 gap-2.5 sm:grid-cols-3 md:grid-cols-4"
              : "-mx-3 flex snap-x snap-mandatory gap-2.5 overflow-x-auto px-3 pb-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"}>
              {s.items.map((i) => (
                <li key={i.unitId} className={expanded ? "" : "w-[42%] shrink-0 snap-start sm:w-44"}>
                  <ItemCard item={i} n={qty[i.unitId] ?? 0} onStep={(d) => onStep(i.unitId, d)} edit={edit} />
                </li>
              ))}
            </ul>
          </section>
        );
      })}
    </div>
  );
}

/** Üstteki sepet düğmesi */
export function CartButton({ count, onClick }: { count: number; onClick: () => void }) {
  return (
    <button type="button" onClick={onClick} className="relative inline-flex items-center gap-1.5 rounded-full px-2 py-1 font-semibold text-brand">
      <ShoppingCart className="h-6 w-6" />
      <span>Sepetim</span>
      <span className={`num inline-flex h-6 min-w-6 items-center justify-center rounded-full px-1.5 text-sm ${count ? "bg-brand text-white" : "bg-surface-2 text-muted"}`}>{count}</span>
    </button>
  );
}

/** Alttaki sabit çubuk: seçim özeti + Sepeti onayla */
export function CartBar({ count, totalK, onConfirm, label = "Sepeti onayla", inApp = false }: {
  count: number; totalK: number; onConfirm: () => void; label?: string;
  /** Uygulama içinde: telefonda alt gezinme çubuğunun üstünde durur */
  inApp?: boolean;
}) {
  if (!count) return null;
  return (
    <div className={`fixed inset-x-0 z-30 px-3 pt-2 ${inApp ? "bottom-[calc(3.75rem+env(safe-area-inset-bottom))] pb-2 md:bottom-0 md:pb-3" : "bottom-0 pb-[max(0.75rem,env(safe-area-inset-bottom))]"}`}>
      <div className="mx-auto flex max-w-2xl items-center gap-3 rounded-2xl border border-border bg-surface/95 p-2 pl-4 shadow-lg backdrop-blur">
        <div className="min-w-0 flex-1 leading-tight">
          <div className="font-bold">{count} ürün seçildi</div>
          <div className="num text-sm text-muted">{formatTRY(fromKurus(totalK))}</div>
        </div>
        <button type="button" onClick={onConfirm} className="h-12 rounded-xl bg-brand px-6 text-base font-semibold text-white shadow-md shadow-brand/30 active:scale-[0.98]">
          {label}
        </button>
      </div>
    </div>
  );
}

/** Sepet özeti (onay adımı) */
export function CartList({ items, qty, onStep }: { items: ShopItem[]; qty: Qty; onStep: (unitId: string, d: number) => void }) {
  const { chosen, totalK } = cartTotals(items, qty);
  return (
    <div>
      {chosen.length === 0 ? <p className="py-4 text-center text-muted">Sepetiniz boş.</p> : (
        <ul className="divide-y divide-border">
          {chosen.map((i) => (
            <li key={i.unitId} className="flex items-center gap-3 py-2">
              <ItemImage item={i} className="h-14 w-12 shrink-0" />
              <span className="min-w-0 flex-1">
                <span className="block font-medium leading-tight">{i.productName}</span>
                <span className="num block text-sm text-muted">{unitLabel(i)} · {formatTRY(i.price)}</span>
              </span>
              <Stepper n={qty[i.unitId] ?? 0} onStep={(d) => onStep(i.unitId, d)} label={i.productName} />
            </li>
          ))}
        </ul>
      )}
      <div className="mt-1 flex justify-between border-t border-border pt-2 text-lg font-bold">
        <span>Toplam</span><span className="num">{formatTRY(fromKurus(totalK))}</span>
      </div>
    </div>
  );
}
