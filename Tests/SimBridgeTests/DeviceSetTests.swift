import Foundation
import Testing
@testable import SimBridge

@Suite struct DeviceSetTests {
    @Test func runtimeName() {
        #expect(DeviceSet.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-27-1") == "iOS 27.1")
        #expect(DeviceSet.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-11-0") == "watchOS 11.0")
    }

    @Test func parsesAndSortsBootedFirst() throws {
        let json = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.iOS-26-1":[
            {"udid":"A","name":"iPhone 16","state":"Shutdown","deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-16"}],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-1":[
            {"udid":"B","name":"iPhone 17 Pro","state":"Booted","deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"}]
        }}
        """
        let devices = try DeviceSet.parseList(Data(json.utf8))
        #expect(devices.map(\.udid) == ["B", "A"])
        #expect(devices[0].runtime == "iOS 27.1")
        #expect(devices[0].deviceType == "iPhone 17 Pro")
    }
}
