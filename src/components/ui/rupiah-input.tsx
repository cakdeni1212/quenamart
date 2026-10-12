"use client";

import { useEffect, useRef, useState, type InputHTMLAttributes } from "react";
import { formatRupiahInput, parseRupiahInput } from "@/lib/money";

type Props = Omit<InputHTMLAttributes<HTMLInputElement>, "value" | "defaultValue" | "onChange" | "type"> & {
  value: string;
  onValueChange: (value: string) => void;
  name?: string;
  currencyPrefix?: boolean;
};

function caretAfterDigits(value: string, digitCount: number) {
  if (digitCount <= 0) return 0;
  let seen = 0;
  for (let i = 0; i < value.length; i += 1) {
    if (/\d/.test(value[i])) seen += 1;
    if (seen === digitCount) return i + 1;
  }
  return value.length;
}

export function RupiahInput({ value, onValueChange, name, currencyPrefix = true, className, ...props }: Props) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [draft, setDraft] = useState(() => formatRupiahInput(value));
  const lastEmitted = useRef<string | null>(null);

  useEffect(() => {
    if (lastEmitted.current === value) {
      lastEmitted.current = null;
      return;
    }
    setDraft(formatRupiahInput(value));
  }, [value]);

  function handleChange(next: string, selectionStart: number | null) {
    const digitsBeforeCaret = next.slice(0, selectionStart ?? next.length).replace(/\D/g, "").length;
    const canonical = parseRupiahInput(next);
    if (canonical !== null) {
      lastEmitted.current = canonical;
      onValueChange(canonical);
      const formatted = formatRupiahInput(canonical);
      setDraft(formatted);
      requestAnimationFrame(() => {
        const input = inputRef.current;
        if (!input) return;
        const caret = caretAfterDigits(formatted, digitsBeforeCaret);
        input.setSelectionRange(caret, caret);
      });
      return;
    }

    // Keep a trailing decimal separator editable while the user enters cents.
    const incomplete = next.replace(/^rp\s*/i, "").replace(/[^\d.,\s]/g, "").replace(/[\s\u00a0]/g, "");
    const trailingSeparator = /[,\.]$/.test(incomplete);
    if (trailingSeparator) {
      const base = parseRupiahInput(incomplete.slice(0, -1));
      if (base !== null) {
        lastEmitted.current = base;
        onValueChange(base);
        const formatted = `${formatRupiahInput(base)},`;
        setDraft(formatted);
        requestAnimationFrame(() => {
          const input = inputRef.current;
          if (input) input.setSelectionRange(formatted.length, formatted.length);
        });
        return;
      }
    }
    setDraft(incomplete);
    if (!incomplete) {
      lastEmitted.current = "";
      onValueChange("");
    }
  }

  return <span className={`rupiah-input${className ? ` ${className}` : ""}`}>
    {currencyPrefix && <span aria-hidden="true">Rp</span>}
    <input {...props} ref={inputRef} type="text" inputMode="decimal" autoComplete="off" value={draft}
      onChange={(event) => handleChange(event.currentTarget.value, event.currentTarget.selectionStart)} />
    {name && <input type="hidden" name={name} value={value} />}
  </span>;
}
