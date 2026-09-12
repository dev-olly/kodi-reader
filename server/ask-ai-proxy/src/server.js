import http from "node:http";

const PORT = Number(process.env.PORT || 8080);
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || "";
const OPENAI_MODEL = process.env.OPENAI_MODEL || "gpt-5.6-terra";
const MAX_BODY_BYTES = Number(process.env.MAX_BODY_BYTES || 256 * 1024);
const RATE_LIMIT_WINDOW_MS = Number(process.env.RATE_LIMIT_WINDOW_MS || 60 * 60 * 1000);
const RATE_LIMIT_REQUESTS = Number(process.env.RATE_LIMIT_REQUESTS || 60);

const buckets = new Map();

function json(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

function clientIP(req) {
  const forwarded = req.headers["fly-client-ip"] || req.headers["x-forwarded-for"] || req.socket.remoteAddress || "unknown";
  return String(forwarded).split(",")[0].trim();
}

function rateLimit(req) {
  const now = Date.now();
  const key = clientIP(req);
  const current = buckets.get(key);
  if (!current || current.resetAt <= now) {
    buckets.set(key, { count: 1, resetAt: now + RATE_LIMIT_WINDOW_MS });
    return null;
  }
  current.count += 1;
  if (current.count <= RATE_LIMIT_REQUESTS) return null;
  return Math.ceil((current.resetAt - now) / 1000);
}

function pruneBuckets() {
  const now = Date.now();
  for (const [key, bucket] of buckets) {
    if (bucket.resetAt <= now) buckets.delete(key);
  }
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      const error = new Error("Request body is too large.");
      error.status = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function openAIHeaders() {
  return {
    authorization: `Bearer ${OPENAI_API_KEY}`,
    "content-type": "application/json",
    accept: "text/event-stream",
  };
}

function sanitizePayload(payload) {
  if (!payload || !Array.isArray(payload.messages)) {
    const error = new Error("Expected a chat completions payload with a messages array.");
    error.status = 400;
    throw error;
  }
  const sanitized = {
    model: OPENAI_MODEL,
    messages: payload.messages,
    stream: true,
  };
  if (typeof payload.temperature === "number") {
    sanitized.temperature = payload.temperature;
  }
  return sanitized;
}

async function proxyChatCompletions(req, res) {
  if (!OPENAI_API_KEY) {
    json(res, 503, { error: { message: "Ask AI is not configured on the server." } });
    return;
  }

  const retryAfter = rateLimit(req);
  if (retryAfter) {
    res.setHeader("retry-after", String(retryAfter));
    json(res, 429, { error: { message: "Ask AI is busy. Please try again later." } });
    return;
  }

  let payload;
  try {
    payload = sanitizePayload(JSON.parse(await readBody(req)));
  } catch (error) {
    json(res, error.status || 400, { error: { message: error.message } });
    return;
  }

  const upstream = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: openAIHeaders(),
    body: JSON.stringify(payload),
  });

  res.writeHead(upstream.status, {
    "content-type": upstream.headers.get("content-type") || "text/event-stream; charset=utf-8",
    "cache-control": "no-cache, no-transform",
    connection: "keep-alive",
  });

  if (!upstream.body) {
    res.end();
    return;
  }

  const reader = upstream.body.getReader();
  req.on("close", () => reader.cancel().catch(() => {}));
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      res.write(value);
    }
  } finally {
    res.end();
  }
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url === "/health") {
      json(res, 200, { ok: true, model: OPENAI_MODEL });
      return;
    }
    if (req.method === "POST" && req.url === "/v1/chat/completions") {
      await proxyChatCompletions(req, res);
      return;
    }
    json(res, 404, { error: { message: "Not found." } });
  } catch (error) {
    console.error("request failed", { message: error.message });
    if (!res.headersSent) {
      json(res, 500, { error: { message: "Ask AI failed." } });
    } else {
      res.end();
    }
  }
});

setInterval(pruneBuckets, RATE_LIMIT_WINDOW_MS).unref();

server.on("error", (error) => {
  console.error("server failed to start", { message: error.message });
  process.exitCode = 1;
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Kodi Reader Ask AI proxy listening on ${PORT}`);
});
