import { useEffect, useLayoutEffect, useRef, useState } from "react";

export interface MenuItem {
  label: string;
  onPick: () => void;
  danger?: boolean;
  hint?: string;
  /** A section label drawn above this item. */
  heading?: string;
}

interface Props {
  x: number;
  y: number;
  title: string;
  items: MenuItem[];
  onClose: () => void;
}

export default function ContextMenu({ x, y, title, items, onClose }: Props) {
  const ref = useRef<HTMLDivElement>(null);

  // Anything that is not a pick closes it, including Escape and a scroll of
  // the canvas underneath.
  useEffect(() => {
    const away = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) onClose();
    };
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("mousedown", away);
    window.addEventListener("keydown", key);
    window.addEventListener("wheel", onClose, { passive: true });
    return () => {
      window.removeEventListener("mousedown", away);
      window.removeEventListener("keydown", key);
      window.removeEventListener("wheel", onClose);
    };
  }, [onClose]);

  // Keep the menu on screen when it was opened near an edge.  The height is
  // measured after the first paint rather than guessed from the item count,
  // because a section label is taller than a row.
  const [shift, setShift] = useState(0);
  useLayoutEffect(() => {
    const box = ref.current?.getBoundingClientRect();
    if (box) setShift(Math.min(0, window.innerHeight - 8 - box.bottom));
  }, [items]);

  return (
    <div
      className="ctxmenu"
      style={{ left: Math.min(x, window.innerWidth - 200), top: y + shift }}
      ref={ref}
    >
      <div className="ctxmenu-title">{title}</div>
      {items.map((item) => (
        <div key={item.label}>
          {item.heading && <div className="ctxmenu-section">{item.heading}</div>}
          <button
            className={item.danger ? "danger" : ""}
            onClick={() => {
              item.onPick();
              onClose();
            }}
          >
            <span>{item.label}</span>
            {item.hint && <span className="ctxmenu-hint">{item.hint}</span>}
          </button>
        </div>
      ))}
    </div>
  );
}
