import Foundation
import AppKit
import Carbon

@main struct ShortcutConflictTest {
    static func main() {
        if CommandLine.arguments.contains("--hold") {
            var ref: EventHotKeyRef?
            let code = RegisterEventHotKey(16,UInt32(controlKey|optionKey|shiftKey),EventHotKeyID(signature:0x49505453,id:99),GetApplicationEventTarget(),OptionBits(kEventHotKeyExclusive),&ref)
            print(code == noErr ? "READY" : "BLOCKED:\(code)"); fflush(stdout)
            guard code == noErr else { exit(2) }
            RunLoop.main.run(until:Date().addingTimeInterval(10))
            if let ref { UnregisterEventHotKey(ref) }; return
        }
        Task { @MainActor in
            let child = Process(); child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]); child.arguments = ["--hold"]
            let pipe = Pipe(); child.standardOutput = pipe
            do { try child.run() } catch { print("FAIL: could not launch isolated holder"); exit(1) }
            let ready = String(data:pipe.fileHandleForReading.availableData,encoding:.utf8) ?? ""
            guard ready.contains("READY") else { print("UNVERIFIED: the test combination is already unavailable: \(ready)"); child.terminate(); exit(2) }
            let shortcut = LifelineShortcut()
            shortcut.register(key:"Y",modifiers:"Control+Option+Shift",enabled:true) {}
            let blocked = shortcut.status.contains("unavailable")
            print("\(blocked ? "PASS" : "FAIL"): another process owns the combination; registration status is \(shortcut.status)")
            shortcut.unregister(); child.terminate()
            while child.isRunning { try? await Task.sleep(for:.milliseconds(20)) }
            shortcut.register(key:"Y",modifiers:"Control+Option+Shift",enabled:true) {}
            let available = shortcut.status.hasPrefix("Global shortcut:")
            print("\(available ? "PASS" : "FAIL"): after the holder exits, the same combination registers successfully")
            shortcut.unregister(); exit(blocked && available ? 0 : 1)
        }; dispatchMain()
    }
}
