import CoreModels
import CoreNavigation
import DesignSystem
import LaunchArguments
import UIKit

// The compose item's "New message" sheet (#2411, the owner 2026-11-13).
extension ChatFeatureBuilder {
    /// The "New message" sheet over `inbox`, at its large detent: search
    /// people, the actions (New group, New channel, each behind its flag),
    /// then Friends, Recent and Suggested.
    func presentNewMessage(from inbox: UIViewController) {
        let model = NewMessageViewModel(
            catalog: catalog, viewer: repository, friends: friends, suggestions: connections,
            directory: people, showsNewGroup: groups != nil, showsNewChannel: channels != nil
        )
        let screen = NewMessageViewController(
            viewModel: model, imagePipeline: imagePipeline, avatars: connections, relations: relations
        )
        let sheet = UINavigationController(rootViewController: screen)
        sheet.modalPresentationStyle = .pageSheet
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.large()]
            presentation.selectedDetentIdentifier = .large
        }
        screen.onClose = { [weak sheet] in _ = sheet?.closePresentation() }
        model.onPick = { [weak sheet, weak inbox, self] target in
            openPicked(target, closing: sheet, under: inbox)
        }
        // New group (#2214): the member picker, pushed in the sheet.
        model.onNewGroup = { [weak sheet, self] in
            guard let sheet else { return }
            pushGroupCreation(in: sheet)
        }
        // New channel (#2230): the creation screen, pushed in the sheet;
        // Create closes it and pushes the channel's thread on the inbox.
        model.onNewChannel = { [weak sheet, self] in
            guard let sheet, let creation = makeChannelCreation(landing: .onTheStack, in: sheet) else { return }
            sheet.pushViewController(creation, animated: true)
        }
        inbox.present(sheet, animated: true)
        #if DEBUG
        // `-new-message-query <text>`: the field seeded once the sheet is up.
        if let text = LaunchArgument.newMessageQuery.value(), !text.hasPrefix("-") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak screen] in screen?.debugType(text) }
        }
        #endif
    }

    /// A person picked (#2411): the sheet goes and the thread is pushed on
    /// the inbox's stack IN THE SAME TURN — the existing thread, or a draft
    /// pushed at once on the identity and created underneath. Back from the
    /// thread lands on Messages, not on the sheet.
    ///
    /// ⚠️ Filmed on the iPhone 18 Pro simulator (iOS 27): UIKit holds the
    /// push until the sheet's close ends, so the inbox stands whole for about
    /// 0.35 s before the push — no blank frame. Pushing the thread unanimated
    /// UNDER the sheet instead let the sheet slide away over a thread whose
    /// transcript had not landed: its body stood blank for about 0.3 s.
    func openPicked(_ target: ConversationTarget, closing sheet: UINavigationController?, under inbox: UIViewController?) {
        guard let navigation = inbox?.navigationController else {
            // No stack under the sheet (a test): the route, once it is gone.
            let route: AppRoute = switch target {
            case .existing(let id): .conversation(id)
            case .draft(let peer, let name, let handle):
                .messageUser(peer, stub: ProfileIdentityStub(handle: handle, displayName: name))
            }
            if sheet?.closePresentation(completion: { [router] in router.route(to: route) }) != true {
                router.route(to: route)
            }
            return
        }
        let thread = makeConversationViewController(target: target)
        _ = sheet?.closePresentation()
        navigation.pushViewController(thread, animated: true)
    }
}
