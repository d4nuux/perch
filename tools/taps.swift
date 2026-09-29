// Dev tool: lists event taps owned by a process. Usage: swift tools/taps.swift $(pgrep -x Perch)
import CoreGraphics
let pid = pid_t(CommandLine.arguments[1])!
var n: UInt32 = 0
CGGetEventTapList(0, nil, &n)
var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(n))
CGGetEventTapList(n, &list, &n)
let mine = list.filter { $0.tappingProcess == pid }
for t in mine { print("tap enabled=\(t.enabled) mask=0x\(String(t.eventsOfInterest, radix: 16))") }
print("taps:", mine.count)
