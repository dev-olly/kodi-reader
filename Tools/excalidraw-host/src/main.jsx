import React, { useCallback, useRef } from "react";
import { createRoot } from "react-dom/client";
import { CaptureUpdateAction, Excalidraw } from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import "./host.css";

const apiRef = { current: null };
const themeRef = { current: "light" };
const applyingRef = { current: false };

function post(body) {
  const handler = window.webkit?.messageHandlers?.excalidraw;
  if (handler) {
    handler.postMessage(body);
  }
}

function serialize(api) {
  const elements = api.getSceneElements();
  const appState = api.getAppState();
  const files = api.getFiles();
  const scene = {
    type: "excalidraw",
    version: 2,
    elements,
    appState: {
      viewBackgroundColor: appState.viewBackgroundColor,
      gridSize: appState.gridSize,
      theme: appState.theme,
    },
    files,
  };
  return { elementCount: elements.length, scene: JSON.stringify(scene) };
}

function applyScene(parsed) {
  const api = apiRef.current;
  if (!api) return;
  applyingRef.current = true;
  api.updateScene({
    elements: parsed.elements ?? [],
    appState: { ...(parsed.appState ?? {}), theme: themeRef.current },
    captureUpdate: CaptureUpdateAction.NEVER,
  });
  const files = parsed.files ? Object.values(parsed.files) : [];
  if (files.length) {
    api.addFiles(files);
  }
  queueMicrotask(() => {
    applyingRef.current = false;
  });
}

window.__excalidraw = {
  load(scene) {
    const parsed = typeof scene === "string" ? JSON.parse(scene) : scene;
    applyScene(parsed);
  },
  setTheme(theme) {
    themeRef.current = theme === "dark" ? "dark" : "light";
    const api = apiRef.current;
    if (!api) return;
    applyingRef.current = true;
    api.updateScene({
      appState: { theme: themeRef.current },
      captureUpdate: CaptureUpdateAction.NEVER,
    });
    queueMicrotask(() => {
      applyingRef.current = false;
    });
  },
  clear() {
    applyScene({ elements: [], appState: {}, files: {} });
  },
  getScene() {
    const api = apiRef.current;
    if (!api) {
      return { elementCount: 0, scene: "{\"elements\":[],\"files\":{}}" };
    }
    return serialize(api);
  },
};

function Host() {
  const timerRef = useRef(null);

  const handleAPI = useCallback((api) => {
    apiRef.current = api;
    post({ type: "ready" });
  }, []);

  return (
    <div style={{ width: "100%", height: "100%" }}>
      <Excalidraw
        excalidrawAPI={handleAPI}
        theme={themeRef.current}
        UIOptions={{
          welcomeScreen: false,
          canvasActions: {
            loadScene: false,
            export: false,
            saveToActiveFile: false,
            toggleTheme: false,
            clearCanvas: true,
          },
        }}
        onChange={(elements) => {
          if (applyingRef.current) return;
          if (timerRef.current) window.clearTimeout(timerRef.current);
          timerRef.current = window.setTimeout(() => {
            post({ type: "sceneChanged", elementCount: elements.length });
          }, 300);
        }}
      />
    </div>
  );
}

window.addEventListener("error", (event) => {
  post({ type: "error", message: String(event.message || event.error || "error") });
});

createRoot(document.getElementById("root")).render(<Host />);
