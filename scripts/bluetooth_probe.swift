import IOBluetooth
import Foundation

let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
print("[bt] paired devices: \(devices.count)")
for d in devices {
    let name = d.name ?? "?"
    let addr = d.addressString ?? "?"
    print("[bt] \(name) \(addr) connected=\(d.isConnected())")
}
