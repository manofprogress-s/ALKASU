import type { ProductKind } from "@/lib/shop";

/**
 * Fotoğrafı yüklenmemiş ürün için sade çizim. Marka logosu çizilmez; yalnızca markanın rengi kullanılır.
 * Fotoğraf yüklenince (Ürünler → ürün → Fotoğraf) yerini fotoğraf alır.
 */
export function ProductArt({ kind, color, className }: { kind: ProductKind; color: string; className?: string }) {
  const id = `g${kind}${color.replace("#", "")}`;
  const water = (
    <defs>
      <linearGradient id={`${id}w`} x1="0" x2="1">
        <stop offset="0" stopColor="#cfe8fb" />
        <stop offset="0.45" stopColor="#f4fbff" />
        <stop offset="1" stopColor="#b9dcf6" />
      </linearGradient>
      <linearGradient id={`${id}c`} x1="0" x2="0" y1="0" y2="1">
        <stop offset="0" stopColor={color} />
        <stop offset="1" stopColor={color} stopOpacity="0.75" />
      </linearGradient>
    </defs>
  );
  const W = `url(#${id}w)`;
  const C = `url(#${id}c)`;
  const stroke = { stroke: "#8fb9d9", strokeWidth: 1.2 };
  let body: React.ReactNode;
  switch (kind) {
    case "damacana":
      body = (
        <>
          <rect x="44" y="6" width="12" height="9" rx="2" fill={C} />
          <path d="M42 15h16l2 10c14 3 24 10 24 22v52c0 9-6 14-14 14H30c-8 0-14-5-14-14V47c0-12 10-19 24-22z" fill={W} {...stroke} />
          <path d="M18 52h64M18 78h64" stroke="#a9d0ee" strokeWidth="1.5" fill="none" />
          <rect x="22" y="58" width="56" height="16" rx="4" fill={color} opacity="0.9" />
          <path d="M30 66l6-5 6 5 6-6 6 6 6-5 6 5" stroke="#fff" strokeWidth="1.6" fill="none" strokeLinejoin="round" />
        </>
      );
      break;
    case "bidon":
      body = (
        <>
          <path d="M34 10h22c4 0 6 3 6 6v6H28v-6c0-3 2-6 6-6z" fill="none" stroke={color} strokeWidth="4" />
          <rect x="44" y="18" width="12" height="8" rx="2" fill={C} />
          <path d="M26 26h48c6 0 10 5 10 11v62c0 8-5 13-13 13H29c-8 0-13-5-13-13V37c0-6 4-11 10-11z" fill={W} {...stroke} />
          <rect x="20" y="62" width="60" height="18" rx="4" fill={color} opacity="0.9" />
          <path d="M28 71l7-5 7 5 7-6 7 6 7-5 7 5" stroke="#fff" strokeWidth="1.6" fill="none" strokeLinejoin="round" />
        </>
      );
      break;
    case "bardak":
      body = (
        <>
          <ellipse cx="50" cy="34" rx="32" ry="7" fill={color} opacity="0.9" />
          <path d="M18 34l8 70c1 5 5 8 10 8h28c5 0 9-3 10-8l8-70z" fill={W} {...stroke} />
          <ellipse cx="50" cy="34" rx="32" ry="7" fill="none" stroke={color} strokeWidth="2" />
          <path d="M26 60h48" stroke="#a9d0ee" strokeWidth="1.5" />
        </>
      );
      break;
    case "soda":
      body = (
        <>
          <rect x="43" y="6" width="14" height="8" rx="2" fill={C} />
          <path d="M45 14h10v18c10 6 14 14 14 24v50c0 5-4 8-8 8H39c-4 0-8-3-8-8V56c0-10 4-18 14-24z" fill={color} opacity="0.85" />
          <path d="M45 14h10v18c10 6 14 14 14 24v50c0 5-4 8-8 8H39c-4 0-8-3-8-8V56c0-10 4-18 14-24z" fill="none" stroke="#0003" />
          <rect x="31" y="64" width="38" height="22" rx="3" fill="#fff" opacity="0.92" />
          <circle cx="50" cy="75" r="6" fill={color} opacity="0.85" />
          <path d="M38 42c2-4 5-6 8-7" stroke="#fff8" strokeWidth="3" strokeLinecap="round" fill="none" />
        </>
      );
      break;
    case "pompa":
      body = (
        <>
          <rect x="42" y="12" width="16" height="14" rx="4" fill={color} />
          <path d="M26 44c0-12 10-18 24-18s24 6 24 18v6H26z" fill="#f2f6fa" stroke="#9fb3c6" />
          <rect x="44" y="50" width="12" height="40" fill="#e6edf3" stroke="#9fb3c6" />
          <path d="M56 36h22c6 0 9 3 9 8v8" stroke={color} strokeWidth="6" fill="none" strokeLinecap="round" />
          <rect x="36" y="90" width="28" height="14" rx="3" fill={color} opacity="0.85" />
        </>
      );
      break;
    case "epompa":
      body = (
        <>
          <rect x="30" y="34" width="40" height="64" rx="12" fill="#fafcfe" stroke="#9fb3c6" />
          <rect x="48" y="40" width="20" height="52" rx="8" fill="#26303b" />
          <path d="M50 34V22h28c4 0 6 3 6 7v8" stroke="#aab6c2" strokeWidth="5" fill="none" strokeLinecap="round" />
          <circle cx="58" cy="50" r="3" fill={color} />
          <rect x="34" y="98" width="32" height="8" rx="4" fill="#cfd8e1" />
        </>
      );
      break;
    case "tup":
      body = (
        <>
          <rect x="40" y="8" width="20" height="10" rx="3" fill="#7d8a97" />
          <path d="M34 18h32v8H34z" fill="#9aa6b2" />
          <path d="M28 34c0-6 6-10 12-10h20c6 0 12 4 12 10v68c0 5-4 8-8 8H36c-4 0-8-3-8-8z" fill={color} />
          <path d="M28 54h44M28 88h44" stroke="#0002" strokeWidth="2" />
          <path d="M36 40v56" stroke="#fff5" strokeWidth="5" strokeLinecap="round" />
        </>
      );
      break;
    case "kutu":
      body = (
        <>
          <path d="M16 40l34-16 34 16v52l-34 16-34-16z" fill="#e9d6b6" stroke="#b89a6a" />
          <path d="M16 40l34 16 34-16M50 56v52" stroke="#b89a6a" fill="none" />
          <path d="M24 62l18 8v14l-18-8z" fill={color} opacity="0.85" />
        </>
      );
      break;
    default:
      body = (
        <>
          <rect x="43" y="6" width="14" height="9" rx="2" fill={C} />
          <path d="M44 15h12v8c9 4 13 11 13 19v62c0 5-4 8-8 8H39c-4 0-8-3-8-8V42c0-8 4-15 13-19z" fill={W} {...stroke} />
          <path d="M32 52h36M32 92h36" stroke="#a9d0ee" strokeWidth="1.5" />
          <rect x="31" y="60" width="38" height="22" rx="3" fill={color} opacity="0.9" />
          <path d="M37 72l5-4 5 4 5-5 5 5 5-4 4 3" stroke="#fff" strokeWidth="1.5" fill="none" strokeLinejoin="round" />
        </>
      );
  }
  return (
    <svg viewBox="0 0 100 120" className={className} role="img" aria-hidden="true">
      {water}
      {body}
    </svg>
  );
}
