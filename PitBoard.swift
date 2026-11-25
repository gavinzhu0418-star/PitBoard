// PitBoard — 菜单栏里的赛程小工具
// 点一下菜单栏图标：联网同步本赛季赛程。下拉面板左边是这一站的官方赛道图（从 F1 官网这一站的比赛页面里找图，
// 下载后缓存在本地；鼠标移到图上，图会平滑放大盖住整块面板，离开面板再缩回），右边是第几站、各节时间
// （按本机时区）和倒计时，底下是同步状态和按钮。
// 赛程数据：Jolpica F1 API（Ergast 的继任者）https://api.jolpi.ca/ergast/f1/
//
// 编译：./build.sh（需要 Xcode 命令行工具）
// 不开界面、直接打印同步结果和赛道图地址：./PitBoard.app/Contents/MacOS/PitBoard --print

import AppKit
import ServiceManagement

// MARK: - 数据模型（对应 API 返回的 JSON）

struct Slot: Codable {
    let date: String
    let time: String?
}

struct Location: Codable {
    let locality: String?
    let country: String?
}

struct Circuit: Codable {
    let circuitId: String?
    let circuitName: String
    let location: Location?

    enum CodingKeys: String, CodingKey {
        case circuitId, circuitName
        case location = "Location"
    }
}

struct Race: Codable {
    let season: String
    let round: String
    let raceName: String
    let circuit: Circuit
    let date: String
    let time: String?
    let fp1, fp2, fp3, sprintQualifying, sprint, qualifying: Slot?

    enum CodingKeys: String, CodingKey {
        case season, round, raceName, date, time
        case circuit = "Circuit"
        case fp1 = "FirstPractice"
        case fp2 = "SecondPractice"
        case fp3 = "ThirdPractice"
        case sprintQualifying = "SprintQualifying"
        case sprint = "Sprint"
        case qualifying = "Qualifying"
    }
}

struct Season: Codable {
    let year: Int
    let races: [Race]
}

/// API 外面包了几层：MRData → RaceTable → Races
struct ScheduleResponse: Decodable {
    let races: [Race]

    private enum RootKeys: String, CodingKey { case mrData = "MRData" }
    private enum MRKeys: String, CodingKey { case raceTable = "RaceTable" }
    private enum TableKeys: String, CodingKey { case races = "Races" }

    init(from decoder: Decoder) throws {
        let table = try decoder.container(keyedBy: RootKeys.self)
            .nestedContainer(keyedBy: MRKeys.self, forKey: .mrData)
            .nestedContainer(keyedBy: TableKeys.self, forKey: .raceTable)
        races = try table.decode([Race].self, forKey: .races)
    }
}

// MARK: - 时间

struct Session {
    let name: String
    let start: Date
    let timeKnown: Bool
    let minutes: Double
    var end: Date { start.addingTimeInterval(minutes * 60) }
}

let isoFormatter = ISO8601DateFormatter()

/// "2026-11-29" + "16:00:00Z" → Date；还没公布具体时间的按当天中午（UTC）算
func makeDate(_ date: String, _ time: String?) -> (date: Date, timeKnown: Bool)? {
    if let time = time {
        let t = time.hasSuffix("Z") ? time : time + "Z"
        if let d = isoFormatter.date(from: "\(date)T\(t)") { return (d, true) }
    }
    if let d = isoFormatter.date(from: "\(date)T12:00:00Z") { return (d, false) }
    return nil
}

extension Race {
    var sessions: [Session] {
        var list: [Session] = []
        func add(_ name: String, _ slot: Slot?, _ minutes: Double) {
            guard let slot = slot, let d = makeDate(slot.date, slot.time) else { return }
            list.append(Session(name: name, start: d.date, timeKnown: d.timeKnown, minutes: minutes))
        }
        add("FP1", fp1, 60)
        add("FP2", fp2, 60)
        add("FP3", fp3, 60)
        add("Sprint Quali", sprintQualifying, 45)
        add("Sprint", sprint, 60)
        add("Quali", qualifying, 60)
        add("Race", Slot(date: date, time: time), 120)
        return list.sorted { $0.start < $1.start }
    }

    /// 正赛开始 3 小时后这一站算结束，切到下一站
    var finishedBy: Date {
        (makeDate(date, time)?.date ?? .distantPast).addingTimeInterval(3 * 3600)
    }
}

/// 例如 "Sat 28 Nov"
let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_AU")
    f.dateFormat = "EEE d MMM"
    return f
}()

let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_AU")
    f.dateFormat = "HH:mm"
    return f
}()

func describe(_ s: Session) -> String {
    let day = dayFormatter.string(from: s.start)
    return s.timeKnown ? "\(day)  \(clockFormatter.string(from: s.start))" : "\(day)  TBC"
}

/// 例如 "2d 3h"、"5h 20m"、"12m"
func countdown(_ interval: TimeInterval) -> String {
    let m = Int(interval / 60)
    if m < 1 { return "<1m" }
    let d = m / 1440, h = m % 1440 / 60, mm = m % 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(mm)m" }
    return "\(mm)m"
}

/// "Qatar Grand Prix" → "Qatar GP"
func short(_ raceName: String) -> String {
    raceName.replacingOccurrences(of: "Grand Prix", with: "GP")
}

// MARK: - 菜单内容

enum Row {
    case header(String)
    case text(String)
    case note(String)
    case session(mark: String, name: String, time: String, bold: Bool)
    case separator

    var plain: String {
        switch self {
        case .header(let s), .text(let s), .note(let s): return s
        case .session(let mark, let name, let time, _): return "\(mark) \(name)\t\(time)"
        case .separator: return "----"
        }
    }
}

/// 第一个还没结束的大奖赛 = 当前站（比赛周末进行中）或下一站
func pick(_ seasons: [Season], now: Date = Date()) -> (current: (race: Race, total: Int)?, previous: Race?) {
    var previous: Race?
    for season in seasons.sorted(by: { $0.year < $1.year }) {
        for race in season.races {
            if race.finishedBy > now {
                return (current: (race: race, total: season.races.count), previous: previous)
            }
            previous = race
        }
    }
    return (current: nil, previous: previous)
}

func buildRows(_ seasons: [Season], now: Date = Date()) -> [Row] {
    let (current, previous) = pick(seasons, now: now)

    guard let cur = current else {
        var rows: [Row] = [.header("Season finished")]
        if let last = previous { rows.append(.note("Last: \(last.season) \(short(last.raceName))")) }
        rows.append(.note("Next calendar not published yet"))
        return rows
    }

    let race = cur.race
    let sessions = race.sessions
    let place = [race.circuit.location?.locality, race.circuit.location?.country]
        .compactMap { $0 }.joined(separator: ", ")
    var rows: [Row] = [
        .header("\(race.season) · Round \(race.round)/\(cur.total)"),
        .text(short(race.raceName)),
        .note(place.isEmpty ? race.circuit.circuitName : "\(race.circuit.circuitName) · \(place)"),
        .separator,
    ]

    let live = sessions.firstIndex { $0.start <= now && now < $0.end }
    let next = sessions.firstIndex { $0.start > now }
    if let i = live {
        rows.append(.text("🔴 \(sessions[i].name) live"))
    } else if let i = next {
        let prefix = i == 0 ? "" : "Race weekend · "
        rows.append(.text("\(prefix)\(sessions[i].name) in \(countdown(sessions[i].start.timeIntervalSince(now)))"))
    } else {
        rows.append(.text("🏁 Race finished"))
    }

    for (i, s) in sessions.enumerated() {
        let isNext = live == nil && i == next
        let mark: String
        if s.end <= now { mark = "✓" }
        else if i == live { mark = "●" }
        else if isNext { mark = "▶" }
        else { mark = "" }
        rows.append(.session(mark: mark, name: s.name, time: describe(s), bold: i == live || isNext))
    }

    if let prev = previous {
        rows.append(.separator)
        let name = prev.season == race.season ? short(prev.raceName) : "\(prev.season) \(short(prev.raceName))"
        rows.append(.note("Prev: \(name)"))
    }
    return rows
}

// MARK: - 网络同步和缓存

struct HTTPStatusError: LocalizedError {
    let code: Int
    var errorDescription: String? { "HTTP \(code)" }
}

enum API {
    static func season(_ year: Int) async throws -> Season {
        var request = URLRequest(url: URL(string: "https://api.jolpi.ca/ergast/f1/\(year).json?limit=100")!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HTTPStatusError(code: http.statusCode)
        }
        let races = try JSONDecoder().decode(ScheduleResponse.self, from: data).races
        return Season(year: year, races: races)
    }

    /// 拉今年的赛程；今年已经没有比赛了就再拉明年的，这样赛季结束后会显示下赛季揭幕战
    static func sync(now: Date = Date()) async throws -> [Season] {
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        let this = try await season(year)
        if this.races.contains(where: { $0.finishedBy > now }) { return [this] }
        if let next = try? await season(year + 1), !next.races.isEmpty { return [this, next] }
        return [this]
    }
}

struct Cache: Codable {
    let fetchedAt: Date
    let seasons: [Season]
}

enum Store {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PitBoard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("schedule.json")
    }()

    static func load() -> Cache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    static func save(_ cache: Cache) {
        try? JSONEncoder().encode(cache).write(to: fileURL)
    }
}

// MARK: - 赛道图（F1 官网比赛页上的 detailed 赛道图）

struct MapError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum TrackMap {
    /// 比赛页地址 https://www.formula1.com/en/racing/<年份>/<slug> 的候选 slug，按顺序试。
    /// 大多数是国家名；几个例外单独列出；最后再试比赛名（例如 2026 年在马来西亚办的巴林站，官网仍是 bahrain）
    static func pageSlugs(_ race: Race) -> [String] {
        func slug(_ s: String) -> String {
            s.folding(options: .diacriticInsensitive, locale: nil)
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        }
        let special = [
            "americas": "united-states", "miami": "miami", "vegas": "las-vegas",
            "silverstone": "great-britain", "yas_marina": "united-arab-emirates",
            "catalunya": "barcelona-catalunya", "imola": "emilia-romagna",
        ]
        var slugs: [String] = []
        if let id = race.circuit.circuitId, let s = special[id] { slugs.append(s) }
        if let country = race.circuit.location?.country { slugs.append(slug(country)) }
        if let r = race.raceName.range(of: " Grand Prix") {
            slugs.append(slug(String(race.raceName[..<r.lowerBound])))
        }
        var seen = Set<String>()
        return slugs.filter { seen.insert($0).inserted }
    }

    static func imageURL(for race: Race) async throws -> URL {
        var failure: Error = MapError(message: "no map on the F1 race page")
        for slug in pageSlugs(race) {
            guard let page = URL(string: "https://www.formula1.com/en/racing/\(race.season)/\(slug)") else { continue }
            do {
                if let url = try await findImage(on: page) { return url }
            } catch {
                failure = error
            }
        }
        throw failure
    }

    /// 在比赛页的 HTML 里找 …/track/<年份>track<赛道>detailed.webp 这张图
    static func findImage(on page: URL) async throws -> URL? {
        let (data, response) = try await URLSession.shared.data(from: page)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HTTPStatusError(code: http.statusCode)
        }
        let html = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        let pattern = #"https://media\.formula1\.com/image/upload/[^"'\s<>]*?/track/[^"'\s<>]*?detailed\.(webp|png|jpg)"#
        guard let range = html.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(html[range]))
    }

    static let folder: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PitBoard/maps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 先看本地缓存，没有再从官网下载
    static func image(for race: Race) async throws -> NSImage {
        let file = folder.appendingPathComponent("\(race.season)-\(race.round)")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) { return image }
        let url = try await imageURL(for: race)
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HTTPStatusError(code: http.statusCode)
        }
        guard let image = NSImage(data: data) else { throw MapError(message: "unreadable image") }
        try? data.write(to: file)
        return image
    }
}

/// 赛道图内容整体偏亮（比如白色线条）就配深色底，否则配白底，保证看得清
func wantsDarkBackground(_ image: NSImage) -> Bool {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
    let side = 48
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    pixels.withUnsafeMutableBytes { buffer in
        guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
    }
    var sum = 0.0, weight = 0.0
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let alpha = Double(pixels[i + 3]) / 255
        guard alpha > 0.05 else { continue }
        // 像素是预乘过 alpha 的，直接累加再除以 alpha 总和就是按不透明度加权的平均亮度
        sum += (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255
        weight += alpha
    }
    return weight > 0 && sum / weight > 0.6
}

// MARK: - 下拉面板

/// 赛道图卡片。平时在面板左边；放大时卡片平滑长大到盖住整块面板（Core Animation 动画）
final class MapView: NSView {
    private let card = CALayer()
    private let picture = CALayer()
    private let caption = CATextLayer()
    private var hasImage = false
    private var expanded = false
    private var smallRect = CGRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 自己提供图层（layer-hosting），卡片和图片都是独立图层，方便做动画
        layer = CALayer()
        wantsLayer = true
        card.cornerRadius = 10
        card.cornerCurve = .continuous
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0
        card.shadowRadius = 12
        card.shadowOffset = CGSize(width: 0, height: -4)
        picture.contentsGravity = .resizeAspect
        caption.string = "Loading track map…"
        caption.font = NSFont.menuFont(ofSize: 12)
        caption.fontSize = 12
        caption.alignmentMode = .center
        caption.foregroundColor = NSColor.gray.cgColor
        caption.contentsScale = 2
        card.addSublayer(picture)
        card.addSublayer(caption)
        layer?.addSublayer(card)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    // 这个视图铺满整块面板：平时让点击穿过去（底下有按钮），放大时挡住点击
    override func hitTest(_ point: NSPoint) -> NSView? {
        expanded ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    /// 放大时卡片四周留 6pt 边
    private var expandedRect: CGRect {
        bounds.insetBy(dx: 6, dy: 6)
    }

    private func place(_ rect: CGRect) {
        card.bounds = CGRect(origin: .zero, size: rect.size)
        card.position = CGPoint(x: rect.midX, y: rect.midY)
        picture.frame = card.bounds.insetBy(dx: 10, dy: 10)
        caption.frame = CGRect(x: 0, y: card.bounds.midY - 8, width: card.bounds.width, height: 16)
    }

    /// rect：平时卡片的位置（本视图坐标）；image 为 nil 时显示“加载中”的占位卡片
    func show(_ image: NSImage?, at rect: CGRect) {
        let fadeIn = !hasImage && image != nil
        hasImage = image != nil
        smallRect = rect
        if image == nil { expanded = false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(expanded ? expandedRect : smallRect)
        caption.isHidden = image != nil
        if let image = image {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            picture.contentsScale = scale
            picture.contents = image.layerContents(forContentsScale: scale)
            card.backgroundColor = (wantsDarkBackground(image) ? NSColor(white: 0.12, alpha: 1) : NSColor.white).cgColor
        } else {
            picture.contents = nil
            card.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
        }
        CATransaction.commit()
        if fadeIn {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.3
            picture.add(fade, forKey: "fadeIn")
        }
    }

    /// 放大 0.35 秒、缩回 0.25 秒，都是先快后慢的缓动；图片按原比例跟着卡片一起变大
    func setExpanded(_ on: Bool, animated: Bool = true) {
        if on && !hasImage { return }
        if animated && on == expanded { return }
        expanded = on
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(on ? 0.35 : 0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        place(on ? expandedRect : smallRect)
        card.shadowOpacity = on ? 0.3 : 0
        CATransaction.commit()
    }
}

/// 整个下拉面板：左边赛道图，右边赛程信息，底下一排状态和按钮。
/// 它是菜单里唯一的一项，所以和菜单同时出现、同时消失。
/// 鼠标移到赛道图上 → 图放大盖住整块面板；鼠标离开面板 → 缩回。
final class DashboardView: NSView {
    static let mapWidth: CGFloat = 360
    let map = MapView(frame: .zero)
    var onSync: () -> Void = {}
    var onToggleLogin: () -> Void = {}
    var onQuit: () -> Void = {}

    private var labels: [NSView] = []
    private let footerLine = NSBox()
    private let noteLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var loginBox = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(loginClicked))
    private lazy var syncButton = NSButton(title: "Sync Now", target: self, action: #selector(syncClicked))
    private lazy var quitButton = NSButton(title: "Quit", target: self, action: #selector(quitClicked))
    private var mapRect = NSRect.zero   // 赛道图平时的位置（本视图坐标，左上角是原点）
    private var mapArea: NSTrackingArea?
    private var panelArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        footerLine.boxType = .separator
        for label in [noteLabel, statusLabel] {
            label.font = .menuFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        for button in [syncButton, quitButton] {
            button.isBordered = false
            button.contentTintColor = .controlAccentColor
            button.font = .menuFont(ofSize: 0)
        }
        loginBox.font = .menuFont(ofSize: 0)
        let fixed: [NSView] = [footerLine, noteLabel, statusLabel, loginBox, syncButton, quitButton]
        for view in fixed { addSubview(view) }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(rows: [Row], image: NSImage?, showMap: Bool, note: String?, status: String, loginOn: Bool) {
        labels.forEach { $0.removeFromSuperview() }
        labels = rows.map { makeView($0) }

        let pad: CGFloat = 14, gap: CGFloat = 18
        let infoX = showMap ? pad + Self.mapWidth + gap : pad

        // 右边：赛程信息从上往下排
        var y = pad
        var infoWidth: CGFloat = 230
        for (row, view) in zip(rows, labels) {
            addSubview(view)
            if case .separator = row {
                view.frame = NSRect(x: infoX, y: y + 5, width: 0, height: 1)
                y += 11
            } else {
                let size = view.fittingSize
                view.frame = NSRect(x: infoX, y: y, width: size.width, height: size.height)
                infoWidth = max(infoWidth, size.width)
                y += size.height + 3
            }
        }
        for view in labels where view is NSBox {
            view.frame.size.width = infoWidth
        }
        let infoHeight = y - pad

        // 左边：赛道图，宽度固定，高度跟图片比例走，和右边顶部对齐
        var mapHeight: CGFloat = 0
        if showMap {
            let ratio = image.map { $0.size.height / max($0.size.width, 1) } ?? 0.7
            mapHeight = min(max(Self.mapWidth * ratio, 180), 360)
        }

        // 底部：（赛道图出错时的提示）+ 分隔线 + 左边状态、右边按钮
        loginBox.state = loginOn ? .on : .off
        statusLabel.stringValue = status
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = note == nil
        let buttons: [NSView] = [loginBox, syncButton, quitButton]
        let buttonsWidth = buttons.reduce(CGFloat(0)) { $0 + $1.fittingSize.width } + 14 * CGFloat(buttons.count - 1)
        let width = max(infoX + infoWidth + pad, pad + 120 + 20 + buttonsWidth + pad)

        var bottom = pad + max(infoHeight, mapHeight)
        if note != nil {
            bottom += 8
            noteLabel.frame = NSRect(x: pad, y: bottom, width: width - pad * 2, height: noteLabel.fittingSize.height)
            bottom += noteLabel.frame.height
        }
        bottom += 10
        footerLine.frame = NSRect(x: pad, y: bottom, width: width - pad * 2, height: 1)
        bottom += 9

        let rowHeight = buttons.map { $0.fittingSize.height }.max() ?? 18
        var x = width - pad
        for button in buttons.reversed() {
            let size = button.fittingSize
            x -= size.width
            button.frame = NSRect(x: x, y: bottom + (rowHeight - size.height) / 2, width: size.width, height: size.height)
            x -= 14
        }
        let statusSize = statusLabel.fittingSize
        statusLabel.frame = NSRect(x: pad, y: bottom + (rowHeight - statusSize.height) / 2,
                                   width: min(statusSize.width, x - pad), height: statusSize.height)
        bottom += rowHeight + pad

        setFrameSize(NSSize(width: width, height: bottom))

        // 赛道图视图铺满整块面板并放在最上层，放大时才能盖住所有内容
        if showMap {
            mapRect = NSRect(x: pad, y: pad, width: Self.mapWidth, height: mapHeight)
            map.frame = bounds
            addSubview(map, positioned: .above, relativeTo: nil)
            // MapView 的坐标原点在左下角，这里换算一下
            map.show(image, at: CGRect(x: mapRect.minX, y: bounds.height - mapRect.maxY,
                                       width: mapRect.width, height: mapRect.height))
        } else {
            map.removeFromSuperview()
            mapRect = .zero
        }
        updateTrackingAreas()
    }

    // 两个感应区：进入赛道图区域就放大；离开整块面板才缩回
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = mapArea { removeTrackingArea(area) }
        if let area = panelArea { removeTrackingArea(area) }
        mapArea = nil
        panelArea = nil
        guard map.superview != nil else { return }
        // 菜单打开时 App 不是前台，所以要 activeAlways
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        let mapZone = NSTrackingArea(rect: mapRect, options: options, owner: self, userInfo: nil)
        let panelZone = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(mapZone)
        addTrackingArea(panelZone)
        mapArea = mapZone
        panelArea = panelZone
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === mapArea { map.setExpanded(true) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === panelArea { map.setExpanded(false) }
    }

    @objc private func syncClicked() {
        onSync()
    }

    @objc private func loginClicked() {
        onToggleLogin()
    }

    @objc private func quitClicked() {
        onQuit()
    }

    private func makeView(_ row: Row) -> NSView {
        switch row {
        case .separator:
            let line = NSBox()
            line.boxType = .separator
            return line
        case .header(let s):
            return label(s, [.font: NSFont.boldSystemFont(ofSize: 14)])
        case .text(let s):
            return label(s, [.font: NSFont.menuFont(ofSize: 0)])
        case .note(let s):
            return label(s, [.font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        case .session(let mark, let name, let time, let bold):
            let style = NSMutableParagraphStyle()
            style.tabStops = [
                NSTextTab(textAlignment: .left, location: 18, options: [:]),
                NSTextTab(textAlignment: .left, location: 108, options: [:]),
            ]
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: bold ? .bold : .regular)
            return label("\(mark)\t\(name)\t\(time)", [.font: font, .paragraphStyle: style])
        }
    }

    private func label(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> NSTextField {
        var attributes = attributes
        if attributes[.foregroundColor] == nil { attributes[.foregroundColor] = NSColor.labelColor }
        return NSTextField(labelWithAttributedString: NSAttributedString(string: text, attributes: attributes))
    }
}

// MARK: - 菜单栏

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var cache = Store.load()
    private var syncing = false
    private var lastError: String?

    // 菜单里只有一项：整块下拉面板（自定义视图）
    private let dashboard = DashboardView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    private let dashboardItem = NSMenuItem()
    private var maps: [String: NSImage] = [:]
    private var mapLoading: Set<String> = []
    private var mapError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 图标是 App 里 Resources/MenuIcon.png（和 @2x），由 build.sh 拷进去
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let logo = Bundle.main.image(forResource: "MenuIcon") {
            statusItem.button?.image = logo
        } else {
            statusItem.button?.title = "🏁"
        }

        dashboard.onSync = { [weak self] in self?.sync() }
        dashboard.onToggleLogin = { [weak self] in self?.toggleLogin() }
        dashboard.onQuit = { NSApp.terminate(nil) }

        menu.delegate = self
        menu.autoenablesItems = false
        dashboardItem.view = dashboard
        menu.addItem(dashboardItem)
        statusItem.menu = menu
        rebuildMenu()
        sync()
    }

    // 每次点开前重画，倒计时是最新的
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        dashboard.map.setExpanded(false, animated: false)
        loadMap()
        // 数据超过 10 分钟就重新同步
        if let t = cache?.fetchedAt, Date().timeIntervalSince(t) < 600 { return }
        sync()
    }

    func menuDidClose(_ menu: NSMenu) {
        dashboard.map.setExpanded(false, animated: false)
    }

    private func sync() {
        guard !syncing else { return }
        syncing = true
        rebuildMenu()
        Task {
            do {
                let seasons = try await API.sync()
                let fresh = Cache(fetchedAt: Date(), seasons: seasons)
                self.cache = fresh
                self.lastError = nil
                Store.save(fresh)
            } catch {
                self.lastError = error.localizedDescription
            }
            self.syncing = false
            self.rebuildMenu()
            self.loadMap()
        }
    }

    // MARK: 赛道图

    private var currentRace: Race? {
        cache.flatMap { pick($0.seasons).current?.race }
    }

    private func mapKey(_ race: Race) -> String {
        "\(race.season)-\(race.round)"
    }

    private func loadMap() {
        guard let race = currentRace else { return }
        let key = mapKey(race)
        guard maps[key] == nil, !mapLoading.contains(key) else { return }
        mapLoading.insert(key)
        mapError = nil
        rebuildMenu()
        Task {
            do {
                self.maps[key] = try await TrackMap.image(for: race)
            } catch {
                self.mapError = error.localizedDescription
            }
            self.mapLoading.remove(key)
            self.rebuildMenu()
        }
    }

    // MARK: 面板内容

    private func rebuildMenu() {
        let race = currentRace
        let image = race.flatMap { maps[mapKey($0)] }
        let loading = race.map { mapLoading.contains(mapKey($0)) } ?? false
        let rows = cache.map { buildRows($0.seasons) } ?? [.text(syncing ? "Syncing…" : "No data yet")]

        var status = ""
        if syncing {
            status = "Syncing…"
        } else if let error = lastError {
            status = "Sync failed: \(error)"
        } else if let t = cache?.fetchedAt {
            status = "Synced \(clockFormatter.string(from: t))"
        }
        let note = (image == nil && !loading) ? mapError.map { "Track map failed: \($0)" } : nil

        dashboard.update(rows: rows, image: image, showMap: image != nil || loading,
                         note: note, status: status, loginOn: SMAppService.mainApp.status == .enabled)
    }

    private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            menu.cancelTracking()
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
                + "\nYou can add PitBoard in System Settings → General → Login Items."
            NSApp.activate()
            _ = alert.runModal()
        }
        if service.status == .requiresApproval {
            menu.cancelTracking()
            SMAppService.openSystemSettingsLoginItems()
        }
        rebuildMenu()
    }
}

// MARK: - 入口

@main
struct PitBoardMain {
    @MainActor
    static func main() {
        // 测试用：不开界面，同步一次后把菜单内容和赛道图地址打印出来
        if CommandLine.arguments.contains("--print") {
            Task {
                do {
                    let seasons = try await API.sync()
                    for row in buildRows(seasons) { print(row.plain) }
                    if let race = pick(seasons).current?.race {
                        do {
                            let url = try await TrackMap.imageURL(for: race)
                            print("Track map: \(url.absoluteString)")
                        } catch {
                            print("Track map failed: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    print("Sync failed: \(error.localizedDescription)")
                }
                exit(0)
            }
            dispatchMain()
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
