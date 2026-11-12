import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizePoint, pdfPoint, quadForRect, boundsForQuad } from '../public/pdf-viewer/geometry.js';

test('PDF anchors use the unrotated CropBox, including nonzero origins', () => {
  const crop = [20, 30, 220, 430];
  assert.deepEqual(normalizePoint([20, 430], crop), [0, 0]);
  assert.deepEqual(normalizePoint([220, 30], crop), [1, 1]);
  assert.deepEqual(pdfPoint([.25, .75], crop), [70, 130]);
  assert.deepEqual(normalizePoint(pdfPoint([.25, .75], crop), crop), [.25, .75]);
});
test('rotated selection geometry survives a viewport scale change', () => {
  const crop = [20, 30, 220, 430];
  // 90° clockwise at scale 2, with the PDF page translated to viewport origin.
  const rotated = { convertToPdfPoint: (x, y) => [20 + y / 2, 30 + x / 2], convertToViewportPoint: (x, y) => [(y - 30) * 2, (x - 20) * 2] };
  const quad = quadForRect({ left: 150, right: 250, top: 100, bottom: 140 }, { left: 50, top: 60, width: 800, height: 400 }, rotated, crop);
  const halfSize = { convertToViewportPoint: (x, y) => [y - 30, x - 20] };
  assert.deepEqual(boundsForQuad(quad, halfSize, crop), { left: 50, top: 20, width: 50, height: 20 });
});
test('selection rectangles are clipped to their page in two-page spreads', () => {
  const viewport = { convertToPdfPoint: (x, y) => [x, 100 - y], convertToViewportPoint: (x, y) => [x, 100 - y] };
  assert.equal(quadForRect({ left: 210, right: 250, top: 20, bottom: 30 }, { left: 0, top: 0, width: 100, height: 100 }, viewport, [0, 0, 100, 100]), null);
  const quad = quadForRect({ left: 90, right: 150, top: 20, bottom: 30 }, { left: 0, top: 0, width: 100, height: 100 }, viewport, [0, 0, 100, 100]);
  const result = boundsForQuad(quad, viewport, [0, 0, 100, 100]);
  assert.ok(Math.abs(result.left - 90) < 1e-9 && Math.abs(result.width - 10) < 1e-9);
});
test('invalid PDF geometry is rejected instead of painting an unrelated region', () => {
  assert.equal(boundsForQuad([0, 0, NaN, 1, 1, 1, 0, 1], {}, [0, 0, 100, 100]), null);
  assert.equal(boundsForQuad([0, 0], {}, [0, 0, 100, 100]), null);
  assert.throws(() => normalizePoint([0, 0], [0, 0, 0, 100]), /CropBox/);
});
