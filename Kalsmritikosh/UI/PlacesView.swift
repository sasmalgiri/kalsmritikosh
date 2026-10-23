//
//  PlacesView.swift
//  Kalsmritikosh
//
//  N-8 — places: photo GPS read from the image files' own metadata (ImageIO,
//  on-device) and place names found in documents (address / city / country /
//  location entities). Private mode shows a list with coordinates and an offline
//  plot of the photo locations on a latitude/longitude grid (drawn on this Mac —
//  no map tiles, no request of any kind). The app never loads map tiles (it has no network
//  entitlement); in Online mode a row can be handed to Apple Maps, which is a
//  separate app the user chooses to open.
//

import SwiftUI
import AppKit
import ImageIO
import os

nonisolated struct PhotoPlace: Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let taken: String?
}

nonisolated struct NamedPlace: Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
    let kind: String
    let documents: Int
}

nonisolated enum PhotoGPSReader {
    /// Signed decimal degrees from an image's GPS dictionary; nil when the image has no GPS.
    static func coordinates(_ url: URL) -> (lat: Double, lon: Double, taken: String?)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        return (latRef.uppercased() == "S" ? -lat : lat, lonRef.uppercased() == "W" ? -lon : lon,
                exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
    }
}

extension AppState {
    func photoPlaces(limit: Int = 5000) async -> [PhotoPlace] {
        guard let database else { return [] }
        let rows = (try? await database.query("""
            SELECT ko.id, f.url FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
            WHERE LOWER(f.url) LIKE '%.jpg' OR LOWER(f.url) LIKE '%.jpeg' OR LOWER(f.url) LIKE '%.heic'
               OR LOWER(f.url) LIKE '%.png' OR LOWER(f.url) LIKE '%.tif' OR LOWER(f.url) LIKE '%.tiff' OR LOWER(f.url) LIKE '%.dng'
            LIMIT ?;
            """, [.integer(Int64(limit))])) ?? []
        let items = rows.compactMap { r -> (UUID, URL)? in
            guard let id = r.uuid(0), let url = r.string(1).flatMap(URL.init(string:)) else { return nil }
            return (id, url)
        }
        return await Task.detached {
            items.compactMap { id, url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let c = PhotoGPSReader.coordinates(url) else { return nil }
                return PhotoPlace(id: id, name: url.lastPathComponent, latitude: c.lat, longitude: c.lon, taken: c.taken)
            }
        }.value
    }

    func namedPlaces(limit: Int = 2000) async -> [NamedPlace] {
        guard let database else { return [] }
        return ((try? await database.query("""
            SELECT e.id, e.value, e.kind, COUNT(DISTINCT m.source_object_id) AS docs
            FROM entities e JOIN entity_mentions m ON m.entity_id = e.id
            WHERE e.kind IN ('address','city','country','location')
            GROUP BY e.id ORDER BY docs DESC LIMIT ?;
            """, [.integer(Int64(limit))])) ?? []).compactMap { r in
            guard let id = r.uuid(0), let name = r.string(1) else { return nil }
            return NamedPlace(id: id, name: name, kind: r.string(2) ?? "", documents: Int(r.int(3) ?? 0))
        }
    }
}

struct PlacesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [PhotoPlace] = []
    @State private var places: [NamedPlace] = []
    @State private var loading = true

    private var online: Bool { ConnectivityMode.current == .online }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Places").font(.title3.bold())
            Text(online
                 ? "Read on this Mac from photo metadata and your documents. “Open in Maps” hands one place to Apple Maps, a separate app."
                 : "Read on this Mac from photo metadata and your documents. Private mode: a list and an offline plot — nothing is looked up online.")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading) {
                    Text("Photos with a location (\(photos.count))").font(.headline)
                    if !photos.isEmpty { PlacesPlot(points: photos).frame(height: 180) }
                    List(photos) { p in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p.name).font(.callout)
                                Text(String(format: "%.5f, %.5f", p.latitude, p.longitude) + (p.taken.map { " · \($0)" } ?? ""))
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if online {
                                Button("Open in Maps") { openInMaps(p.latitude, p.longitude, p.name) }.buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                }
                .frame(minWidth: 320)
                VStack(alignment: .leading) {
                    Text("Places named in documents (\(places.count))").font(.headline)
                    List(places) { p in
                        HStack {
                            Text(p.name)
                            Text(p.kind).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(p.documents) doc\(p.documents == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minWidth: 280)
            }
            .overlay { if loading { ProgressView("Reading photo locations…") } }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 500)
        .task {
            async let ph = appState.photoPlaces()
            async let pl = appState.namedPlaces()
            photos = await ph; places = await pl
            loading = false
        }
    }

    private func openInMaps(_ lat: Double, _ lon: Double, _ name: String) {
        var c = URLComponents(string: "maps://")
        c?.queryItems = [URLQueryItem(name: "ll", value: "\(lat),\(lon)"), URLQueryItem(name: "q", value: name)]
        if let url = c?.url { NSWorkspace.shared.open(url) }
    }
}


/// Offline plot of photo coordinates on an equirectangular latitude/longitude grid. Zooms to the
/// points' extent (with margin); no map data or network is used.
struct PlacesPlot: View {
    let points: [PhotoPlace]
    @State private var hovered: PhotoPlace?
    /// Grid-label size; scales with the user's text size (U-1).
    @ScaledMetric(relativeTo: .caption2) private var gridLabelSize: CGFloat = 8

    var body: some View {
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let pad = 2.0
        let minLat = max(-90, (lats.min() ?? 0) - pad), maxLat = min(90, (lats.max() ?? 0) + pad)
        let minLon = max(-180, (lons.min() ?? 0) - pad), maxLon = min(180, (lons.max() ?? 0) + pad)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let sx = w / max(maxLon - minLon, 0.01), sy = h / max(maxLat - minLat, 0.01)
            let pt: (PhotoPlace) -> CGPoint = { p in CGPoint(x: (p.longitude - minLon) * sx, y: (maxLat - p.latitude) * sy) }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.06)))
                    let step = Self.gridStep(maxLon - minLon)
                    var lon = (minLon / step).rounded(.up) * step
                    while lon <= maxLon {
                        let x = (lon - minLon) * sx
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.secondary.opacity(0.2)))
                        ctx.draw(Text(String(format: "%.0f°", lon)).font(.system(size: gridLabelSize)).foregroundColor(.secondary), at: CGPoint(x: x + 10, y: size.height - 6))
                        lon += step
                    }
                    var lat = (minLat / step).rounded(.up) * step
                    while lat <= maxLat {
                        let y = (maxLat - lat) * sy
                        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(.secondary.opacity(0.2)))
                        ctx.draw(Text(String(format: "%.0f°", lat)).font(.system(size: gridLabelSize)).foregroundColor(.secondary), at: CGPoint(x: 12, y: y - 6))
                        lat += step
                    }
                    for p in points {
                        let c = pt(p)
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)), with: .color(.accentColor))
                    }
                }
                ForEach(points) { p in
                    Color.clear.frame(width: 14, height: 14).contentShape(Rectangle())
                        .position(pt(p))
                        .onHover { inside in hovered = inside ? p : (hovered == p ? nil : hovered) }
                        .help("\(p.name) — \(String(format: "%.4f, %.4f", p.latitude, p.longitude))")
                }
                if let hv = hovered {
                    Text(hv.name).font(.caption2).padding(3).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4)).padding(4)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Plot of \(points.count) photo locations")
    }

    static func gridStep(_ span: Double) -> Double {
        for s in [0.01, 0.05, 0.1, 0.5, 1, 2, 5, 10, 15, 30] where span / s <= 8 { return s }
        return 60
    }
}
