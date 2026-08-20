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
