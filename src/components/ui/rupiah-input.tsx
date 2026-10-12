"use client";

import { useEffect, useRef, useState, type InputHTMLAttributes } from "react";
import { editRupiahInput, formatRupiahInput } from "@/lib/money";

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
    const edit = editRupiahInput(next);
    setDraft(edit.display);
    if (edit.canonical !== null) {
      lastEmitted.current = edit.canonical;
      onValueChange(edit.canonical);
      requestAnimationFrame(() => {
        const input = inputRef.current;
        if (!input) return;
        const caret = edit.incomplete ? edit.display.length : caretAfterDigits(edit.display, digitsBeforeCaret);
        input.setSelectionRange(caret, caret);
      });
    } else if (edit.display === "") {
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
