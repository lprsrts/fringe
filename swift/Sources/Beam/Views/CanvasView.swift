import AppKit
import SwiftUI

struct CanvasView: View {
    @Environment(AppState.self) private var model
    @Environment(\.displayScale) private var displayScale
    // Gesture state resets when a gesture ends and also when it is cancelled, which
    // `onEnded` never hears about; `onChange` below closes the undo step either way.
    @GestureState private var drag: CanvasDrag?
    @GestureState private var pinch: CanvasPinch?
    @UIState private var hoveredElement: UUID?

    var body: some View {
        let geometry = model.geometry
        let rect = geometry.imageRect
        let isWindowAspect = model.output.aspect == .window

        // The image sits in an overlay so its size never feeds back into the column's layout.
        Color.clear
            .overlay(alignment: .topLeading) {
                ImageLayer(
                    raster: model.rasterImage,
                    scene: model.scene,
                    selectedID: model.selectedElementID,
                    fillsWindow: isWindowAspect
                )
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            }
        .background {
            Color(white: 0.11)
                .ignoresSafeArea()
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.containerSize = $0 }
        .onChange(of: displayScale, initial: true) { _, scale in model.displayScale = scale }
        .gesture(dragGesture(geometry))
        .simultaneousGesture(magnifyGesture(geometry))
        // A single tap recogniser reads the click count itself; stacking a double-tap
        // recogniser on top would hold every single click back by the double-click interval.
        .onTapGesture { location in
            guard rect.contains(location) else { return }
            let hit = hitElement(at: location, geometry)
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                if hit == nil { model.zoomToFit() }
            } else {
                model.selection = hit.map { .element($0) } ?? .beam
            }
        }
        .onChange(of: drag) { old, new in
            guard new == nil, let old else { return }
            switch old {
            case .element: model.endTracking("Move Element")
            case .pan: model.endTracking("Pan")
            case .outside: break
            }
        }
        .onChange(of: pinch) { old, new in
            if new == nil, old != nil {
                model.endTracking("Zoom")
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoveredElement = hitElement(at: location, geometry)
            case .ended:
                hoveredElement = nil
            }
        }
        .pointerStyle(pointerStyle)
    }

    private var pointerStyle: PointerStyle? {
        switch drag {
        case .element:
            return .columnResize(directions: .all)
        case .pan:
            return .grabActive
        case .outside:
            return nil
        case nil:
            return hoveredElement == nil ? .grabIdle : .columnResize(directions: .all)
        }
    }

    /// Glyphs can only be hit while they are drawn.
    private func hitElement(at point: CGPoint, _ geometry: CanvasGeometry) -> UUID? {
        guard model.style.showOverlays, model.style.showElementGlyphs else { return nil }
        return geometry.hitTestElement(at: point, in: model.elements)
    }

    private func dragGesture(_ geometry: CanvasGeometry) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($drag) { value, drag, _ in
                if drag == nil {
                    drag = startDrag(at: value.startLocation, geometry)
                }

                let dz = geometry.deltaZ(forDeltaX: value.translation.width)
                switch drag {
                case .pan(let startPanZ):
                    model.scene.framing.panZ = startPanZ - dz
                case .element(let id, let startZ):
                    let factor = NSEvent.modifierFlags.contains(.option) ? 0.1 : 1.0
                    model.scene[element: id]?.z = startZ + dz * factor
                case .outside, nil:
                    break
                }
            }
    }

    private func startDrag(at location: CGPoint, _ geometry: CanvasGeometry) -> CanvasDrag {
        guard geometry.imageRect.contains(location) else { return .outside }
        model.beginTracking()
        if let id = hitElement(at: location, geometry), let element = model.scene[element: id] {
            model.selection = .element(id)
            return .element(id: id, startZ: element.z)
        }
        return .pan(startPanZ: model.framing.panZ)
    }

    private func magnifyGesture(_ geometry: CanvasGeometry) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, pinch, _ in
                if pinch == nil {
                    let rect = geometry.imageRect
                    let anchor = rect.width > 0 ? (value.startLocation.x - rect.minX) / rect.width : 0.5
                    pinch = CanvasPinch(framing: model.framing, anchor: Double(min(1, max(0, anchor))))
                    model.beginTracking()
                }
                guard let pinch else { return }
                var framing = pinch.framing
                framing.zoom(by: Double(value.magnification), anchor: pinch.anchor)
                model.scene.framing = framing
            }
    }
}

private enum CanvasDrag: Equatable {
    case pan(startPanZ: Double)
    case element(id: UUID, startZ: Double)
    /// Started on the letterbox around the image; does nothing.
    case outside
}

private struct CanvasPinch: Equatable {
    var framing: FramingModel
    /// Horizontal position of the pinch in the image, 0 at the left edge.
    var anchor: Double
}

/// The rendered field with the overlays drawn over it.
private struct ImageLayer: View {
    let raster: CGImage?
    let scene: BeamScene
    let selectedID: UUID?
    let fillsWindow: Bool

    var body: some View {
        ZStack {
            if let raster {
                // Only a full-bleed image may be mirrored under the sidebar and toolbar; a
                // letterboxed one would suggest a wider crop than the export has.
                Image(decorative: raster, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .backgroundExtensionEffect(isEnabled: fillsWindow)
                    .shadow(color: .black.opacity(fillsWindow ? 0 : 0.35), radius: 12, y: 4)
            }
            Canvas { context, size in
                context.withCGContext { cg in
                    VectorRenderer.drawOverlays(
                        in: cg,
                        size: size,
                        flipped: false,
                        beam: scene.beam,
                        elements: scene.elements,
                        style: scene.style,
                        framing: scene.framing,
                        selectedID: selectedID,
                        minimumTextScale: 1
                    )
                }
            }
            .allowsHitTesting(false)
        }
    }
}
