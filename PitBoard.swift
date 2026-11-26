// PitBoard — a menu bar app for F1 race weekends
// Click the menu bar icon to sync this season's schedule. The panel shows the official circuit map for the
// current round on the left (found on that round's formula1.com race page, downloaded once and cached; hover
// over it and it smoothly grows to cover the whole panel), the round, every session in local time and a
// countdown on the right. Under them: constructor standings, driver standings, and the full results
// of the latest finished session. Sync status and buttons along the bottom.
//
// Data: schedule and standings from the Jolpica F1 API (the Ergast successor) https://api.jolpi.ca/ergast/f1/;
// latest session results and team colours from OpenF1 https://openf1.org; circuit maps are loaded at
// runtime from formula1.com and cached locally.
//
// Build: ./build.sh (needs the Xcode Command Line Tools)
// Print the synced data without the UI: ./PitBoard.app/Contents/MacOS/PitBoard --print

import AppKit
import ServiceManagement

// MARK: - Models (match the API's JSON)

struct Slot: Codable {
    let date: String
    let time: String?
}

struct Location: Codable {
    let locality: String?
    let country: String?
    let lat: String?    // for the weather forecast
    let long: String?
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

/// The API wraps the races in a few layers: MRData → RaceTable → Races
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

// MARK: - Standings models (Jolpica)

struct StandingDriver: Codable {
    let driverId: String
    let code: String?
    let familyName: String
}

struct StandingConstructor: Codable {
    let constructorId: String
    let name: String
}

struct DriverStanding: Codable {
    let position: String?
    let points: String
    let driver: StandingDriver
    let constructors: [StandingConstructor]

    enum CodingKeys: String, CodingKey {
        case position, points
        case driver = "Driver"
        case constructors = "Constructors"
    }
}

struct TeamStanding: Codable {
    let position: String?
    let points: String
    let constructor: StandingConstructor

    enum CodingKeys: String, CodingKey {
        case position, points
        case constructor = "Constructor"
    }
}

/// MRData → StandingsTable → StandingsLists[0] → DriverStandings or ConstructorStandings
struct StandingsResponse<Item: Codable>: Decodable {
    let round: Int
    let items: [Item]

    private enum Keys: String, CodingKey {
        case mrData = "MRData", table = "StandingsTable", lists = "StandingsLists", round
        case drivers = "DriverStandings", teams = "ConstructorStandings"
    }

    init(from decoder: Decoder) throws {
        var lists = try decoder.container(keyedBy: Keys.self)
            .nestedContainer(keyedBy: Keys.self, forKey: .mrData)
            .nestedContainer(keyedBy: Keys.self, forKey: .table)
            .nestedUnkeyedContainer(forKey: .lists)
        guard !lists.isAtEnd else {
            round = 0
            items = []
            return
        }
        let first = try lists.nestedContainer(keyedBy: Keys.self)
        round = Int(try first.decodeIfPresent(String.self, forKey: .round) ?? "") ?? 0
        items = try first.decodeIfPresent([Item].self, forKey: .drivers)
            ?? first.decodeIfPresent([Item].self, forKey: .teams) ?? []
    }
}

struct Standings: Codable {
    let season: Int
    let round: Int
    let drivers: [DriverStanding]
    let teams: [TeamStanding]
}

/// One race result with its fastest lap (Jolpica /results)
struct RaceResult: Codable {
    let driver: StandingDriver
    let constructor: StandingConstructor
    let fastestLap: FastestLap?

    struct FastestLap: Codable {
        let rank: String?
        let time: LapTime?

        struct LapTime: Codable {
            let time: String?
        }

        enum CodingKeys: String, CodingKey {
            case rank
            case time = "Time"
        }
    }

    enum CodingKeys: String, CodingKey {
        case driver = "Driver"
        case constructor = "Constructor"
        case fastestLap = "FastestLap"
    }
}

/// MRData → RaceTable → Races[] → Results[], all races flattened
struct ResultsResponse: Decodable {
    let results: [RaceResult]

    private enum Keys: String, CodingKey {
        case mrData = "MRData", table = "RaceTable", races = "Races", results = "Results"
    }

    init(from decoder: Decoder) throws {
        var races = try decoder.container(keyedBy: Keys.self)
            .nestedContainer(keyedBy: Keys.self, forKey: .mrData)
            .nestedContainer(keyedBy: Keys.self, forKey: .table)
            .nestedUnkeyedContainer(forKey: .races)
        var all: [RaceResult] = []
        while !races.isAtEnd {
            let race = try races.nestedContainer(keyedBy: Keys.self)
            all += try race.decodeIfPresent([RaceResult].self, forKey: .results) ?? []
        }
        results = all
    }
}

// MARK: - Session result models (OpenF1, decoded with convertFromSnakeCase)

struct OFSession: Codable {
    let sessionKey: Int
    let sessionName: String
    let dateEnd: String?
    let location: String?
    let countryName: String?
    let circuitShortName: String?
    let isCancelled: Bool?
}

struct OFDriver: Codable {
    let driverNumber: Int
    let nameAcronym: String?
    let teamColour: String?
}

struct OFResult: Codable {
    let position: Int?
    let driverNumber: Int
    let duration: LapValue?        // best lap (practice, qualifying) or total time (sprint, race)
    let gapToLeader: GapValue?
    let dnf: Bool?
    let dns: Bool?
    let dsq: Bool?
}

/// gap_to_leader: seconds behind the winner, or text such as "+1 LAP" (qualifying sends an array, not used)
enum GapValue: Codable {
    case seconds(Double)
    case text(String)
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .seconds(value)
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else {
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .seconds(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        case .unknown: try container.encodeNil()
        }
    }
}

struct OFLap: Codable {
    let driverNumber: Int
    let lapDuration: Double?
}

/// One tyre stint of one driver (OpenF1 /stints)
struct OFStint: Codable {
    let driverNumber: Int
    let compound: String?
    let lapStart: Int?
    let lapEnd: Int?
}

/// A best lap in seconds: one number (practice) or [Q1, Q2, Q3] with nulls (qualifying, uses the last time set)
struct LapValue: Codable {
    let seconds: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let one = try? container.decode(Double.self) {
            seconds = one
        } else if let many = try? container.decode([Double?].self) {
            seconds = many.last(where: { $0 != nil }) ?? nil
        } else {
            seconds = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(seconds)
    }
}

/// One line of the latest finished session, ready to display (also kept in the cache); position 0 = unclassified
struct BoardRow: Codable {
    let position: Int
    let code: String
    let colour: String?
    let time: String
    let fastest: Bool?           // optional so caches from older versions still load
}

struct SessionBoard: Codable {
    let title: String
    let rows: [BoardRow]
    var fastestLap: BoardRow? = nil   // sprint and race: who set the fastest lap, shown under the results
}

// MARK: - Time

struct Session {
    let name: String
    let start: Date
    let timeKnown: Bool
    let minutes: Double
    var end: Date { start.addingTimeInterval(minutes * 60) }
}

let isoFormatter = ISO8601DateFormatter()

/// "2026-11-29" + "16:00:00Z" → Date; a session without a published time counts as noon UTC that day
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

    /// A round counts as finished 3 hours after the race starts; then the next round takes over
    var finishedBy: Date {
        (makeDate(date, time)?.date ?? .distantPast).addingTimeInterval(3 * 3600)
    }
}

/// e.g. "Sat 28 Nov"
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

/// e.g. "2d 3h", "5h 20m", "12m"
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

/// OpenF1 timestamps look like "2026-11-28T15:30:00+00:00"
func isoDate(_ text: String) -> Date? {
    isoFormatter.date(from: text)
}

/// 84.567 → "1:24.567"
func lapText(_ seconds: Double) -> String {
    let minutes = Int(seconds) / 60
    let rest = seconds - Double(minutes * 60)
    return minutes > 0 ? String(format: "%d:%06.3f", minutes, rest) : String(format: "%.3f", rest)
}

/// Total race time: 5504.742 → "1:31:44.742", 1844.2 → "30:44.200"
func raceTime(_ seconds: Double) -> String {
    let hours = Int(seconds) / 3600
    let minutes = Int(seconds) % 3600 / 60
    let rest = seconds - Double(hours * 3600 + minutes * 60)
    return hours > 0 ? String(format: "%d:%02d:%06.3f", hours, minutes, rest)
                     : String(format: "%d:%06.3f", minutes, rest)
}

/// Sprint / race result like the official classification: the winner's time, then "+5.123s", "+1 Lap", "DNF"
func raceGap(_ result: OFResult, winner: Bool) -> String {
    if result.dsq == true { return "DSQ" }
    if result.dns == true { return "DNS" }
    if result.dnf == true { return "DNF" }
    if winner { return result.duration?.seconds.map(raceTime) ?? "—" }
    switch result.gapToLeader {
    case .seconds(let gap)?:
        return String(format: "+%.3fs", gap)
    case .text(let text)?:
        return text.replacingOccurrences(of: "LAPS", with: "Laps").replacingOccurrences(of: "LAP", with: "Lap")
    default:
        return "—"
    }
}

/// "Practice 1" → "FP1", "Qualifying" → "Quali" …
func shortSession(_ name: String) -> String {
    switch name {
    case "Practice 1": return "FP1"
    case "Practice 2": return "FP2"
    case "Practice 3": return "FP3"
    case "Qualifying": return "Quali"
    case "Sprint Qualifying", "Sprint Shootout": return "Sprint Quali"
    default: return name
    }
}

/// "Alpine F1 Team" → "Alpine", "RB F1 Team" → "Racing Bulls"
func teamName(_ constructor: StandingConstructor) -> String {
    if constructor.constructorId == "rb" { return "Racing Bulls" }
    return constructor.name.replacingOccurrences(of: " F1 Team", with: "")
}

/// "FF8000" → NSColor
func colour(hex: String?) -> NSColor? {
    guard let hex = hex?.replacingOccurrences(of: "#", with: ""), hex.count == 6,
          let value = Int(hex, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

let gold = NSColor(srgbRed: 0.85, green: 0.65, blue: 0.13, alpha: 1)
let silver = NSColor(srgbRed: 0.66, green: 0.67, blue: 0.70, alpha: 1)
let bronze = NSColor(srgbRed: 0.80, green: 0.50, blue: 0.20, alpha: 1)

/// Pirelli's hard tyre is white; on a light background that turns light grey so it stays visible
let hardWhite = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : NSColor(white: 0.6, alpha: 1)
}

/// Sidewall colours by OpenF1 compound name
func compoundColour(_ compound: String) -> NSColor {
    switch compound.uppercased() {
    case "SOFT": return .systemRed
    case "MEDIUM": return .systemYellow
    case "HARD": return hardWhite
    case "INTERMEDIATE": return .systemGreen
    case "WET": return .systemBlue
    default: return .systemGray
    }
}

/// The weekend's compounds in order: 0 = hard (white), 1 = medium (yellow), 2 = soft (red)
func tyreColour(rank: Int) -> NSColor {
    compoundColour(["HARD", "MEDIUM", "SOFT"][min(max(rank, 0), 2)])
}

// MARK: - Panel content

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

/// The first Grand Prix that hasn't finished = the current round (race weekend under way) or the next one
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

// MARK: - Championship maths

/// Most points one driver / one team can still score: every race and sprint that is still to come or not yet
/// counted in the standings (current rules: race 25 / 18, sprint 8 / 7, no fastest-lap point)
func pointsStillAvailable(races: [Race], standingsRound: Int, now: Date = Date()) -> (driver: Double, team: Double) {
    var driver = 0.0, team = 0.0
    for race in races {
        let pending = (Int(race.round) ?? 0) > standingsRound
        if pending || race.finishedBy > now {
            driver += 25
            team += 25 + 18
        }
        if let sprint = race.sprint, let start = makeDate(sprint.date, sprint.time)?.date,
           pending || start.addingTimeInterval(2 * 3600) > now {
            driver += 8
            team += 8 + 7
        }
    }
    return (driver, team)
}

/// 1-based positions that can no longer change: both the gap to the one ahead and the gap to the one behind
/// are bigger than what is still available (equal points could still go either way on countback)
func lockedPositions(_ points: [Double], available: Double) -> Set<Int> {
    if available <= 0 { return Set(points.indices.map { $0 + 1 }) }
    var locked = Set<Int>()
    for i in points.indices {
        let safeAhead = i == 0 || points[i - 1] - points[i] > available
        let safeBehind = i == points.count - 1 || points[i] - points[i + 1] > available
        if safeAhead && safeBehind { locked.insert(i + 1) }
    }
    return locked
}

// MARK: - Sync and cache

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

    /// Fetch this year's schedule; if no races are left, fetch next year's too so the season opener shows after the finale
    static func sync(now: Date = Date()) async throws -> [Season] {
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        let this = try await season(year)
        if this.races.contains(where: { $0.finishedBy > now }) { return [this] }
        if let next = try? await season(year + 1), !next.races.isEmpty { return [this, next] }
        return [this]
    }

    /// GET a JSON endpoint and decode it
    static func get<T: Decodable>(_ type: T.Type, _ url: String, snakeCase: Bool = false) async throws -> T {
        guard let address = URL(string: url) else { throw AppError(message: "bad URL") }
        var request = URLRequest(url: address)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HTTPStatusError(code: http.statusCode)
        }
        let decoder = JSONDecoder()
        if snakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        return try decoder.decode(T.self, from: data)
    }

    /// Driver and constructor standings; before a season's first race, falls back to the previous season
    static func standings(year: Int) async throws -> Standings {
        for season in [year, year - 1] {
            let base = "https://api.jolpi.ca/ergast/f1/\(season)"
            let drivers = try await get(StandingsResponse<DriverStanding>.self, base + "/driverstandings.json?limit=100")
            guard !drivers.items.isEmpty else { continue }
            let teams = try await get(StandingsResponse<TeamStanding>.self, base + "/constructorstandings.json?limit=100")
            return Standings(season: season, round: drivers.round, drivers: drivers.items, teams: teams.items)
        }
        throw AppError(message: "no standings yet")
    }
}

struct Cache: Codable {
    let fetchedAt: Date
    let seasons: [Season]
    var standings: Standings? = nil
    var board: SessionBoard? = nil
    var colours: [String: String]? = nil   // driver code → team colour (hex), from OpenF1
    var extras: [String: RaceExtras]? = nil   // "season-round" → tyres, circuit facts, last race here
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

// MARK: - Circuit map (the "detailed" map on each formula1.com race page)

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum TrackMap {
    /// Candidate slugs for the race page https://www.formula1.com/en/racing/<year>/<slug>, tried in order.
    /// Mostly the country name; a few exceptions are listed; the race name comes last
    /// (e.g. the 2026 Bahrain GP held in Malaysia still lives at "bahrain")
    static func pageSlugs(_ race: Race) -> [String] {
        func slug(_ s: String) -> String { urlSlug(s) }
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
        var failure: Error = AppError(message: "no map on the F1 race page")
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

    /// Find …/track/<year>track<circuit>detailed.webp in the race page's HTML
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

    /// Use the local cache first; download from formula1.com only when it's missing
    static func image(for race: Race) async throws -> NSImage {
        let file = folder.appendingPathComponent("\(race.season)-\(race.round)")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) { return image }
        let url = try await imageURL(for: race)
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HTTPStatusError(code: http.statusCode)
        }
        guard let image = NSImage(data: data) else { throw AppError(message: "unreadable image") }
        try? data.write(to: file)
        return image
    }
}

/// A mostly light map (e.g. white lines) gets a dark card, anything else a white one, so it stays readable
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
        // Pixels are premultiplied, so their sum divided by the total alpha is the alpha-weighted mean brightness
        sum += (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255
        weight += alpha
    }
    return weight > 0 && sum / weight > 0.6
}

// MARK: - Race extras: parsing (tyres, circuit facts, last race here)
// The pages are prose, so every parser is strict: when it isn't sure it returns nil and the line is hidden.

/// Capture groups of the first match ("" for a group that took no part), or nil when nothing matches
func captures(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (0..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }
}

/// &amp; &quot; &#39; &nbsp; &#233; &#xE9; …
func decodeEntities(_ s: String) -> String {
    guard s.contains("&"),
          let regex = try? NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);") else { return s }
    let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
    var result = ""
    var last = s.startIndex
    for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
        guard let whole = Range(match.range, in: s), let nameRange = Range(match.range(at: 1), in: s) else { continue }
        let name = String(s[nameRange])
        let replacement: String?
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            replacement = UInt32(name.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
        } else if name.hasPrefix("#") {
            replacement = UInt32(name.dropFirst(), radix: 10).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
        } else {
            replacement = named[name]
        }
        result += s[last..<whole.lowerBound]
        result += replacement ?? String(s[whole])
        last = whole.upperBound
    }
    result += s[last...]
    return result
}

/// A page's visible text: scripts and styles dropped, every tag turned into a line break, entities decoded
func plainText(_ html: String) -> String {
    var s = html.replacingOccurrences(of: #"<(script|style)\b[\s\S]*?</\1\s*>"#, with: " ",
                                      options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: #"<[^>]*>"#, with: "\n", options: .regularExpression)
    s = decodeEntities(s)
    s = s.replacingOccurrences(of: #"[ \t\r\f\x{0B}\x{A0}]+"#, with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: #" *\n\s*"#, with: "\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The "Circuit" box of a formula1.com race page
struct CircuitFacts: Codable, Equatable {
    var length: String?       // "5.419 km"
    var laps: Int?
    var recordTime: String?   // "1:22.384"
    var recordName: String?   // "Lando Norris"
    var recordYear: Int?
}

func parseCircuitFacts(_ text: String) -> CircuitFacts? {
    let length = captures(#"Circuit Length\D{0,40}?(\d+(?:\.\d+)?)\s*km"#, in: text)
    let laps = captures(#"Number of Laps\D{0,40}?(\d+)"#, in: text)
    let record = captures(#"Fastest lap time\D{0,40}?(\d+:\d{2}\.\d{3})\s*([^()\d][^()]{0,60}?)\s*\((\d{4})\)"#, in: text)
    guard length != nil || laps != nil || record != nil else { return nil }
    var facts = CircuitFacts()
    if let length = length { facts.length = length[1] + " km" }
    if let laps = laps { facts.laps = Int(laps[1]) }
    if let record = record {
        facts.recordTime = record[1]
        facts.recordName = record[2].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        facts.recordYear = Int(record[3])
    }
    return facts
}

/// Pirelli's three compounds for the weekend from the "What tyres will…" article: the first three different
/// C numbers that appear within 300 characters of each other, hardest (lowest number) first
func parseCompounds(_ text: String) -> [Int]? {
    guard let regex = try? NSRegularExpression(pattern: #"\bC([0-6])\b"#) else { return nil }
    let ns = text as NSString
    var found: [(position: Int, number: Int)] = []
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        if let number = Int(ns.substring(with: match.range(at: 1))) { found.append((match.range.location, number)) }
    }
    for (index, first) in found.enumerated() {
        var seen: [Int] = []
        for item in found[index...] {
            if item.position - first.position > 300 { break }
            if !seen.contains(item.number) {
                seen.append(item.number)
                if seen.count == 3 { return seen.sorted() }
            }
        }
    }
    return nil
}

/// [1, 2, 3] → ["C1 H", "C2 M", "C3 S"] (hard, medium, soft)
func compoundLabels(_ numbers: [Int]) -> [String] {
    zip(numbers, ["H", "M", "S"]).map { "C\($0) \($1)" }
}

/// A per-set lap limit ("a maximum stint length of 27 laps", "27-lap tyre limit", "…-27-lap-limit-…")
func parseLapLimit(_ text: String) -> Int? {
    let match = captures(#"(?i)maximum (?:stint length )?of (\d{2}) laps"#, in: text)
        ?? captures(#"(?i)(\d{2})[- ]lap[- ](?:tyres?[- ])?limit"#, in: text)
    return match.flatMap { Int($0[1]) }
}

/// Every formula1.com article link in a page or feed, made absolute
func articleLinks(in html: String) -> [String] {
    let text = html.replacingOccurrences(of: "\\/", with: "/")
    guard let regex = try? NSRegularExpression(pattern: #"(?:https://www\.formula1\.com)?/en/latest/article/[A-Za-z0-9._-]+"#)
    else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
        let link = ns.substring(with: match.range)
        return link.hasPrefix("https://") ? link : "https://www.formula1.com" + link
    }
}

/// The part of an article slug that names the race: "Qatar Grand Prix" → "qatar",
/// "Bahrain Grand Prix in Malaysia" → "bahrain" (formula1.com cuts long slugs short: "…-2026-australian-grand.<id>")
func raceKey(_ raceName: String) -> String {
    let head = raceName.range(of: " Grand Prix").map { String(raceName[..<$0.lowerBound]) } ?? raceName
    return urlSlug(head)
}

/// This race's "What tyres will the teams and drivers have for the <season> <race>" article; links to other
/// races' articles (a race page or the feed can carry them) are ignored
func tyreArticleURL(in html: String, season: Int, raceKey: String) -> URL? {
    let link = articleLinks(in: html).first { $0.contains("/what-tyres-will") && $0.contains("-\(season)-\(raceKey)") }
    return link.flatMap { URL(string: $0) }
}

/// A lap limit named in one of this race's article links, e.g. …/explained-why-theres-a-27-lap-limit-on-tyres-for-the-qatar-grand-prix
func lapLimitFromLinks(in html: String, raceKey: String) -> Int? {
    for link in articleLinks(in: html) where link.contains(raceKey) {
        if let limit = parseLapLimit(link) { return limit }
    }
    return nil
}

/// Lowercase letters and digits only, accents removed: "Montréal" → "montreal", "yas_marina" → "yasmarina"
func normalisedName(_ s: String?) -> String {
    (s ?? "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
}

/// Is an OpenF1 race at the same circuit as a Jolpica race? Same country (Jolpica's USA / UK / UAE are spelt
/// out in OpenF1) and a circuit or place name that is equal or a prefix of the other ("spa" / "spafrancorchamps").
/// The country alone is never enough, so a new circuit (Madrid) never borrows another's race (Barcelona).
func sameCircuit(id: String?, locality: String?, country: String?,
                 ofCircuit: String?, ofLocation: String?, ofCountry: String?) -> Bool {
    let aliases = ["usa": "unitedstates", "uk": "unitedkingdom", "uae": "unitedarabemirates"]
    func countryKey(_ s: String?) -> String {
        let key = normalisedName(s)
        return aliases[key] ?? key
    }
    let mineCountry = countryKey(country)
    guard !mineCountry.isEmpty, mineCountry == countryKey(ofCountry) else { return false }
    let mine = [normalisedName(id), normalisedName(locality)].filter { $0.count >= 3 }
    let theirs = [normalisedName(ofCircuit), normalisedName(ofLocation)].filter { $0.count >= 3 }
    return mine.contains { a in theirs.contains { b in a == b || a.hasPrefix(b) || b.hasPrefix(a) } }
}

/// One stint of a race: compound and its first and last lap
struct StintSpan: Codable, Equatable {
    let compound: String   // SOFT, MEDIUM, HARD, INTERMEDIATE, WET (OpenF1 spelling)
    let from: Int
    let to: Int
}

/// The laps a driver pitted on: the last lap of every stint but the final one
func pitLaps(_ stints: [StintSpan]) -> [Int] {
    stints.sorted { $0.from < $1.from }.dropLast().map(\.to)
}

/// [7, 32] → "Pit L7 · L32", [] → "No stop"
func pitText(_ laps: [Int]) -> String {
    laps.isEmpty ? "No stop" : "Pit " + laps.map { "L\($0)" }.joined(separator: " · ")
}

/// Teams that were renamed, mapped to today's name, so an old lap record still gets a colour
func teamLineage(_ constructorId: String) -> String {
    let lineage = ["toro_rosso": "rb", "alphatauri": "rb", "renault": "alpine", "lotus_f1": "alpine",
                   "force_india": "aston_martin", "racing_point": "aston_martin", "sauber": "audi",
                   "alfa": "audi", "brawn": "mercedes"]
    return lineage[constructorId] ?? constructorId
}

/// "Lando Norris" → "NOR", for when Jolpica has no code
func fallbackCode(_ name: String) -> String {
    String(name.split(separator: " ").last?.prefix(3) ?? "").uppercased()
}

/// "São Paulo Grand Prix" → "sao-paulo-grand-prix" (formula1.com URL style)
func urlSlug(_ s: String) -> String {
    s.folding(options: .diacriticInsensitive, locale: nil)
        .lowercased()
        .replacingOccurrences(of: " ", with: "-")
        .filter { $0.isLetter || $0.isNumber || $0 == "-" }
}

// MARK: - Race extras: loading and caching

/// Who set the lap record, and for which team (Jolpica constructorId)
struct RecordHolder: Codable, Equatable {
    let code: String
    let constructorId: String
}

/// One of the top three in the last race on this circuit, with their stints
struct StrategyRow: Codable {
    let position: Int
    let code: String
    let colour: String?   // that year's team colour (hex)
    let stints: [StintSpan]
}

struct PastStrategy: Codable {
    let place: String     // "Lusail"
    let year: Int
    let laps: Int         // race length, for scaling the bars
    let rows: [StrategyRow]
}

/// Everything extra about one round, cached; every field optional so older caches still load
struct RaceExtras: Codable {
    var facts: CircuitFacts?
    var compounds: [Int]?        // [1, 2, 3] = C1 hard, C2 medium, C3 soft
    var lapLimit: Int?           // laps allowed per set, when Pirelli sets one
    var webCheckedAt: Date?      // last look at formula1.com
    var record: RecordHolder?
    var recordDone: Bool?        // record holder looked up (or there is no record)
    var past: PastStrategy?
    var pastDone: Bool?          // last race here looked up (found or not)
    var weather: [WeatherPoint]? // race start, +1 h, +2 h (Open-Meteo)
    var weatherAt: Date?         // last successful forecast request
}

/// formula1.com: look again at most every 6 hours until both the circuit facts and the compounds are known
/// (the tyre article only appears in race week)
func needsWeb(_ extras: RaceExtras?, now: Date) -> Bool {
    guard let extras = extras else { return true }
    if extras.facts != nil && extras.compounds != nil { return false }
    guard let checked = extras.webCheckedAt else { return true }
    return now.timeIntervalSince(checked) >= 6 * 3600
}

/// A look at formula1.com only counts when the server answered; offline, the next sync tries again
func nextWebCheck(previous: Date?, now: Date, reached: Bool) -> Date? {
    reached ? now : previous
}

/// OpenF1 last race here: once per round, again on the next sync if it failed
func needsPast(_ extras: RaceExtras?) -> Bool {
    extras?.pastDone != true
}

/// Jolpica record holder: needs the race page's facts first, then once per round
func needsRecord(_ extras: RaceExtras?) -> Bool {
    extras?.facts != nil && extras?.recordDone != true
}

/// The top three of a race with their stints in order; drivers without stint data are left out
func buildPastStrategy(place: String, year: Int, results: [OFResult], drivers: [OFDriver],
                       stints: [OFStint]) -> PastStrategy? {
    var info: [Int: OFDriver] = [:]
    for driver in drivers { info[driver.driverNumber] = driver }
    var byDriver: [Int: [StintSpan]] = [:]
    for stint in stints {
        guard let from = stint.lapStart, let to = stint.lapEnd else { continue }
        byDriver[stint.driverNumber, default: []].append(StintSpan(compound: stint.compound ?? "UNKNOWN", from: from, to: to))
    }
    let podium = results.compactMap { result -> (position: Int, number: Int)? in
        guard let position = result.position, (1...3).contains(position) else { return nil }
        return (position, result.driverNumber)
    }.sorted { $0.position < $1.position }

    var rows: [StrategyRow] = []
    for entry in podium {
        let spans = (byDriver[entry.number] ?? []).sorted { $0.from < $1.from }
        guard !spans.isEmpty else { continue }
        let driver = info[entry.number]
        rows.append(StrategyRow(position: entry.position, code: driver?.nameAcronym ?? "#\(entry.number)",
                                colour: driver?.teamColour, stints: spans))
    }
    guard !rows.isEmpty else { return nil }
    let laps = rows.flatMap { $0.stints.map(\.to) }.max() ?? 0
    return PastStrategy(place: place, year: year, laps: laps, rows: rows)
}

/// The result whose fastest lap equals the record time (else the fastest lap of the race)
func pickRecordHolder(_ results: [RaceResult], time: String) -> RecordHolder? {
    guard let match = results.first(where: { $0.fastestLap?.time?.time == time })
            ?? results.first(where: { $0.fastestLap?.rank == "1" }) else { return nil }
    return RecordHolder(code: match.driver.code ?? fallbackCode(match.driver.familyName),
                        constructorId: match.constructor.constructorId)
}

extension API {
    /// The lap record holder's code and team that year (Jolpica, all races on this circuit that year)
    static func recordHolder(year: Int, circuitId: String, time: String) async throws -> RecordHolder? {
        let url = "https://api.jolpi.ca/ergast/f1/\(year)/circuits/\(circuitId)/results.json?limit=100"
        let response = try await get(ResultsResponse.self, url)
        return pickRecordHolder(response.results, time: time)
    }
}

enum RaceInfo {
    /// formula1.com's news feed (only the latest 10 articles, so it's just a fallback for the race page's links)
    static let feed = URL(string: "https://www.formula1.com/en/latest/all.xml")!

    static func page(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HTTPStatusError(code: http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Fill in whatever is still missing for one round. Never throws: a part that fails stays empty
    /// and is tried again on a later sync.
    static func refresh(_ race: Race, cached: RaceExtras?, now: Date = Date()) async -> RaceExtras {
        var extras = cached ?? RaceExtras()
        if needsWeb(cached, now: now) {
            let reached = await loadWeb(race, into: &extras)
            extras.webCheckedAt = nextWebCheck(previous: extras.webCheckedAt, now: now, reached: reached)
        }
        // A request that fails leaves its "done" flag unset, so a later sync tries again;
        // an answer of "nothing there" (record before 2004, a new circuit) counts as done
        if needsRecord(extras) {
            if let facts = extras.facts, let time = facts.recordTime, let year = facts.recordYear,
               let circuitId = race.circuit.circuitId {
                do {
                    extras.record = try await API.recordHolder(year: year, circuitId: circuitId, time: time)
                    extras.recordDone = true
                } catch {}
            } else {
                extras.recordDone = true   // a new circuit has no lap record yet
            }
        }
        if needsPast(extras) {
            do {
                extras.past = try await OpenF1.pastStrategy(for: race)
                extras.pastDone = true
            } catch {}
        }
        // Race forecast: needs a known start time and the circuit's coordinates
        if let start = makeDate(race.date, race.time), start.timeKnown,
           needsWeather(extras, start: start.date, now: now),
           let lat = race.circuit.location?.lat, let long = race.circuit.location?.long {
            do {
                extras.weather = try await Weather.forecast(lat: lat, long: long, start: start.date)
                extras.weatherAt = now
            } catch {}
        }
        return extras
    }

    /// The race page gives the circuit facts and, in race week, links to the tyre article and any lap-limit
    /// article; the news feed is the fallback for those links; the tyre article names the compounds.
    /// Returns whether formula1.com answered at all (any HTTP status), so being offline isn't counted as a check.
    private static func loadWeb(_ race: Race, into extras: inout RaceExtras) async -> Bool {
        let season = Int(race.season) ?? 0
        let key = raceKey(race.raceName)
        var reached = false
        var tyreLink: URL?
        var limit: Int?
        for slug in TrackMap.pageSlugs(race) {
            guard let url = URL(string: "https://www.formula1.com/en/racing/\(race.season)/\(slug)") else { continue }
            let html: String
            do {
                html = try await page(url)
                reached = true
            } catch is HTTPStatusError {
                reached = true   // the server answered (e.g. 404 for this slug): try the next one
                continue
            } catch {
                continue
            }
            guard let facts = parseCircuitFacts(plainText(html)) else { continue }
            extras.facts = facts
            tyreLink = tyreArticleURL(in: html, season: season, raceKey: key)
            limit = lapLimitFromLinks(in: html, raceKey: key)
            break
        }
        if extras.compounds == nil, tyreLink == nil || limit == nil, let rss = try? await page(feed) {
            reached = true
            tyreLink = tyreLink ?? tyreArticleURL(in: rss, season: season, raceKey: key)
            limit = limit ?? lapLimitFromLinks(in: rss, raceKey: key)
        }
        if extras.compounds == nil, let link = tyreLink, let html = try? await page(link) {
            let text = plainText(html)
            extras.compounds = parseCompounds(text)
            limit = limit ?? parseLapLimit(text)
        }
        if let limit = limit { extras.lapLimit = limit }
        return reached
    }
}

// MARK: - Race weather (Open-Meteo)

/// The forecast for one hour: WMO weather code and whether it's daylight
struct WeatherPoint: Codable, Equatable {
    let code: Int
    let isDay: Bool
}

/// SF Symbol for a WMO weather code; clear and partly cloudy skies get a moon at night
func weatherSymbol(code: Int, isDay: Bool) -> String {
    switch code {
    case 0, 1: return isDay ? "sun.max.fill" : "moon.stars.fill"
    case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
    case 3: return "cloud.fill"
    case 45, 48: return "cloud.fog.fill"
    case 51...57: return "cloud.drizzle.fill"
    case 61, 63, 66, 80, 81: return "cloud.rain.fill"
    case 65, 67, 82: return "cloud.heavyrain.fill"
    case 71...77, 85, 86: return "cloud.snow.fill"
    case 95...99: return "cloud.bolt.rain.fill"
    default: return "cloud.fill"
    }
}

/// The hourly forecast at the race start, one hour in and two hours in (about the finish);
/// nil when any of them is missing, so the panel never shows a partial forecast
func pickRacePoints(times: [Int], codes: [Int?], isDay: [Int?], start: Date) -> [WeatherPoint]? {
    var points: [WeatherPoint] = []
    for offset in [0, 3600, 7200] {
        let moment = Int(start.timeIntervalSince1970) + offset
        guard let index = times.firstIndex(where: { $0 <= moment && moment < $0 + 3600 }),
              index < codes.count, let code = codes[index] else { return nil }
        let day = index < isDay.count ? (isDay[index] ?? 1) : 1
        points.append(WeatherPoint(code: code, isDay: day == 1))
    }
    return points
}

/// Open-Meteo's hourly forecast (decoded with convertFromSnakeCase; times as Unix seconds)
struct ForecastResponse: Decodable {
    let hourly: Hourly

    struct Hourly: Decodable {
        let time: [Int]
        let weatherCode: [Int?]
        let isDay: [Int?]
    }
}

enum Weather {
    /// The forecast at the circuit for the race start, +1 h and +2 h; nil when those hours aren't covered yet
    static func forecast(lat: String, long: String, start: Date) async throws -> [WeatherPoint]? {
        let url = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(long)"
            + "&hourly=weather_code,is_day&timeformat=unixtime&forecast_days=16"
        let response = try await API.get(ForecastResponse.self, url, snakeCase: true)
        return pickRacePoints(times: response.hourly.time, codes: response.hourly.weatherCode,
                              isDay: response.hourly.isDay, start: start)
    }
}

/// Weather icons fill the space left under the session list: 3 pt margin above and below, 20–36 pt
func weatherIconSize(available: CGFloat) -> CGFloat {
    min(max(available - 6, 20), 36)
}

/// Ask for the forecast only when the race starts within 15 days (Open-Meteo looks 16 days ahead) and
/// hasn't finished, at most once an hour
func needsWeather(_ extras: RaceExtras?, start: Date, now: Date) -> Bool {
    guard now < start.addingTimeInterval(2 * 3600), start.timeIntervalSince(now) < 15 * 86400 else { return false }
    guard let fetched = extras?.weatherAt else { return true }
    return now.timeIntervalSince(fetched) >= 3600
}

// MARK: - Latest session results (OpenF1)

enum OpenF1 {
    static let base = "https://api.openf1.org/v1/"

    /// The free tier allows 3 requests a second: wait a little before each call, and retry once if throttled (HTTP 429)
    private static func fetch<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        try await Task.sleep(nanoseconds: 400_000_000)
        do {
            return try await API.get(type, base + path, snakeCase: true)
        } catch let error as HTTPStatusError where error.code == 429 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await API.get(type, base + path, snakeCase: true)
        }
    }

    /// The most recent session that ended at least 30 minutes ago (OpenF1 treats data as live, and paid,
    /// until then). Practice is ordered by best lap; qualifying, sprint and race by classification.
    /// Also returns every driver's team colour (driver code → hex).
    static func latestBoard(now: Date = Date()) async throws -> (board: SessionBoard, colours: [String: String]) {
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        var finished: [OFSession] = []
        for season in [year, year - 1] where finished.isEmpty {
            finished = try await fetch([OFSession].self, "sessions?year=\(season)").filter {
                guard $0.isCancelled != true, let end = $0.dateEnd.flatMap(isoDate) else { return false }
                return end.addingTimeInterval(30 * 60) <= now
            }
        }
        guard let session = finished.max(by: {
            ($0.dateEnd.flatMap(isoDate) ?? .distantPast) < ($1.dateEnd.flatMap(isoDate) ?? .distantPast)
        })
        else { throw AppError(message: "no finished session yet") }

        let key = session.sessionKey
        let drivers = try await fetch([OFDriver].self, "drivers?session_key=\(key)")
        let results = try await fetch([OFResult].self, "session_result?session_key=\(key)")

        var codes: [Int: String] = [:]
        var colours: [String: String] = [:]
        for driver in drivers {
            guard let code = driver.nameAcronym else { continue }
            codes[driver.driverNumber] = code
            if let hex = driver.teamColour { colours[code] = hex }
        }

        // Best lap per driver: practice and qualifying come with it; for a sprint or race, take it from the laps
        let name = session.sessionName
        let isPractice = name.hasPrefix("Practice") || name.hasPrefix("Day")
        let isRace = name == "Race" || name == "Sprint"
        var best: [Int: Double] = [:]
        if isRace {
            let laps = try await fetch([OFLap].self, "laps?session_key=\(key)")
            for lap in laps {
                guard let time = lap.lapDuration, time > 0 else { continue }
                best[lap.driverNumber] = min(best[lap.driverNumber] ?? time, time)
            }
        } else {
            for result in results {
                if let time = result.duration?.seconds { best[result.driverNumber] = time }
            }
        }

        // Everyone: practice fastest first (no lap time at the end); otherwise classification order
        // (no position at the end); ties by car number so the order stays put between refreshes
        let ordered = results.sorted { a, b in
            let keyA = isPractice ? (best[a.driverNumber] ?? .infinity) : Double(a.position ?? Int.max)
            let keyB = isPractice ? (best[b.driverNumber] ?? .infinity) : Double(b.position ?? Int.max)
            return keyA != keyB ? keyA < keyB : a.driverNumber < b.driverNumber
        }

        let fastest = best.values.min()
        var rows: [BoardRow] = []
        for (index, result) in ordered.enumerated() {
            let code = codes[result.driverNumber] ?? "#\(result.driverNumber)"
            let time = best[result.driverNumber]
            // Sprint / race: winner's time, then the gap to the winner; practice / qualifying: best lap
            rows.append(BoardRow(position: isPractice ? index + 1 : (result.position ?? 0),
                                 code: code,
                                 colour: colours[code],
                                 time: isRace ? raceGap(result, winner: index == 0) : (time.map(lapText) ?? "—"),
                                 fastest: !isRace && time != nil && time == fastest))
        }
        let place = session.location ?? session.countryName ?? ""
        var board = SessionBoard(title: "\(place) · \(shortSession(name))", rows: rows)
        // Sprint / race: whoever set the fastest lap gets a line of their own under the results
        if isRace, let quickest = best.min(by: { $0.value < $1.value }) {
            let code = codes[quickest.key] ?? "#\(quickest.key)"
            board.fastestLap = BoardRow(position: 0, code: code, colour: colours[code],
                                        time: lapText(quickest.value), fastest: true)
        }
        return (board, colours)
    }
}

extension OpenF1 {
    /// The most recent race on this circuit before this season (OpenF1 covers 2023 onwards): the top three
    /// with their stints. nil when the circuit hasn't been raced in that time.
    static func pastStrategy(for race: Race) async throws -> PastStrategy? {
        let season = Int(race.season) ?? 0
        guard season - 1 >= 2023 else { return nil }
        for year in stride(from: season - 1, through: 2023, by: -1) {
            let sessions = try await fetch([OFSession].self, "sessions?session_name=Race&year=\(year)")
            guard let session = sessions.last(where: {
                $0.isCancelled != true
                    && sameCircuit(id: race.circuit.circuitId, locality: race.circuit.location?.locality,
                                   country: race.circuit.location?.country,
                                   ofCircuit: $0.circuitShortName, ofLocation: $0.location, ofCountry: $0.countryName)
            }) else { continue }
            let key = session.sessionKey
            let results = try await fetch([OFResult].self, "session_result?session_key=\(key)")
            let drivers = try await fetch([OFDriver].self, "drivers?session_key=\(key)")
            let stints = try await fetch([OFStint].self, "stints?session_key=\(key)")
            return buildPastStrategy(place: session.location ?? session.circuitShortName ?? race.circuit.circuitName,
                                     year: year, results: results, drivers: drivers, stints: stints)
        }
        return nil
    }
}

// MARK: - Dropdown panel

/// Circuit map card. Normally on the left of the panel; on hover it smoothly grows to cover the whole panel (Core Animation)
final class MapView: NSView {
    private let card = CALayer()
    private let picture = CALayer()
    private let caption = CATextLayer()
    private var hasImage = false
    private var expanded = false
    private var smallRect = CGRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting view: the card and the picture are standalone layers, which keeps them easy to animate
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

    // This view covers the whole panel: clicks pass through normally (the buttons are underneath)
    // and are blocked while the map is enlarged
    override func hitTest(_ point: NSPoint) -> NSView? {
        expanded ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    /// When enlarged, the card keeps a 6 pt margin
    private var expandedRect: CGRect {
        bounds.insetBy(dx: 6, dy: 6)
    }

    private func place(_ rect: CGRect) {
        card.bounds = CGRect(origin: .zero, size: rect.size)
        card.position = CGPoint(x: rect.midX, y: rect.midY)
        picture.frame = card.bounds.insetBy(dx: 10, dy: 10)
        caption.frame = CGRect(x: 0, y: card.bounds.midY - 8, width: card.bounds.width, height: 16)
    }

    /// rect: the card's normal position (this view's coordinates); a nil image shows the loading placeholder
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

    /// Grows in 0.35 s and shrinks in 0.25 s, both easing out; the picture keeps its aspect ratio as the card grows
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

/// The whole dropdown panel: circuit map on the left, schedule on the right, status and buttons along the bottom.
/// It is the menu's only item, so it appears and disappears together with the menu.
/// Pointer enters the map → the map grows to cover the panel; pointer leaves the panel → it shrinks back.
/// What the three tables under the map show
struct TeamRow {
    let position: String
    let name: String
    let colour: NSColor?         // team colour
    let points: String
    let pointsColour: NSColor?   // gold once the title is decided, team colour otherwise
}

struct DriverRow {
    let position: String
    let code: String
    let colour: NSColor?         // team colour
    let points: String
    let pointsColour: NSColor?   // gold / silver / bronze once P1 / P2 / P3 is decided
}

struct LapRow {
    let position: String
    let code: String
    let colour: NSColor?         // team colour
    let time: String
    let fastest: Bool            // fastest lap of the session, shown in purple
}

/// One of last race's top three: code in that year's team colour, stints bar, pit laps
struct StrategyLine {
    let position: String
    let code: String
    let colour: NSColor?
    let stints: [StintSpan]
    let pits: String             // "Pit L7 · L32"
}

/// Shown under Constructors: this round's tyres, the last race on this circuit, circuit facts
struct RaceBlock {
    var compounds: [String] = []   // "C1 H", "C2 M", "C3 S"
    var lapLimit: String?          // "Max 27 laps per set"
    var pastTitle: String?         // "Lusail 2025 · Top 3"
    var raceLaps = 0
    var lines: [StrategyLine] = []
    var length: String?
    var laps: String?
    var recordTime: String?
    var recordCode: String?
    var recordColour: NSColor?     // colour of the team he set it with; nil = grey
    var recordYear: String?
}

/// Turn a round's cached extras into what the panel shows; nil when there's nothing to show.
/// teamColour: today's colour per constructorId.
func makeRaceBlock(_ extras: RaceExtras, teamColour: [String: NSColor]) -> RaceBlock? {
    var block = RaceBlock()
    if let numbers = extras.compounds { block.compounds = compoundLabels(numbers) }
    block.lapLimit = extras.lapLimit.map { "Max \($0) laps per set" }
    if let past = extras.past {
        block.pastTitle = "\(past.place) \(past.year) · Top 3"
        block.raceLaps = past.laps
        block.lines = past.rows.map {
            StrategyLine(position: "\($0.position)", code: $0.code, colour: colour(hex: $0.colour),
                         stints: $0.stints, pits: pitText(pitLaps($0.stints)))
        }
    }
    if let facts = extras.facts {
        block.length = facts.length
        block.laps = facts.laps.map { String($0) }
        if let time = facts.recordTime {
            block.recordTime = time
            block.recordYear = facts.recordYear.map { String($0) }
            if let holder = extras.record {
                block.recordCode = holder.code
                block.recordColour = teamColour[teamLineage(holder.constructorId)]
            } else {
                block.recordCode = facts.recordName.map { fallbackCode($0) }
            }
        }
    }
    let empty = block.compounds.isEmpty && block.lapLimit == nil && block.lines.isEmpty
        && block.length == nil && block.laps == nil && block.recordTime == nil
    return empty ? nil : block
}

struct Tables {
    var teams: [TeamRow] = []
    var drivers: [DriverRow] = []
    var sessionTitle = ""
    var laps: [LapRow] = []
    var fastestLap: LapRow? = nil   // sprint / race only: an extra line under the results, time in purple
    var race: RaceBlock? = nil      // under Constructors
    var weather: [WeatherPoint] = []   // race start, +1 h, end: under the latest session

    var isEmpty: Bool { teams.isEmpty && drivers.isEmpty && laps.isEmpty && race == nil && weather.isEmpty }
}

/// A race-long bar split into stints, coloured by compound, with a small gap at each pit stop
final class StintBar: NSView {
    private let stints: [StintSpan]
    private let total: Int

    init(stints: [StintSpan], total: Int) {
        self.stints = stints
        self.total = max(total, stints.map(\.to).max() ?? 1, 1)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = bounds.width / CGFloat(total)
        for stint in stints {
            var rect = NSRect(x: CGFloat(stint.from - 1) * scale, y: 0,
                              width: CGFloat(stint.to - stint.from + 1) * scale, height: bounds.height)
            if stint.to < total { rect.size.width -= 1.5 }
            guard rect.width > 0 else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            compoundColour(stint.compound).setFill()
            path.fill()
            if stint.compound.uppercased() == "HARD" {   // keeps white visible on a light background
                path.lineWidth = 0.5
                NSColor.separatorColor.setStroke()
                path.stroke()
            }
        }
    }
}

final class DashboardView: NSView {
    static let mapWidth: CGFloat = 360
    let map = MapView(frame: .zero)
    var onSync: () -> Void = {}
    var onToggleLogin: () -> Void = {}
    var onQuit: () -> Void = {}

    private var labels: [NSView] = []
    private var tableViews: [NSView] = []
    private let footerLine = NSBox()
    private let noteLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var loginBox = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(loginClicked))
    private lazy var syncButton = NSButton(title: "Sync Now", target: self, action: #selector(syncClicked))
    private lazy var quitButton = NSButton(title: "Quit", target: self, action: #selector(quitClicked))
    private var mapRect = NSRect.zero   // the map's normal position (this view's coordinates, origin top left)
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

    func update(rows: [Row], image: NSImage?, showMap: Bool, tables: Tables,
                note: String?, status: String, loginOn: Bool) {
        labels.forEach { $0.removeFromSuperview() }
        labels = rows.map { makeView($0) }
        tableViews.forEach { $0.removeFromSuperview() }
        tableViews = []

        let pad: CGFloat = 14, gap: CGFloat = 18
        let infoX = showMap ? pad + Self.mapWidth + gap : pad

        // Right: schedule rows, top to bottom
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

        // Left: circuit map, fixed width, height from the image's aspect ratio, top-aligned with the right column
        var mapHeight: CGFloat = 0
        if showMap {
            let ratio = image.map { $0.size.height / max($0.size.width, 1) } ?? 0.7
            mapHeight = min(max(Self.mapWidth * ratio, 180), 360)
        }

        // Bottom: (map error note) + separator + status on the left, buttons on the right
        loginBox.state = loginOn ? .on : .off
        statusLabel.stringValue = status
        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = note == nil
        let buttons: [NSView] = [loginBox, syncButton, quitButton]
        let buttonsWidth = buttons.reduce(CGFloat(0)) { $0 + $1.fittingSize.width } + 14 * CGFloat(buttons.count - 1)
        let tablesWidth: CGFloat = tables.isEmpty ? 0 : pad * 2 + gap * 2 + 3 * 150
        let width = max(infoX + infoWidth + pad, pad + 120 + 20 + buttonsWidth + pad, tablesWidth)

        var bottom = pad + max(infoHeight, mapHeight)

        // Middle: constructors, drivers, latest session results — three columns side by side
        if !tables.isEmpty {
            bottom = placeTables(tables, top: bottom + 16, width: width)
        }

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

        // The map view covers the whole panel and sits on top, so the enlarged map covers everything
        if showMap {
            mapRect = NSRect(x: pad, y: pad, width: Self.mapWidth, height: mapHeight)
            map.frame = bounds
            addSubview(map, positioned: .above, relativeTo: nil)
            // MapView's origin is at the bottom left, so convert
            map.show(image, at: CGRect(x: mapRect.minX, y: bounds.height - mapRect.maxY,
                                       width: mapRect.width, height: mapRect.height))
        } else {
            map.removeFromSuperview()
            mapRect = .zero
        }
        updateTrackingAreas()
    }

    /// Three columns under the map; returns the y where they end
    private func placeTables(_ tables: Tables, top: CGFloat, width: CGFloat) -> CGFloat {
        let pad: CGFloat = 14, gap: CGFloat = 18, rowHeight: CGFloat = 19
        let column = (width - pad * 2 - gap * 2) / 3
        var bottom = top

        func put(_ view: NSView, _ frame: NSRect) {
            view.frame = frame
            addSubview(view)
            tableViews.append(view)
        }
        func header(_ title: String, x: CGFloat, y: CGFloat? = nil) {
            put(makeText(title.uppercased(), size: 11, weight: .semibold, colour: .secondaryLabelColor),
                NSRect(x: x, y: y ?? top, width: column, height: 15))
        }

        // Under Constructors: this round's tyres, the last race on this circuit and the circuit facts,
        // each part only when it has data; returns where it ends
        func placeRace(_ race: RaceBlock, x: CGFloat, from start: CGFloat) -> CGFloat {
            var y = start
            if !race.compounds.isEmpty || race.lapLimit != nil {
                header("Tyres", x: x, y: y)
                y += 21
                if !race.compounds.isEmpty {
                    // Spread across the row: hard at the left edge, medium centred, soft at the right edge
                    let third = column / 3
                    let alignments: [NSTextAlignment] = [.left, .center, .right]
                    for (rank, label) in race.compounds.enumerated() {
                        put(makeText(label, weight: .semibold, colour: tyreColour(rank: rank),
                                     align: alignments[min(rank, 2)]),
                            NSRect(x: x + CGFloat(rank) * third, y: y, width: third, height: 16))
                    }
                    y += rowHeight
                }
                if let limit = race.lapLimit {
                    put(makeText(limit, size: 11, colour: .secondaryLabelColor),
                        NSRect(x: x, y: y, width: column, height: 16))
                    y += rowHeight
                }
                y += 4
            }
            // Position, code in that year's team colour, stints bar, pit laps underneath
            if let title = race.pastTitle, !race.lines.isEmpty {
                header(title, x: x, y: y)
                y += 21
                for line in race.lines {
                    put(makeText(line.position, colour: .secondaryLabelColor, align: .right),
                        NSRect(x: x, y: y, width: 24, height: 16))
                    put(makeText(line.code, weight: .bold, colour: line.colour),
                        NSRect(x: x + 32, y: y, width: 36, height: 16))
                    put(StintBar(stints: line.stints, total: race.raceLaps),
                        NSRect(x: x + 70, y: y + 4, width: column - 70, height: 8))
                    put(makeText(line.pits, size: 10, colour: .secondaryLabelColor),
                        NSRect(x: x + 70, y: y + 14, width: column - 70, height: 13))
                    y += 30
                }
                y += 4
            }
            if race.length != nil || race.laps != nil || race.recordTime != nil {
                header("Circuit", x: x, y: y)
                y += 21
                let valueX: CGFloat = 58
                for (label, value) in [("Length", race.length), ("Laps", race.laps)] {
                    guard let value = value else { continue }
                    put(makeText(label, colour: .secondaryLabelColor), NSRect(x: x, y: y, width: valueX - 2, height: 16))
                    put(makeText(value), NSRect(x: x + valueX, y: y, width: column - valueX, height: 16))
                    y += rowHeight
                }
                // Lap record: the year in full at the column's right edge (lined up with the points above),
                // then the time and the holder's code (colour of the team he set it with) in the space left
                if let time = race.recordTime {
                    put(makeText("Lap rec.", colour: .secondaryLabelColor), NSRect(x: x, y: y, width: valueX - 2, height: 16))
                    var right = x + column
                    if let year = race.recordYear {
                        let field = makeText(year, colour: .secondaryLabelColor)
                        let width = field.fittingSize.width
                        put(field, NSRect(x: right - width, y: y, width: width, height: 16))
                        right -= width + 4
                    }
                    var cursor = x + valueX
                    func add(_ field: NSTextField) {
                        let width = min(field.fittingSize.width, right - cursor)
                        guard width > 8 else { return }
                        put(field, NSRect(x: cursor, y: y, width: width, height: 16))
                        cursor += width + 4
                    }
                    add(makeText(time))
                    if let code = race.recordCode {
                        add(makeText(code, weight: .bold, colour: race.recordColour ?? .secondaryLabelColor))
                    }
                    y += rowHeight
                }
            }
            return y
        }

        // Constructors: position, team name in team colour, points (gold once the title is decided, team colour otherwise)
        var x = pad
        if !tables.teams.isEmpty {
            header("Constructors", x: x)
            var y = top + 21
            for row in tables.teams {
                put(makeText(row.position, colour: .secondaryLabelColor, align: .right),
                    NSRect(x: x, y: y, width: 24, height: 16))
                put(makeText(row.name, weight: .semibold, colour: row.colour),
                    NSRect(x: x + 32, y: y, width: column - 32 - 56, height: 16))
                put(makeText(row.points, weight: .semibold, colour: row.pointsColour, align: .right),
                    NSRect(x: x + column - 56, y: y, width: 56, height: 16))
                y += rowHeight
            }
            bottom = max(bottom, y)
        }
        if let race = tables.race {
            // bottom is still where Constructors ends: nothing else has been placed yet
            bottom = max(bottom, placeRace(race, x: x, from: tables.teams.isEmpty ? top : bottom + 8))
        }

        // Drivers: position, code in team colour, points (gold / silver / bronze once that place is decided)
        x += column + gap
        if !tables.drivers.isEmpty {
            header("Drivers", x: x)
            var y = top + 21
            for row in tables.drivers {
                put(makeText(row.position, colour: .secondaryLabelColor, align: .right),
                    NSRect(x: x, y: y, width: 24, height: 16))
                put(makeText(row.code, weight: .bold, colour: row.colour),
                    NSRect(x: x + 32, y: y, width: 44, height: 16))
                put(makeText(row.points, weight: .semibold, colour: row.pointsColour, align: .right),
                    NSRect(x: x + 82, y: y, width: column - 82, height: 16))
                y += rowHeight
            }
            bottom = max(bottom, y)
        }

        // Latest session: position, code in team colour, best lap (purple = fastest of the session)
        x += column + gap
        var rightBottom = top
        if !tables.laps.isEmpty {
            header(tables.sessionTitle, x: x)
            var y = top + 21
            for row in tables.laps + (tables.fastestLap.map { [$0] } ?? []) {
                put(makeText(row.position, colour: .secondaryLabelColor, align: .right),
                    NSRect(x: x, y: y, width: 24, height: 16))
                put(makeText(row.code, weight: .bold, colour: row.colour),
                    NSRect(x: x + 32, y: y, width: 44, height: 16))
                put(makeText(row.time, colour: row.fastest ? NSColor.systemPurple : nil, align: .right),
                    NSRect(x: x + 76, y: y, width: column - 76, height: 16))
                y += rowHeight
            }
            rightBottom = y
            bottom = max(bottom, y)
        }

        // Under it: the race forecast (start › +1 h › end) as three icons spread across the column,
        // as large as the space left at the bottom allows
        if tables.weather.count == 3 {
            let available = tables.laps.isEmpty ? 42 : bottom - rightBottom
            let size = weatherIconSize(available: available)
            let iconY = (tables.laps.isEmpty ? top : rightBottom) + max((available - size) / 2, 3)
            let slot = column / 5   // icon, arrow, icon, arrow, icon
            for (index, point) in tables.weather.enumerated() {
                if index > 0 {
                    put(makeText("›", size: 18, colour: .secondaryLabelColor, align: .center),
                        NSRect(x: x + slot * CGFloat(index * 2 - 1), y: iconY + (size - 22) / 2, width: slot, height: 22))
                }
                put(weatherIcon(point, size: size),
                    NSRect(x: x + slot * CGFloat(index * 2) + (slot - size) / 2, y: iconY, width: size, height: size))
            }
            bottom = max(bottom, iconY + size)
        }
        return bottom
    }

    /// One forecast hour as a multicolour SF Symbol (sun, cloud, rain, …; moon at night), drawn to fit `size`
    private func weatherIcon(_ point: WeatherPoint, size: CGFloat) -> NSImageView {
        let name = weatherSymbol(code: point.code, isDay: point.isDay)
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.72, weight: .regular).applying(.preferringMulticolor())
        let view = NSImageView(frame: .zero)
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: name)?.withSymbolConfiguration(config)
        view.imageScaling = .scaleProportionallyDown
        return view
    }

    private func makeText(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                          colour: NSColor? = nil, align: NSTextAlignment = .left) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        label.textColor = colour ?? .labelColor
        label.alignment = align
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    // Two tracking areas: entering the map enlarges it; only leaving the whole panel shrinks it back
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = mapArea { removeTrackingArea(area) }
        if let area = panelArea { removeTrackingArea(area) }
        mapArea = nil
        panelArea = nil
        guard map.superview != nil else { return }
        // The app isn't active while its menu is open, hence activeAlways
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

// MARK: - Menu bar

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var cache = Store.load()
    private var syncing = false
    private var lastError: String?

    // The menu has a single item: the whole dropdown panel (a custom view)
    private let dashboard = DashboardView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    private let dashboardItem = NSMenuItem()
    private var maps: [String: NSImage] = [:]
    private var mapLoading: Set<String> = []
    private var mapError: String?
    private var boardError: String?   // why the latest session couldn't be loaded
    private var extrasLoading: Set<String> = []   // rounds whose tyres / circuit block is being fetched

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Icon: Resources/MenuIcon.png (and @2x) inside the app, copied there by build.sh
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

    // Rebuild every time the menu opens so the countdown is current
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        dashboard.map.setExpanded(false, animated: false)
        loadMap()
        loadExtras()
        // Re-sync when the data is more than 10 minutes old
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
                var fresh = Cache(fetchedAt: Date(), seasons: seasons)
                // Standings and the latest session are extras: if one fails, keep the last copy
                let year = seasons.first?.year ?? Calendar(identifier: .gregorian).component(.year, from: Date())
                fresh.standings = (try? await API.standings(year: year)) ?? self.cache?.standings
                do {
                    let latest = try await OpenF1.latestBoard()
                    fresh.board = latest.board
                    fresh.colours = latest.colours
                    self.boardError = nil
                } catch {
                    fresh.board = self.cache?.board
                    fresh.colours = self.cache?.colours
                    self.boardError = error.localizedDescription
                }
                fresh.extras = self.cache?.extras   // fetched separately by loadExtras(); keep them
                self.cache = fresh
                self.lastError = nil
                Store.save(fresh)
            } catch {
                self.lastError = error.localizedDescription
            }
            self.syncing = false
            self.rebuildMenu()
            self.loadMap()
            self.loadExtras()
        }
    }

    // MARK: Circuit map

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

    // MARK: Tyres, last race here, circuit facts

    /// Fetch what's still missing for the round on screen (RaceInfo decides what that is), then cache it
    private func loadExtras() {
        guard let race = currentRace else { return }
        let key = mapKey(race)
        let cached = cache?.extras?[key]
        let start = makeDate(race.date, race.time).flatMap { $0.timeKnown ? $0.date : nil }
        let weatherDue = start.map { needsWeather(cached, start: $0, now: Date()) } ?? false
        guard !extrasLoading.contains(key),
              needsWeb(cached, now: Date()) || needsRecord(cached) || needsPast(cached) || weatherDue else { return }
        extrasLoading.insert(key)
        Task {
            let fresh = await RaceInfo.refresh(race, cached: cached)
            if self.cache != nil {
                var all = self.cache?.extras ?? [:]
                all[key] = fresh
                self.cache?.extras = all
                if let cache = self.cache { Store.save(cache) }
            }
            self.extrasLoading.remove(key)
            self.rebuildMenu()
        }
    }

    // MARK: Panel content

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
        var notes: [String] = []
        if image == nil, !loading, let error = mapError { notes.append("Track map failed: \(error)") }
        if cache?.board == nil, let error = boardError { notes.append("Latest session failed: \(error)") }
        let note = notes.isEmpty ? nil : notes.joined(separator: " · ")

        dashboard.update(rows: rows, image: image, showMap: image != nil || loading, tables: makeTables(),
                         note: note, status: status, loginOn: SMAppService.mainApp.status == .enabled)
    }

    /// Constructors (name + points), all drivers (code + points) and the latest session's full results
    private func makeTables() -> Tables {
        var tables = Tables()
        guard let cache = cache else { return tables }
        let colours = cache.colours ?? [:]

        // A team's colour = the colour of one of its drivers (driver's latest team); also used for the lap record
        var teamColour: [String: NSColor] = [:]
        if let standings = cache.standings {
            let races = cache.seasons.first { $0.year == standings.season }?.races ?? []
            let available = pointsStillAvailable(races: races, standingsRound: standings.round)

            for entry in standings.drivers {
                guard let team = entry.constructors.last?.constructorId, teamColour[team] == nil,
                      let code = entry.driver.code, let c = colour(hex: colours[code]) else { continue }
                teamColour[team] = c
            }

            // Constructors: the champion's points turn gold once nobody can catch them, others use the team colour
            let teamLocked = lockedPositions(standings.teams.map { Double($0.points) ?? 0 }, available: available.team)
            for (index, entry) in standings.teams.enumerated() {
                let id = entry.constructor.constructorId
                let champion = index == 0 && teamLocked.contains(1)
                tables.teams.append(TeamRow(position: entry.position ?? "–", name: teamName(entry.constructor),
                                            colour: teamColour[id], points: entry.points,
                                            pointsColour: champion ? gold : teamColour[id]))
            }

            // Drivers: P1–P3 turn gold / silver / bronze once that place can't change any more
            let driverLocked = lockedPositions(standings.drivers.map { Double($0.points) ?? 0 }, available: available.driver)
            let medals = [gold, silver, bronze]
            for (index, entry) in standings.drivers.enumerated() {
                let code = entry.driver.code ?? String(entry.driver.familyName.prefix(3)).uppercased()
                let medal = index < 3 && driverLocked.contains(index + 1) ? medals[index] : nil
                let team = entry.constructors.last.flatMap { teamColour[$0.constructorId] }
                tables.drivers.append(DriverRow(position: entry.position ?? "–", code: code,
                                                colour: colour(hex: colours[code]) ?? team,
                                                points: entry.points, pointsColour: medal))
            }
        }

        if let board = cache.board {
            tables.sessionTitle = board.title
            tables.fastestLap = board.fastestLap.map {
                LapRow(position: "FL", code: $0.code, colour: colour(hex: $0.colour), time: $0.time, fastest: true)
            }
            tables.laps = board.rows.map {
                LapRow(position: $0.position > 0 ? "\($0.position)" : "–", code: $0.code, colour: colour(hex: $0.colour),
                       time: $0.time, fastest: $0.fastest ?? false)
            }
        }

        if let race = currentRace, let extras = cache.extras?[mapKey(race)] {
            tables.race = makeRaceBlock(extras, teamColour: teamColour)
            if let points = extras.weather, points.count == 3 { tables.weather = points }
        }
        return tables
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

// MARK: - Entry point

@main
struct PitBoardMain {
    @MainActor
    static func main() {
        // For testing: sync once without the UI, then print the panel content and the map URL
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
                        // The block under Constructors: tyres, last race on this circuit, circuit facts
                        let extras = await RaceInfo.refresh(race, cached: nil)
                        print("---- Tyres: " + (extras.compounds.map { compoundLabels($0).joined(separator: " · ") } ?? "not found yet"))
                        if let limit = extras.lapLimit { print("Max \(limit) laps per set") }
                        if let facts = extras.facts {
                            print("Length \(facts.length ?? "?") · Laps \(facts.laps.map { String($0) } ?? "?")")
                            if let time = facts.recordTime {
                                let holder = extras.record.map { "\($0.code) (\($0.constructorId))" } ?? facts.recordName ?? "?"
                                print("Lap record \(time) \(holder) \(facts.recordYear.map { String($0) } ?? "")")
                            }
                        } else {
                            print("Circuit facts not found")
                        }
                        if let past = extras.past {
                            print("---- \(past.place) \(past.year) · Top 3 (\(past.laps) laps)")
                            for row in past.rows {
                                let stints = row.stints.map { "\($0.compound.prefix(1))\($0.from)-\($0.to)" }.joined(separator: " ")
                                print("\(row.position)\t\(row.code)\t\(stints)\t\(pitText(pitLaps(row.stints)))")
                            }
                        } else {
                            print("No earlier race on this circuit in OpenF1 (2023 onwards)")
                        }
                        if let points = extras.weather {
                            let icons = points.map { weatherSymbol(code: $0.code, isDay: $0.isDay) }
                            print("Race weather (start › +1h › end): " + icons.joined(separator: " › "))
                        } else {
                            print("Race weather: no forecast yet (Open-Meteo looks 16 days ahead)")
                        }
                    }
                    do {
                        let standings = try await API.standings(year: seasons.first?.year ?? 0)
                        print("---- Constructors after round \(standings.round)")
                        for entry in standings.teams {
                            print("\(entry.position ?? "–")\t\(teamName(entry.constructor))\t\(entry.points)")
                        }
                        print("---- Drivers")
                        for entry in standings.drivers {
                            print("\(entry.position ?? "–")\t\(entry.driver.code ?? "?")\t\(entry.points)")
                        }
                    } catch {
                        print("Standings failed: \(error.localizedDescription)")
                    }
                    do {
                        let latest = try await OpenF1.latestBoard()
                        print("---- \(latest.board.title)")
                        for row in latest.board.rows {
                            print("\(row.position)\t\(row.code)\t\(row.time)\(row.fastest == true ? "  fastest" : "")")
                        }
                        if let lap = latest.board.fastestLap {
                            print("FL\t\(lap.code)\t\(lap.time)")
                        }
                    } catch {
                        print("Latest session failed: \(error.localizedDescription)")
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
