type ListenerTarget = Pick<Document, 'addEventListener' | 'removeEventListener'> & { defaultView?: Pick<Window, 'addEventListener' | 'removeEventListener'> | null };

/** One global listener set coordinates registered action disclosures only. */
export function createActionMenuCoordinator(target: ListenerTarget) {
  const menus = new Set<HTMLDetailsElement>();
  let current: HTMLDetailsElement | null = null;
  const contains = (menu: HTMLElement, node: EventTarget | null) => Boolean(node && typeof (node as Node).nodeType === 'number' && menu.contains(node as Node));
  const summary = (menu: HTMLDetailsElement) => menu.querySelector('summary');
  const close = (menu: HTMLDetailsElement, restoreFocus = false) => {
    menu.open = false;
    if (current === menu) current = null;
    if (restoreFocus) summary(menu)?.focus({ preventScroll: true });
  };
  const dismiss = () => { for (const menu of menus) if (menu.open) close(menu); };
  const select = (menu: HTMLDetailsElement) => {
    for (const other of menus) if (other !== menu && other.open) close(other);
    current = menu;
  };
  const outside = (event: Event) => {
    for (const menu of menus) if (menu.open && !contains(menu, event.target)) close(menu);
  };
  const click = (event: Event) => {
    const owner = [...menus].find(menu => contains(menu, event.target));
    if (!owner) { dismiss(); return; }
    const trigger = summary(owner);
    if (trigger && contains(trigger, event.target)) {
      // Handle pointer and keyboard-generated clicks uniformly, including
      // WebKit versions without native mutually exclusive details groups.
      event.preventDefault();
      if (owner.open) close(owner);
      else { select(owner); owner.open = true; trigger.focus({ preventScroll: true }); }
      return;
    }
  };
  const activate = (event: Event) => {
    const owner = [...menus].find(menu => contains(menu, event.target));
    if (!owner?.open) return;
    const node = event.target as Element | null;
    const element = node && typeof node.closest === 'function' ? node : node?.parentElement;
    const item = element && typeof element.closest === 'function' ? element.closest('button, a, [role="menuitem"]') : null;
    if (!item || !contains(owner, item)) return;
    if ((item as HTMLButtonElement).disabled || item.getAttribute('aria-disabled') === 'true') return;
    // React handles the item's click at its root before document bubbling.
    // Hiding it during capture can cancel activation in WebKit. Restore the
    // trigger only if the callback has not moved focus into a new dialog.
    close(owner, contains(owner, owner.ownerDocument.activeElement));
  };
  const keydown = (event: Event) => {
    const key = event as KeyboardEvent;
    if (key.key !== 'Escape') return;
    const menu = current?.open ? current : [...menus].find(candidate => candidate.open);
    if (!menu) return;
    key.preventDefault(); key.stopPropagation(); close(menu, true);
  };
  const toggle = (event: Event) => {
    const menu = event.target as HTMLDetailsElement;
    if (!menus.has(menu)) return;
    if (menu.open) select(menu);
    else if (current === menu) current = null;
  };
  const listeners = { pointerdown: outside, click, keydown, toggle, focusin: outside };
  const windowBlur = (event: Event) => { if (event.target === target.defaultView) dismiss(); };
  const listen = (enabled: boolean) => {
    for (const [name, handler] of Object.entries(listeners)) {
      if (enabled) target.addEventListener(name, handler, true);
      else target.removeEventListener(name, handler, true);
    }
    if (enabled) {
      target.addEventListener('click', activate, false);
      target.defaultView?.addEventListener('blur', windowBlur, false);
    } else {
      target.removeEventListener('click', activate, false);
      target.defaultView?.removeEventListener('blur', windowBlur, false);
    }
  };
  return {
    dismiss,
    register(menu: HTMLDetailsElement) {
      if (menus.has(menu)) return () => {};
      if (!menus.size) listen(true);
      menus.add(menu);
      if (menu.open) select(menu);
      let registered = true;
      return () => {
        if (!registered) return;
        registered = false;
        close(menu); menus.delete(menu);
        if (!menus.size) listen(false);
      };
    },
  };
}

const coordinators = new WeakMap<Document, ReturnType<typeof createActionMenuCoordinator>>();
export function registerActionMenu(menu: HTMLDetailsElement): () => void {
  let coordinator = coordinators.get(menu.ownerDocument);
  if (!coordinator) { coordinator = createActionMenuCoordinator(menu.ownerDocument); coordinators.set(menu.ownerDocument, coordinator); }
  return coordinator.register(menu);
}
