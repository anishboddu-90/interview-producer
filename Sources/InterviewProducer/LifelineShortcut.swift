import Foundation
import Carbon
import Observation

@MainActor @Observable final class LifelineShortcut {
    var status = "Shortcut not registered"
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var action: (() -> Void)?
    static let keyCodes: [String:UInt32] = ["A":0,"S":1,"D":2,"F":3,"H":4,"G":5,"Z":6,"X":7,"C":8,"V":9,"B":11,"Q":12,"W":13,"E":14,"R":15,"Y":16,"T":17,"O":31,"U":32,"I":34,"P":35,"L":37,"J":38,"K":40,"N":45,"M":46]
    func register(key: String,modifiers: String,enabled: Bool,action: @escaping () -> Void) {
        unregister(); self.action = action
        guard enabled else { status = "Global shortcut off; Next Question button remains available."; return }
        guard let code = Self.keyCodes[key] else { status = "Unsupported shortcut key"; return }
        var type = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let install = InstallEventHandler(GetApplicationEventTarget(),{ _,event,raw in
            guard let raw, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            guard read == noErr, id.signature == 0x514C4946, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let target = Unmanaged<LifelineShortcut>.fromOpaque(raw).takeUnretainedValue()
            Task { @MainActor in target.action?() }
            return noErr
        },1,&type,Unmanaged.passUnretained(self).toOpaque(),&handler)
        guard install == noErr else { status = "Global shortcut handler unavailable (\(install)); use Next Question."; return }
        var flags: UInt32 = 0
        if modifiers.contains("Control") { flags |= UInt32(controlKey) }
        if modifiers.contains("Option") { flags |= UInt32(optionKey) }
        if modifiers.contains("Shift") { flags |= UInt32(shiftKey) }
        if modifiers.contains("Command") { flags |= UInt32(cmdKey) }
        let result = RegisterEventHotKey(code,flags,EventHotKeyID(signature:0x514C4946,id:1),GetApplicationEventTarget(),OptionBits(kEventHotKeyExclusive),&hotKey)
        status = result == noErr ? "Global shortcut: \(modifiers)+\(key)" : "Shortcut unavailable or already in use (\(result)). Choose another combination; Next Question still works."
    }
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
