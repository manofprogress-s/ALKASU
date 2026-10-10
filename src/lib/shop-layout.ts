import { buildSections, naturalSection, sectionOf, sectionToken, type ShopItem } from "@/lib/shop";

/** Mağaza düzeni değişikliği (save_shop_layout'a gider) */
export interface LayoutChange {
  unit_id: string;
  hidden?: boolean;
  sort?: number | null;
  section?: string | null;
}

export type LayoutOp =
  | { op: "hide"; unitId: string }
  | { op: "show"; unitId: string }
  | { op: "move"; unitId: string; dir: -1 | 1 }
  | { op: "swap"; a: string; b: string }
  | { op: "replace"; unitId: string; withUnitId: string }
  | { op: "reset"; unitId: string };

/** Bölüm adı ürünün kendi bölümüyse null (otomatik), değilse adın kendisi */
function sectionFor(i: ShopItem, title: string): string | null {
  return naturalSection(i) === title ? null : title;
}

/** Düzenleyicide görünen bölümler: çok satanlar otomatiktir, düzenlenmez */
export function editableSections(items: ShopItem[]) {
  return buildSections(items, 0);
}

/**
 * Düzen işlemini uygular (W-11). Saf fonksiyon: yeni ürün listesi ve kaydedilecek değişiklikleri döner.
 * Sıra değişen bölümdeki tüm ürünlere 10, 20, 30… sırası yazılır (sonradan eklenen ürünler sona düşer).
 */
export function applyLayout(items: ShopItem[], op: LayoutOp): { items: ShopItem[]; changes: LayoutChange[] } {
  const map = new Map(items.map((i) => [i.unitId, { ...i }]));
  const changed = new Map<string, LayoutChange>();
  const touch = (id: string, c: Omit<LayoutChange, "unit_id">) => {
    const it = map.get(id);
    if (!it) return;
    Object.assign(it, c);
    changed.set(id, { ...(changed.get(id) ?? { unit_id: id }), ...c });
  };
  const sectionList = (title: string) =>
    editableSections([...map.values()]).find((s) => s.title === title)?.items.map((i) => i.unitId) ?? [];
  const renumber = (title: string, order: string[]) =>
    order.forEach((id, idx) => {
      const it = map.get(id)!;
      touch(id, { sort: (idx + 1) * 10, section: sectionFor(it, title) });
    });

  switch (op.op) {
    case "hide":
      touch(op.unitId, { hidden: true });
      break;
    case "show":
      touch(op.unitId, { hidden: false });
      break;
    case "reset":
      touch(op.unitId, { sort: null, section: null });
      break;
    case "move": {
      const it = map.get(op.unitId);
      if (!it) break;
      const title = sectionOf(it);
      const order = sectionList(title);
      const i = order.indexOf(op.unitId);
      const j = i + op.dir;
      if (i < 0 || j < 0 || j >= order.length) break;
      [order[i], order[j]] = [order[j]!, order[i]!];
      renumber(title, order);
      break;
    }
    case "swap": {
      const a = map.get(op.a);
      const b = map.get(op.b);
      if (!a || !b || a.unitId === b.unitId) break;
      const ta = sectionOf(a);
      const tb = sectionOf(b);
      if (ta === tb) {
        const order = sectionList(ta);
        const i = order.indexOf(a.unitId);
        const j = order.indexOf(b.unitId);
        [order[i], order[j]] = [order[j]!, order[i]!];
        renumber(ta, order);
      } else {
        const oa = sectionList(ta);
        const ob = sectionList(tb);
        oa[oa.indexOf(a.unitId)] = b.unitId;
        ob[ob.indexOf(b.unitId)] = a.unitId;
        renumber(ta, oa);
        renumber(tb, ob);
      }
      break;
    }
    case "replace": {
      const a = map.get(op.unitId);
      const b = map.get(op.withUnitId);
      if (!a || !b || a.unitId === b.unitId) break;
      const ta = sectionOf(a);
      const tb = b.hidden ? null : sectionOf(b);
      const oa = sectionList(ta).filter((id) => id !== b.unitId);
      oa[oa.indexOf(a.unitId)] = b.unitId;
      touch(a.unitId, { hidden: true });
      touch(b.unitId, { hidden: false });
      renumber(ta, oa);
      if (tb && tb !== ta) renumber(tb, sectionList(tb).filter((id) => id !== b.unitId));
      break;
    }
  }
  return { items: [...map.values()], changes: [...changed.values()] };
}

/**
 * Bölümü bir adım yukarı/aşağı taşır (W-12). Kaydedilecek tam bölüm sırası ve anında gösterim için güncellenmiş ürünler döner.
 */
export function moveSection(items: ShopItem[], key: string, dir: -1 | 1): { items: ShopItem[]; titles: string[] } | null {
  const sections = buildSections(items);
  const i = sections.findIndex((s) => s.key === key);
  const j = i + dir;
  if (i < 0 || j < 0 || j >= sections.length) return null;
  const order = [...sections];
  [order[i], order[j]] = [order[j]!, order[i]!];
  const titles = order.map(sectionToken);
  const rank = new Map(titles.map((t, idx) => [t, (idx + 1) * 10]));
  const topRank = rank.get("__top__") ?? null;
  return {
    titles,
    items: items.map((it) => ({ ...it, sectionRank: rank.get(sectionOf(it)) ?? null, topRank })),
  };
}
