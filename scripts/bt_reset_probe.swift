import IOBluetooth
import Foundation

let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
guard let dev = devices.first(where: { ($0.name ?? "").uppercased().contains("EDIFIER") }) else {
    print("[bt] EDIFIER not found"); exit(1)
}
print("[bt] found \(dev.name ?? "?") \(dev.addressString ?? "?") connected=\(dev.isConnected())")
let closeResult = dev.closeConnection()
print("[bt] closeConnection -> \(closeResult)")
Thread.sleep(forTimeInterval: 1.5)
print("[bt] after close connected=\(dev.isConnected())")
let openResult = dev.openConnection()
print("[bt] openConnection -> \(openResult)")
var reconnected = false
for i in 0..<24 {
    Thread.sleep(forTimeInterval: 0.5)
    if dev.isConnected() { print("[bt] reconnected after \(String(format: "%.1f", Double(i) * 0.5 + 0.5))s"); reconnected = true; break }
}
print("[bt] final connected=\(dev.isConnected()) reconnected=\(reconnected)")
