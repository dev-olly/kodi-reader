export interface AudioPlaybackStatus {
  path?: string | null; phase?: string; cancelled?: boolean; paused?: boolean;
  position?: number; elapsed?: number; duration?: number;
}
export interface AudioCardPlayback { active: boolean; paused: boolean; position: number; duration: number }
export function audioCardPlayback(path: string | undefined, status: AudioPlaybackStatus): AudioCardPlayback {
  const finite = (value: unknown) => typeof value === 'number' && Number.isFinite(value) ? Math.max(0, value) : 0;
  const duration = finite(status.duration);
  const position = Math.min(finite(status.position ?? status.elapsed), duration || Number.MAX_SAFE_INTEGER);
  const matching = Boolean(path) && status.path === path && status.cancelled !== true;
  const paused = status.phase === 'paused' || status.paused === true;
  const active = matching && (status.phase === 'playing' || status.phase === 'paused' || (!status.phase && duration > 0 && position < duration));
  return { active, paused: active && paused, position: active ? position : 0, duration: matching ? duration : 0 };
}
