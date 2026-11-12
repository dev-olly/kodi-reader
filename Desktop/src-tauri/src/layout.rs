//! All child-view platform work is isolated here; no Apple project dependencies.
use crate::Bounds;
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
use tauri::{LogicalPosition, LogicalSize};
use tauri::{Manager, Webview};

pub fn position(view: &Webview, bounds: Bounds) -> Result<(), String> {
    if bounds.width < 1.0 || bounds.height < 1.0 {
        return view.hide().map_err(|e| e.to_string());
    }
    view.show().map_err(|e| e.to_string())?;
    #[cfg(target_os = "macos")]
    position_macos(view, bounds)?;
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        // DOM rectangles are relative to the chrome webview. Native children
        // are relative to its parent, whose origin can include window chrome.
        let scale = view.window().scale_factor().map_err(|e| e.to_string())?;
        let origin = view
            .app_handle()
            .get_webview("main-ui")
            .and_then(|main| main.bounds().ok())
            .map(|rect| rect.position.to_logical::<f64>(scale))
            .unwrap_or(LogicalPosition::new(0., 0.));
        view.set_bounds(tauri::Rect {
            position: LogicalPosition::new(origin.x + bounds.x, origin.y + bounds.y).into(),
            size: LogicalSize::new(bounds.width, bounds.height).into(),
        })
        .map_err(|e| e.to_string())?;
    }
    #[cfg(target_os = "linux")]
    {
        use gtk::prelude::*;
        view.with_webview(move |native| {
            let widget = native.inner();
            if let Some(parent) = widget
                .parent()
                .and_then(|p| p.downcast::<gtk::Overlay>().ok())
            {
                // Overlay children do not contribute to the window's minimum
                // size. A Fixed + size_request feedback loop makes a window
                // impossible to shrink after its first larger allocation.
                widget.set_margin_start(bounds.x.round() as i32);
                widget.set_margin_top(bounds.y.round() as i32);
                widget.set_size_request(bounds.width.round() as i32, bounds.height.round() as i32);
                parent.queue_resize();
            }
        })
        .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn position_macos(view: &Webview, bounds: Bounds) -> Result<(), String> {
    use objc2_app_kit::NSView;
    use objc2_foundation::{NSPoint, NSRect, NSSize};

    fn from_native(rect: NSRect) -> Bounds {
        Bounds {
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height,
        }
    }

    fn to_native(rect: Bounds) -> NSRect {
        NSRect::new(
            NSPoint::new(rect.x, rect.y),
            NSSize::new(rect.width, rect.height),
        )
    }

    let main = view
        .app_handle()
        .get_webview("main-ui")
        .ok_or("The main interface is unavailable")?;
    let reader = view.clone();
    main.with_webview(move |native| {
        // Tauri executes native callbacks on AppKit's main thread and keeps
        // their WKWebView alive. No native pointer escapes either callback.
        let main_view = unsafe { &*(native.inner().cast::<NSView>()) };
        let Some(window) = main_view.window() else {
            return;
        };
        // Tauri's visible title bar uses a full-size content view. WebKit
        // automatically insets the DOM viewport below the title bar, but Wry's
        // bounds() describes the entire native frame. Use AppKit's unobscured
        // content rectangle instead of adding a fixed title-bar height.
        let layout = main_view.convertRect_fromView(window.contentLayoutRect(), None);
        let Some(viewport) = intersection(from_native(main_view.bounds()), from_native(layout))
        else {
            let _ = reader.hide();
            return;
        };
        let native_rect = dom_rect_in_native_view(viewport, main_view.isFlipped(), bounds);
        let Some(native_rect) = intersection(native_rect, viewport) else {
            let _ = reader.hide();
            return;
        };
        let window_rect = main_view.convertRect_toView(to_native(native_rect), None);
        // Only a numeric rectangle and a Tauri handle cross this callback
        // boundary. The reader may have closed before the queued callback runs.
        let _ = reader.with_webview(move |native| {
            let reader_view = unsafe { &*(native.inner().cast::<NSView>()) };
            // The hierarchy is read and used synchronously on the main thread.
            if let Some(parent) = unsafe { reader_view.superview() } {
                // AppKit converts both the parent origin and flipped axes.
                // Applying this frame directly avoids another Wry Y inversion.
                let frame = parent.convertRect_fromView(window_rect, None);
                reader_view.setFrame(frame);
            }
        });
    })
    .map_err(|error| error.to_string())
}

#[cfg(any(target_os = "macos", test))]
fn intersection(a: Bounds, b: Bounds) -> Option<Bounds> {
    let x = a.x.max(b.x);
    let y = a.y.max(b.y);
    let right = (a.x + a.width).min(b.x + b.width);
    let bottom = (a.y + a.height).min(b.y + b.height);
    (right > x && bottom > y).then_some(Bounds {
        x,
        y,
        width: right - x,
        height: bottom - y,
    })
}

/// DOM rectangles always start at the viewport's top left; AppKit views may
/// have either axis orientation and a nonzero bounds origin.
#[cfg(any(target_os = "macos", test))]
fn dom_rect_in_native_view(viewport: Bounds, flipped: bool, dom: Bounds) -> Bounds {
    Bounds {
        x: viewport.x + dom.x,
        y: if flipped {
            viewport.y + dom.y
        } else {
            viewport.y + viewport.height - dom.y - dom.height
        },
        width: dom.width,
        height: dom.height,
    }
}

/// Stock Tauri uses a vertical GTK box. The trusted UI is the expanding main
/// child of an Overlay; reader children occupy explicit overlay rectangles.
/// Their requested sizes never raise the parent window's minimum dimensions.
pub fn mount(view: &Webview) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        use gtk::prelude::*;
        let app = view.app_handle().clone();
        let main = view.label() == "main-ui";
        view.with_webview(move |native| {
            let widget = native.inner();
            let Some(window) = app.get_window("main-ui") else {
                return;
            };
            let Ok(vbox) = window.default_vbox() else {
                return;
            };
            let overlay = vbox
                .children()
                .into_iter()
                .find_map(|w| w.downcast::<gtk::Overlay>().ok())
                .unwrap_or_else(|| {
                    let overlay = gtk::Overlay::new();
                    overlay.set_hexpand(true);
                    overlay.set_vexpand(true);
                    vbox.pack_start(&overlay, true, true, 0);
                    overlay.show();
                    overlay
                });
            if let Some(parent) = widget
                .parent()
                .and_then(|p| p.downcast::<gtk::Container>().ok())
            {
                parent.remove(&widget);
            }
            if main {
                widget.set_size_request(-1, -1);
                widget.set_hexpand(true);
                widget.set_vexpand(true);
                widget.set_halign(gtk::Align::Fill);
                widget.set_valign(gtk::Align::Fill);
                overlay.add(&widget);
            } else {
                // DOM bounds use physical left-to-right x coordinates even in
                // an RTL desktop locale. This affects only GTK allocation;
                // publication text direction remains controlled by its HTML.
                widget.set_direction(gtk::TextDirection::Ltr);
                widget.set_halign(gtk::Align::Start);
                widget.set_valign(gtk::Align::Start);
                overlay.add_overlay(&widget);
                overlay.set_overlay_pass_through(&widget, false);
            }
            widget.show();
        })
        .map_err(|e| e.to_string())?;
    }
    #[cfg(not(target_os = "linux"))]
    let _ = view;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x: f64, y: f64, width: f64, height: f64) -> Bounds {
        Bounds {
            x,
            y,
            width,
            height,
        }
    }

    fn values(rect: Bounds) -> (f64, f64, f64, f64) {
        (rect.x, rect.y, rect.width, rect.height)
    }

    #[test]
    fn title_bar_inset_keeps_the_child_below_the_dom_toolbar() {
        let full_frame = rect(0., 0., 1280., 891.);
        let layout = rect(0., 0., 1280., 860.);
        let viewport = intersection(full_frame, layout).unwrap();
        let native = dom_rect_in_native_view(viewport, false, rect(0., 61., 1280., 760.));
        assert_eq!(values(native), (0., 39., 1280., 760.));
        // Top-left position in the full native frame includes 31pt title bar.
        assert_eq!(full_frame.height - native.y - native.height, 92.);
    }

    #[test]
    fn flipped_and_unflipped_coordinate_spaces_describe_the_same_rectangle() {
        let dom = rect(20., 61., 600., 500.);
        let unflipped = dom_rect_in_native_view(rect(0., 0., 1000., 800.), false, dom);
        let flipped = dom_rect_in_native_view(rect(0., 31., 1000., 800.), true, dom);
        assert_eq!(values(unflipped), (20., 239., 600., 500.));
        assert_eq!(values(flipped), (20., 92., 600., 500.));
        // A flipped parent uses the physical top directly; an unflipped
        // parent's bottom-up frame is reflected exactly once by convertRect.
        assert_eq!(831. - unflipped.y - unflipped.height, flipped.y);
    }

    #[test]
    fn titlebarless_and_resized_viewports_use_current_geometry() {
        let dom = rect(15., 60., 500., 400.);
        let full_screen = dom_rect_in_native_view(rect(0., 0., 900., 700.), false, dom);
        assert_eq!(values(full_screen), (15., 240., 500., 400.));
        let resized = dom_rect_in_native_view(rect(8., 12., 1200., 950.), false, dom);
        assert_eq!(values(resized), (23., 502., 500., 400.));
    }

    #[test]
    fn a_stale_oversized_dom_rectangle_is_clipped_to_the_visible_viewport() {
        let viewport = rect(0., 0., 800., 600.);
        let native = dom_rect_in_native_view(viewport, false, rect(700., 500., 200., 200.));
        assert_eq!(
            values(intersection(viewport, native).unwrap()),
            (700., 0., 100., 100.)
        );
        assert!(intersection(viewport, rect(900., 0., 100., 100.)).is_none());
    }
}
