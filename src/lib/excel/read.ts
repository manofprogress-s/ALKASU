// Excel/CSV okuma: şablon sayfalarını {başlık: değer} satırlarına çevirir. Tarayıcıda çalışır.
export type SheetRows = Record<string, string>[] & { row?: number };

function cellText(v: unknown): string {
  if (v === null || v === undefined) return "";
  if (typeof v === "number") return Number.isInteger(v) ? String(v) : String(Math.round(v * 10000) / 10000);
  if (typeof v === "boolean") return v ? "E" : "H";
  if (v instanceof Date) return v.toISOString().slice(0, 10);
  if (typeof v === "object") {
    const o = v as { text?: string; result?: unknown; richText?: { text: string }[] };
    if (o.richText) return o.richText.map((r) => r.text).join("");
    if (o.result !== undefined) return cellText(o.result);
    if (o.text !== undefined) return String(o.text);
  }
  return String(v).trim();
}

export function normalizeHeader(h: string): string {
  return h.replace(/\*/g, "").trim().toLocaleLowerCase("tr-TR").replace(/\s+/g, "_");
}

/** Metin hücrelerdeki Türkçe ondalık virgülü noktaya çevirir ("25,50" → "25.50"). */
export function normalizeNumberText(s: string): string {
  const t = s.trim();
  if (/^-?\d{1,3}(\.\d{3})+,\d+$/.test(t)) return t.replace(/\./g, "").replace(",", ".");
  if (/^-?\d+,\d+$/.test(t)) return t.replace(",", ".");
  return t;
}

export async function readWorkbook(file: File): Promise<Record<string, Record<string, string>[]>> {
  if (/\.csv$/i.test(file.name)) return { "Ürünler": parseCsv(await file.text()) };
  const ExcelJS = (await import("exceljs")).default;
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(await file.arrayBuffer());
  const out: Record<string, Record<string, string>[]> = {};
  wb.eachSheet((ws) => {
    const headers: string[] = [];
    const rows: Record<string, string>[] = [];
    ws.eachRow({ includeEmpty: false }, (row, n) => {
      const values = row.values as unknown[];
      if (n === 1) {
        values.forEach((v, i) => (headers[i] = normalizeHeader(cellText(v))));
        return;
      }
      const r: Record<string, string> = { row: String(n) };
      let any = false;
      headers.forEach((h, i) => {
        if (!h) return;
        const t = normalizeNumberText(cellText(values[i]));
        if (t !== "") any = true;
        r[h] = t;
      });
      if (any) rows.push(r);
    });
    out[ws.name] = rows;
  });
  return out;
}

export function parseCsv(text: string): Record<string, string>[] {
  const clean = text.replace(/^﻿/, "");
  const firstLine = clean.split(/\r?\n/)[0] ?? "";
  const sep = (firstLine.match(/;/g)?.length ?? 0) >= (firstLine.match(/,/g)?.length ?? 0) ? ";" : ",";
  const rows: string[][] = [];
  let cur: string[] = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < clean.length; i++) {
    const c = clean[i];
    if (quoted) {
      if (c === '"' && clean[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"') quoted = true;
    else if (c === sep) { cur.push(field); field = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && clean[i + 1] === "\n") i++;
      cur.push(field); rows.push(cur); cur = []; field = "";
    } else field += c;
  }
  if (field !== "" || cur.length) { cur.push(field); rows.push(cur); }
  const headers = (rows.shift() ?? []).map(normalizeHeader);
  return rows
    .map((r, idx) => {
      const o: Record<string, string> = { row: String(idx + 2) };
      headers.forEach((h, i) => (o[h] = normalizeNumberText((r[i] ?? "").trim())));
      return o;
    })
    .filter((o) => Object.entries(o).some(([k, v]) => k !== "row" && v !== ""));
}
