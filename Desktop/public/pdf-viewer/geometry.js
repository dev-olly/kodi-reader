// Normalized, unrotated CropBox coordinates: origin top-left, x right, y down.
export function normalizePoint(point, pageView) {
  const [minX, minY, maxX, maxY] = pageView;
  if (maxX <= minX || maxY <= minY) throw new Error('Invalid PDF CropBox');
  return [Math.min(1, Math.max(0, (point[0] - minX) / (maxX - minX))), Math.min(1, Math.max(0, (maxY - point[1]) / (maxY - minY)))];
}
export function pdfPoint(normalized, pageView) {
  const [minX, minY, maxX, maxY] = pageView;
  return [minX + normalized[0] * (maxX - minX), maxY - normalized[1] * (maxY - minY)];
}
export function quadForRect(rect, box, viewport, pageView) {
  const x0 = Math.max(0, rect.left - box.left); const x1 = Math.min(box.width, rect.right - box.left);
  const y0 = Math.max(0, rect.top - box.top); const y1 = Math.min(box.height, rect.bottom - box.top);
  if (x1 <= x0 || y1 <= y0) return null;
  return [[x0, y0], [x1, y0], [x1, y1], [x0, y1]].flatMap(([x, y]) => normalizePoint(viewport.convertToPdfPoint(x, y), pageView));
}
export function boundsForQuad(quad, viewport, pageView) {
  const values = Array.isArray(quad) ? quad : quad?.points;
  if (!Array.isArray(values) || values.length !== 8 || !values.every(Number.isFinite)) return null;
  const points = [0, 2, 4, 6].map(offset => viewport.convertToViewportPoint(...pdfPoint([values[offset], values[offset + 1]], pageView)));
  const xs = points.map(point => point[0]); const ys = points.map(point => point[1]);
  return { left: Math.min(...xs), top: Math.min(...ys), width: Math.max(...xs) - Math.min(...xs), height: Math.max(...ys) - Math.min(...ys) };
}
