//
//  CaseMapCanvas.swift
//  Kalsmritikosh
//
//  Living case map, M3: the spatial map and its equivalent list.
//  • The map draws in WORLD coordinates through the view's viewport: pan (drag the background), zoom
//    (pinch or the buttons), fit everything shown, fit the selection; drag an item to move it (stored in the
//    ledger, undoable), pin/unpin, hide from this view, collapse/expand groups. Rendering is bounded: only
//    items in the visible area are drawn, at most `drawCap`, and the screen says how many were held back.
//  • Icons, text and line style carry the meaning (never colour alone); every item has the same size.
//  • The list shows exactly the same items under the same filters, with the same selection and inspector,
//    usable with the keyboard and VoiceOver.
//

import SwiftUI

struct CaseMapCanvas: View {
    let map: CaseMapWorkspaceModel
    let projection: CaseMapProjection
    let result: CaseMapViewResult
    let repository: CaseMapRepository?
    let actor: String

    static let drawCap = 400
    @State private var size: CGSize = .zero
    @State private var dragNode: CaseMapNodeID?
    @State private var dragOffset: CGSize = .zero
    @State private var panStart: CaseMapViewport?
    @State private var zoomStart: CaseMapViewport?

    private var viewport: CaseMapViewport { map.viewport(default: fitAll(size) ?? CaseMapViewport()) }

    var body: some View {
        GeometryReader { geo in
            let vp = viewport
            let rect = vp.worldRect(width: geo.size.width, height: geo.size.height)
            let cull = CaseMapLayout.cull(result.shown, positions: map.displayPlacements, in: rect, cap: Self.drawCap)
            let groups = groupCards
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(&ctx, vp: vp, drawn: cull.drawn, groups: groups) }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(vp: vp, drawn: cull.drawn))
                    .simultaneousGesture(SpatialTapGesture().onEnded { tap($0.location, vp: vp, drawn: cull.drawn, groups: groups) })
                    .simultaneousGesture(MagnifyGesture().onChanged { v in
                        let start = zoomStart ?? vp
                        if zoomStart == nil { zoomStart = vp }
                        zoom(to: start.scale * v.magnification, around: v.startLocation, from: start)
                    }.onEnded { _ in zoomStart = nil })
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Case map: \(cull.drawn.count) items drawn. The list shows the same items for the keyboard and VoiceOver.")
                    .accessibilityChildren {
                        // M9 — items and links drawn on the canvas, each with its label and value (state, review,
                        // pinned, selected); activating one selects it for the inspector.
                        ForEach(cull.drawn, id: \.self) { id in
                            if let n = projection.node(id) {
                                Rectangle().accessibilityLabel(CaseMapSpoken.nodeLabel(n))
                                    .accessibilityValue(CaseMapSpoken.nodeValue(n, pinned: map.displayPlacements[id]?.pinned == true, selected: map.selection == .node(id)))
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { map.select(.node(id)) }
                            }
                        }
                        let drawnSet = Set(cull.drawn)
                        ForEach(result.links.filter { lid in projection.link(lid).map { drawnSet.contains($0.from) && drawnSet.contains($0.to) } ?? false }, id: \.self) { lid in
                            if let l = projection.link(lid) {
                                Rectangle().accessibilityLabel(CaseMapSpoken.linkLabel(l, in: projection))
                                    .accessibilityValue(CaseMapSpoken.linkValue(l, selected: map.selection == .link(lid)))
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { map.select(.link(lid)) }
                            }
                        }
                        ForEach(groups, id: \.0.id) { g, _ in
                            Rectangle().accessibilityLabel("\(g.title): \(g.members.count) item(s), collapsed")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint("Opens the group.")
                                .accessibilityAction { Task { await map.toggleCollapse(g.id, repository: repository, actor: actor) } }
                        }
                    }
                controls(vp: vp, geo: geo.size, cull: cull)
            }
            .onAppear { size = geo.size; map.canvasSize = (geo.size.width, geo.size.height) }
            .onChange(of: geo.size) { _, new in size = new; map.canvasSize = (new.width, new.height) }
            .clipped()
        }
    }

    // MARK: Drawing

    private func position(_ id: CaseMapNodeID) -> CaseMapPoint? {
        guard var p = map.displayPlacements[id]?.point else { return nil }
        if id == dragNode { p.x += dragOffset.width / viewport.scale; p.y += dragOffset.height / viewport.scale }
        return p
    }

    private func draw(_ ctx: inout GraphicsContext, vp: CaseMapViewport, drawn: [CaseMapNodeID], groups: [(CaseMapGroup, CaseMapPoint)]) {
        let drawnSet = Set(drawn)
        let selected = map.selection
        // Links between drawn items, with their line style and an arrow for direction.
        for lid in result.links {
            guard let l = projection.link(lid), drawnSet.contains(l.from), drawnSet.contains(l.to),
                  let a = position(l.from), let b = position(l.to) else { continue }
            let pa = vp.toScreen(a), pb = vp.toScreen(b)
            var path = Path()
            path.move(to: CGPoint(x: pa.x, y: pa.y)); path.addLine(to: CGPoint(x: pb.x, y: pb.y))
            let isSel = selected == .link(l.id)
            // MAP-11 — the width and the dash come from the selection and the link TYPE only (never its certainty).
            let dash: [CGFloat] = CaseMapVisual.dash(l.type).map { CGFloat($0) }
            ctx.stroke(path, with: .color(isSel ? .accentColor : .secondary.opacity(0.7)), style: StrokeStyle(lineWidth: CaseMapVisual.lineWidth(l, selected: isSel), dash: dash))
            if l.directed {
                let angle = atan2(pb.y - pa.y, pb.x - pa.x)
                let tip = CGPoint(x: pb.x - cos(angle) * 30 * vp.scale, y: pb.y - sin(angle) * 30 * vp.scale)
                var head = Path()
                head.move(to: tip)
                head.addLine(to: CGPoint(x: tip.x - cos(angle - 0.4) * 9, y: tip.y - sin(angle - 0.4) * 9))
                head.move(to: tip)
                head.addLine(to: CGPoint(x: tip.x - cos(angle + 0.4) * 9, y: tip.y - sin(angle + 0.4) * 9))
                ctx.stroke(head, with: .color(isSel ? .accentColor : .secondary), lineWidth: 1.2)
            }
            if CaseMapZoomDetail.level(vp.scale).showsLinkLabels {
                let mid = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
                ctx.draw(Text(l.type.label).font(.system(size: 9)).foregroundStyle(.secondary), at: mid)
            }
        }
        // Items: one size for all; icon + kind + title + state symbol.
        let w = CaseMapLayout.nodeWidth * vp.scale, h = CaseMapLayout.nodeHeight * vp.scale
        for id in drawn {
            guard let n = projection.node(id), let p = position(id) else { continue }
            let c = vp.toScreen(p)
            let box = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
            let shape = Path(roundedRect: box, cornerRadius: 8 * vp.scale)
            ctx.fill(shape, with: .color(Color(nsColor: .controlBackgroundColor)))
            let isSel = selected == .node(id)
            ctx.stroke(shape, with: .color(isSel ? .accentColor : .secondary.opacity(0.5)),
                       style: StrokeStyle(lineWidth: isSel ? 3 : 1, dash: n.kind == .note ? [4, 3] : []))
            // MAP-07 — a record in the chosen date/amount range; MAP-09 — a record chosen with others.
            if map.isInSubset(id) {
                ctx.stroke(Path(roundedRect: box.insetBy(dx: -4, dy: -4), cornerRadius: 10 * vp.scale), with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }
            if map.multiSelection.contains(id) {
                ctx.draw(Image(systemName: "checkmark.circle.fill"), in: CGRect(x: box.minX - 6, y: box.minY - 6, width: 14, height: 14))
            }
            let detail = CaseMapZoomDetail.level(vp.scale)
            guard detail > .outline else { continue }
            let fs = max(8, 11 * vp.scale)
            ctx.draw(Image(systemName: n.kind.symbol), in: CGRect(x: box.minX + 6 * vp.scale, y: box.minY + 6 * vp.scale, width: 14 * vp.scale, height: 14 * vp.scale))
            ctx.draw(Image(systemName: n.status.kind.symbol), in: CGRect(x: box.maxX - 20 * vp.scale, y: box.minY + 6 * vp.scale, width: 13 * vp.scale, height: 13 * vp.scale))
            if map.displayPlacements[id]?.pinned == true {
                ctx.draw(Image(systemName: "pin.fill"), in: CGRect(x: box.maxX - 36 * vp.scale, y: box.minY + 6 * vp.scale, width: 11 * vp.scale, height: 11 * vp.scale))
            }
            ctx.draw(Text(n.kind.label).font(.system(size: fs * 0.8)).foregroundStyle(.secondary),
                     at: CGPoint(x: box.minX + 24 * vp.scale, y: box.minY + 13 * vp.scale), anchor: .leading)
            // MAP-02 — at close zoom the card shows more of the same record (state, date, amount, sources, first line).
            let extra = CaseMapZoomDetail.cardLines(n, at: detail)
            let fold = result.folds[id]
            let reserved = (extra.isEmpty ? 0 : 0.45) + (fold == nil ? 0 : 0.18)
            ctx.draw(Text(n.title).font(.system(size: fs, weight: .medium)),
                     in: CGRect(x: box.minX + 6 * vp.scale, y: box.minY + 22 * vp.scale, width: w - 12 * vp.scale, height: (h - 24 * vp.scale) * (1 - reserved)))
            if !extra.isEmpty {
                ctx.draw(Text(extra.joined(separator: "\n")).font(.system(size: max(7, 7 * vp.scale))).foregroundStyle(.secondary),
                         in: CGRect(x: box.minX + 6 * vp.scale, y: box.minY + h * 0.5, width: w - 12 * vp.scale, height: h * 0.32))
            }
            // MAP-04 — a folded branch says what it holds, including what is new, blocked or waiting for review.
            if let fold {
                ctx.draw(Text("▸ " + fold.label).font(.system(size: max(7, 8 * vp.scale), weight: .semibold)),
                         in: CGRect(x: box.minX + 6 * vp.scale, y: box.maxY - 14 * vp.scale, width: w - 12 * vp.scale, height: 12 * vp.scale))
            }
        }
        // Collapsed groups: one card each, at the centre of what they hold, with the count.
        for (g, p) in groups {
            let c = vp.toScreen(p)
            let box = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
            let shape = Path(roundedRect: box, cornerRadius: 12 * vp.scale)
            ctx.fill(shape, with: .color(.secondary.opacity(0.12)))
            ctx.stroke(shape, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
            if vp.scale > 0.3 {
                ctx.draw(Image(systemName: "square.stack.3d.up"), in: CGRect(x: box.minX + 6 * vp.scale, y: box.minY + 6 * vp.scale, width: 14 * vp.scale, height: 14 * vp.scale))
                ctx.draw(Text("\(g.title) — \(g.members.count) (collapsed)").font(.system(size: max(8, 11 * vp.scale), weight: .medium)),
                         in: CGRect(x: box.minX + 24 * vp.scale, y: box.minY + 6 * vp.scale, width: w - 30 * vp.scale, height: h - 10 * vp.scale))
            }
        }
    }

    /// Where each collapsed group's card sits: clear of every shown item and every earlier card
    /// (CaseMapLayout.groupCardPoint), so a card never covers an item; same result whatever is on screen.
    private var groupCards: [(CaseMapGroup, CaseMapPoint)] {
        var occupied = result.shown.compactMap { map.displayPlacements[$0]?.point }
        var out: [(CaseMapGroup, CaseMapPoint)] = []
        for g in result.collapsedGroups {
            guard let p = CaseMapLayout.groupCardPoint(g.members.compactMap { map.displayPlacements[$0]?.point }, avoiding: occupied) else { continue }
            out.append((g, p))
            occupied.append(p)
        }
        return out
    }

    // MARK: Interaction

    private func dragGesture(vp: CaseMapViewport, drawn: [CaseMapNodeID]) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragNode == nil && panStart == nil {
                    let w = vp.toWorld(x: v.startLocation.x, y: v.startLocation.y)
                    if let hit = CaseMapLayout.hit(w, ids: drawn, positions: map.displayPlacements) { dragNode = hit } else { panStart = vp }
                }
                if dragNode != nil { dragOffset = v.translation }
                else if let start = panStart {
                    var n = start
                    n.originX = start.originX - v.translation.width / start.scale
                    n.originY = start.originY - v.translation.height / start.scale
                    map.setViewport(n)
                }
            }
            .onEnded { v in
                if let id = dragNode, let p = map.displayPlacements[id]?.point {
                    let target = CaseMapPoint(x: (p.x + v.translation.width / vp.scale).rounded(), y: (p.y + v.translation.height / vp.scale).rounded())
                    Task { await map.move(id, to: target, repository: repository) }
                }
                dragNode = nil; dragOffset = .zero; panStart = nil
            }
    }

    private func tap(_ location: CGPoint, vp: CaseMapViewport, drawn: [CaseMapNodeID], groups: [(CaseMapGroup, CaseMapPoint)]) {
        let w = vp.toWorld(x: location.x, y: location.y)
        if let hit = CaseMapLayout.hit(w, ids: drawn, positions: map.displayPlacements) {
            // MAP-09 — ⌘-click chooses items together (for Arrange, Pin and Unpin); a plain click selects one.
            if NSEvent.modifierFlags.contains(.command) { map.toggleMulti(hit) } else { map.select(.node(hit)) }
            return
        }
        if let g = groups.first(where: { abs($0.1.x - w.x) <= CaseMapLayout.nodeWidth / 2 && abs($0.1.y - w.y) <= CaseMapLayout.nodeHeight / 2 }) {
            Task { await map.toggleCollapse(g.0.id, repository: repository, actor: actor) }
            return
        }
        // A link: within a few points of its line.
        let tolerance = 6 / vp.scale
        let drawnSet = Set(drawn)
        for lid in result.links {
            guard let l = projection.link(lid), drawnSet.contains(l.from), drawnSet.contains(l.to),
                  let a = map.displayPlacements[l.from]?.point, let b = map.displayPlacements[l.to]?.point else { continue }
            if Self.distance(w, a, b) <= tolerance { map.select(.link(l.id)); return }
        }
        map.select(nil)
    }

    static func distance(_ p: CaseMapPoint, _ a: CaseMapPoint, _ b: CaseMapPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return p.distance(to: CaseMapPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private func zoom(to scale: Double, around point: CGPoint, from start: CaseMapViewport) {
        let s = max(CaseMapViewport.minScale, min(CaseMapViewport.maxScale, scale))
        let anchor = start.toWorld(x: point.x, y: point.y)
        map.setViewport(CaseMapViewport(scale: s, originX: anchor.x - point.x / s, originY: anchor.y - point.y / s))
    }

    private func fitAll(_ size: CGSize) -> CaseMapViewport? {
        guard size.width > 0, let b = CaseMapLayout.bounds(of: result.shown.compactMap { map.displayPlacements[$0]?.point }) else { return nil }
        return CaseMapLayout.fit(b, width: size.width, height: size.height)
    }

    @ViewBuilder private func controls(vp: CaseMapViewport, geo: CGSize, cull: (drawn: [CaseMapNodeID], offScreen: Int, overCap: Int)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { zoom(to: vp.scale * 1.25, around: CGPoint(x: geo.width / 2, y: geo.height / 2), from: vp) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: [.command, .control])
                Button { zoom(to: vp.scale / 1.25, around: CGPoint(x: geo.width / 2, y: geo.height / 2), from: vp) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: [.command, .control])
                Button { if let f = fitAll(geo) { map.setViewport(f) } } label: { Label("Fit all", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("Fit everything shown in this view")
                Button {
                    guard case .node(let id)? = map.selection else { return }
                    let pts = ([id] + projection.links(of: id).map { $0.from == id ? $0.to : $0.from }).compactMap { map.displayPlacements[$0]?.point }
                    if let b = CaseMapLayout.bounds(of: pts) { map.setViewport(CaseMapLayout.fit(b, width: geo.width, height: geo.height)) }
                } label: { Label("Fit selection", systemImage: "scope") }
                    .help("Fit the selected item and what links to it")
                if case .node(let id)? = map.selection {
                    if !CaseMapFolds.descendants(of: id, in: projection).isEmpty, map.frame == nil {
                        Button { Task { await map.toggleFold(id, repository: repository, actor: actor) } } label: {
                            Label(map.isFolded(id) ? "Unfold branch" : "Fold branch", systemImage: map.isFolded(id) ? "chevron.down.square" : "chevron.right.square")
                        }
                        .help("Folds what hangs under this item (what was taken from it, its results and work, what was placed in it) into its card, which counts them and says how many are new, blocked or waiting for review.")
                    }
                    Button { Task { await map.togglePin(id, repository: repository) } } label: {
                        Label(map.displayPlacements[id]?.pinned == true ? "Unpin" : "Pin", systemImage: map.displayPlacements[id]?.pinned == true ? "pin.slash" : "pin")
                    }
                    Button { Task { await map.hide(id, repository: repository, actor: actor) } } label: { Label("Hide from this view", systemImage: "eye.slash") }
                }
            }
            .labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.small)
            if cull.overCap > 0 {
                Text("Showing \(cull.drawn.count) of the items in this area (display limit \(Self.drawCap)); \(cull.overCap) more are here — zoom in, or use the list.")
                    .font(.caption2).padding(4).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
            if cull.offScreen > 0 {
                Text("\(cull.offScreen) shown item(s) are outside this area — Fit all brings them in.")
                    .font(.caption2).foregroundStyle(.secondary).padding(4).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(8)
    }
}

/// The equivalent list: the same items, filters, selection and inspector; keyboard and VoiceOver.
struct CaseMapList: View {
    let map: CaseMapWorkspaceModel
    let projection: CaseMapProjection
    let result: CaseMapViewResult
    let repository: CaseMapRepository?
    let actor: String
    /// Smart-map M1 — open a row's record as a frame (the inspector's command, here for the keyboard path).
    var openFrame: (CaseMapNodeID) -> Void = { _ in }
    /// M9 — pages shown per section (and for the links); every row stays reachable through "Show more". Deep dive batch 5:
    /// kept in the model, so a reveal opens the page that holds its row.
    private var pages: [String: Int] { map.listPages }

    var body: some View {
        List(selection: Binding<CaseMapWorkspaceModel.Selection?>(get: { map.selection }, set: { map.select($0) })) {
            ForEach(CaseMapListPaging.sections(projection, result: result), id: \.title) { section in
                let page = CaseMapListPaging.visible(section.ids, pages: pages[section.title] ?? 1)
                Section("\(section.title) (\(section.ids.count))") {
                    ForEach(Array(page.rows), id: \.self) { id in
                        if let n = projection.node(id) { row(n).tag(CaseMapWorkspaceModel.Selection.node(id)) }
                    }
                    if page.remaining > 0 { moreButton(section.title, remaining: page.remaining) }
                }
            }
            if !result.collapsedGroups.isEmpty {
                Section("Collapsed groups") {
                    ForEach(result.collapsedGroups) { g in
                        Button { Task { await map.toggleCollapse(g.id, repository: repository, actor: actor) } } label: {
                            Label("\(g.title) — \(g.members.count) item(s), collapsed. Expand", systemImage: "square.stack.3d.up")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if !result.links.isEmpty {
                let linkPage = CaseMapListPaging.visible(result.links, pages: pages["links"] ?? 1)
                Section("Links (\(result.links.count))") {
                    ForEach(Array(linkPage.rows), id: \.self) { lid in
                        if let l = projection.link(lid) {
                            Label("\(projection.node(l.from)?.title ?? "?") — \(l.type.label) → \(projection.node(l.to)?.title ?? "?")",
                                  systemImage: l.type.stroke == .solid ? "line.diagonal" : "line.diagonal.arrow")
                                .font(.caption).lineLimit(2)
                                .tag(CaseMapWorkspaceModel.Selection.link(lid))
                                .accessibilityLabel(CaseMapSpoken.linkLabel(l, in: projection))
                                .accessibilityValue(CaseMapSpoken.linkValue(l, selected: map.selection == .link(lid)))
                        }
                    }
                    if linkPage.remaining > 0 { moreButton("links", remaining: linkPage.remaining) }
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("case.map.list")
    }

    private func moreButton(_ key: String, remaining: Int) -> some View {
        Button("Show \(min(remaining, CaseMapListPaging.pageSize)) more (\(remaining) not shown yet)") { map.listPages[key] = (pages[key] ?? 1) + 1 }
            .buttonStyle(.borderless).font(.caption)
            .help("The list shows long sections a page at a time so it stays quick; every item is reachable.")
    }

    private func row(_ n: CaseMapNode) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: n.kind.symbol).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title).lineLimit(2)
                Label(n.status.text, systemImage: n.status.kind.symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let f = result.folds[n.id] { Text("▸ " + f.label).font(.caption2.weight(.semibold)).lineLimit(1) }
            if map.isInSubset(n.id) { Image(systemName: "largecircle.fill.circle").font(.caption).accessibilityLabel("In the chosen range") }
            if map.multiSelection.contains(n.id) { Image(systemName: "checkmark.circle.fill").font(.caption).accessibilityLabel("Chosen") }
            if map.displayPlacements[n.id]?.pinned == true { Image(systemName: "pin.fill").font(.caption).accessibilityLabel("Pinned") }
            Text(n.review.label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CaseMapSpoken.nodeLabel(n))
        .accessibilityValue(CaseMapSpoken.nodeValue(n, pinned: map.displayPlacements[n.id]?.pinned == true, selected: map.selection == .node(n.id)))
        .accessibilityAction(named: "Open as frame") { openFrame(n.id) }
        .contextMenu {
            Button("Open as frame") { openFrame(n.id) }
            if !CaseMapFolds.descendants(of: n.id, in: projection).isEmpty, map.frame == nil {
                Button(map.isFolded(n.id) ? "Unfold branch" : "Fold branch") { Task { await map.toggleFold(n.id, repository: repository, actor: actor) } }
            }
            Button(map.multiSelection.contains(n.id) ? "Remove from the choice" : "Choose with others") { map.toggleMulti(n.id) }
            Button("Hide from this view") { Task { await map.hide(n.id, repository: repository, actor: actor) } }
            Button(map.displayPlacements[n.id]?.pinned == true ? "Unpin" : "Pin") { Task { await map.togglePin(n.id, repository: repository) } }
        }
    }
}
