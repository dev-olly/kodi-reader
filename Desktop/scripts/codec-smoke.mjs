import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const binary = resolve(process.argv[2] ?? process.env.KODI_FFMPEG_PATH ?? '');
if (!process.argv[2] && !process.env.KODI_FFMPEG_PATH) throw new Error('Supply the built FFmpeg executable path.');
const directory = mkdtempSync(join(tmpdir(), 'kodi-codec-'));
const run = (args) => {
  const result = spawnSync(binary, ['-nostdin', '-hide_banner', '-loglevel', 'error', ...args], { encoding: 'utf8', timeout: 30_000 });
  if (result.error || result.status !== 0) throw new Error(`Codec smoke check failed: ${result.error?.message ?? result.stderr}`);
};
try {
  // Exercise exactly the F32 PCM → AAC/M4A → variable-speed PCM → ASR WAV path.
  const samples = Buffer.alloc(44_100 * 4);
  for (let i = 0; i < 44_100; i++) samples.writeFloatLE(Math.sin(i * 2 * Math.PI * 440 / 44_100) * 0.15, i * 4);
  const pcm = join(directory, 'recording.f32le');
  const m4a = join(directory, 'recording.m4a');
  const decoded = join(directory, 'decoded.f32le');
  const wav = join(directory, 'transcription.wav');
  writeFileSync(pcm, samples);
  run(['-y', '-f', 'f32le', '-ar', '44100', '-ac', '1', '-i', pcm, '-c:a', 'aac', '-b:a', '64k', '-ar', '44100', '-movflags', '+faststart', m4a]);
  run(['-y', '-i', m4a, '-vn', '-af', 'atempo=1.5', '-ar', '48000', '-ac', '1', '-f', 'f32le', decoded]);
  run(['-y', '-i', m4a, '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', wav]);
  const result = readFileSync(decoded);
  if (result.length < 48_000 || result.length > 48_000 * 4) throw new Error('Variable-speed audio duration was outside expected bounds.');
  let peak = 0;
  for (let i = 0; i + 4 <= result.length; i += 4) peak = Math.max(peak, Math.abs(result.readFloatLE(i)));
  if (!Number.isFinite(peak) || peak < 0.01) throw new Error('Decoded audio was silent or invalid.');
  if (readFileSync(wav).toString('ascii', 0, 4) !== 'RIFF') throw new Error('Transcription WAV was not created.');
  console.log('AAC/M4A, local playback resampling/speed and transcription WAV smoke checks passed.');
} finally {
  rmSync(directory, { recursive: true, force: true });
}
