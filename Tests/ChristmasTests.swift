import AppKit

/// Fixed local dates let seasonal behavior run in tests during any month.
enum ChristmasTests {
    static func run(root: URL) throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { checks += 1; assert(condition(), message) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Edmonton")!
        func date(_ day: Int, _ hour: Int = 12) -> Date { calendar.date(from: DateComponents(year: 2026, month: 12, day: day, hour: hour))! }
        check(ChristmasSeason.at(date(17, 23), calendar: calendar) == .none, "Ordinary days do not schedule Santa")
        check(ChristmasSeason.at(date(18, 0), calendar: calendar) == .week && ChristmasSeason.at(date(23), calendar: calendar) == .week, "The whole preceding week is included")
        check(ChristmasSeason.at(date(24), calendar: calendar) == .eve && ChristmasSeason.at(date(25), calendar: calendar) == .week, "Only Christmas Eve schedules Santa naturally")
        check(ChristmasSeason.at(date(26, 0), calendar: calendar) == .none, "Automatic Santa visits end after Christmas Eve")
        var windows: [SnowStormWindow] = []
        for i in 0..<16 {
            let frame = CGRect(x: Double(i % 4) * 185, y: Double(i / 4) * 95 + 70, width: 270, height: 125)
            windows.append(SnowStormWindow(id: UInt32(i + 10), owner: Int32(i), frame: frame, level: 0))
        }
        let screen = CGRect(x: 0, y: 0, width: 800, height: 500)
        check(SnowStormWindowQuery.canDecorate(level: 0, hasTitle: false, ownerPolicy: .regular) &&
              SnowStormWindowQuery.canDecorate(level: 0, hasTitle: true, ownerPolicy: .accessory) &&
              !SnowStormWindowQuery.canDecorate(level: 0, hasTitle: false, ownerPolicy: .accessory) &&
              !SnowStormWindowQuery.canDecorate(level: 1, hasTitle: true, ownerPolicy: .regular),
              "Normal app windows remain eligible when macOS omits their titles; utility surfaces stay excluded")
        let untitledNormal = SnowStormWindow(id: 901, owner: 44,
            frame: CGRect(x: 25, y: 60, width: 330, height: 210), level: 0, decoratable: false)
        let untitledUtility = SnowStormWindow(id: 902, owner: 45,
            frame: CGRect(x: 390, y: 60, width: 330, height: 210), level: 0, decoratable: false)
        let validated = ChristmasWindowValidator(regularOwners: { [44] }, accessibilityTrusted: { false })
            .validate([untitledNormal, untitledUtility], desktopTop: screen.maxY)
        check(validated[0].decoratable && !validated[1].decoratable,
              "The live validator promotes untitled normal-app windows without promoting utility surfaces")
        let week = ChristmasScene(season: .none, windows: windows, screens: [screen], seed: 107,
                                  decorationsEnabled: true, lightsEnabled: true)
        let transparentSurface = SnowStormWindow(id: 9000, owner: 9000,
            frame: CGRect(x: 75, y: 300, width: 500, height: 170), level: 0, decoratable: false)
        check(ChristmasWindowMatching.contains(transparentSurface, in: [transparentSurface.frame.offsetBy(dx: 3, dy: -2)]) &&
              !ChristmasWindowMatching.contains(transparentSurface, in: [transparentSurface.frame.offsetBy(dx: 80, dy: 0)]),
              "Accessibility geometry identifies the actual window behind a decoration")
        let cleanScene = ChristmasScene(season: .none, windows: [transparentSurface] + windows,
                                       screens: [screen], seed: 107, decorationsEnabled: true, lightsEnabled: true)
        check(cleanScene.decoration(for: transparentSurface.id) == nil && cleanScene.decorations.count == week.decorations.count,
              "Untitled transparent surfaces cannot acquire floating Christmas decorations")
        var temporarilyUntitled = windows.first { week.decoration(for: $0.id) != nil }!
        temporarilyUntitled.decoratable = false
        let retainedWindows = windows.map { $0.id == temporarilyUntitled.id ? temporarilyUntitled : $0 }
        let retainedScene = ChristmasScene(season: .none, windows: retainedWindows,
                                           screens: [screen], seed: 107, decorationsEnabled: true, lightsEnabled: true,
                                           retainedDecorationIDs: Array(week.decorations.keys))
        check(retainedScene.decoration(for: temporarilyUntitled.id) == week.decoration(for: temporarilyUntitled.id),
              "A real window keeps its artwork if its title briefly disappears during a drag")
        let allKinds = Set(week.decorations.values.flatMap { decoration -> [ChristmasDecoration.Kind] in
            (decoration.kind.map { [$0] } ?? []) + decoration.extras
        })
        check(week.decorations.count == windows.count &&
              windows.allSatisfy { week.decoration(for: $0.id) != nil } &&
              allKinds.count >= 13 && ChristmasDecoration.Kind.allCases.count == 15,
              "Every normal window receives a varied selection from fifteen festive motifs")
        check(week.decorations.values.allSatisfy { !$0.extras.isEmpty },
              "Each decorated window has multiple motifs")
        check(week.decorations.values.allSatisfy(\.lights) && week.chimneys.count == 1 &&
              week.target == nil && week.santa == .none,
              "Decorations keep one chimney on an ordinary day without summoning Santa")
        let carolerSource = week.decorations.keys.sorted().first { week.carolerFraction(for: $0) != nil }!
        func carolers(at time: Double) -> CarolerPlacement {
            week.carolerPlacements(at: time).first { $0.sourceID == carolerSource }!
        }
        let starting = carolers(at: 0), walking = carolers(at: 5), stopped = carolers(at: 10)
        check(starting.stage == .resting && walking.stage == .walking && walking.windowID == starting.windowID &&
              walking.fraction > starting.fraction && stopped.stage == .resting && stopped.fraction > walking.fraction,
              "Carolers walk across their roof to a destination, then stop moving their feet")
        let contact = StickWalkPose.at(0, stride: 6.5, walking: true)
        let passing = StickWalkPose.at(.pi / 2, stride: 6.5, walking: true)
        let opposite = StickWalkPose.at(.pi, stride: 6.5, walking: true)
        let returnPassing = StickWalkPose.at(3 * .pi / 2, stride: 6.5, walking: true)
        let loop = StickWalkPose.at(2 * .pi, stride: 6.5, walking: true)
        check(contact.leftFootX < -6 && contact.rightFootX > 6 &&
              contact.leftLift == 0 && contact.rightLift == 0 && contact.armSwing > 0,
              "A wide planted step starts with the opposite arm forward")
        check(abs(passing.leftFootX) < 0.001 && abs(passing.rightFootX) < 0.001 &&
              passing.leftLift > 2 && passing.rightLift == 0,
              "The feet close underneath the body while the swinging foot lifts")
        check(opposite.leftFootX > 6 && opposite.rightFootX < -6 &&
              abs(opposite.leftLift) < 0.001 && abs(opposite.rightLift) < 0.001 && opposite.armSwing < 0 &&
              returnPassing.rightLift > 2 && returnPassing.leftLift == 0,
              "The next planted step reverses legs and arms before the other foot lifts")
        check(abs(loop.leftFootX - contact.leftFootX) < 0.001 &&
              abs(loop.rightFootX - contact.rightFootX) < 0.001 &&
              abs(loop.armSwing - contact.armSwing) < 0.001 &&
              StickWalkPose.at(0, stride: 6.5, walking: false).leftLift == 0,
              "The gait loops without a pose jump and stopped figures keep still feet")
        let flash = stride(from: 12.5, through: 16, by: 0.05).map(carolers(at:))
        check(flash.contains { $0.stage == .departing && $0.opacity > 0 && $0.opacity < 1 } &&
              flash.contains { $0.stage == .arriving && $0.opacity > 0 && $0.opacity < 1 } &&
              carolers(at: 16.8).windowID != starting.windowID,
              "A snowflake flash fades the group out and back onto another window")
        let decorationsOnly = ChristmasScene(season: .none, windows: windows, screens: [screen], seed: 107, decorationsEnabled: true)
        check(decorationsOnly.decorations.count == windows.count && decorationsOnly.decorations.values.allSatisfy { $0.kind != nil && !$0.extras.isEmpty && !$0.lights },
              "Decorations do not require the Lights checkbox")
        let lightsOnly = ChristmasScene(season: .none, windows: windows, screens: [screen], seed: 107, lightsEnabled: true)
        check(lightsOnly.decorations.count == windows.count &&
              lightsOnly.decorations.values.allSatisfy { $0.lights && $0.kind == nil && $0.extras.isEmpty },
              "Lights appear on every eligible window without the Decorations checkbox")
        let reordered = ChristmasScene(season: .none, windows: windows.reversed(), screens: [screen], seed: 107,
                                       decorationsEnabled: true, lightsEnabled: true)
        check(reordered.decorations == week.decorations, "Window focus changes do not reshuffle the decorations")
        let moved = windows.map { SnowStormWindow(id: $0.id, owner: $0.owner,
            frame: $0.frame.offsetBy(dx: 12, dy: 8), level: $0.level) }
        let movingScene = ChristmasScene(season: .none, windows: moved, screens: [screen], seed: 107,
                                         decorationsEnabled: true, lightsEnabled: true,
                                         retainedDecorationIDs: Array(week.decorations.keys))
        check(movingScene.decorations == week.decorations,
              "Moving windows keeps each window's motifs, light pattern, and roof position")
        let litAtTop = windows.first { week.decoration(for: $0.id)?.lights == true }!
        let raised = windows.map { window -> SnowStormWindow in
            guard window.id == litAtTop.id else { return window }
            return SnowStormWindow(id: window.id, owner: window.owner,
                frame: CGRect(x: window.frame.minX, y: screen.maxY + 20 - window.frame.height,
                              width: window.frame.width, height: window.frame.height), level: window.level)
        }
        let raisedScene = ChristmasScene(season: .none, windows: raised, screens: [screen], seed: 107,
                                         decorationsEnabled: true, lightsEnabled: true,
                                         retainedDecorationIDs: Array(week.decorations.keys))
        check(raisedScene.decoration(for: litAtTop.id) == week.decoration(for: litAtTop.id),
              "Hanging lights remain attached when a window reaches the top of the display")
        let added = windows + [SnowStormWindow(id: 200, owner: 200, frame: CGRect(x: 10, y: 40, width: 300, height: 120), level: 0)]
        let expanded = ChristmasScene(season: .none, windows: added, screens: [screen], seed: 107,
                                      decorationsEnabled: true, lightsEnabled: true,
                                      retainedDecorationIDs: Array(week.decorations.keys))
        check(week.decorations.allSatisfy { expanded.decoration(for: $0.key) == $0.value } &&
              expanded.decoration(for: 200) != nil,
              "Opening another normal window adds artwork without replacing existing decorations")
        let wireBefore = ChristmasDrawing.lightWireY(roof: 190, fraction: 0.4, span: 600, windowID: 10, seed: 107)
        let wireAfter = ChristmasDrawing.lightWireY(roof: 198, fraction: 0.4, span: 600, windowID: 10, seed: 107)
        check(abs((wireAfter - wireBefore) - 8) < 0.0001,
              "Lights follow a moving roof without changing their shape")
        let titleWire = ChristmasDrawing.lightWireY(roof: 190, fraction: 0.3, span: 900, windowID: 10, seed: 107)
        let rightWire = ChristmasDrawing.lightWireY(roof: 190, fraction: 0.9, span: 900, windowID: 10, seed: 107)
        check(titleWire >= 191 && rightWire < 190,
              "The fixed left title area keeps bulbs high while the right side keeps its normal sag")
        let deerFirst = NSBitmapImageRep(cgImage: ChristmasPixels.reindeer[0][0]).representation(using: .png, properties: [:])!
        let deerSecond = NSBitmapImageRep(cgImage: ChristmasPixels.reindeer[0][1]).representation(using: .png, properties: [:])!
        let otherDeer = NSBitmapImageRep(cgImage: ChristmasPixels.reindeer[1][0]).representation(using: .png, properties: [:])!
        check(deerFirst != deerSecond && deerFirst != otherDeer && ChristmasPixels.reindeer.count == 4 &&
              ChristmasPixels.sleigh.width == 55 && ChristmasPixels.chimney.height == 48,
              "Each reindeer has fixed markings and two distinct gallop frames")
        let giftSizes = Set(ChristmasPixels.gifts.map { "\($0.width)x\($0.height)" })
        let giftImages = Set(ChristmasPixels.gifts.compactMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
        })
        check(ChristmasPixels.gifts.count == 12 && giftSizes.count >= 8 && giftImages.count == 12,
              "Presents have a dozen distinct pixel designs with varied shapes and sizes")
        let newArt = [ChristmasPixels.gingerbreadHouses, ChristmasPixels.toyTrains,
                      ChristmasPixels.lanternPairs, ChristmasPixels.wreaths,
                      ChristmasPixels.nutcrackers, ChristmasPixels.rockingHorses,
                      ChristmasPixels.snowGlobes, ChristmasPixels.holidayMailboxes]
        check(newArt.allSatisfy { sprites in
            sprites.count == 4 && Set(sprites.compactMap {
                NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
            }).count == 4
        }, "Each new decoration has four distinct pixel designs")
        func hasRedNose(_ image: CGImage) -> Bool {
            let bitmap = NSBitmapImageRep(cgImage: image)
            return (0..<bitmap.pixelsHigh).contains { y in
                (0..<bitmap.pixelsWide).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y) else { return false }
                    return color.redComponent > 0.95 && color.redComponent > color.greenComponent * 1.8 &&
                        color.blueComponent < 0.45
                }
            }
        }
        for pose in 0..<2 {
            let noses = ChristmasPixels.reindeer.indices.filter { hasRedNose(ChristmasPixels.reindeer[$0][pose]) }
            check(noses == [ChristmasPixels.leadReindeerIndex] && ChristmasPixels.leadReindeerIndex == 3,
                  "Only the foremost reindeer has a red nose in gallop frame \(pose)")
        }
        let eve = ChristmasScene(season: .eve, windows: windows, screens: [screen], seed: 107)
        check(eve.chimneys.count == 1 && eve.target == eve.chimneys.first && eve.santa == .automatic,
              "Christmas Eve uses one chimney for repeating Santa visits")
        check(eve.target != windows.first?.id, "Santa chooses a chimney below the frontmost window")
        let frontmostOnly = ChristmasScene(season: .eve, windows: [windows[0]], screens: [screen], seed: 107)
        check(frontmostOnly.target == windows[0].id &&
              ChristmasScene.landingVisible(on: windows[0], in: [windows[0]]),
              "An exposed chimney on the frontmost window remains a valid Santa destination")
        if let target = windows.first(where: { $0.id == eve.target }) {
            let first = SantaVisitPose.at(0, target: target, screen: screen)!
            let early = SantaVisitPose.at(2.5, target: target, screen: screen)!
            let near = SantaVisitPose.at(5, target: target, screen: screen)!
            let landingX = ChristmasScene.chimneyX(on: target) - 53
            check(first.sleigh.x + 49 + 3 * 47 + Double(ChristmasPixels.reindeer[3][0].width) < screen.minX - 20,
                  "Santa and every reindeer begin fully outside the screen")
            check(early.sleigh.x > first.sleigh.x + (landingX - first.sleigh.x) * 0.5 &&
                  near.sleigh.x > early.sleigh.x && near.sleigh.x < landingX,
                  "Santa flies in quickly and slows smoothly near the target")
            let approach = stride(from: 0.0, through: 8.5, by: 0.1).compactMap {
                SantaVisitPose.at($0, target: target, screen: screen)?.sleigh.x
            }
            check(zip(approach, approach.dropFirst()).allSatisfy { $0 <= $1 },
                  "Santa's approach advances continuously without jumping")
            let ride = SantaVisitPose.at(9.4 - 0.0001, target: target, screen: screen)!
            let dismount = SantaVisitPose.at(9.4, target: target, screen: screen)!
            let walk = SantaVisitPose.at(10.6, target: target, screen: screen)!
            let climb = SantaVisitPose.at(12, target: target, screen: screen)!
            let descend = SantaVisitPose.at(13.2, target: target, screen: screen)!
            check(!ride.carriesPresent && dismount.carriesPresent && walk.carriesPresent &&
                  climb.carriesPresent && descend.carriesPresent,
                  "Santa takes one present from the sleigh and carries it toward the chimney")
            check(hypot(ride.santa.x - dismount.santa.x, ride.santa.y - dismount.santa.y) < 0.01 &&
                  hypot(walk.santa.x - (ChristmasScene.chimneyX(on: target) - 44), walk.santa.y - (target.frame.maxY + 2)) < 0.01 &&
                  hypot(climb.santa.x - (ChristmasScene.chimneyX(on: target) - 18), climb.santa.y - (target.frame.maxY + 2)) < 0.01 &&
                  hypot(descend.santa.x - (target.frame.minX + target.frame.width * 0.72), descend.santa.y - (target.frame.maxY + 44)) < 0.01,
                  "One Santa moves continuously from sleigh to roof to chimney")
            let landing = SantaVisitPose.at(8.5, target: target, screen: screen)!
            check(abs((landing.sleigh.y - 2) - target.frame.maxY) < 0.01,
                  "The sleigh runner lands on the chosen window roof")
            let parked = [10.6, 14.6, 16.5, 19.49].compactMap { SantaVisitPose.at($0, target: target, screen: screen) }
            check(parked.count == 4 && parked.allSatisfy { $0.sleigh == landing.sleigh },
                  "The sleigh and reindeer wait at the chimney until Santa remounts")
            let down = SantaVisitPose.at(14.0, target: target, screen: screen)!
            let inside = SantaVisitPose.at(15, target: target, screen: screen)!
            let up = SantaVisitPose.at(16.6, target: target, screen: screen)!
            let returning = SantaVisitPose.at(18.2, target: target, screen: screen)!
            let remount = SantaVisitPose.at(19.2, target: target, screen: screen)!
            let departure = SantaVisitPose.at(20, target: target, screen: screen)!
            check(down.carriesPresent && !inside.carriesPresent && !up.carriesPresent &&
                  !returning.carriesPresent && !remount.carriesPresent && !departure.carriesPresent,
                  "The present goes down the chimney and Santa returns empty-handed")
            check(down.stage == .descending && inside.stage == .inside && up.stage == .resurfacing &&
                  returning.stage == .returning && remount.stage == .remounting && departure.stage == .departing &&
                  down.santa.y < descend.santa.y && up.santa.y > inside.santa.y &&
                  departure.sleigh.x > landing.sleigh.x &&
                  SantaVisitPose.at(SantaVisitPose.duration, target: target, screen: screen) == nil,
                  "Santa descends, resurfaces, remounts, and then departs")
            for boundary in [9.4, 10.6, 12, 13.2, 14.4, 16, 17.2, 17.76, 18.8, 19.5] {
                let before = SantaArticulation.at(boundary - 0.0001)
                let after = SantaArticulation.at(boundary)
                check(abs(before.gait.leftFootX - after.gait.leftFootX) < 0.08 &&
                      abs(before.gait.rightFootX - after.gait.rightFootX) < 0.08 &&
                      abs(before.gait.leftLift - after.gait.leftLift) < 0.08 &&
                      abs(before.gait.rightLift - after.gait.rightLift) < 0.08 &&
                      abs(before.handLift - after.handLift) < 0.08 &&
                      abs(before.crouch - after.crouch) < 0.08,
                      "Santa's limbs remain continuous at action boundary \(boundary)")
            }
            check(SantaArticulation.at(10.0).gait.rightLift > 8 &&
                  SantaArticulation.at(12.6).handLift > 4 &&
                  SantaArticulation.at(13.5).gait.leftLift > 0 &&
                  SantaArticulation.at(18.1).gait.leftLift > 0 &&
                  SantaArticulation.at(19.1).gait.rightLift > 8,
                  "Dismount, chimney ascent and descent, return, and remount articulate Santa's limbs")
        }
        let overlapping = [
            SnowStormWindow(id: 500, owner: 1, frame: CGRect(x: 0, y: 190, width: 390, height: 210), level: 0),
            SnowStormWindow(id: 501, owner: 2, frame: CGRect(x: 65, y: 100, width: 300, height: 200), level: 0),
            SnowStormWindow(id: 502, owner: 3, frame: CGRect(x: 450, y: 100, width: 300, height: 200), level: 0)
        ]
        let exposedScene = ChristmasScene(season: .eve, windows: overlapping, screens: [screen], seed: 107)
        check(exposedScene.target == 502 && !ChristmasScene.landingVisible(on: overlapping[1], in: overlapping) &&
              ChristmasScene.landingVisible(on: overlapping[2], in: overlapping),
              "Santa chooses the chimney with an exposed landing path")
        let coveredAgain = ChristmasScene(season: .eve, windows: [overlapping[0],
            SnowStormWindow(id: 503, owner: 4, frame: CGRect(x: 440, y: 190, width: 320, height: 210), level: 0),
            overlapping[1], overlapping[2]], screens: [screen], seed: 107, preferredTarget: 502)
        check(coveredAgain.target == nil,
              "A covered destination hides the current visit instead of switching chimneys")
        let coverageScreens = [StaticEffectScreen(id: 1, frame: screen)]
        let coverage = SnowStormController(settings: SnowStormSettings(), screens: { coverageScreens },
            cursor: { nil }, query: { _, _ in [] }, present: { _, _ in }, presentField: { _, _ in },
            automaticTicks: false, currentDate: { date(23) }, holidayCalendar: calendar, holidaySeed: 107)
        coverage.advanceForTesting(dt: 1.0 / 30, windows: overlapping, cursor: nil)
        coverage.triggerSanta()
        check(coverage.christmas.target == 502, "A manual visit locks onto the exposed chimney")
        let coveredWindows = [overlapping[0],
            SnowStormWindow(id: 503, owner: 4, frame: CGRect(x: 440, y: 190, width: 320, height: 210), level: 0),
            overlapping[1], overlapping[2]]
        coverage.advanceForTesting(dt: 1.0 / 30, windows: coveredWindows, cursor: nil)
        check(coverage.christmas.target == nil, "Santa is hidden while the landing path is covered")
        coverage.advanceForTesting(dt: 1.0 / 30, windows: overlapping, cursor: nil)
        check(coverage.christmas.target == 502, "Santa resumes at the original chimney when the roof is exposed")
        coverage.shutdown()
        let roofline = windows.map { SnowStormWindow(id: $0.id, owner: $0.owner,
            frame: CGRect(x: $0.frame.minX, y: 360, width: $0.frame.width, height: $0.frame.height), level: $0.level) }
        check(ChristmasScene(season: .eve, windows: roofline, screens: [screen], seed: 107).chimneys.count == 1,
              "Christmas Eve decorates roofs even when all windows reach the display top")
        let none = ChristmasScene(season: .week, windows: windows, seed: 107)
        check(none.decorations.isEmpty && none.chimneys.isEmpty && none.target == nil,
              "The preceding week adds no artwork when both checkboxes are off")
        let manual = ChristmasScene(season: .none, windows: windows, screens: [screen], seed: 107, manualSantaStart: 3)
        check(manual.chimneys.count == 1 && manual.santa == .manual(start: 3) && manual.santaPhase(time: 7) == 4,
              "A secret Santa request starts one visit on an ordinary day")
        let visitAtExistingChimney = ChristmasScene(season: .none, windows: windows, screens: [screen], seed: 107,
            decorationsEnabled: true, lightsEnabled: true, manualSantaStart: 3,
            preferredTarget: week.chimneys.first)
        check(visitAtExistingChimney.chimneys == week.chimneys && visitAtExistingChimney.target == week.chimneys.first,
              "Starting Santa's visit does not add or move the existing chimney")
        let screens = [StaticEffectScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 500))]
        var today = date(23)
        let controller = SnowStormController(settings: SnowStormSettings(decorations: true, lights: true), screens: { screens }, cursor: { nil }, query: { _, _ in [] },
            present: { _, _ in }, presentField: { _, _ in }, automaticTicks: false, currentDate: { today }, holidayCalendar: calendar, holidaySeed: 107)
        controller.advanceForTesting(dt: 1.0 / 30, windows: windows, cursor: nil)
        check(controller.christmas.season == .week && controller.christmas.chimneys.count == 1 &&
              controller.allPanels.count == windows.count + 1,
              "Christmas week presents one persistent chimney and artwork on every normal window")
        let persistentChimney = controller.christmas.chimneys.first
        check(controller.allPanels.allSatisfy { $0.ignoresMouseEvents && !$0.canBecomeKey }, "Festive surfaces remain click-through and nonactivating")
        check(controller.allPanels.filter { $0.frame.height == 106 + ChristmasDrawing.windowStripDrop }.count == windows.count,
              "Decorated window strips include space below the top edge for hanging lights")
        let lit = windows.first { week.decoration(for: $0.id)?.lights == true }!
        let other = windows.first { $0.id != lit.id }!
        var reanchors: [UInt32] = []
        let movingLights = SnowStormController(settings: SnowStormSettings(decorations: true, lights: true),
            screens: { screens }, cursor: { nil }, query: { _, _ in [] },
            present: { _, target in if let target { reanchors.append(target.id) } },
            presentField: { _, _ in }, automaticTicks: false, currentDate: { date(23) },
            holidayCalendar: calendar, holidaySeed: 107)
        movingLights.advanceForTesting(dt: 1.0 / 30, windows: [lit, other], cursor: nil)
        reanchors.removeAll()
        var draggedLit = lit; draggedLit.frame.origin.x += 3
        movingLights.advanceForTesting(dt: 1.0 / 30, windows: [draggedLit, other], cursor: nil)
        check(reanchors == [lit.id], "Dragging the frontmost lit window re-anchors its own light strip above it")
        reanchors.removeAll()
        movingLights.advanceForTesting(dt: 1.0 / 30, windows: [draggedLit, other], cursor: nil)
        check(reanchors == [lit.id], "The foreground light strip is re-anchored even when its window has not moved")
        movingLights.shutdown()
        if let display = NSScreen.screens.first {
            let first = NSWindow(contentRect: CGRect(x: display.frame.midX - 260, y: display.frame.midY - 90, width: 300, height: 180),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            let second = NSWindow(contentRect: first.frame.offsetBy(dx: 220, dy: 35),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            first.title = "Christmas lights layer fixture"
            second.title = "Christmas lights focus fixture"
            first.orderFrontRegardless(); second.orderFrontRegardless()
            defer { first.orderOut(nil); second.orderOut(nil) }
            let firstWindow = SnowStormWindow(id: UInt32(first.windowNumber), owner: getpid(), frame: first.frame, level: 0)
            let secondWindow = SnowStormWindow(id: UInt32(second.windowNumber), owner: getpid(), frame: second.frame, level: 0)
            let layeredLights = SnowStormController(settings: SnowStormSettings(lights: true),
                screens: { [StaticEffectScreen(id: 1, frame: display.frame)] }, cursor: { nil },
                query: { _, _ in [] }, automaticTicks: false, currentDate: { date(23) },
                holidayCalendar: calendar, holidaySeed: 107)
            defer { layeredLights.shutdown() }
            layeredLights.advanceForTesting(dt: 1.0 / 30, windows: [secondWindow, firstWindow], cursor: nil)
            let strips = layeredLights.allPanels.filter { $0.frame.height == 106 + ChristmasDrawing.windowStripDrop }
            let firstStrip = strips.first { abs($0.frame.minX - (first.frame.minX - 4)) < 0.5 }!
            let secondStrip = strips.first { abs($0.frame.minX - (second.frame.minX - 4)) < 0.5 }!
            func orderedIDs() -> [Int] {
                (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                    .compactMap { $0[kCGWindowNumber as String] as? Int }
            }
            second.orderFrontRegardless()
            layeredLights.reanchorDecoratedPanelsForTesting()
            var ids = orderedIDs()
            check(ids.firstIndex(of: secondStrip.windowNumber)! < ids.firstIndex(of: second.windowNumber)!,
                  "Clicking the foreground window leaves its Christmas lights above it")
            first.orderFrontRegardless()
            layeredLights.reanchorDecoratedPanelsForTesting()
            ids = orderedIDs()
            check(ids.firstIndex(of: firstStrip.windowNumber)! < ids.firstIndex(of: first.windowNumber)! &&
                  ids.firstIndex(of: first.windowNumber)! < ids.firstIndex(of: secondStrip.windowNumber)!,
                  "Changing focus immediately raises the newly focused lights and keeps the old strip behind")
            second.orderFrontRegardless()
            let frontmostSanta = SnowStormController(settings: SnowStormSettings(),
                screens: { [StaticEffectScreen(id: 1, frame: display.frame)] }, cursor: { nil },
                query: { _, _ in [] }, automaticTicks: false, currentDate: { date(23) },
                holidayCalendar: calendar, holidaySeed: 107)
            defer { frontmostSanta.shutdown() }
            frontmostSanta.advanceForTesting(dt: 1.0 / 30, windows: [secondWindow], cursor: nil)
            frontmostSanta.triggerSanta()
            let santaLayer = frontmostSanta.santaPanelsForTesting.first
            ids = orderedIDs()
            let santaAboveFrontmost = santaLayer.flatMap { layer -> Bool? in
                guard let santaIndex = ids.firstIndex(of: layer.windowNumber),
                      let windowIndex = ids.firstIndex(of: second.windowNumber) else { return nil }
                return santaIndex < windowIndex
            } == true
            check(frontmostSanta.christmas.target == secondWindow.id &&
                  ids.firstIndex(of: second.windowNumber)! < ids.firstIndex(of: first.windowNumber)! &&
                  santaAboveFrontmost,
                  "Santa's flight layer stays above the frontmost chimney window")
        }
        today = date(24); controller.advanceForTesting(dt: 1.0 / 30, windows: windows, cursor: nil)
        check(controller.christmas.season == .eve && controller.christmas.chimneys == [persistentChimney].compactMap { $0 },
              "Christmas Eve Santa visits the existing chimney without adding another")
        today = date(26); controller.advanceForTesting(dt: 1.0 / 30, windows: windows, cursor: nil)
        check(controller.christmas.season == .none && controller.allPanels.count == windows.count + 1 && controller.christmas.santa == .none,
              "Checkbox artwork remains after Christmas while automatic Santa stops")
        controller.update(settings: SnowStormSettings())
        controller.advanceForTesting(dt: 1.0 / 30, windows: windows, cursor: nil)
        check(controller.allPanels.count == 1, "Turning both artwork checkboxes off removes their window strips")
        controller.triggerSanta()
        check(controller.christmas.santa != .none && controller.christmas.chimneys.count == 1 &&
              controller.allPanels.count == 3 && controller.santaPanelsForTesting.count == 1,
              "Manual Santa can start without Decorations or Lights and gets one flight layer")
        let firstVisit = controller.christmas.santa
        controller.advanceForTesting(dt: 1, windows: windows, cursor: nil)
        controller.triggerSanta()
        check(controller.christmas.santa == firstVisit,
              "A second Santa request cannot start while the first is delivering")
        for _ in 0..<700 { controller.advanceForTesting(dt: 1.0 / 30, windows: windows, cursor: nil) }
        check(controller.christmas.santa == .none && controller.allPanels.count == 1,
              "Manual Santa finishes after one delivery instead of repeating")
        controller.shutdown(); check(controller.allPanels.isEmpty, "Shutdown releases festive surfaces")
        let yetiWindows = [
            SnowStormWindow(id: 900, owner: 1, frame: CGRect(x: 15, y: 65, width: 220, height: 130), level: 0),
            SnowStormWindow(id: 916, owner: 2, frame: CGRect(x: 300, y: 120, width: 320, height: 150), level: 0)
        ]
        let yetiScene = ChristmasScene(season: .none, windows: yetiWindows, screens: [screen], seed: 107,
                                       decorationsEnabled: true)
        check(yetiScene.carolerFraction(for: 916) != nil &&
              ChristmasScene.roofVisible(on: yetiWindows[1], in: yetiWindows,
                                         fractions: [yetiScene.carolerFraction(for: 916)!]),
              "A real caroler group on an exposed roof can host the encounter")
        check((480...960).contains(YetiEncounter.nextDelay(seed: 107)),
              "Natural Yeti visits are separated by eight to sixteen minutes")
        let runFrames = (0..<8).map { YetiAnimation.frame(at: (Double($0) + 0.01) / 12, biting: false) }
        let biteFrames = (0..<2).map { YetiAnimation.frame(at: (Double($0) + 0.01) / 12, biting: true) }
        let uniqueYetiArt = Set(ChristmasPixels.yeti.compactMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
        })
        check(ChristmasPixels.yeti.count == YetiAnimation.frameCount && uniqueYetiArt.count == 8 &&
              Set(runFrames).count == YetiAnimation.runningFrames && biteFrames == [6, 7],
              "The Yeti snaps through six distinct running silhouettes and two attack poses")
        let naturalYeti = SnowStormController(settings: SnowStormSettings(decorations: true),
            screens: { screens }, cursor: { nil }, query: { _, _ in [] }, present: { _, _ in },
            presentField: { _, _ in }, automaticTicks: false, currentDate: { date(23) }, holidayCalendar: calendar, holidaySeed: 107)
        naturalYeti.advanceForTesting(dt: 1.0 / 30, windows: yetiWindows, cursor: nil)
        naturalYeti.scheduleYetiNowForTesting()
        naturalYeti.advanceForTesting(dt: 1.0 / 30, windows: yetiWindows, cursor: nil)
        let firstYeti = naturalYeti.christmas.yeti
        check(firstYeti?.windowID == 916 && firstYeti?.temporaryCarolers == false,
              "A rare natural visit targets an existing caroler")
        naturalYeti.triggerYeti()
        check(naturalYeti.christmas.yeti == firstYeti, "A second Yeti cannot start during an encounter")
        for _ in 0..<35 { naturalYeti.advanceForTesting(dt: 0.05, windows: yetiWindows, cursor: nil) }
        check(naturalYeti.christmas.yeti.map { $0.phase(at: naturalYeti.simulation.time) >= YetiEncounter.biteTime } == true,
              "One caroler disappears during the bite")
        for _ in 0..<35 { naturalYeti.advanceForTesting(dt: 0.05, windows: yetiWindows, cursor: nil) }
        check(naturalYeti.christmas.yeti == nil && naturalYeti.christmas.consumedCarolers.contains(916),
              "The Yeti exits and the eaten caroler remains missing")
        naturalYeti.shutdown()
        let manualYeti = SnowStormController(settings: SnowStormSettings(), screens: { screens },
            cursor: { nil }, query: { _, _ in [] }, present: { _, _ in }, presentField: { _, _ in },
            automaticTicks: false, currentDate: { date(23) }, holidayCalendar: calendar, holidaySeed: 107)
        manualYeti.triggerYeti()
        manualYeti.advanceForTesting(dt: 1.0 / 30, windows: yetiWindows, cursor: nil)
        check(manualYeti.christmas.yeti?.temporaryCarolers == true &&
              manualYeti.christmas.decoration(for: manualYeti.christmas.yeti!.windowID) != nil,
              "The Lights-label summon supplies carolers even when Decorations is off")
        manualYeti.shutdown()
        try settingsChecks(root: root) { check($0, $1) }
        try preview(root: root, scene: week, eve: eve, windows: windows)
        try previewYeti(root: root, windows: yetiWindows, screen: screen)
        print("\(checks) Christmas checks passed: stable decorations, Santa visits, rare and summoned Yeti encounters, window attachment, and cleanup.")
    }
    private static func settingsChecks(root: URL, check: (Bool, String) -> Void) throws {
        let prefs = PreferenceStore(defaults: MemoryDefaults())
        prefs.set(StaticEffect.snowStorm.rawValue, for: .staticEffect)
        prefs.set(true, for: .suspended)
        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { false })
        let logger = FileLogger(directory: root.appendingPathComponent("christmas-settings-logs"), maintenance: false)
        let runtime = RuntimeCoordinator(preferences: prefs, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: prefs, permissions: permissions, runtime: runtime,
                                      logger: logger, login: LoginService(preferences: prefs))
        let page = VisualEffectsPageController(.visualEffects, context: context)
        _ = page.view
        let fireplace = page.controls["visualEffects.static.option.fireplace"] as! ActionButton
        let decorations = page.controls["visualEffects.static.option.decorations"] as! ActionButton
        let lights = page.controls["visualEffects.static.option.lights"] as! ActionButton
        check(lights.superview?.superview === fireplace.superview && decorations.superview?.superview === fireplace.superview,
              "Fireplace, Decorations, and Lights checkboxes share one horizontal row")
        let snowRows = fireplace.superview!.superview as! NSStackView
        let gust = page.controls["visualEffects.static.option.windgusts"] as! NSSlider
        let width = page.controls["visualEffects.static.option.fireplaceWidth"] as! NSSlider
        let height = page.controls["visualEffects.static.option.fireplaceHeight"] as! NSSlider
        func settingsRow(for control: NSView) -> NSView {
            var row = control
            while row.superview !== snowRows { row = row.superview! }
            return row
        }
        let gustIndex = snowRows.arrangedSubviews.firstIndex(of: settingsRow(for: gust))!
        let widthIndex = snowRows.arrangedSubviews.firstIndex(of: settingsRow(for: width))!
        let heightIndex = snowRows.arrangedSubviews.firstIndex(of: settingsRow(for: height))!
        check(widthIndex == gustIndex + 1 && heightIndex == widthIndex + 1,
              "Fireplace Width and Height appear directly below Wind Gusts")
        check(!prefs.bool(.stormDecorations) && !prefs.bool(.stormLights), "Decoration and light checkboxes default off")
        decorations.state = .on; _ = decorations.sendAction(decorations.action!, to: decorations.target)
        check(prefs.bool(.stormDecorations) && !prefs.bool(.stormLights), "Decorations saves independently of Lights")
        lights.state = .on; _ = lights.sendAction(lights.action!, to: lights.target)
        check(prefs.bool(.stormDecorations) && prefs.bool(.stormLights), "Lights saves independently of Decorations")
        func views(_ parent: NSView) -> [NSView] { [parent] + parent.subviews.flatMap(views) }
        let label = views(page.view).first { $0.identifier?.rawValue == "visualEffects.static.decorationsLabel" }!
        let gesture = label.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first!
        check(gesture.numberOfClicksRequired == 2 && gesture.target === page,
              "Only a double-click on the Decorations text label is wired to Santa")
        var summons = 0
        let token = NotificationCenter.default.addObserver(forName: .santaRequested, object: prefs, queue: nil) { _ in summons += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let handled = NSApp.sendAction(gesture.action!, to: gesture.target, from: gesture)
        check(handled && summons == 1 && prefs.bool(.stormDecorations),
              "The label's double-click action requests Santa without changing the checkbox")
        let lightsLabel = views(page.view).first { $0.identifier?.rawValue == "visualEffects.static.lightsLabel" }!
        let yetiGesture = lightsLabel.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first!
        check(yetiGesture.numberOfClicksRequired == 2 && yetiGesture.target === page,
              "Only a double-click on the Lights text label is wired to the Yeti")
        var yetiSummons = 0
        let yetiToken = NotificationCenter.default.addObserver(forName: .yetiRequested, object: prefs, queue: nil) { _ in yetiSummons += 1 }
        defer { NotificationCenter.default.removeObserver(yetiToken) }
        let yetiHandled = NSApp.sendAction(yetiGesture.action!, to: yetiGesture.target, from: yetiGesture)
        check(yetiHandled && yetiSummons == 1 && prefs.bool(.stormLights),
              "The Lights label's double-click requests the Yeti without changing its checkbox")
        let livePrefs = PreferenceStore(defaults: MemoryDefaults())
        livePrefs.set(StaticEffect.snowStorm.rawValue, for: .staticEffect)
        let live = StaticEffectsController(preferences: livePrefs, reducedMotion: { false }, screens: { [] },
                                           present: { _, _ in }, automaticPlacement: false)
        livePrefs.requestSanta()
        check(live.stormForTesting?.christmas.santa.active == true,
              "The live Snow Storm receives the secret Santa request")
        live.shutdown()
        let yetiPrefs = PreferenceStore(defaults: MemoryDefaults())
        yetiPrefs.set(StaticEffect.snowStorm.rawValue, for: .staticEffect)
        let screen = StaticEffectScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let yetiLive = StaticEffectsController(preferences: yetiPrefs, reducedMotion: { false },
            screens: { [screen] }, present: { _, _ in }, automaticPlacement: false)
        let roofs = [
            SnowStormWindow(id: 900, owner: 1, frame: CGRect(x: 15, y: 65, width: 220, height: 130), level: 0),
            SnowStormWindow(id: 916, owner: 2, frame: CGRect(x: 300, y: 120, width: 320, height: 150), level: 0)
        ]
        yetiLive.stormForTesting?.advanceForTesting(dt: 1.0 / 30, windows: roofs, cursor: nil)
        yetiPrefs.requestYeti()
        check(yetiLive.stormForTesting?.christmas.yeti?.temporaryCarolers == true,
              "The live Snow Storm receives the Lights-label Yeti request without Decorations")
        yetiLive.shutdown()
    }
    private static func preview(root: URL, scene: ChristmasScene, eve: ChristmasScene, windows: [SnowStormWindow]) throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
        let flightWindows = [
            SnowStormWindow(id: 100, owner: 1, frame: CGRect(x: 90, y: 90, width: 340, height: 180), level: 0),
            SnowStormWindow(id: 101, owner: 2, frame: CGRect(x: 470, y: 155, width: 250, height: 130), level: 0),
            SnowStormWindow(id: 102, owner: 3, frame: CGRect(x: 245, y: 40, width: 270, height: 125), level: 0)
        ]
        let flightEve = ChristmasScene(season: .eve, windows: flightWindows, screens: [bounds], seed: 107,
                                       decorationsEnabled: true, lightsEnabled: true)
        for (name, current, time) in [("christmas-week.png", scene, 8.0), ("christmas-week-motion.png", scene, 8.35),
                                      ("christmas-eve-flight.png", eve, 5.0),
                                      ("christmas-eve-landing.png", eve, 8.8), ("christmas-eve-dismount.png", eve, 10.0),
                                      ("christmas-eve-walk.png", eve, 11.3),
                                      ("christmas-eve-climb.png", eve, 12.7), ("christmas-eve-chimney.png", eve, 13.7),
                                      ("christmas-eve-inside.png", eve, 15.0),
                                      ("christmas-eve-return.png", eve, 17.8),
                                      ("christmas-eve-return-walk.png", eve, 18.3),
                                      ("christmas-eve-remount.png", eve, 19.2),
                                      ("christmas-eve-depart.png", eve, 20.5)] {
            let isFlight = name == "christmas-eve-flight.png"
            let current = isFlight ? flightEve : current
            let renderedWindows = isFlight ? flightWindows : windows
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            let c = graphics.cgContext
            c.setFillColor(CGColor(red: 0.04, green: 0.10, blue: 0.18, alpha: 1)); c.fill(bounds)
            for w in renderedWindows.reversed() where w.frame.intersects(bounds) {
                c.setFillColor(CGColor(red: 0.20, green: 0.28, blue: 0.37, alpha: 1)); c.fill(w.frame)
                if let decoration = current.decoration(for: w.id) {
                    ChristmasDrawing.window(w, decoration: decoration, chimney: current.hasChimney(w.id),
                        time: time, scene: current, in: c, origin: .zero)
                }
            }
            ChristmasDrawing.santaVisit(scene: current, windows: renderedWindows, screen: bounds, time: time, in: c, origin: .zero)
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
        }
        let before = try Data(contentsOf: root.appendingPathComponent("christmas-week.png"))
        let after = try Data(contentsOf: root.appendingPathComponent("christmas-week-motion.png"))
        assert(before != after, "Carolers and lights must animate between preview frames")
        try spriteSheet(root: root)
        try presentSheet(root: root)
        try decorationSheet(root: root)
        try walkCycleSheet(root: root)
    }
    private static func walkCycleSheet(root: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 300)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 300,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let c = graphics.cgContext
        c.setFillColor(CGColor(red: 0.055, green: 0.10, blue: 0.16, alpha: 1)); c.fill(bounds)
        let phases: [Double] = [0, .pi / 4, .pi / 2, .pi, 3 * .pi / 2, 7 * .pi / 4]
        for row in 0..<2 {
            let baseline = row == 0 ? 167.0 : 24.0
            c.setStrokeColor(NSColor(calibratedWhite: 0.43, alpha: 0.7).cgColor)
            c.setLineWidth(1); c.move(to: CGPoint(x: 12, y: baseline)); c.addLine(to: CGPoint(x: 888, y: baseline)); c.strokePath()
            for (index, phase) in phases.enumerated() {
                let x = 80 + Double(index) * 140
                c.saveGState()
                c.translateBy(x: x, y: baseline)
                c.scaleBy(x: 2.5, y: 2.5)
                ChristmasDrawing.walkFigure(in: c, x: 0, y: 0, phase: phase, singing: row == 0)
                c.restoreGState()
                ("\(index + 1)" as NSString).draw(at: CGPoint(x: x - 4, y: baseline - 18),
                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                                     .foregroundColor: NSColor.white])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("christmas-walk-cycle.png"))
    }
    private static func decorationSheet(root: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 650)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 650,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let c = graphics.cgContext
        c.setFillColor(CGColor(red: 0.055, green: 0.10, blue: 0.16, alpha: 1)); c.fill(bounds)
        c.interpolationQuality = .none
        let groups: [(String, [CGImage])] = [
            ("GINGERBREAD", ChristmasPixels.gingerbreadHouses),
            ("TOY TRAIN", ChristmasPixels.toyTrains),
            ("LANTERNS", ChristmasPixels.lanternPairs),
            ("WREATH", ChristmasPixels.wreaths),
            ("NUTCRACKER", ChristmasPixels.nutcrackers),
            ("ROCKING HORSE", ChristmasPixels.rockingHorses),
            ("SNOW GLOBE", ChristmasPixels.snowGlobes),
            ("MAILBOX", ChristmasPixels.holidayMailboxes)
        ]
        for (row, group) in groups.enumerated() {
            let y = 570 - Double(row) * 80
            (group.0 as NSString).draw(at: CGPoint(x: 15, y: y + 15),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                                 .foregroundColor: NSColor.white])
            for (column, image) in group.1.enumerated() {
                c.draw(image, in: CGRect(x: 200 + Double(column) * 165, y: y,
                                         width: Double(image.width) * 2, height: Double(image.height) * 2))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("christmas-more-decorations.png"))
    }
    private static func presentSheet(root: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 300)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 300,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let c = graphics.cgContext
        c.setFillColor(CGColor(red: 0.055, green: 0.10, blue: 0.16, alpha: 1)); c.fill(bounds)
        c.interpolationQuality = .none
        for (index, image) in ChristmasPixels.gifts.enumerated() {
            let column = index % 6, row = index / 6
            let x = 30 + Double(column) * 145, y = 178 - Double(row) * 125
            c.draw(image, in: CGRect(x: x, y: y, width: Double(image.width) * 3,
                                     height: Double(image.height) * 3))
            ("GIFT \(index + 1)" as NSString).draw(at: CGPoint(x: x, y: y - 22),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                                 .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("christmas-presents.png"))
    }
    private static func spriteSheet(root: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 340)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 340,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let c = graphics.cgContext
        c.setFillColor(CGColor(red: 0.055, green: 0.10, blue: 0.16, alpha: 1)); c.fill(bounds)
        c.interpolationQuality = .none
        let samples: [(String, CGImage, Double, Double)] = [
            ("SLEIGH", ChristmasPixels.sleigh, 35, 215),
            ("REINDEER / GALLOP A", ChristmasPixels.reindeer[0][0], 325, 215),
            ("LEAD / RED NOSE", ChristmasPixels.reindeer[ChristmasPixels.leadReindeerIndex][0], 620, 215),
            ("CHIMNEY", ChristmasPixels.chimney, 35, 45),
            ("PRESENTS", ChristmasPixels.gifts[0], 325, 55),
            ("CANDY CANE", ChristmasPixels.candyCane, 620, 50)
        ]
        for (label, image, x, y) in samples {
            c.draw(image, in: CGRect(x: x, y: y, width: Double(image.width) * 3, height: Double(image.height) * 3))
            (label as NSString).draw(at: CGPoint(x: x, y: y - 22),
                                     withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                                                      .foregroundColor: NSColor.white])
        }
        for i in 1..<5 {
            let image = ChristmasPixels.gifts[i]
            c.draw(image, in: CGRect(x: 380 + Double(i) * 48, y: 60,
                                     width: Double(image.width) * 2, height: Double(image.height) * 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("christmas-pixel-sprites.png"))
    }
    private static func previewYeti(root: URL, windows: [SnowStormWindow], screen: CGRect) throws {
        let spriteStrip = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720, pixelsHigh: 120,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
        let stripGraphics = NSGraphicsContext(bitmapImageRep: spriteStrip)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = stripGraphics
        stripGraphics.cgContext.setFillColor(NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.17, alpha: 1).cgColor)
        stripGraphics.cgContext.fill(CGRect(x: 0, y: 0, width: 720, height: 120))
        for (index, image) in ChristmasPixels.yeti.enumerated() {
            ChristmasPixels.draw(image, in: stripGraphics.cgContext, x: Double(index) * 90 + 12, y: 25)
            (index < 6 ? "run \(index + 1)" : "bite \(index - 5)" as String).draw(
                at: CGPoint(x: index * 90 + 18, y: 7),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                                 .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        try spriteStrip.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("yeti-run-cycle.png"))
        let base = ChristmasScene(season: .none, windows: windows, screens: [screen], seed: 107,
                                  decorationsEnabled: true)
        let encounter = YetiEncounter(start: 0, windowID: 916,
                                      carolerFraction: base.carolerFraction(for: 916)!,
                                      direction: 1, temporaryCarolers: false)
        for (name, time) in [("yeti-approach.png", 0.96), ("yeti-bite.png", 1.48),
                             ("yeti-exit.png", 2.25)] {
            let scene = ChristmasScene(season: .none, windows: windows, screens: [screen], seed: 107,
                                       decorationsEnabled: true, yeti: encounter)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 500,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            let c = graphics.cgContext
            c.setFillColor(CGColor(red: 0.04, green: 0.10, blue: 0.18, alpha: 1)); c.fill(screen)
            for window in windows.reversed() {
                c.setFillColor(CGColor(red: 0.20, green: 0.28, blue: 0.37, alpha: 1)); c.fill(window.frame)
                if let decoration = scene.decoration(for: window.id) {
                    ChristmasDrawing.window(window, decoration: decoration, chimney: false,
                                            time: time, scene: scene, in: c, origin: .zero)
                }
            }
            ChristmasDrawing.yetiVisit(scene: scene, windows: windows, screen: screen,
                                       time: time, in: c, origin: .zero)
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
        }
    }
}
