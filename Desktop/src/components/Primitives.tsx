import { useEffect, useLayoutEffect, useRef, type ButtonHTMLAttributes, type ReactNode } from 'react';
import { LoaderCircle, X } from 'lucide-react';
import { registerActionMenu } from '../actionMenus';

export function ActionMenu({ label, trigger, children, className = 'inline-menu' }: { label: string; trigger: ReactNode; children: ReactNode; className?: string }) {
  const menu = useRef<HTMLDetailsElement>(null);
  useLayoutEffect(() => menu.current ? registerActionMenu(menu.current) : undefined, []);
  return <details ref={menu} className={className}><summary aria-label={label}>{trigger}</summary><div className="menu-popover">{children}</div></details>;
}

export function IconButton({ label, children, active, ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { label: string; children: ReactNode; active?: boolean }) {
  return <button className={`icon-button${active ? ' active' : ''}`} title={label} aria-label={label} aria-pressed={active === undefined ? undefined : active} {...props}>{children}</button>;
}
export function EmptyState({ icon, title, children, action }: { icon: ReactNode; title: string; children: ReactNode; action?: ReactNode }) {
  return <div className="empty-state"><div className="empty-icon">{icon}</div><h2>{title}</h2><div className="empty-description">{children}</div>{action}</div>;
}
export function Spinner({ label = 'Loading…' }: { label?: string }) { return <span className="loading" role="status"><LoaderCircle className="spin" size={18} />{label}</span>; }
export function Modal({ title, children, onClose, wide = false }: { title: string; children: ReactNode; onClose: () => void; wide?: boolean }) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const element = dialog.current;
    const previouslyFocused = document.activeElement as HTMLElement | null;
    element?.showModal();
    return () => { element?.close(); previouslyFocused?.focus(); };
  }, []);
  return <dialog ref={dialog} className={`modal${wide ? ' modal-wide' : ''}`} onCancel={event => { event.preventDefault(); onClose(); }} onClick={event => { if (event.target === dialog.current) onClose(); }}>
    <div className="modal-header"><h2>{title}</h2><IconButton label="Close dialog" onClick={onClose}><X size={19} /></IconButton></div>{children}
  </dialog>;
}
