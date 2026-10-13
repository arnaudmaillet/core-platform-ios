import CoreNetworking
import CoreStorage
import Foundation

/// What Parental Supervision says (#417), in one place so tests pin it. The
/// teen is always told the truth: who supervises them, what that person can
/// see and set, and that ending it tells the other side (backend #848 sends
/// SUPERVISION_ENDED to the side that did not end it).
enum SupervisionCopy {
    static let header = "Parental Supervision"

    /// Under the supervision rows: what it is, from the viewer's side.
    static func footer(teen: Bool, linked: Bool, full: Bool) -> String {
        if teen {
            let room: String = full ? " You have two supervisors, the most allowed." : ""
            let what: String = "A parent or guardian can see your daily time in the app and set limits on your account."
            let always: String = "You always see who supervises you here, and either of you can end it at any time."
            return "\(what) \(always) It ends by itself when you turn 18.\(room)"
        }
        return linked
            ? "You see each teen's daily time in the app and set their limits. They always see that you supervise them, and either of you can end it."
            : "Supervise a teen aged 13 to 17: see their daily time in the app and set limits on their account. The teen always sees that you supervise them, and either of you can end it."
    }

    static func inviteRowTitle(teen: Bool) -> String { teen ? "Invite a Parent" : "Invite a Teen" }
    static let enterCodeTitle = "Enter an Invite Code"
    static let failedRow = "Couldn't load supervision. Tap to try again."

    /// The row's second line: which side the other person is on.
    static func roleText(_ supervision: Supervision) -> String {
        supervision.otherRole == .supervisor ? "Supervises you" : "You supervise"
    }

    /// "Since 3 Oct 2026".
    static func sinceText(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMy")
        return "Since \(formatter.string(from: date))"
    }

    // MARK: Invite

    static func inviteTitle(teen: Bool) -> String { teen ? "Invite a Parent" : "Invite a Teen" }

    static func inviteExplanation(teen: Bool) -> String {
        teen
            ? "Show this code to your parent or guardian, or send it. They enter it in Settings → Family and Teens on their account."
            : "Show this code to your teen, or send it. They enter it in Settings → Family and Teens on their account."
    }

    /// "Works once, until 14:05 tomorrow."
    static func expiryText(_ expiresAt: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = calendar.locale ?? .current
        time.setLocalizedDateFormatFromTemplate("jmm")
        let day: String
        if calendar.isDate(expiresAt, inSameDayAs: now) {
            day = "today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(expiresAt, inSameDayAs: tomorrow) {
            day = "tomorrow"
        } else {
            let date = DateFormatter()
            date.calendar = calendar
            date.timeZone = calendar.timeZone
            date.locale = calendar.locale ?? .current
            date.setLocalizedDateFormatFromTemplate("dMMM")
            day = "on \(date.string(from: expiresAt))"
        }
        return "Works once, until \(time.string(from: expiresAt)) \(day)."
    }

    /// What the share sheet sends: a line to read, the code and the link.
    static func shareText(_ invite: SupervisionInvite, teen: Bool) -> String {
        let ask = teen ? "I'd like you to supervise my account." : "I'd like to supervise your account."
        let link: String = invite.link.map { " or open \($0.absoluteString)" } ?? ""
        return "\(ask) In Settings → Family and Teens, enter the code \(invite.displayCode)\(link). It works once, for 24 hours."
    }

    // MARK: Accept

    static func acceptExplanation(teen: Bool) -> String {
        teen
            ? "Enter the code your parent or guardian shared. Once linked, they'll see your daily time in the app and can set limits on your account. You'll always see who supervises you, and you can end it at any time."
            : "Enter the code your teen shared. Once linked, you'll see their daily time in the app and can set limits on their account. They'll see that you supervise them, and either of you can end it."
    }

    static func linkedToast(_ supervision: Supervision) -> String { "Linked with \(supervision.handleText)" }

    // MARK: End

    static func endTitle(_ supervision: Supervision) -> String {
        supervision.otherRole == .supervisor ? "Stop supervision by \(supervision.handleText)?" : "Stop supervising \(supervision.handleText)?"
    }

    /// Honest about who is told: the backend notifies the other side (#848).
    static func endMessage(_ supervision: Supervision) -> String {
        supervision.otherRole == .supervisor
            ? "\(supervision.handleText) will be told. If no one else supervises you, the limits they set are lifted and your settings stay as they are."
            : "\(supervision.handleText) will be told. You'll no longer see their activity or set their limits."
    }

    static let endAction = "End Supervision"

    static func endedToast(_ supervision: Supervision) -> String {
        supervision.otherRole == .supervisor ? "Supervision by \(supervision.handleText) ended" : "Stopped supervising \(supervision.handleText)"
    }

    // MARK: Overview and limits

    static let screenTimeHeader = "Daily Time in the App"
    static let limitsHeader = "Limits"
    static let overviewFailedRow = "Couldn't load the activity. Tap to try again."

    /// Under the days: what the numbers are, honestly.
    static let screenTimeFooter = "Time in the app on all devices, counted only while a daily limit is set. Days without use aren't listed."

    static let noTimeYet = "No time counted in the last 7 days"

    /// "Today", "Yesterday", or "Mon 6 Oct" for a teen's local day.
    static func dayText(_ day: String, today: Date = Date(), calendar: Calendar = .current) -> String {
        let todayKey = ScreenTimeLedger.key(for: today, calendar: calendar)
        if day == todayKey { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           day == ScreenTimeLedger.key(for: yesterday, calendar: calendar) {
            return "Yesterday"
        }
        guard let date = BirthDate(iso: day)?.date(calendar: calendar) else { return day }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return formatter.string(from: date)
    }

    static func minutesText(_ minutes: Int) -> String {
        ScreenTimeLedger.durationText(TimeInterval(minutes * 60))
    }

    static func dailyLimitText(_ minutes: Int?) -> String {
        minutes.map { ScreenTimeLedger.durationText(TimeInterval($0 * 60)) } ?? "Off"
    }

    static func floorText(_ floor: AudienceFloor?) -> String {
        switch floor {
        case .followers: "Followers"
        case .mutuals: "Mutual Followers"
        case .noOne: "No One"
        case nil: "No Limit"
        }
    }

    static func onOff(_ on: Bool) -> String { on ? "On" : "Off" }

    /// The limits as rows: what each is, and its value.
    static func limitRows(_ limits: SupervisionLimits) -> [(title: String, value: String)] {
        [
            ("Daily Limit", dailyLimitText(limits.dailyMinutes)),
            ("Private Account", onOff(limits.privateAccount)),
            ("Who Can Message", floorText(limits.messages)),
            ("Who Can Comment", floorText(limits.comments)),
            ("Hidden from Search", onOff(limits.hiddenFromSearch)),
        ]
    }

    static let noLimits = "No limits set"

    /// Under the limits. `teen`: the viewer is the teen. `changedBy`: who
    /// made the last change, when known.
    static func limitsFooter(teen: Bool, teenName: String, changedBy: String?, changedAt: Date?) -> String {
        let rule: String = teen
            ? "Set by your supervisors. You can choose stricter settings, but not looser ones."
            : "\(teenName) can choose stricter settings, but not looser ones. Any other supervisor shares these limits: the last change applies."
        guard let changedAt else { return rule }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMMy")
        let when: String = formatter.string(from: changedAt)
        let who: String = changedBy.map { " by \($0)" } ?? ""
        return "\(rule) Last changed\(who) on \(when)."
    }

    static let editLimitsTitle = "Edit Limits"
    static let limitsSaved = "Limits saved"

    // MARK: Refusals

    /// A refusal or a failure, as a toast. `teen` is the viewer's side, nil
    /// while unread (a link opened cold): the words then fit either side.
    static func failureText(_ error: any Error, teen: Bool?, fallback: String) -> String {
        switch error as? SupervisionError {
        case .invalidCode: "This code isn't valid or has expired"
        case .ageDoesNotFit:
            switch teen {
            case true?: "Supervision is for accounts aged 13 to 17. Check your date of birth in Account"
            case false?: "Only an adult can supervise. Add or check your date of birth in Account"
            case nil: "Supervision links an adult with a teen aged 13 to 17. Check your date of birth in Account"
            }
        case .teenHasTwoSupervisors: teen == true ? "You already have two supervisors" : "This teen already has two supervisors"
        case .alreadyLinked: "Your accounts are already linked"
        case .notFound: "This supervision has already ended"
        case .ownCode: "This is your own code. Share it with the other person"
        case .tooManyAttempts: "Too many wrong codes. Try again in an hour"
        case .invalidLimit: "A daily limit is 15 minutes to 24 hours"
        case .transport, nil: FailureCopy.title(for: error, fallback: fallback)
        }
    }
}
