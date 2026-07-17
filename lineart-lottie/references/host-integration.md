# Consuming the Lottie in a React app

A drop-in `lottie-react` host that plays **draw-on → seamless breath** and honors
**`prefers-reduced-motion`**. This is the shipped NEM pattern (empty-state heart),
generalized. Web uses `lottie-react` (`^2.4.1`, wraps `lottie-web`); RN uses
`lottie-react-native` with the same JSON + `playSegments`.

> **Why the host must handle reduced-motion:** a design-system global CSS
> reduced-motion kill-switch (`animation-duration: 0.01ms`) does **not** stop a
> JS/SVG Lottie — `lottie-web` drives frames via `requestAnimationFrame`, not CSS.
> So the host renders a static, fully-drawn **poster** when the user prefers
> reduced motion.

## The pure plan helper

Derives the poster frame + idle segment from the Lottie's markers — pure, unit-testable, no DOM.

```ts
// lineArtPlan.ts
export interface LineArtPlan {
  op: number;
  idle: number;
  posterFrame: number;
  idleSegment: [number, number];
}
interface LottieLike { op?: number; markers?: Array<{ cm?: string; tm?: number }> }

export function lineArtPlan(data: LottieLike): LineArtPlan {
  const op = typeof data.op === "number" ? data.op : 1;
  const idleMarker = data.markers?.find((m) => m.cm === "idle");
  const idle = typeof idleMarker?.tm === "number" ? idleMarker.tm : 0;
  return { op, idle, posterFrame: Math.max(0, op - 1), idleSegment: [idle, op] };
}
```

## The component

```tsx
// LineArtMark.tsx
import { useEffect, useRef, useState } from "react";
import Lottie, { type LottieRefCurrentProps } from "lottie-react";
import { lineArtPlan } from "./lineArtPlan";

const REDUCE_QUERY = "(prefers-reduced-motion: reduce)";

// Local matchMedia hook — kept off framer-motion so the mark doesn't depend on
// framer-motion being mocked in unit tests, and reads the OS setting directly.
function usePrefersReducedMotion(): boolean {
  const [reduced, setReduced] = useState(
    () => typeof window !== "undefined" && !!window.matchMedia?.(REDUCE_QUERY)?.matches,
  );
  useEffect(() => {
    const mql = window.matchMedia?.(REDUCE_QUERY);
    if (!mql) return;
    const onChange = () => setReduced(mql.matches);
    mql.addEventListener?.("change", onChange);
    return () => mql.removeEventListener?.("change", onChange);
  }, []);
  return reduced;
}

export function LineArtMark({
  animationData,
  className,
  loop = true,
}: {
  animationData: unknown;
  className?: string;
  loop?: boolean;
}) {
  const ref = useRef<LottieRefCurrentProps>(null);
  const reducedMotion = usePrefersReducedMotion();
  const plan = lineArtPlan(animationData as Parameters<typeof lineArtPlan>[0]);

  // Honor reduced-motion toggled AFTER mount (flipping `autoplay` won't stop an
  // already-playing instance); also a backstop for the onDOMLoaded poster seek.
  useEffect(() => {
    const player = ref.current;
    if (!player) return;
    if (reducedMotion) player.goToAndStop(plan.posterFrame, true);
    else player.play();
  }, [reducedMotion, plan.posterFrame]);

  return (
    <Lottie
      lottieRef={ref}
      animationData={animationData}
      loop={false}
      autoplay={!reducedMotion}
      onDOMLoaded={() => {
        if (reducedMotion) ref.current?.goToAndStop(plan.posterFrame, true);
      }}
      onComplete={() => {
        if (!reducedMotion && loop) ref.current?.playSegments(plan.idleSegment, true);
      }}
      className={className}
      aria-hidden
    />
  );
}
```

Usage: `<LineArtMark animationData={leaf} className="w-28 h-28" />` (import the
JSON directly; Vite/webpack inline it). `loop={false}` = draw on once and stop.

## Testing notes

- Add a **global** `lottie-react` stub in test-setup so components that render it
  don't need a canvas: `vi.mock("lottie-react", () => ({ __esModule:true, default: () => null }))`.
- For the component's own tests, mock `lottie-react` **locally** to (a) capture the
  props and (b) assign a stub `{goToAndStop, playSegments, play}` to the passed
  `lottieRef`, then drive `props.onDOMLoaded()` / `props.onComplete()` and assert:
  autoplay true when motion allowed; `goToAndStop(posterFrame, true)` under reduced
  motion; `playSegments(idleSegment, true)` on complete only when motion allowed.
- Toggle reduced motion by stubbing `window.matchMedia` to return `{ matches }`.

## Bundle

Each motif JSON is ~4–40 KB and inlines into the bundle when imported. For a large
set shown rarely (e.g. an empty state), consider a dynamic `import()` so the JSON
only loads when the mark renders.
