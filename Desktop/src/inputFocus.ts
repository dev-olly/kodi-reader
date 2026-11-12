/** WebKit on macOS does not always focus a range input when clicked. */
export function focusRangeControl(event: { currentTarget: HTMLInputElement }): void {
  if (!event.currentTarget.disabled) event.currentTarget.focus({ preventScroll: true });
}

export function ownsKeyboardInput(target: EventTarget | null): boolean {
  const element = target as HTMLElement | null;
  return Boolean(element && typeof element.matches === 'function' &&
    (element.matches('input, textarea, select') || element.isContentEditable));
}
