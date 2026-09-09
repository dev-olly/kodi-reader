import React, { useCallback, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  CaptureUpdateAction,
  Excalidraw,
  convertToExcalidrawElements,
} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import "./host.css";

const apiRef = { current: null };
const themeRef = { current: "light" };
const applyingRef = { current: false };
const loadVersionRef = { current: 0 };
const loadedOnceRef = { current: false };

const DEFAULTS = {
  strokeColor: "#245744",
  backgroundColor: "#E1EDDB",
  fillStyle: "solid",
  strokeWidth: 2,
  roughness: 0,
  roundness: { type: 3 },
  fontFamily: 1,
  fontSize: 24,
};

const SIMPLE_TOOLS = [
  { id: "selection", label: "Select" },
  { id: "hand", label: "Pan" },
  { id: "freedraw", label: "Pen" },
  { id: "rectangle", label: "Rectangle" },
  { id: "ellipse", label: "Ellipse" },
  { id: "arrow", label: "Connector" },
  { id: "text", label: "Text" },
];

const COLOR_SWATCHES = [
  { id: "green", label: "Green fill", backgroundColor: "#E1EDDB", strokeColor: "#245744" },
  { id: "yellow", label: "Yellow fill", backgroundColor: "#FFF2C1", strokeColor: "#245744" },
  { id: "ink", label: "Ink only", backgroundColor: "transparent", strokeColor: "#245744" },
  { id: "connector", label: "Connector green", backgroundColor: "transparent", strokeColor: "#648676" },
];

function post(body) {
  const handler = window.webkit?.messageHandlers?.excalidraw;
  if (handler) {
    handler.postMessage(body);
  }
}

function serialize(api) {
  const elements = api.getSceneElementsIncludingDeleted();
  const appState = api.getAppState();
  const files = api.getFiles();
  const scene = {
    type: "excalidraw",
    version: 2,
    elements,
    appState: serializeAppState(appState),
    files,
  };
  return {
    elementCount: api.getSceneElements().filter((element) => !element.isDeleted).length,
    scene: JSON.stringify(scene),
  };
}

function serializeAppState(appState) {
  const transientKeys = new Set([
    "collaborators",
    "contextMenu",
    "editingElement",
    "editingFrame",
    "editingLinearElement",
    "editingTextElement",
    "errorMessage",
    "openDialog",
    "openMenu",
    "openPopup",
    "pendingImageElementId",
    "resizingElement",
    "selectionElement",
    "suggestedBindings",
    "toast",
  ]);
  const output = {};
  Object.entries(appState).forEach(([key, value]) => {
    if (transientKeys.has(key)) return;
    if (typeof value === "function") return;
    if (value instanceof Map || value instanceof Set) return;
    output[key] = value;
  });
  output.theme = appState.theme;
  return output;
}

function applyScene(parsed) {
  const api = apiRef.current;
  if (!api) return;
  const version = ++loadVersionRef.current;
  applyingRef.current = true;
  const files = parsed.files ? Object.values(parsed.files) : [];
  if (files.length) {
    api.addFiles(files);
  }
  api.updateScene({
    elements: parsed.elements ?? [],
    appState: {
      ...(parsed.appState ?? {}),
      theme: themeRef.current,
      ...defaultsForScene(parsed),
    },
    captureUpdate: CaptureUpdateAction.NEVER,
  });
  queueMicrotask(() => {
    if (loadVersionRef.current !== version) return;
    applyingRef.current = false;
  });
}

function defaultsForScene(parsed) {
  const hasElements = (parsed.elements ?? []).some((element) => !element.isDeleted);
  const existingAppState = parsed.appState ?? {};
  if (hasElements) return {};
  return {
    currentItemStrokeColor: existingAppState.currentItemStrokeColor ?? DEFAULTS.strokeColor,
    currentItemBackgroundColor:
      existingAppState.currentItemBackgroundColor ?? DEFAULTS.backgroundColor,
    currentItemFillStyle: existingAppState.currentItemFillStyle ?? DEFAULTS.fillStyle,
    currentItemStrokeWidth: existingAppState.currentItemStrokeWidth ?? DEFAULTS.strokeWidth,
    currentItemRoughness: existingAppState.currentItemRoughness ?? DEFAULTS.roughness,
    currentItemRoundness: existingAppState.currentItemRoundness ?? DEFAULTS.roundness,
    currentItemFontFamily: existingAppState.currentItemFontFamily ?? DEFAULTS.fontFamily,
    currentItemFontSize: existingAppState.currentItemFontSize ?? DEFAULTS.fontSize,
    viewBackgroundColor:
      existingAppState.viewBackgroundColor === undefined
        ? "#ffffff"
        : existingAppState.viewBackgroundColor,
  };
}

function setCurrentStyle(style) {
  const api = apiRef.current;
  if (!api) return;
  api.updateScene({
    appState: style,
    captureUpdate: CaptureUpdateAction.NEVER,
  });
}

function clickNativeAction(selector) {
  const button = document.querySelector(selector);
  if (button instanceof HTMLButtonElement && !button.disabled) {
    button.click();
    return true;
  }
  return false;
}

function makeTemplateElements() {
  const leftId = `kodi_attention_${crypto.randomUUID()}`;
  const rightId = `kodi_noticing_${crypto.randomUUID()}`;
  return convertToExcalidrawElements(
    [
      {
        id: leftId,
        type: "rectangle",
        x: -260,
        y: -70,
        width: 190,
        height: 96,
        strokeColor: DEFAULTS.strokeColor,
        backgroundColor: "#E1EDDB",
        fillStyle: "solid",
        strokeWidth: 2,
        roughness: 0,
        roundness: { type: 3 },
        label: {
          text: "attention",
          fontFamily: 1,
          fontSize: 24,
          strokeColor: "#1f3329",
        },
      },
      {
        id: rightId,
        type: "rectangle",
        x: 80,
        y: 30,
        width: 190,
        height: 96,
        strokeColor: DEFAULTS.strokeColor,
        backgroundColor: "#FFF2C1",
        fillStyle: "solid",
        strokeWidth: 2,
        roughness: 0,
        roundness: { type: 3 },
        label: {
          text: "noticing",
          fontFamily: 1,
          fontSize: 24,
          strokeColor: "#1f3329",
        },
      },
      {
        type: "arrow",
        x: -50,
        y: -6,
        width: 120,
        height: 72,
        strokeColor: "#648676",
        backgroundColor: "transparent",
        fillStyle: "solid",
        strokeWidth: 2,
        roughness: 0,
        startArrowhead: null,
        endArrowhead: "arrow",
        start: { id: leftId },
        end: { id: rightId },
        label: {
          text: "a new perspective",
          fontFamily: 1,
          fontSize: 18,
          strokeColor: "#245744",
        },
      },
    ],
    { regenerateIds: false },
  );
}

function Icon({ name }) {
  const common = {
    "aria-hidden": "true",
    fill: "none",
    focusable: "false",
    stroke: "currentColor",
    strokeLinecap: "round",
    strokeLinejoin: "round",
    strokeWidth: 1.8,
    viewBox: "0 0 24 24",
  };

  switch (name) {
    case "selection":
      return (
        <svg {...common}>
          <path d="M5 3.5 18.5 12 13 14l-2.3 5.5L5 3.5Z" />
          <path d="m13.2 14.2 3.8 3.8" />
        </svg>
      );
    case "hand":
      return (
        <svg {...common}>
          <path d="M8 12V7.5a1.5 1.5 0 0 1 3 0V12" />
          <path d="M11 11V6.5a1.5 1.5 0 0 1 3 0V12" />
          <path d="M14 11.5V8a1.5 1.5 0 0 1 3 0v6.5a6 6 0 0 1-11.2 3L4 14.2a1.7 1.7 0 0 1 2.9-1.7L8 14" />
        </svg>
      );
    case "freedraw":
      return (
        <svg {...common}>
          <path d="M4 17.5c3.8-6.6 5.8 2.6 9-1.2 1.5-1.8 2.3-4.3 6.5-7" />
          <path d="m17.3 5.8 2.9 2.9" />
          <path d="m15.8 10.2 3-3a1.2 1.2 0 0 1 1.7 0l.3.3a1.2 1.2 0 0 1 0 1.7l-3 3" />
        </svg>
      );
    case "rectangle":
      return (
        <svg {...common}>
          <rect x="5" y="6" width="14" height="12" rx="1.5" />
        </svg>
      );
    case "ellipse":
      return (
        <svg {...common}>
          <ellipse cx="12" cy="12" rx="7" ry="5" />
        </svg>
      );
    case "arrow":
      return (
        <svg {...common}>
          <path d="M5 17 17 5" />
          <path d="M10 5h7v7" />
        </svg>
      );
    case "text":
      return (
        <svg {...common}>
          <path d="M5 6h14" />
          <path d="M12 6v12" />
          <path d="M9 18h6" />
        </svg>
      );
    case "undo":
      return (
        <svg {...common}>
          <path d="M9 7H4v5" />
          <path d="M4.5 11.5a7 7 0 1 0 2-5" />
        </svg>
      );
    case "redo":
      return (
        <svg {...common}>
          <path d="M15 7h5v5" />
          <path d="M19.5 11.5a7 7 0 1 1-2-5" />
        </svg>
      );
    case "zoomOut":
      return (
        <svg {...common}>
          <circle cx="10.5" cy="10.5" r="5.5" />
          <path d="M8 10.5h5" />
          <path d="m15 15 4 4" />
        </svg>
      );
    case "zoomIn":
      return (
        <svg {...common}>
          <circle cx="10.5" cy="10.5" r="5.5" />
          <path d="M8 10.5h5" />
          <path d="M10.5 8v5" />
          <path d="m15 15 4 4" />
        </svg>
      );
    case "fit":
      return (
        <svg {...common}>
          <path d="M8 4H4v4" />
          <path d="M16 4h4v4" />
          <path d="M8 20H4v-4" />
          <path d="M16 20h4v-4" />
          <path d="M9 9h6v6H9z" />
        </svg>
      );
    case "connection":
      return (
        <svg {...common}>
          <rect x="4" y="6" width="6" height="5" rx="1.2" />
          <rect x="14" y="13" width="6" height="5" rx="1.2" />
          <path d="M10 8.5c3.5 0 1 7 4 7" />
        </svg>
      );
    case "advanced":
      return (
        <svg {...common}>
          <path d="M4 7h10" />
          <path d="M18 7h2" />
          <circle cx="16" cy="7" r="2" />
          <path d="M4 17h2" />
          <path d="M10 17h10" />
          <circle cx="8" cy="17" r="2" />
        </svg>
      );
    default:
      return null;
  }
}

function StrokeWidthIcon({ width }) {
  return (
    <svg
      aria-hidden="true"
      fill="none"
      focusable="false"
      stroke="currentColor"
      strokeLinecap="round"
      viewBox="0 0 24 24"
    >
      <path d="M5 12h14" strokeWidth={width} />
    </svg>
  );
}

window.__excalidraw = {
  load(scene) {
    const parsed = typeof scene === "string" ? JSON.parse(scene) : scene;
    loadedOnceRef.current = true;
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
    loadedOnceRef.current = true;
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
  const [advanced, setAdvanced] = useState(false);
  const [appState, setAppState] = useState(null);
  const [elementCount, setElementCount] = useState(0);

  const handleAPI = useCallback((api) => {
    apiRef.current = api;
    if (!loadedOnceRef.current) {
      applyScene({ elements: [], appState: {}, files: {} });
    }
    post({ type: "ready" });
  }, []);

  const handleChange = useCallback((elements, nextAppState) => {
    setAppState(nextAppState);
    const liveCount = elements.filter((element) => !element.isDeleted).length;
    setElementCount(liveCount);
    document.documentElement.style.setProperty("--kodi-scroll-x", `${nextAppState.scrollX ?? 0}px`);
    document.documentElement.style.setProperty("--kodi-scroll-y", `${nextAppState.scrollY ?? 0}px`);
    document.documentElement.style.setProperty(
      "--kodi-zoom",
      `${nextAppState.zoom?.value ?? 1}`,
    );
    if (applyingRef.current) return;
    if (timerRef.current) window.clearTimeout(timerRef.current);
    timerRef.current = window.setTimeout(() => {
      const api = apiRef.current;
      if (!api) return;
      post({ type: "sceneChanged", elementCount: liveCount });
    }, 300);
  }, []);

  const uiOptions = useMemo(
    () => ({
      welcomeScreen: false,
      canvasActions: {
        loadScene: false,
        export: false,
        saveToActiveFile: false,
        toggleTheme: false,
        clearCanvas: true,
      },
    }),
    [],
  );

  return (
    <div className={`kodi-excalidraw-host ${advanced ? "is-advanced" : "is-simple"}`}>
      <SimpleToolbar
        advanced={advanced}
        appState={appState}
        elementCount={elementCount}
        onAdvancedChange={setAdvanced}
      />
      <div className="kodi-dot-grid" aria-hidden="true" />
      <Excalidraw
        excalidrawAPI={handleAPI}
        theme={themeRef.current}
        UIOptions={uiOptions}
        handleKeyboardGlobally={false}
        onChange={handleChange}
      />
    </div>
  );
}

function SimpleToolbar({ advanced, appState, elementCount, onAdvancedChange }) {
  const activeTool = appState?.activeTool?.type ?? "selection";
  const zoom = Math.round((appState?.zoom?.value ?? 1) * 100);
  const canUseTemplate = elementCount === 0;

  const selectTool = (tool) => {
    apiRef.current?.setActiveTool({ type: tool });
  };

  const insertTemplate = () => {
    const api = apiRef.current;
    if (!api || api.getSceneElements().some((element) => !element.isDeleted)) return;
    const elements = [
      ...api.getSceneElementsIncludingDeleted(),
      ...makeTemplateElements(),
    ];
    api.updateScene({
      elements,
      appState: {
        currentItemStrokeColor: DEFAULTS.strokeColor,
        currentItemBackgroundColor: DEFAULTS.backgroundColor,
      },
      captureUpdate: CaptureUpdateAction.IMMEDIATELY,
    });
    requestAnimationFrame(() => api.scrollToContent(elements.filter((element) => !element.isDeleted)));
  };

  return (
    <div className="kodi-simple-toolbar" aria-label="Drawing tools">
      <div className="tool-group">
        {SIMPLE_TOOLS.map((tool) => (
          <button
            key={tool.id}
            type="button"
            className={`icon-button ${activeTool === tool.id ? "is-active" : ""}`}
            aria-label={tool.label}
            data-tooltip={tool.label}
            title={tool.label}
            onClick={() => selectTool(tool.id)}
          >
            <Icon name={tool.id} />
          </button>
        ))}
      </div>

      <div className="tool-group swatches" aria-label="Drawing colors">
        {COLOR_SWATCHES.map((swatch) => (
          <button
            key={swatch.id}
            type="button"
            aria-label={swatch.label}
            data-tooltip={swatch.label}
            title={swatch.label}
            className="swatch"
            style={{ "--swatch": swatch.backgroundColor, "--swatch-stroke": swatch.strokeColor }}
            onClick={() =>
              setCurrentStyle({
                currentItemStrokeColor: swatch.strokeColor,
                currentItemBackgroundColor: swatch.backgroundColor,
              })
            }
          />
        ))}
      </div>

      <div className="tool-group widths" aria-label="Stroke width">
        {[1, 2, 4].map((width) => (
          <button
            key={width}
            type="button"
            aria-label={`${width} point stroke`}
            data-tooltip={`${width} point stroke`}
            title={`${width} point stroke`}
            className="icon-button"
            onClick={() => setCurrentStyle({ currentItemStrokeWidth: width })}
          >
            <StrokeWidthIcon width={width} />
          </button>
        ))}
      </div>

      <div className="tool-group">
        <button type="button" className="icon-button" aria-label="Undo" data-tooltip="Undo" title="Undo" onClick={() => clickNativeAction(".undo-button-container button")}>
          <Icon name="undo" />
        </button>
        <button type="button" className="icon-button" aria-label="Redo" data-tooltip="Redo" title="Redo" onClick={() => clickNativeAction(".redo-button-container button")}>
          <Icon name="redo" />
        </button>
        <button type="button" className="icon-button" aria-label="Zoom out" data-tooltip="Zoom out" title="Zoom out" onClick={() => clickNativeAction(".zoom-out-button")}>
          <Icon name="zoomOut" />
        </button>
        <span className="zoom-readout" aria-label={`Zoom ${zoom} percent`}>
          {zoom}%
        </span>
        <button type="button" className="icon-button" aria-label="Zoom in" data-tooltip="Zoom in" title="Zoom in" onClick={() => clickNativeAction(".zoom-in-button")}>
          <Icon name="zoomIn" />
        </button>
        <button type="button" className="icon-button" aria-label="Fit to content" data-tooltip="Fit to content" title="Fit to content" onClick={() => apiRef.current?.scrollToContent(apiRef.current.getSceneElements())}>
          <Icon name="fit" />
        </button>
      </div>

      <div className="tool-group trailing">
        {canUseTemplate && (
          <button
            type="button"
            className="icon-button template-button"
            aria-label="Connection template"
            data-tooltip="Connection template"
            title="Connection template"
            onClick={insertTemplate}
          >
            <Icon name="connection" />
          </button>
        )}
        <button
          type="button"
          className={`advanced-button ${advanced ? "is-active" : ""}`}
          aria-pressed={advanced}
          aria-label="Advanced tools"
          data-tooltip="Advanced tools"
          title="Advanced tools"
          onClick={() => onAdvancedChange((value) => !value)}
        >
          <Icon name="advanced" />
        </button>
      </div>
    </div>
  );
}

window.addEventListener("error", (event) => {
  post({ type: "error", message: String(event.message || event.error || "error") });
});

createRoot(document.getElementById("root")).render(<Host />);
