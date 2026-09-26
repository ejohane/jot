import { useEffect, useRef, useState } from "react";

// A short grace period lets the cursor pause without making the controls flicker.
const idleDelay = 1500;

export function usePointerActivity() {
  const [active, setActive] = useState(false);
  const timer = useRef<number | undefined>(undefined);
  const clearTimer = () => {
    window.clearTimeout(timer.current);
    timer.current = undefined;
  };
  const hide = () => {
    clearTimer();
    setActive(false);
  };
  const reveal = () => {
    clearTimer();
    setActive(true);
    timer.current = window.setTimeout(hide, idleDelay);
  };

  useEffect(() => {
    const onVisibility = () => { if (document.hidden) hide(); };
    window.addEventListener("blur", hide);
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      clearTimer();
      window.removeEventListener("blur", hide);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, []);

  return { active, reveal, hide };
}
