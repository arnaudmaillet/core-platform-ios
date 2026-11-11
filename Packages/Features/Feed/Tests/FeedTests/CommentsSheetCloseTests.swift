import CoreModels
import CoreNavigation
import Testing
import UIKit
@testable import Feed

/// THE COMMENTS SHEET'S CLOSE LANDS IN ONE MOVEMENT (#2287 § 4). The owner's
/// film: the media's way back to full screen cut short — a card at ~60 % of
/// the screen, full screen the next frame — because the session's end put
/// the page back (`clearCommentsSheetLayout`) as UIKit's dismissal completed,
/// over a motion still running. The media now lands on its own clock
/// (`CommentsSheetLanding`), the page is put back only from rest, and the
/// motion's last frame is the resting cell.
@MainActor
@Suite(.serialized)
struct CommentsSheetCloseTests {
    private static let frame: CFTimeInterval = 1.0 / 120
    /// The media shrunk over a collapsed sheet: a portrait clip in the room
    /// above it.
    private static let collapsed = CommentsSheetPose(
        progress: 1, region: CGRect(x: 8, y: 70, width: 386, height: 420), out: 0, towardsPreview: 0, interface: 1
    )

    // MARK: - The movement

    /// Landed by its deadline, whatever the sheet does — here, a sheet that
    /// never moves.
    @Test func theWayBackLandsByItsDeadlineWhateverTheSheet() {
        var landing = CommentsSheetLanding(from: Self.collapsed, start: 10, duration: 0.35)
        var now: CFTimeInterval = 10
        var frames = 0
        while !landing.hasLanded, frames < 100 {
            now += Self.frame
            frames += 1
            _ = landing.advance(to: now, sheetRemaining: 1)
        }
        #expect(landing.hasLanded)
        #expect(now <= 10.35 + Self.frame + 0.0001, "landed late: \(now - 10) s")
        #expect(landing.pose(remaining: landing.remaining).isAtRest)
    }

    /// Never behind the sheet: under its opaque ground, a media growing
    /// faster is hidden; slower, it would open a gap over the sheet's top.
    @Test func theMediaNeverStaysBehindTheSheet() {
        var landing = CommentsSheetLanding(from: Self.collapsed, start: 0, duration: 0.35)
        let pose = landing.advance(to: 0.02, sheetRemaining: 0.4)
        #expect(abs(landing.remaining - 0.4) < 0.0001)
        #expect(abs(pose.progress - 0.4) < 0.0001)
    }

    /// ⚠️ THE SHEET LEADS FROM ITS FIRST FRAME (the coordinator's film): a
    /// first frame that comes late, the sheet barely moved, leaves the media
    /// where the sheet says — not far ahead on a clock of its own (the old
    /// ease-out put it at 0.36 of the way here: the collapsed card thrown to
    /// nearly full screen).
    @Test func theSheetLeadsFromItsFirstFrame() {
        var landing = CommentsSheetLanding(from: Self.collapsed, start: 0, duration: 0.35)
        let pose = landing.advance(to: 0.1, sheetRemaining: 0.97)
        #expect(abs(landing.remaining - 0.97) < 0.0001, "the media ran ahead of the sheet: \(landing.remaining)")
        #expect(abs(pose.progress - 0.97) < 0.0001)
    }

    /// Pulled ahead by the sheet, then left alone (the sheet gone): it
    /// carries on from there, never back, never in a jump, landed by the
    /// same deadline.
    @Test func pulledAheadItCarriesOnFromThere() {
        var landing = CommentsSheetLanding(from: Self.collapsed, start: 0, duration: 0.35)
        _ = landing.advance(to: 0.02, sheetRemaining: 0.4)
        var last = landing.remaining
        var now: CFTimeInterval = 0.02
        var frames = 0
        while !landing.hasLanded, frames < 100 {
            now += Self.frame
            frames += 1
            _ = landing.advance(to: now, sheetRemaining: nil)
            #expect(landing.remaining <= last + 0.000_001, "went back: \(last) → \(landing.remaining)")
            #expect(last - landing.remaining < 0.1, "a jump: \(last) → \(landing.remaining)")
            last = landing.remaining
        }
        #expect(landing.hasLanded)
        #expect(now <= 0.35 + Self.frame + 0.0001)
    }

    /// No dimming on the way back (the owner): a media still scaled out comes
    /// in at its brightness early in the movement; the page's interface
    /// waits for it, and the last pose is the page at rest.
    @Test func theMediaComesBackLitAndTheInterfaceWaitsForIt() {
        let scaledOut = CommentsSheetPose(
            progress: 1, region: Self.collapsed.region, out: 1, towardsPreview: 1, interface: 1
        )
        let landing = CommentsSheetLanding(from: scaledOut, start: 0, duration: 0.35)
        #expect(landing.pose(remaining: CommentsSheetLanding.outGoneBy).out == 0)
        #expect(landing.pose(remaining: 0.5).interface == 1, "the interface came back before the media")
        #expect(landing.pose(remaining: 0).isAtRest)
    }

    /// A reopening while the media is still on its way back turns around
    /// from where it stands: the new sheet's pose takes over as it reaches
    /// the media, with nothing jumping on the way.
    @Test func aReopeningTurnsAroundFromWhereTheMediaStands() {
        let handed = CommentsSheetPose(
            progress: 0.4, region: CGRect(x: 8, y: 70, width: 386, height: 420), out: 0, towardsPreview: 0.2,
            interface: 0.8
        )
        let room = CGRect(x: 8, y: 62, width: 386, height: 780)
        let rising = { (progress: CGFloat) in
            CommentsSheetPose(progress: progress, region: room, out: 0, towardsPreview: 0, interface: progress)
        }
        let first = handed.turningAround(towards: rising(0))
        #expect(first.pose == handed, "the media moved at the reopening")
        #expect(!first.caughtUp)
        let half = handed.turningAround(towards: rising(0.2))
        #expect(half.pose.progress == 0.4, "the media did not hold where it stood")
        #expect(half.pose.region.height > handed.region.height && half.pose.region.height < room.height)
        let caught = handed.turningAround(towards: rising(0.5))
        #expect(caught.caughtUp)
        #expect(caught.pose == rising(0.5))
    }

    // MARK: - The session

    private final class Count {
        var value = 0
    }

    /// A session over a portrait clip's cell, in a window — no sheet
    /// presented: its close is driven by hand (`debugBeginLanding`).
    private func makeSession() -> (SnapCommentsSheetSession, SnapFeedCell, UIWindow, Count) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let feed = UIViewController()
        window.rootViewController = feed
        window.isHidden = false
        let cell = SnapFeedCell(frame: window.bounds)
        feed.view.addSubview(cell)
        cell.debugFrameClip(aspect: CGSize(width: 9, height: 16))
        let ended = Count()
        let session = SnapCommentsSheetSession(
            postID: PostID("p"), panel: UIViewController(), cell: cell, feed: feed,
            walletBadge: nil, onWalletTap: nil
        ) { ended.value += 1 }
        return (session, cell, window, ended)
    }

    private static func isIdentity(_ transform: CGAffineTransform) -> Bool {
        abs(transform.a - 1) < 0.0001 && abs(transform.d - 1) < 0.0001 && abs(transform.b) < 0.0001
            && abs(transform.c) < 0.0001 && abs(transform.tx) < 0.01 && abs(transform.ty) < 0.01
    }

    /// ⚠️ THE CLOSE NEVER PUTS THE PAGE BACK WHILE THE MEDIA MOVES — not even
    /// when UIKit's dismissal completes first, mid-way: the page is put back
    /// once, from rest, and only then does the session end.
    @Test func theCloseNeverClearsTheLayoutWhileTheMediaMoves() {
        let (session, cell, window, ended) = makeSession()
        defer { window.isHidden = true }
        let moves = !UIAccessibility.isReduceMotionEnabled
        session.debugBeginLanding(from: Self.collapsed, now: 0, duration: 0.35)
        #expect(session.phase == .landing)
        #expect(cell.debugCommentsSheetClears == 0)
        var now: CFTimeInterval = 0
        var frames = 0
        while session.phase == .landing, frames < 200 {
            now += Self.frame
            frames += 1
            if frames == 12 {
                session.debugSheetDidGo()
                #expect(cell.debugCommentsSheetClears == 0, "the sheet's end put the page back mid-way")
                #expect(ended.value == 0, "the session ended with the media in flight")
            }
            session.debugFollowLanding(now: now)
            if session.phase == .landing {
                #expect(cell.debugCommentsSheetClears == 0, "cleared at frame \(frames) with the media moving")
                // Still visibly on its way over the first two thirds: the
                // curve's last frames are within a hair of home anyway.
                if moves, now < 0.35 * 2 / 3 {
                    #expect(!Self.isIdentity(cell.debugCommentsSheetCardTransform), "the media was snapped home at \(now)")
                }
            }
        }
        #expect(session.phase == .landed)
        #expect(cell.debugCommentsSheetClears == 1, "the page was put back \(cell.debugCommentsSheetClears) times")
        #expect(ended.value == 1)
    }

    /// ⚠️ FROM COLLAPSED, THE WAY BACK STARTS FROM THE RESTING CARD (the
    /// coordinator's film, 2026-11-11): the first frames are the collapsed
    /// pose the sheet left — the picture's frame, its window (the cut) and
    /// its corners within a point — and the window then opens a few points
    /// a frame, never at once.
    @Test func fromCollapsedTheFirstFramesAreTheRestingCard() throws {
        let (session, cell, window, _) = makeSession()
        defer { window.isHidden = true }
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        // The sheet at rest, collapsed, as `follow` draws it.
        cell.setCommentsSheetLayout(Self.collapsed, sheetCornerRadius: 0, previewCornerRadius: SnapCommentsPreview.cornerRadius)
        let resting = try #require(cell.commentsSheetPictureFrame)
        let restingRadius = cell.commentsSheetPictureRadius
        let near = { (a: CGRect, b: CGRect) in
            abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1
                && abs(a.height - b.height) < 1
        }

        session.debugBeginLanding(from: Self.collapsed, now: 0, duration: 0.35)
        let started = try #require(cell.commentsSheetPictureFrame)
        #expect(near(started, resting), "the way back began at \(started), the card rested at \(resting)")
        session.debugFollowLanding(now: Self.frame)
        let first = try #require(cell.commentsSheetPictureFrame)
        #expect(near(first, resting), "the first frame jumped: \(resting) → \(first)")
        #expect(abs(cell.commentsSheetPictureRadius - restingRadius) < 1)

        var previous = first
        var now = Self.frame
        var frames = 1
        var widest: CGFloat = 0
        while session.phase == .landing, frames < 200 {
            now += Self.frame
            frames += 1
            session.debugFollowLanding(now: now)
            guard session.phase == .landing, let shown = cell.commentsSheetPictureFrame else { break }
            widest = max(widest, abs(shown.width - previous.width))
            previous = shown
        }
        #expect(widest < 6, "the window opened \(widest) pt in one frame")
    }

    /// The media lands before the sheet has gone: the page is at rest under
    /// the sheet's last frames, and the session waits for the sheet.
    @Test func aMediaLandedFirstWaitsForTheSheet() {
        let (session, cell, window, ended) = makeSession()
        defer { window.isHidden = true }
        session.debugBeginLanding(from: Self.collapsed, now: 0, duration: 0.35)
        var now: CFTimeInterval = 0
        var frames = 0
        while session.phase == .landing, frames < 200 {
            now += Self.frame
            frames += 1
            session.debugFollowLanding(now: now)
        }
        #expect(session.phase == .landed)
        #expect(cell.debugCommentsSheetClears == 1)
        #expect(ended.value == 0, "the session ended before its sheet had gone")
        session.debugSheetDidGo()
        #expect(ended.value == 1)
        #expect(cell.debugCommentsSheetClears == 1, "the page was put back twice")
    }

    /// THE MOTION'S LAST FRAME IS THE RESTING CELL: the picture's frame and
    /// crop (the sheet's window onto it) where the page shows it at rest,
    /// the card untransformed and lit, the interface back — and clearing
    /// the sheet's layout from there moves nothing. On the way, no frame
    /// jumps.
    @Test func theMotionsLastFrameIsTheCellsRestingFrameAndCrop() throws {
        let (_, cell, window, _) = makeSession()
        defer { window.isHidden = true }
        let resting = try #require(cell.commentsSheetRestingPictureFrame)
        cell.setCommentsSheetLayout(Self.collapsed, sheetCornerRadius: 38, previewCornerRadius: 20)
        let shrunk = try #require(cell.commentsSheetPictureFrame)
        #expect(shrunk.height < resting.height - 100, "the media never shrank: \(shrunk) for \(resting)")

        var landing = CommentsSheetLanding(from: Self.collapsed, start: 0, duration: 0.35)
        var previous = shrunk
        var now: CFTimeInterval = 0
        var frames = 0
        while !landing.hasLanded, frames < 100 {
            now += Self.frame
            frames += 1
            cell.setCommentsSheetLayout(
                landing.advance(to: now, sheetRemaining: nil), sheetCornerRadius: 38, previewCornerRadius: 20
            )
            let shown = try #require(cell.commentsSheetPictureFrame)
            let step = max(
                abs(shown.minX - previous.minX), abs(shown.minY - previous.minY),
                abs(shown.maxX - previous.maxX), abs(shown.maxY - previous.maxY)
            )
            #expect(step < 60, "a jump of \(step) pt at frame \(frames)")
            previous = shown
        }
        let landed = try #require(cell.commentsSheetPictureFrame)
        let close = { (a: CGRect, b: CGRect) in
            abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5
                && abs(a.height - b.height) < 0.5
        }
        #expect(close(landed, resting), "landed on \(landed), the page rests on \(resting)")
        #expect(Self.isIdentity(cell.debugCommentsSheetCardTransform))
        #expect(cell.debugCommentsSheetCardAlpha == 1)
        #expect(cell.debugCommentsSheetInterfaceAlpha == 1)
        // A filling clip wears the screen's corners at rest, as the page does.
        #expect(abs(cell.commentsSheetPictureRadius - ScreenGeometry.cornerRadius(behind: cell)) < 0.5)

        cell.clearCommentsSheetLayout()
        let cleared = try #require(cell.commentsSheetRestingPictureFrame)
        #expect(close(cleared, landed), "clearing the layout moved the picture: \(landed) → \(cleared)")
        #expect(Self.isIdentity(cell.debugCommentsSheetCardTransform))
    }
}
