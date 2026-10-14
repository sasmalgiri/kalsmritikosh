//
//  PlacesView.swift
//  Kalsmritikosh
//
//  N-8 — places: photo GPS read from the image files' own metadata (ImageIO,
//  on-device) and place names found in documents (address / city / country /
//  location entities). Private mode shows a list with coordinates and makes no
//  request of any kind. The app itself never loads map tiles (it has no network
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
                 : "Read on this Mac from photo metadata and your documents. Private mode: a list only — nothing is looked up online.")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading) {
                    Text("Photos with a location (\(photos.count))").font(.headline)
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
