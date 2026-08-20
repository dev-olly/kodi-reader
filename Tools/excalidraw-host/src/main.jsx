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
