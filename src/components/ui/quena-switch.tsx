import styles from "./quena-switch.module.css";

type QuenaSwitchProps = {
  label: string;
  checked: boolean;
  onCheckedChange: (checked: boolean) => void;
  disabled?: boolean;
};

export function QuenaSwitch({ label, checked, onCheckedChange, disabled = false }: QuenaSwitchProps) {
  return (
    <button
      aria-checked={checked}
      aria-label={label}
      className={styles.switch}
      data-state={checked ? "on" : "off"}
      disabled={disabled}
      onClick={() => onCheckedChange(!checked)}
      role="switch"
      type="button"
    >
      <span aria-hidden="true" className={styles.knob} />
    </button>
  );
}
