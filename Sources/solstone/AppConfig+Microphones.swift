import SolstoneCore

public extension AppConfig {
    func selectBestMicrophone(from available: [AudioInputDevice]) -> AudioInputDevice? {
        let availableUIDs = Set(available.map { $0.uid })

        for entry in microphonePriority {
            if availableUIDs.contains(entry.uid) {
                return available.first(where: { $0.uid == entry.uid })
            }
        }

        return nil
    }

    mutating func addMicrophone(_ device: AudioInputDevice) -> Bool {
        guard !microphonePriority.contains(where: { $0.uid == device.uid }) else {
            return false
        }
        microphonePriority.append(MicrophoneEntry(uid: device.uid, name: device.name))
        return true
    }
}
