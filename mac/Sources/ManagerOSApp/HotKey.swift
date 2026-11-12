import AppKit
import Carbon.HIToolbox

/// ⌃⌥⌘V from any app: the clipboard becomes a new topic. Carbon hot keys need no Accessibility permission.
/// ⌘⇧V is left to other apps, where it usually means "Paste and Match Style".
enum GlobalHotKey {
    private static var ref: EventHotKeyRef?

    static func install() {
        guard ref == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let m = AppModel.shared else { return }
                    m.pasteAsTopic()
                    m.openMain?()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            return noErr
        }, 1, &type, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D4F5321), id: 1) // "MOS!"
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}
